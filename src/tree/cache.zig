//! A cache for storing the results of layout computation
//!
//! The final-layout entry owns a `LayoutOutput`, whose out-of-flow candidate list is heap
//! allocated. `get`, `store`, `clear` and `deinit` therefore take the allocator that the stored
//! outputs were allocated with (the tree's allocator).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Size = @import("../geometry.zig").Size;
const AvailableSpace = @import("../style.zig").AvailableSpace;
const layout = @import("layout.zig");
const CollapsibleMarginSet = layout.CollapsibleMarginSet;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const RunMode = layout.RunMode;
const SizingMode = layout.SizingMode;
const RequestedAxis = layout.RequestedAxis;

/// The number of cache entries for each node in the tree
const cache_size: usize = 9;

/// `f32` infinity as a u32
const infinity_bits: u32 = 0b0_11111111_00000000000000000000000;
/// `f32` negative infinity as a u32
const neg_infinity_bits: u32 = 0b1_11111111_00000000000000000000000;

// The `CacheKey` encodes two f32s as a u64. We know that the f32s will always be
// non-negative, so we pack two extra bits encoding the `RequestedAxis` into the
// sign bits of the f32s. These constants help to encode and decode those bits.

/// The sign bit of the first f32
const sign_bit_1: u64 = 1 << 63;
/// The sign bit of the second f32
const sign_bit_2: u64 = 1 << 31;
/// Mask of both sign bits (used to compute non_sign_bits_mask)
const both_sign_bits_mask: u64 = sign_bit_1 | sign_bit_2;
/// Mask of excluding the sign bits (used when setting/getting the size excluding the packed bits)
const non_sign_bits_mask: u64 = ~both_sign_bits_mask;

/// Mask which includes only the bits which encode the x-axis value that we can use to ignore the
/// y-axis value when comparing a cache key.
const x_axis_value_mask: u64 = @as(u64, std.math.maxInt(u32)) << 32;

/// Pack `?f32` into `u32`
inline fn optionCacheKey(input: ?f32) u32 {
    return if (input) |value| @bitCast(value) else infinity_bits;
}

/// Pack `Size(?f32)` into `u64`
inline fn sizeOptionCacheKey(input: Size(?f32)) u64 {
    return @as(u64, optionCacheKey(input.width)) << 32 | @as(u64, optionCacheKey(input.height));
}

/// Pack `AvailableSpace` into `u32`
inline fn availableSpaceCacheKey(input: AvailableSpace) u32 {
    return switch (input) {
        .definite => |value| @bitCast(-value),
        .min_content => neg_infinity_bits,
        .max_content => infinity_bits,
    };
}

/// Encodes combination of a `known_dimension` (`?f32`) and `AvailableSpace` in
/// a single dimension into a cache key in a single dimension.
inline fn mixedCacheKey(kd: ?f32, avs: AvailableSpace) u32 {
    return if (kd) |value| @bitCast(value) else availableSpaceCacheKey(avs);
}

/// Encodes combination of a `known_dimension` (`?f32`) and `AvailableSpace` in
/// two dimensions into a cache key in a single dimension.
inline fn sizeMixedCacheKey(kd: Size(?f32), avs: Size(AvailableSpace)) u64 {
    return @as(u64, mixedCacheKey(kd.width, avs.width)) << 32 | @as(u64, mixedCacheKey(kd.height, avs.height));
}

