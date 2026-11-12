//! A tagged-pointer abstraction that allows size styles in laffy to be represented
//! in just 64 bits. Wrapped by types in the `dimension` and `grid` modules.
//!
//! Only 64-bit targets are supported. On those, upstream packs the tag, an `f32` value and a
//! `calc()` pointer into a single pointer-sized word. laffy stores the same bits in a
//! `packed struct(u64)`, so the tag values, bit tests and the in-memory representation are
//! identical to upstream:
//!
//!   - bits 0..8: the tag (the low 3 bits are shared with `calc()` pointers)
//!   - bits 32..64: the `f32` value (for variants that carry one)
//!   - for `calc()` variants the whole word is the pointer with the low 3 tag bits or'ed in
const std = @import("std");
const LengthPercentage = @import("dimension.zig").LengthPercentage;

comptime {
    if (@sizeOf(usize) != 8) {
        @compileError("laffy only supports targets with a pointer width of 64 bits");
    }
}

/// The low byte (8 bits)
const tag_mask: u64 = 0b11111111;
/// The low 3 bits
const calc_tag_mask: u64 = 0b111;

/// A resolver for `calc()` values that always returns `0.0`.
///
/// Pass this wherever an API takes `calc: anytype` and the caller does not support `calc()`
/// values (upstream code passes `|_, _| 0.0` in the same situations).
pub const NoCalc = struct {
    pub fn resolveCalcValue(_: NoCalc, _: *const anyopaque, _: f32) f32 {
        return 0.0;
    }
};

/// A resolver for `calc()` values that always returns a fixed value. Mostly useful in tests
/// (upstream tests commonly pass `|_, _| 42.42`).
pub const ConstCalc = struct {
    value: f32,

    pub fn resolveCalcValue(self: ConstCalc, _: *const anyopaque, _: f32) f32 {
        return self.value;
    }
};