/// Space-optimised cache key that packs bits into as small a size as possible
const CacheKey = struct {
    /// The initial cached size of the node itself
    kd_available_space: u64,
    /// The initial cached size of the parent's node
    parent_size: u64,
    /// Whether each known dimension is definite. Normalized such that an axis
    /// without a known dimension is always `true`.
    known_dimensions_are_definite: Size(bool),

    /// Return the parent size with the extra bits that encode the requested axis masked out
    fn parentSize(self: CacheKey) u64 {
        return self.parent_size & non_sign_bits_mask;
    }

    /// Return the parent size with the extra bits that encode the requested axis masked out
    /// And the y-axis value masked out
    fn xAxisParentSize(self: CacheKey) u64 {
        return self.parent_size & (x_axis_value_mask & non_sign_bits_mask);
    }

    /// Return the bits that encode the requested axis
    fn requestedAxisBits(self: CacheKey) u64 {
        return self.parent_size & both_sign_bits_mask;
    }

    /// Whether a cached entry with this key contains a valid size for the axis requested by `other`.
    /// Sizes computed for a single axis may contain garbage values in the other axis, so an entry
    /// is only usable if it was computed for the same axis (or for both axes).
    fn sizeIsValidFor(self: CacheKey, other: CacheKey) bool {
        const entry_axis = self.requestedAxisBits();
        return entry_axis == both_sign_bits_mask or entry_axis == other.requestedAxisBits();
    }

    fn eql(self: CacheKey, other: CacheKey) bool {
        return self.kd_available_space == other.kd_available_space and
            self.parent_size == other.parent_size and
            std.meta.eql(self.known_dimensions_are_definite, other.known_dimensions_are_definite);
    }

    /// Upstream `From<&LayoutInput> for CacheKey`
    fn fromInput(input: *const LayoutInput) CacheKey {
        // Pack axis enum into spare bits in the known_dimensions and available_space values
        const extra_bits: u64 = switch (input.axis) {
            .horizontal => sign_bit_1,
            .vertical => sign_bit_2,
            .both => sign_bit_1 | sign_bit_2,
        };

        return .{
            .kd_available_space = sizeMixedCacheKey(input.known_dimensions, input.available_space),
            .parent_size = (sizeOptionCacheKey(input.parent_size) & non_sign_bits_mask) | extra_bits,
            .known_dimensions_are_definite = .{
                .width = input.known_dimensions_are_definite.width or input.known_dimensions.width == null,
                .height = input.known_dimensions_are_definite.height or input.known_dimensions.height == null,
            },
        };
    }
};

/// The layout inputs that affect a node's layout but are not part of the `CacheKey`: the
/// `SizingMode` and whether each of the node's vertical margins is collapsible, packed into a `u8`.
///
/// These are determined by the layout algorithm of the node's parent and by the node's own style,
/// so they only change for a given node when one of those changes. Rather than keying every entry
/// on them, a `Cache` records the single mode that all of its entries were computed with.
const CacheMode = struct {
    inner: u8,

    /// Set if the sizing mode is `SizingMode.inherent_size`
    const inherent_size_bit: u8 = 0b001;
    /// Set if the node's top margin is collapsible
    const collapsible_start_margin_bit: u8 = 0b010;
    /// Set if the node's bottom margin is collapsible
    const collapsible_end_margin_bit: u8 = 0b100;

    /// The mode of a cache that has never been stored to. Which mode this is does not matter,
    /// as such a cache has no entries.
    const initial: CacheMode = .{ .inner = 0 };

    /// Upstream `From<&LayoutInput> for CacheMode`
    inline fn fromInput(input: *const LayoutInput) CacheMode {
        const inherent_size: u8 = @intFromBool(input.sizing_mode == .inherent_size);
        const collapsible = input.vertical_margins_are_collapsible;
        return .{ .inner = (inherent_size * inherent_size_bit) |
            (@as(u8, @intFromBool(collapsible.start)) * collapsible_start_margin_bit) |
            (@as(u8, @intFromBool(collapsible.end)) * collapsible_end_margin_bit) };
    }
};

/// Cached intermediate layout results
fn CacheEntry(comptime T: type) type {
    return struct {
        /// The key for the cache entry
        key: CacheKey,
        /// The cached size and baselines of the item
        content: T,
    };
}

/// A cache for caching the results of a sizing a Grid Item or Flexbox Item
pub const Cache = struct {
    /// The cache entry for the node's final layout (owns its `LayoutOutput`)
    final_layout_entry: ?CacheEntry(LayoutOutput) = null,
    /// The cache entries for the node's preliminary size measurements
    measure_entries: [cache_size]?CacheEntry(Size(f32)) = @splat(null),
    /// Tracks which measure entries have been used since the eviction cursor last passed them
    recently_used_entries: u16 = 0,
    /// The next measure entry to consider replacing
    next_measure_entry: u8 = 0,
    /// Tracks if all cache entries are empty
    is_empty: bool = true,
    /// The `sizing_mode` and `vertical_margins_are_collapsible` inputs that all of the cache's
    /// entries were computed with. Results are only retrieved for inputs that have the same mode,
    /// and storing a result that was computed with a different mode drops the existing entries.
    mode: CacheMode = CacheMode.initial,

    /// Free the memory owned by the cache's entries
    pub fn deinit(self: *Cache, gpa: Allocator) void {
        if (self.final_layout_entry) |*entry| entry.content.deinit(gpa);
        self.* = .{};
    }

    /// Try to retrieve a cached result from the cache.
    ///
    /// The returned output is a copy owned by the caller (see `LayoutOutput.deinit`).
    pub fn get(self: *Cache, gpa: Allocator, input: *const LayoutInput) LayoutError!?LayoutOutput {
        if (self.mode.inner != CacheMode.fromInput(input).inner) {
            return null;
        }
        const key = CacheKey.fromInput(input);
        switch (input.run_mode) {
            .perform_layout => {
                if (self.final_layout_entry) |*entry| {
                    if (entry.key.eql(key)) return try entry.content.clone(gpa);
                }
                return null;
            },
            .compute_size => {
                for (&self.measure_entries, 0..) |*maybe_entry, index| {
                    const entry = maybe_entry.* orelse continue;
                    if (entry.key.kd_available_space == key.kd_available_space and
                        std.meta.eql(entry.key.known_dimensions_are_definite, key.known_dimensions_are_definite) and
                        (entry.key.xAxisParentSize() == key.xAxisParentSize()) and
                        entry.key.sizeIsValidFor(key))
                    {
                        self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                        return LayoutOutput.fromOuterSize(entry.content);
                    }
                }

                return null;
            },
            .perform_hidden_layout => return null,
        }
    }

    /// Store a computed size in the cache. The cache takes ownership of `layout_output` (it is
    /// freed with `gpa` when it is replaced or discarded).
    pub fn store(self: *Cache, gpa: Allocator, input: *const LayoutInput, layout_output: LayoutOutput) void {
        var output = layout_output;
        if (input.run_mode == .perform_hidden_layout) {
            output.deinit(gpa);
            return;
        }
        const mode = CacheMode.fromInput(input);
        if (self.mode.inner != mode.inner) {
            _ = self.clear(gpa);
            self.mode = mode;
        }
        const key = CacheKey.fromInput(input);
        switch (input.run_mode) {
            .perform_layout => {
                self.is_empty = false;
                if (self.final_layout_entry) |*entry| entry.content.deinit(gpa);
                self.final_layout_entry = .{ .key = key, .content = output };
            },
            .compute_size => {
                // Only the size is stored
                defer output.deinit(gpa);
                // Measure entries only store the size, and cache hits are reconstructed with
                // `LayoutOutput.fromOuterSize`, which resets the margin-collapse metadata
                // (`top_margin`, `bottom_margin`, `margins_can_collapse_through`). Results that
                // carry such metadata cannot be reconstructed from their size, so don't cache them.
                if (output.margins_can_collapse_through or
                    !output.top_margin.eql(CollapsibleMarginSet.zero) or
                    !output.bottom_margin.eql(CollapsibleMarginSet.zero))
                {
                    return;
                }
                self.is_empty = false;
                for (&self.measure_entries, 0..) |*maybe_entry, index| {
                    if (maybe_entry.*) |*entry| {
                        if (entry.key.eql(key)) {
                            entry.content = output.size;
                            self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                            return;
                        }
                    }
                }
                while (self.recently_used_entries & (@as(u16, 1) << @intCast(self.next_measure_entry)) != 0) {
                    self.recently_used_entries &= ~(@as(u16, 1) << @intCast(self.next_measure_entry));
                    self.next_measure_entry += 1;
                    if (self.next_measure_entry == cache_size) {
                        self.next_measure_entry = 0;
                    }
                }
                const entry_index: usize = self.next_measure_entry;
                self.measure_entries[entry_index] = .{ .key = key, .content = output.size };
                self.recently_used_entries |= @as(u16, 1) << @intCast(entry_index);
                self.next_measure_entry += 1;
                if (self.next_measure_entry == cache_size) {
                    self.next_measure_entry = 0;
                }
            },
            .perform_hidden_layout => {},
        }
    }

    /// Clear all cache entries and reports clear operation outcome (`ClearState`)
    pub fn clear(self: *Cache, gpa: Allocator) ClearState {
        if (self.is_empty) {
            return .already_empty;
        }
        self.is_empty = true;
        if (self.final_layout_entry) |*entry| entry.content.deinit(gpa);
        self.final_layout_entry = null;
        self.measure_entries = @splat(null);
        self.recently_used_entries = 0;
        self.next_measure_entry = 0;
        return .cleared;
    }

    /// Returns true if all cache entries are null, else false
    pub fn isEmpty(self: *const Cache) bool {
        if (self.final_layout_entry != null) return false;
        for (self.measure_entries) |entry| {
            if (entry != null) return false;
        }
        return true;
    }
};