/// A representation of a length as a compact 64-bit tagged pointer
pub const CompactLength = packed struct(u64) {
    /// The raw tagged word (see the file documentation for the layout)
    bits: u64,

    // Tag layout
    //
    // Tags are 8 bits. The low 3 bits are shared with pointer variants (such as `calc()`), which require
    // an 8-byte aligned pointer and so always have those bits clear. They are assigned as follows:
    //
    //   - Bit 0 (`non_pointer_bit`): set for every variant that is *not* a pointer. Pointer variants
    //     (`calc()`) have this bit clear, so `isPlainCalc()` is a single bit test.
    //   - Bit 1 (`keyword_bit`): set for every variant that is *not* a plain length, percentage or calc()
    //     value (i.e. everything that cannot be resolved to a length given only a percentage basis).
    //   - Bit 2 (`percentage_bit`): set for every variant whose resolved value depends on a percentage basis,
    //     including all `calc()` variants. `usesPercentage()` is a single bit test.
    //
    // Pointer variants are distinguished by bit 1: `calc()` is `0b100` and `fit-content(calc())` is `0b110`.
    // Any pointer variant's `tag()` includes address bits 3..7, so pointer variants must be tested with low-bit
    // masks (`isPlainCalc()`, `isFitContentCalc()`, `hasCalc()`) rather than as `switch` prongs.
    //
    // Within the keyword class, bit 3 (`sizing_keyword_bit`) is set for the CSS sizing keywords
    // (`min-content`, `max-content`, `fit-content`, `fit-content()`, `stretch`) and clear for `auto`,
    // `fr` and `content`. The remaining high bits distinguish variants within a class.

    /// Bit set for all non-pointer (i.e. not `calc()`) tags
    pub const non_pointer_bit: usize = 0b0001;
    /// Bit set for all tags that are not a plain length, percentage or calc() value
    pub const keyword_bit: usize = 0b0010;
    /// Bit set for all tags whose value depends on a percentage basis (including `calc()`)
    pub const percentage_bit: usize = 0b0100;
    /// Bit set (in addition to `keyword_bit`) for all CSS sizing keyword tags
    pub const sizing_keyword_bit: usize = 0b1000;

    /// The tag indicating a calc() value
    pub const calc_tag: usize = 0b0000_0100;
    /// The tag indicating a fit-content() value with a calc() limit
    pub const fit_content_calc_tag: usize = 0b0000_0110;
    /// The tag indicating a length value
    pub const length_tag: usize = 0b0000_0001;
    /// The tag indicating a percentage value
    pub const percent_tag: usize = 0b0000_0101;
    /// The tag indicating an auto value
    pub const auto_tag: usize = 0b0000_0011;
    /// The tag indicating an fr value
    pub const fr_tag: usize = 0b0001_0011;
    /// The tag indicating a content keyword value
    pub const content_tag: usize = 0b0010_0011;
    /// The tag indicating a min-content value
    pub const min_content_tag: usize = 0b0000_1011;
    /// The tag indicating a max-content value
    pub const max_content_tag: usize = 0b0001_1011;
    /// The tag indicating a fit-content value with px limit
    pub const fit_content_px_tag: usize = 0b0010_1011;
    /// The tag indicating a plain fit-content keyword value (no limit)
    pub const fit_content_keyword_tag: usize = 0b0011_1011;
    /// The tag indicating a stretch keyword value
    pub const stretch_tag: usize = 0b0100_1011;
    /// The tag indicating a fit-content value with percent limit
    pub const fit_content_percent_tag: usize = 0b0000_1111;

    // Inner constructors (upstream `CompactLengthInner`)

    /// Construct from a tag and pointer
    fn fromPtr(ptr: *const anyopaque, tag_value: usize) CompactLength {
        return .{ .bits = @as(u64, @intFromPtr(ptr)) | @as(u64, tag_value) };
    }

    /// Construct from a tag and numeric value
    fn fromVal(val: f32, tag_value: usize) CompactLength {
        const val_bits: u32 = @bitCast(val);
        return .{ .bits = (@as(u64, val_bits) << 32) | @as(u64, tag_value) };
    }

    /// Construct from only a tag
    fn fromTag(tag_value: usize) CompactLength {
        return .{ .bits = @as(u64, tag_value) };
    }

    /// Get the calc tag (low 3 bits)
    fn calcTag(self: CompactLength) usize {
        return @intCast(self.bits & calc_tag_mask);
    }

    // Constructors

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) CompactLength {
        return fromVal(val, length_tag);
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) CompactLength {
        return fromVal(val, percent_tag);
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    /// Panics if `ptr` is null or not 8-byte aligned (as upstream).
    pub fn calc(ptr: *const anyopaque) CompactLength {
        const addr = @intFromPtr(ptr);
        if (addr == 0) @panic("calc() pointer must not be null");
        if (addr & 0b111 != 0) @panic("calc() pointer must have its low 3 bits clear");
        return fromPtr(ptr, calc_tag);
    }

    /// A `fit-content(calc())` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation of the limit and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    /// Panics if `ptr` is null or not 8-byte aligned (as upstream).
    pub fn fitContentCalc(ptr: *const anyopaque) CompactLength {
        const addr = @intFromPtr(ptr);
        if (addr == 0) @panic("fit-content(calc()) pointer must not be null");
        if (addr & 0b111 != 0) @panic("fit-content(calc()) pointer must have its low 3 bits clear");
        return fromPtr(ptr, fit_content_calc_tag);
    }

    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes.
    pub const auto: CompactLength = fromTag(auto_tag);

    /// The dimension as a fraction of the total available grid space (`fr` units in CSS)
    /// Specified value is the numerator of the fraction. Denominator is the sum of all fraction specified in that grid dimension
    /// Spec: <https://www.w3.org/TR/css3-grid-layout/#fr-unit>
    pub fn fromFr(val: f32) CompactLength {
        return fromVal(val, fr_tag);
    }

    /// The size should be the "min-content" size.
    /// This is the smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    pub const min_content: CompactLength = fromTag(min_content_tag);

    /// The size should be the "max-content" size.
    /// This is the smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    pub const max_content: CompactLength = fromTag(max_content_tag);

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a LENGTH value passed to this function.
    ///
    /// The effect of this is that the item takes the size of `limit` clamped
    /// by the min-content and max-content sizes.
    pub fn fitContentPx(limit: f32) CompactLength {
        return fromVal(limit, fit_content_px_tag);
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a PERCENTAGE value passed to this function.
    ///
    /// The effect of this is that the item takes the size of `limit` clamped
    /// by the min-content and max-content sizes.
    pub fn fitContentPercent(limit: f32) CompactLength {
        return fromVal(limit, fit_content_percent_tag);
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, stretch))`
    /// where `stretch` is the "stretch-fit" size (the size the box would take if it filled the available space)
    pub const fit_content_keyword: CompactLength = fromTag(fit_content_keyword_tag);

    /// The size should be the "stretch-fit" size: the size the box would take
    /// if it filled the available space
    /// (<https://www.w3.org/TR/css-sizing-4/#stretch-fit-sizing>)
    pub const stretch: CompactLength = fromTag(stretch_tag);

    /// The size should be an automatic size based on the box's content
    /// (<https://www.w3.org/TR/css-flexbox-1/#valdef-flex-basis-content>)
    ///
    /// This keyword is only valid for `flex-basis`. In any other context it behaves as `auto`.
    pub const content: CompactLength = fromTag(content_tag);

    /// Zero length (upstream `TaffyZero::ZERO`)
    pub const zero: CompactLength = fromLength(0.0);

    /// Create a `fit-content(…)` value from a `LengthPercentage` limit (upstream `TaffyFitContent`)
    pub fn fitContent(lp: LengthPercentage) CompactLength {
        const value_ = lp.inner.value();
        switch (lp.inner.tag()) {
            length_tag => return fitContentPx(value_),
            percent_tag => return fitContentPercent(value_),
            else => {
                if (lp.inner.isPlainCalc()) return fitContentCalc(lp.inner.calcValue());
                unreachable;
            },
        }
    }

    // Accessors

    /// Get the primary tag
    pub fn tag(self: CompactLength) usize {
        return @intCast(self.bits & tag_mask);
    }

    /// Get the numeric value associated with the `CompactLength`
    /// (e.g. the pixel value for a LENGTH variant)
    pub fn value(self: CompactLength) f32 {
        return @bitCast(@as(u32, @truncate(self.bits >> 32)));
    }

    /// Get the calc pointer of the `CompactLength` (with the tag bits cleared)
    pub fn calcValue(self: CompactLength) *const anyopaque {
        return @ptrFromInt(@as(usize, @intCast(self.bits & ~calc_tag_mask)));
    }

    /// Returns true if the value is a plain calc() value (not a fit-content(calc()) value)
    pub fn isPlainCalc(self: CompactLength) bool {
        return self.calcTag() & (non_pointer_bit | keyword_bit) == 0;
    }

    /// Returns true if the value is a fit-content() value with a calc() limit
    pub fn isFitContentCalc(self: CompactLength) bool {
        return self.tag() & (non_pointer_bit | keyword_bit) == keyword_bit;
    }

    /// Returns true if the value holds a calc() pointer: either a plain calc() value or a
    /// fit-content() value with a calc() limit. `calcValue()` is valid for exactly these values.
    pub fn hasCalc(self: CompactLength) bool {
        return self.tag() & non_pointer_bit == 0;
    }

    /// Returns true if the value is 0 px (bitwise equal to `zero`, so `-0.0` is not zero)
    pub fn isZero(self: CompactLength) bool {
        return self == zero;
    }

    /// Returns true if the value is a length or percentage value
    pub fn isLengthOrPercentage(self: CompactLength) bool {
        return self.tag() & (non_pointer_bit | keyword_bit) == non_pointer_bit;
    }

    /// Returns true if the value is a length, a percentage or a plain `calc()` value (not a
    /// `fit-content(calc())` value): anything that resolves to a length given a percentage basis
    pub fn isLengthPercentageOrCalc(self: CompactLength) bool {
        return self.tag() & keyword_bit == 0;
    }

    /// Returns true if the value is auto
    pub fn isAuto(self: CompactLength) bool {
        return self.tag() == auto_tag;
    }

    /// Returns true if the value is the content keyword
    pub fn isContent(self: CompactLength) bool {
        return self.tag() == content_tag;
    }

    /// Returns true if the value is min-content
    pub fn isMinContent(self: CompactLength) bool {
        return self.tag() == min_content_tag;
    }

    /// Returns true if the value is max-content
    pub fn isMaxContent(self: CompactLength) bool {
        return self.tag() == max_content_tag;
    }

    /// Returns true if the value is a fit-content(...) value
    pub fn isFitContent(self: CompactLength) bool {
        const t = self.tag();
        return t == fit_content_px_tag or t == fit_content_percent_tag or self.isFitContentCalc();
    }

    /// Returns true if the value is min-content, max-content, fit-content, fit-content(...), or stretch
    pub fn isSizingKeyword(self: CompactLength) bool {
        const mask: usize = non_pointer_bit | keyword_bit | sizing_keyword_bit;
        return self.tag() & mask == mask or self.isFitContentCalc();
    }

    /// Returns true if the value is max-content or a fit-content(...) value
    pub fn isMaxOrFitContent(self: CompactLength) bool {
        const t = self.tag();
        return t == max_content_tag or t == fit_content_px_tag or t == fit_content_percent_tag or
            self.isFitContentCalc();
    }

    /// Returns true if the max track sizing function is `MaxContent`, `FitContent` or `Auto` else false.
    /// "In all cases, treat auto and fit-content() as max-content, except where specified otherwise for fit-content()."
    /// See: <https://www.w3.org/TR/css-grid-1/#algo-terms>
    pub fn isMaxContentAlike(self: CompactLength) bool {
        const t = self.tag();
        return t == auto_tag or t == max_content_tag or t == fit_content_px_tag or
            t == fit_content_percent_tag or self.isFitContentCalc();
    }

    /// Returns true if the min track sizing function is `MinContent` or `MaxContent`, else false.
    pub fn isMinOrMaxContent(self: CompactLength) bool {
        const t = self.tag();
        return t == min_content_tag or t == max_content_tag;
    }

    /// Returns true if the value is auto, min-content, max-content, or fit-content(...)
    pub fn isIntrinsic(self: CompactLength) bool {
        const t = self.tag();
        return t == auto_tag or t == min_content_tag or t == max_content_tag or
            t == fit_content_px_tag or t == fit_content_percent_tag or self.isFitContentCalc();
    }

    /// Returns true if the value is and fr value
    pub fn isFr(self: CompactLength) bool {
        return self.tag() == fr_tag;
    }

    /// Whether the track sizing functions depends on the size of the parent node
    pub fn usesPercentage(self: CompactLength) bool {
        return self.tag() & percentage_bit != 0;
    }

    /// Resolve percentage values against the passed parent_size, returning the value.
    /// Non-percentage values always return null.
    ///
    /// `calc` must provide `resolveCalcValue(ptr: *const anyopaque, basis: f32) f32`.
    pub fn resolvedPercentageSize(self: CompactLength, parent_size: f32, calc_resolver: anytype) ?f32 {
        if (self.tag() == percent_tag) return self.value() * parent_size;
        if (self.isPlainCalc()) return calc_resolver.resolveCalcValue(self.calcValue(), parent_size);
        return null;
    }
};

/// Converts an `Into<f64>`-style number (any int or float, or a comptime number) into an `f32`
/// the same way upstream does (`value.into() as f32`: via `f64`).
pub fn toF32(value: anytype) f32 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .comptime_float => @floatCast(@as(f64, value)),
        .comptime_int => @floatCast(@as(f64, @floatFromInt(value))),
        .float => @floatCast(@as(f64, @floatCast(value))),
        .int => @floatCast(@as(f64, @floatFromInt(value))),
        else => @compileError("expected a number, found " ++ @typeName(T)),
    };
}

const testing = std.testing;

fn fromRawTag(tag: usize) CompactLength {
    return CompactLength.fromTag(tag);
}

const non_percentage_tags = [_]usize{
    CompactLength.length_tag,
    CompactLength.auto_tag,
    CompactLength.fr_tag,
    CompactLength.min_content_tag,
    CompactLength.max_content_tag,
    CompactLength.fit_content_px_tag,
    CompactLength.fit_content_keyword_tag,
    CompactLength.stretch_tag,
    CompactLength.content_tag,
};
const percentage_tags = [_]usize{ CompactLength.percent_tag, CompactLength.fit_content_percent_tag };

test "tags are unique and fit in a byte" {
    const all = non_percentage_tags ++ percentage_tags ++ [_]usize{ CompactLength.calc_tag, CompactLength.fit_content_calc_tag };
    for (all, 0..) |a, i| {
        try testing.expect(a <= 0xFF);
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "non-pointer tags have non-pointer bit set" {
    for (non_percentage_tags ++ percentage_tags) |tag| {
        try testing.expect(tag & CompactLength.non_pointer_bit != 0);
    }
    try testing.expectEqual(@as(usize, 0), CompactLength.calc_tag & CompactLength.non_pointer_bit);
}

test "keyword bits match predicates" {
    for (non_percentage_tags ++ percentage_tags) |raw_tag| {
        const value = fromRawTag(raw_tag);
        const tag = value.tag();
        const is_plain = tag == CompactLength.length_tag or tag == CompactLength.percent_tag;
        try testing.expectEqual(is_plain, tag & CompactLength.keyword_bit == 0);
        try testing.expectEqual(is_plain, value.isLengthOrPercentage());
        const is_sizing_keyword = switch (tag) {
            CompactLength.min_content_tag,
            CompactLength.max_content_tag,
            CompactLength.fit_content_keyword_tag,
            CompactLength.fit_content_px_tag,
            CompactLength.fit_content_percent_tag,
            CompactLength.stretch_tag,
            => true,
            else => false,
        };
        try testing.expectEqual(is_sizing_keyword, value.isSizingKeyword());
    }
    try testing.expectEqual(@as(usize, 0), CompactLength.calc_tag & CompactLength.keyword_bit);
    try testing.expect(CompactLength.fit_content_calc_tag & CompactLength.keyword_bit != 0);
    try testing.expectEqual(@as(usize, 0), CompactLength.fit_content_calc_tag & CompactLength.non_pointer_bit);
    try testing.expect(CompactLength.fit_content_calc_tag & CompactLength.percentage_bit != 0);
}

test "percentage bit matches usesPercentage" {
    for (non_percentage_tags) |tag| try testing.expectEqual(@as(usize, 0), tag & CompactLength.percentage_bit);
    for (percentage_tags) |tag| try testing.expect(tag & CompactLength.percentage_bit != 0);
    try testing.expect(CompactLength.calc_tag & CompactLength.percentage_bit != 0);

    try testing.expect(!CompactLength.fromLength(10.0).usesPercentage());
    try testing.expect(!CompactLength.auto.usesPercentage());
    try testing.expect(!CompactLength.fromFr(1.0).usesPercentage());
    try testing.expect(!CompactLength.min_content.usesPercentage());
    try testing.expect(!CompactLength.max_content.usesPercentage());
    try testing.expect(!CompactLength.fitContentPx(10.0).usesPercentage());
    try testing.expect(!CompactLength.fit_content_keyword.usesPercentage());
    try testing.expect(!CompactLength.stretch.usesPercentage());
    try testing.expect(!CompactLength.content.usesPercentage());
    try testing.expect(CompactLength.fromPercent(0.5).usesPercentage());
    try testing.expect(CompactLength.fitContentPercent(0.5).usesPercentage());
}

test "fit-content(calc()) round trips pointer" {
    const boxed = try testing.allocator.create(u64);
    defer testing.allocator.destroy(boxed);
    boxed.* = 0;
    const ptr: *const anyopaque = boxed;
    const value = CompactLength.fitContentCalc(ptr);
    try testing.expect(value.isFitContentCalc());
    try testing.expect(value.hasCalc());
    try testing.expect(!value.isPlainCalc());
    try testing.expect(value.isFitContent());
    try testing.expect(value.isSizingKeyword());
    try testing.expect(value.isIntrinsic());
    try testing.expect(value.isMaxOrFitContent());
    try testing.expect(value.isMaxContentAlike());
    try testing.expect(value.usesPercentage());
    try testing.expect(!value.isLengthOrPercentage());
    try testing.expectEqual(ptr, value.calcValue());

    const calc_value = CompactLength.calc(ptr);
    try testing.expect(calc_value.isPlainCalc());
    try testing.expect(calc_value.hasCalc());
    try testing.expect(!calc_value.isFitContentCalc());
    try testing.expect(!calc_value.isFitContent());
    try testing.expect(!calc_value.isSizingKeyword());
}

test "calc round trips pointer" {
    const boxed = try testing.allocator.create(u64);
    defer testing.allocator.destroy(boxed);
    boxed.* = 42;
    const ptr: *const anyopaque = boxed;
    const value = CompactLength.calc(ptr);
    try testing.expect(value.isPlainCalc());
    try testing.expect(value.usesPercentage());
    try testing.expect(!value.isLengthOrPercentage());
    try testing.expect(!value.isAuto());
    try testing.expect(!value.isIntrinsic());
    try testing.expectEqual(ptr, value.calcValue());
}

test "value round trips and isZero" {
    try testing.expectEqual(@as(f32, 12.5), CompactLength.fromLength(12.5).value());
    try testing.expectEqual(@as(f32, -0.25), CompactLength.fromPercent(-0.25).value());
    try testing.expect(CompactLength.zero.isZero());
    try testing.expect(!CompactLength.fromLength(-0.0).isZero());
    try testing.expectEqual(@as(?f32, 5.0), CompactLength.fromPercent(0.5).resolvedPercentageSize(10.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, null), CompactLength.fromLength(0.5).resolvedPercentageSize(10.0, NoCalc{}));
}