/// Clear operation outcome. See `Cache.clear`
pub const ClearState = enum {
    /// Cleared some values
    cleared,
    /// Everything was already cleared
    already_empty,
};

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Line = @import("../geometry.zig").Line;

fn testInput(width: f32) LayoutInput {
    return .{
        .run_mode = .compute_size,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = width, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = Size(?f32).none,
        .available_space = .{ .width = .max_content, .height = .max_content },
        .vertical_margins_are_collapsible = Line(bool).false,
    };
}

fn testOutput(width: f32) LayoutOutput {
    return LayoutOutput.fromOuterSize(.{ .width = width, .height = width });
}

/// Assert that `cache.get(in)` returns `expected` (or nothing)
fn expectGet(cache: *Cache, in: LayoutInput, expected: ?LayoutOutput) !void {
    var result = try cache.get(testing.allocator, &in);
    defer if (result) |*r| r.deinit(testing.allocator);
    if (expected) |e| {
        try testing.expect(result != null);
        try testing.expect(result.?.eql(&e));
    } else {
        try testing.expect(result == null);
    }
}

fn countMeasureEntries(cache: *const Cache) usize {
    var count: usize = 0;
    for (cache.measure_entries) |entry| {
        if (entry != null) count += 1;
    }
    return count;
}

test "recently used measure entries get a second chance" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    for (0..cache_size) |width| {
        cache.store(testing.allocator, &testInput(@floatFromInt(width)), testOutput(@floatFromInt(width)));
    }
    cache.store(testing.allocator, &testInput(@floatFromInt(cache_size)), testOutput(@floatFromInt(cache_size)));

    try expectGet(&cache, testInput(1.0), testOutput(1.0));
    cache.store(testing.allocator, &testInput(@floatFromInt(cache_size + 1)), testOutput(@floatFromInt(cache_size + 1)));

    try expectGet(&cache, testInput(1.0), testOutput(1.0));
    try expectGet(&cache, testInput(2.0), null);
}

test "storing an existing measurement updates it in place" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    cache.store(testing.allocator, &testInput(1.0), testOutput(1.0));
    cache.store(testing.allocator, &testInput(2.0), testOutput(2.0));
    cache.store(testing.allocator, &testInput(1.0), testOutput(3.0));

    try testing.expectEqual(@as(usize, 2), countMeasureEntries(&cache));
    try expectGet(&cache, testInput(1.0), testOutput(3.0));
}

test "measurements with margin collapse metadata are not cached" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);

    var collapse_through = testOutput(1.0);
    collapse_through.margins_can_collapse_through = true;
    cache.store(testing.allocator, &testInput(1.0), collapse_through);
    try expectGet(&cache, testInput(1.0), null);

    var carried_margin = testOutput(2.0);
    carried_margin.top_margin = CollapsibleMarginSet.fromMargin(10.0);
    cache.store(testing.allocator, &testInput(2.0), carried_margin);
    try expectGet(&cache, testInput(2.0), null);
}

test "retrieving a measurement only marks its slot as used" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    cache.store(testing.allocator, &testInput(1.0), testOutput(1.0));
    cache.store(testing.allocator, &testInput(2.0), testOutput(2.0));
    cache.recently_used_entries = 0;
    const entries = cache.measure_entries;

    try expectGet(&cache, testInput(1.0), testOutput(1.0));
    try testing.expect(std.meta.eql(cache.measure_entries, entries));
    try testing.expect(cache.recently_used_entries != 0);
}

fn performLayoutInput(width: f32, height: f32) LayoutInput {
    var result = testInput(width);
    result.run_mode = .perform_layout;
    result.known_dimensions = .{ .width = width, .height = height };
    result.parent_size = .{ .width = width, .height = height };
    return result;
}

/// Inputs that differ from `input`/`performLayoutInput` only in their mode
fn otherModes(base: LayoutInput) [4]LayoutInput {
    var result: [4]LayoutInput = @splat(base);
    result[0].sizing_mode = .content_size;
    result[1].vertical_margins_are_collapsible = Line(bool).true;
    result[2].vertical_margins_are_collapsible = .{ .start = true, .end = false };
    result[3].vertical_margins_are_collapsible = .{ .start = false, .end = true };
    return result;
}

test "cache mode distinguishes every combination of inputs" {
    var modes: [8]CacheMode = @splat(CacheMode.initial);
    for (&modes, 0..) |*mode, index| {
        var in = testInput(1.0);
        in.sizing_mode = if (index & 1 == 0) .content_size else .inherent_size;
        in.vertical_margins_are_collapsible = .{ .start = index & 2 != 0, .end = index & 4 != 0 };
        mode.* = CacheMode.fromInput(&in);
    }
    for (modes, 0..) |mode, index| {
        for (modes[0..index]) |earlier| {
            try testing.expect(earlier.inner != mode.inner);
        }
    }
}

test "retrieving with a different mode misses and keeps the entries" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    cache.store(testing.allocator, &performLayoutInput(100.0, 50.0), testOutput(1.0));
    cache.store(testing.allocator, &testInput(1.0), testOutput(2.0));

    for (otherModes(performLayoutInput(100.0, 50.0))) |other| {
        try expectGet(&cache, other, null);
    }
    for (otherModes(testInput(1.0))) |other| {
        try expectGet(&cache, other, null);
    }

    try expectGet(&cache, performLayoutInput(100.0, 50.0), testOutput(1.0));
    try expectGet(&cache, testInput(1.0), testOutput(2.0));
}

test "storing with a different mode drops the existing entries" {
    for (otherModes(testInput(3.0))) |other| {
        var cache: Cache = .{};
        defer cache.deinit(testing.allocator);
        cache.store(testing.allocator, &performLayoutInput(100.0, 50.0), testOutput(1.0));
        cache.store(testing.allocator, &testInput(1.0), testOutput(2.0));

        cache.store(testing.allocator, &other, testOutput(3.0));
        try expectGet(&cache, other, testOutput(3.0));
        try testing.expect(cache.final_layout_entry == null);
        try testing.expectEqual(@as(usize, 1), countMeasureEntries(&cache));

        // The old entries are gone, even for inputs that have the mode that the cache had before
        cache.store(testing.allocator, &testInput(4.0), testOutput(4.0));
        try expectGet(&cache, performLayoutInput(100.0, 50.0), null);
        try expectGet(&cache, testInput(1.0), null);
        try expectGet(&cache, other, null);
        try expectGet(&cache, testInput(4.0), testOutput(4.0));
    }

    for (otherModes(performLayoutInput(100.0, 50.0))) |other| {
        var cache: Cache = .{};
        defer cache.deinit(testing.allocator);
        cache.store(testing.allocator, &performLayoutInput(100.0, 50.0), testOutput(1.0));
        cache.store(testing.allocator, &testInput(1.0), testOutput(2.0));

        cache.store(testing.allocator, &other, testOutput(3.0));
        try expectGet(&cache, other, testOutput(3.0));
        try testing.expectEqual(@as(usize, 0), countMeasureEntries(&cache));
        try expectGet(&cache, performLayoutInput(100.0, 50.0), null);
    }
}

test "hidden layouts do not affect the cache" {
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    cache.store(testing.allocator, &testInput(1.0), testOutput(1.0));
    cache.store(testing.allocator, &LayoutInput.hidden, testOutput(2.0));
    try expectGet(&cache, testInput(1.0), testOutput(1.0));
}

test "final layout entries own their out-of-flow candidates" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var out = testOutput(5.0);
    try out.oof_candidates.push(gpa, .{
        .node = @import("node.zig").NodeId.new(7),
        .order = 1,
        .position = .fixed,
        .static_position = .{
            .x = layout.AxisStaticPosition.fromEdge(0.0, .start),
            .y = layout.AxisStaticPosition.fromEdge(0.0, .start),
        },
    });
    cache.store(gpa, &performLayoutInput(5.0, 5.0), out);
    // Replacing the entry frees the previous output
    var out2 = try out.clone(gpa);
    out2.size.width = 6.0;
    cache.store(gpa, &performLayoutInput(5.0, 5.0), out2);
    var got = (try cache.get(gpa, &performLayoutInput(5.0, 5.0))).?;
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), got.oof_candidates.asSlice().len);
    try testing.expectEqual(@as(f32, 6.0), got.size.width);
    try testing.expectEqual(ClearState.cleared, cache.clear(gpa));
    try testing.expectEqual(ClearState.already_empty, cache.clear(gpa));
    try testing.expect(cache.isEmpty());
}
