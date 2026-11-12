//! Implements the track sizing algorithm
//! <https://www.w3.org/TR/css-grid-1/#layout-algorithm>
//!
//! Upstream passes closures for the track predicates, distribution proportions and limits of the
//! space distribution helpers. laffy passes small structs with a `call(self, *const GridTrack)`
//! method instead (see the "Track predicates and properties" section).
const std = @import("std");
const geometry = @import("../../geometry.zig");
const AbstractAxis = geometry.AbstractAxis;
const Line = geometry.Line;
const Size = geometry.Size;
const style_mod = @import("../../style.zig");
const AlignContent = style_mod.AlignContent;
const AvailableSpace = style_mod.AvailableSpace;
const CompactLength = style_mod.CompactLength;
const LayoutError = @import("../../tree/layout.zig").LayoutError;
const traits = @import("../../tree/traits.zig");
const Scratch = @import("../../util/scratch.zig");
const math = @import("../../util/math.zig");
const maybeMin = math.maybeMin;
const resolveOrZero = @import("../../util/resolve.zig").resolveOrZero;
const sys = @import("../../util/sys.zig");
const FrontBackVecBuilder = @import("../../util/front_back_vec_builder.zig").FrontBackVecBuilder;
const childFirstBaseline = @import("../common/alignment.zig").childFirstBaseline;
const types = @import("types.zig");
const GridItem = types.GridItem;
const GridTrack = types.GridTrack;
const TrackCounts = types.TrackCounts;
const TrackSizeEstimate = types.TrackSizeEstimate;

const inf = std.math.inf(f32);

/// The sort key of `value` under `f32::total_cmp` (the total order of IEEE 754)
fn totalCmpKey(value: f32) i32 {
    var bits: i32 = @bitCast(value);
    bits ^= @as(i32, @bitCast(@as(u32, @bitCast(bits >> 31)) >> 1));
    return bits;
}

/// `iter.max_by(|a, b| a.total_cmp(b))`: keeps the last maximum element
const TotalCmpMax = struct {
    best: ?f32 = null,

    fn add(self: *TotalCmpMax, value: f32) void {
        if (self.best) |best| {
            if (totalCmpKey(value) >= totalCmpKey(best)) self.best = value;
        } else {
            self.best = value;
        }
    }
};

/// `iter.min_by(|a, b| a.total_cmp(b))`: keeps the first minimum element
const TotalCmpMin = struct {
    best: ?f32 = null,

    fn add(self: *TotalCmpMin, value: f32) void {
        if (self.best) |best| {
            if (totalCmpKey(value) < totalCmpKey(best)) self.best = value;
        } else {
            self.best = value;
        }
    }
};

/// Takes an axis, and a list of grid items sorted firstly by whether they cross a flex track
/// in the specified axis (items that don't cross a flex track first) and then by the number
/// of tracks they cross in specified axis (ascending order).
///
/// The list holds pointers so that the `GridItem`s themselves stay in document order and
/// only the (pointer-sized) references are sorted.
const ItemBatcher = struct {
    /// The axis in which the ItemBatcher is operating. Used when querying properties from items.
    axis: AbstractAxis,
    /// The starting index of the current batch
    index_offset: usize,
    /// The span of the items in the current batch
    current_span: u16,
    /// Whether the current batch of items cross a flexible track
    current_is_flex: bool,

    /// Create a new ItemBatcher for the specified axis
    fn new(axis: AbstractAxis) ItemBatcher {
        return .{ .index_offset = 0, .axis = axis, .current_span = 1, .current_is_flex = false };
    }

    const Batch = struct { []*GridItem, bool };

    /// This is basically a manual version of Iterator::next which passes `items`
    /// in as a parameter on each iteration
    fn next(self: *ItemBatcher, items: []*GridItem) ?Batch {
        if (self.current_is_flex or self.index_offset >= items.len) {
            return null;
        }

        const item = items[self.index_offset];
        self.current_span = item.span(self.axis);
        self.current_is_flex = item.crossesFlexibleTrack(self.axis);

        const next_index_offset = if (self.current_is_flex) items.len else blk: {
            for (items, 0..) |candidate, index| {
                if (candidate.crossesFlexibleTrack(self.axis) or candidate.span(self.axis) > self.current_span) break :blk index;
            }
            break :blk items.len;
        };

        const batch = items[self.index_offset..next_index_offset];
        self.index_offset = next_index_offset;

        return .{ batch, self.current_is_flex };
    }
};

/// This struct captures a bunch of variables which are used to compute the intrinsic sizes of children so that those variables
/// don't have to be passed around all over the place below. It then has methods that implement the intrinsic sizing computations
fn IntrinsicSizeMeasurer(comptime Tree: type) type {
    return struct {
        const Self = @This();

        /// The layout tree
        tree: Tree,
        /// The tracks in the opposite axis to the one we are currently sizing
        other_axis_tracks: []const GridTrack,
        /// How to estimate an other-axis track's size, which is passed to the child size measurement functions
        get_track_size_estimate: TrackSizeEstimate,
        /// The axis we are currently sizing
        axis: AbstractAxis,
        /// The available grid space
        inner_node_size: Size(?f32),

        /// Compute the available_space to be passed to the child sizing functions
        /// These are estimates based on either the max track sizing function or the provisional base size in the opposite
        /// axis to the one currently being sized.
        /// https://www.w3.org/TR/css-grid-1/#algo-overview
        fn gridAreaSize(self: *const Self, item: *GridItem, axis_tracks: []const GridTrack) Size(?f32) {
            return item.gridAreaSizeCached(self.axis, axis_tracks, self.other_axis_tracks, self.inner_node_size, self.get_track_size_estimate, self.tree);
        }

        /// Compute the item's resolved margins for size contributions. Horizontal percentage margins always resolve
        /// to zero if the container size is indefinite as otherwise this would introduce a cyclic dependency.
        fn marginsAxisSumsWithBaselineShims(self: *const Self, item: *const GridItem, percentage_basis: ?f32) Size(f32) {
            return item.marginsAxisSumsWithBaselineShims(percentage_basis, self.tree);
        }

        /// Retrieve the item's min content contribution from the cache or compute it using the provided parameters
        fn minContentContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) LayoutError!f32 {
            const grid_area_size = self.gridAreaSize(item, axis_tracks);
            const available_space = grid_area_size.with(self.axis, null);
            const margin_axis_sums = self.marginsAxisSumsWithBaselineShims(item, available_space.width);
            const contribution = try item.minContentContributionCached(self.axis, self.tree, grid_area_size, available_space);
            return contribution + margin_axis_sums.get(self.axis);
        }

        /// Retrieve the item's max content contribution from the cache or compute it using the provided parameters
        fn maxContentContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) LayoutError!f32 {
            const grid_area_size = self.gridAreaSize(item, axis_tracks);
            const available_space = grid_area_size.with(self.axis, null);
            const margin_axis_sums = self.marginsAxisSumsWithBaselineShims(item, available_space.width);
            const contribution = try item.maxContentContributionCached(self.axis, self.tree, grid_area_size, available_space);
            return contribution + margin_axis_sums.get(self.axis);
        }

        /// The minimum contribution of an item is the smallest outer size it can have.
        /// Specifically:
        ///   - If the item’s computed preferred size behaves as auto or depends on the size of its containing block in the relevant axis:
        ///     Its minimum contribution is the outer size that would result from assuming the item’s used minimum size as its preferred size;
        ///   - Else the item’s minimum contribution is its min-content contribution.
        ///
        /// Because the minimum contribution often depends on the size of the item’s content, it is considered a type of intrinsic size contribution.
        fn minimumContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) LayoutError!f32 {
            const grid_area_size = self.gridAreaSize(item, axis_tracks);
            const available_space = grid_area_size.with(self.axis, null);
            const margin_axis_sums = self.marginsAxisSumsWithBaselineShims(item, available_space.width);
            const contribution = try item.minimumContributionCached(self.tree, self.axis, axis_tracks, grid_area_size, self.inner_node_size);
            return contribution + margin_axis_sums.get(self.axis);
        }
    };
}

/// When applying the track sizing algorithm and estimating the size in the other axis for content sizing items
/// we should take into account align-content/justify-content if both the grid container and all items in the
/// other axis have definite sizes. This function computes such a per-gutter additional size adjustment.
pub fn computeAlignmentGutterAdjustment(
    alignment: AlignContent,
    axis_inner_node_size: ?f32,
    get_track_size_estimate: TrackSizeEstimate,
    tree: anytype,
    tracks: []const GridTrack,
) f32 {
    if (tracks.len <= 1) {
        return 0.0;
    }

    // As items never cross the outermost gutters in a grid, we can simplify our calculations by
    // treating Start and End the same. The safety modifier doesn't influence gutter weight;
    // overflow fallback is handled when offsets are computed.
    const outer_gutter_weight: usize = switch (alignment.keyword) {
        .start, .flex_start, .end, .flex_end, .center => 1,
        // Normal is resolved to Stretch in `computeGridLayout`
        .normal, .stretch => 0,
        .space_between => 0,
        .space_around => 1,
        .space_evenly => 1,
    };

    const inner_gutter_weight: usize = switch (alignment.keyword) {
        .flex_start, .start, .flex_end, .end, .center, .normal, .stretch => 0,
        .space_between => 1,
        .space_around => 2,
        .space_evenly => 1,
    };

    if (inner_gutter_weight == 0) {
        return 0.0;
    }

    if (axis_inner_node_size) |inner_size| {
        const free_space: f32 = blk: {
            var track_size_sum: f32 = -0.0;
            for (tracks) |*track| {
                track_size_sum += get_track_size_estimate.estimate(track, inner_size, tree) orelse break :blk 0.0;
            }
            break :blk @max(0.0, inner_size - track_size_sum);
        };

        const weighted_track_count = (((tracks.len - 3) / 2) * inner_gutter_weight) + (2 * outer_gutter_weight);

        return (free_space / @as(f32, @floatFromInt(weighted_track_count))) * @as(f32, @floatFromInt(inner_gutter_weight));
    }

    return 0.0;
}

/// Convert origin-zero coordinates track placement in grid track vector indexes
pub fn resolveItemTrackIndexes(items: []GridItem, column_counts: TrackCounts, row_counts: TrackCounts) void {
    for (items) |*item| {
        item.column_indexes = .{
            .start = @intCast(item.column.start.intoTrackVecIndex(column_counts)),
            .end = @intCast(item.column.end.intoTrackVecIndex(column_counts)),
        };
        item.row_indexes = .{
            .start = @intCast(item.row.start.intoTrackVecIndex(row_counts)),
            .end = @intCast(item.row.end.intoTrackVecIndex(row_counts)),
        };
    }
}

/// Whether any track in `tracks` satisfies `predicate`
fn anyTrack(tracks: []const GridTrack, predicate: anytype) bool {
    for (tracks) |*track| {
        if (predicate.call(track)) return true;
    }
    return false;
}

/// Determine (in each axis) whether the item crosses any flexible tracks
pub fn determineIfItemCrossesFlexibleOrIntrinsicTracks(items: []GridItem, columns: []const GridTrack, rows: []const GridTrack) void {
    for (items) |*item| {
        const item_columns = item.spannedTracks(.@"inline", columns);
        const item_rows = item.spannedTracks(.block, rows);
        item.crosses_flexible_column = anyTrack(item_columns, IsFlexible{});
        item.crosses_intrinsic_column = anyTrack(item_columns, HasIntrinsicSizingFunction{});
        item.crosses_flexible_row = anyTrack(item_rows, IsFlexible{});
        item.crosses_intrinsic_row = anyTrack(item_rows, HasIntrinsicSizingFunction{});
    }
}

/// Track sizing algorithm
/// Note: Gutters are treated as empty fixed-size tracks for the purpose of the track sizing algorithm.
pub fn trackSizingAlgorithm(
    tree: anytype,
    axis: AbstractAxis,
    axis_min_size: ?f32,
    axis_max_size: ?f32,
    axis_alignment: AlignContent,
    other_axis_alignment: AlignContent,
    available_grid_space: Size(AvailableSpace),
    inner_node_size: Size(?f32),
    axis_tracks: []GridTrack,
    other_axis_tracks: []GridTrack,
    items: []GridItem,
    get_track_size_estimate: TrackSizeEstimate,
    has_baseline_aligned_item: bool,
) LayoutError!void {
    // 11.4 Initialise Track sizes
    // Initialize each track’s base size and growth limit.
    const percentage_basis = inner_node_size.get(axis) orelse axis_min_size;
    initializeTrackSizes(tree, axis_tracks, percentage_basis);

    // Resolve fit-content() limits against the container's inner size (these are fixed for the rest of this pass)
    const axis_inner_node_size = inner_node_size.get(axis);
    for (axis_tracks) |*track| {
        track.resolveFitContentLimit(axis_inner_node_size, tree);
    }

    // 11.5.1 Shim item baselines
    if (has_baseline_aligned_item) {
        try resolveItemBaselines(tree, axis, items, inner_node_size);
    }

    // If all tracks have a fixed min track sizing function and base_size = growth_limit,
    // then the track sizes are already final and we can skip the rest of this function.
    // Note that tracks with an intrinsic min track sizing function can still grow beyond
    // a fixed growth limit (e.g. minmax(auto, 0px)), so they cannot be skipped.
    const all_final = for (axis_tracks) |*track| {
        if (!(track.base_size == track.growth_limit and
            track.min_track_sizing_function.definiteValue(percentage_basis, tree) != null)) break false;
    } else true;
    if (all_final) {
        return;
    }

    // Pre-computations for 11.5 Resolve Intrinsic Track Sizes

    // Compute an additional amount to add to each spanned gutter when computing item's estimated size in the
    // in the opposite axis based on the alignment, container size, and estimated track sizes in that axis
    const gutter_alignment_adjustment = computeAlignmentGutterAdjustment(
        other_axis_alignment,
        inner_node_size.get(axis.other()),
        get_track_size_estimate,
        tree,
        other_axis_tracks,
    );
    if (other_axis_tracks.len > 3) {
        var i: usize = 2;
        while (i < other_axis_tracks.len) : (i += 2) {
            other_axis_tracks[i].content_alignment_adjustment = gutter_alignment_adjustment;
        }
    }

    // 11.5 Resolve Intrinsic Track Sizes
    try resolveIntrinsicTrackSizes(
        tree,
        axis,
        axis_tracks,
        other_axis_tracks,
        items,
        available_grid_space.get(axis),
        inner_node_size,
        get_track_size_estimate,
    );

    // 11.6. Maximise Tracks
    // Distributes free space (if any) to tracks with FINITE growth limits, up to their limits.
    maximiseTracks(axis_tracks, available_grid_space.get(axis));

    // For the purpose of the final two expansion steps ("Expand Flexible Tracks" and "Stretch auto Tracks"), we only want to expand
    // into space generated by the grid container's size (as defined by either it's preferred size style or by it's parent node through
    // something like stretch alignment), not just any available space. To do this we map definite available space to AvailableSpace.max_content
    // in the case that inner_node_size is null. A min-content constraint in the block axis is also mapped to AvailableSpace.max_content,
    // as the min-content block size of a grid container is its max-content block size.
    const axis_available_space_for_expansion: AvailableSpace = if (inner_node_size.get(axis)) |available_space|
        .{ .definite = available_space }
    else switch (available_grid_space.get(axis)) {
        .min_content => if (axis == .@"inline") .min_content else .max_content,
        else => .max_content,
    };

    // 11.7. Expand Flexible Tracks
    // This step sizes flexible tracks using the largest value it can assign to an fr without exceeding the available space.
    try expandFlexibleTracks(
        tree,
        axis,
        axis_tracks,
        other_axis_tracks,
        items,
        axis_min_size,
        axis_max_size,
        axis_available_space_for_expansion,
        inner_node_size,
        get_track_size_estimate,
    );

    // 11.8. Stretch auto Tracks
    // This step expands tracks that have an auto max track sizing function by dividing any remaining positive, definite free space equally amongst them.
    if (axis_alignment == AlignContent.stretch) {
        stretchAutoTracks(axis_tracks, axis_min_size, axis_available_space_for_expansion);
    }
}

/// Whether it is a minimum or maximum size's space being distributed
/// This controls behaviour of the space distribution algorithm when distributing beyond limits
/// See "distributing space beyond limits" at https://www.w3.org/TR/css-grid-1/#extra-space
const IntrinsicContributionType = enum {
    /// It's a minimum size's space being distributed
    minimum,
    /// It's a maximum size's space being distributed
    maximum,
};

/// Add any planned base size increases to the base size after a round of distributing space to base sizes
/// Reset the planed base size increase to zero ready for the next round.
fn flushPlannedBaseSizeIncreases(tracks: []GridTrack) void {
    for (tracks) |*track| {
        track.base_size += track.base_size_planned_increase;
        track.base_size_planned_increase = 0.0;
    }
}

/// Add any planned growth limit increases to the growth limit after a round of distributing space to growth limits
/// Reset the planed growth limit increase to zero ready for the next round.
fn flushPlannedGrowthLimitIncreases(tracks: []GridTrack, set_infinitely_growable: bool) void {
    for (tracks) |*track| {
        if (track.growth_limit_planned_increase > 0.0) {
            track.growth_limit = if (track.growth_limit == inf)
                track.base_size + track.growth_limit_planned_increase
            else
                track.growth_limit + track.growth_limit_planned_increase;
            track.infinitely_growable = set_infinitely_growable;
        } else {
            track.infinitely_growable = false;
        }
        track.growth_limit_planned_increase = 0.0;
    }
}

/// 11.4 Initialise Track sizes
/// Initialize each track’s base size and growth limit.
fn initializeTrackSizes(tree: anytype, axis_tracks: []GridTrack, axis_inner_node_size: ?f32) void {
    for (axis_tracks) |*track| {
        // For each track, if the track’s min track sizing function is:
        // - A fixed sizing function
        //     Resolve to an absolute length and use that size as the track’s initial base size.
        //     Note: Indefinite lengths cannot occur, as they’re treated as auto.
        // - An intrinsic sizing function
        //     Use an initial base size of zero.
        track.base_size = track.min_track_sizing_function.definiteValue(axis_inner_node_size, tree) orelse 0.0;

        // For each track, if the track’s max track sizing function is:
        // - A fixed sizing function
        //     Resolve to an absolute length and use that size as the track’s initial growth limit.
        // - An intrinsic sizing function
        //     Use an initial growth limit of infinity.
        // - A flexible sizing function
        //     Use an initial growth limit of infinity.
        track.growth_limit = track.max_track_sizing_function.definiteValue(axis_inner_node_size, tree) orelse inf;

        // In all cases, if the growth limit is less than the base size, increase the growth limit to match the base size.
        if (track.growth_limit < track.base_size) {
            track.growth_limit = track.base_size;
        }
    }
}

fn lessThanOtherAxisStart(other_axis: AbstractAxis, a: *GridItem, b: *GridItem) bool {
    return a.placement(other_axis).start.inner < b.placement(other_axis).start.inner;
}

/// 11.5.1 Shim baseline-aligned items so their intrinsic size contributions reflect their baseline alignment.
fn resolveItemBaselines(tree: anytype, axis: AbstractAxis, items_in: []GridItem, inner_node_size: Size(?f32)) LayoutError!void {
    // Sort items by track in the other axis (row) start position so that we can iterate items in groups which
    // are in the same track in the other axis (row)
    const other_axis = axis.other();
    const scratch = Scratch.allocatorOf(tree);
    const items = try scratch.alloc(*GridItem, items_in.len);
    defer scratch.free(items);
    for (items, items_in) |*ptr, *item| ptr.* = item;
    std.mem.sort(*GridItem, items, other_axis, lessThanOtherAxisStart);

    // Iterate over grid rows
    var remaining_items = items;
    while (remaining_items.len != 0) {
        // Get the row index of the current row
        const current_row = remaining_items[0].placement(other_axis).start;

        // Find the item index of the first item that is in a different row (or the end of the list)
        var next_row_first_item = remaining_items.len;
        for (remaining_items, 0..) |item, index| {
            if (item.placement(other_axis).start != current_row) {
                next_row_first_item = index;
                break;
            }
        }

        // Use this index to split the `remaining_items` slice in two slices:
        //    - A `row_items` slice containing the items (that start) in the current row
        //    - A new `remaining_items` consisting of the remainder of the `remaining_items` slice
        //      that hasn't been split off into `row_items
        const row_items = remaining_items[0..next_row_first_item];
        remaining_items = remaining_items[next_row_first_item..];

        // Count how many items in *this row* are baseline aligned
        // If a row has one or zero items participating in baseline alignment then baseline alignment is a no-op
        // for those items and we skip further computations for that row
        var row_baseline_item_count: usize = 0;
        for (row_items) |item| {
            if (item.participatesInBaselineAlignment()) row_baseline_item_count += 1;
        }
        if (row_baseline_item_count <= 1) {
            continue;
        }

        // Compute the baselines of all items in the row participating in baseline alignment
        for (row_items) |item| {
            if (!item.participatesInBaselineAlignment()) {
                continue;
            }

            const measured_size_and_baselines = try traits.performChildLayout(
                tree,
                item.node,
                Size(?f32).none,
                inner_node_size,
                Size(AvailableSpace).min_content,
                .inherent_size,
                Line(bool).false,
            );

            const height = measured_size_and_baselines.size.height;
            const baseline = childFirstBaseline(measured_size_and_baselines.baselines.first, height, item.overflow.y) orelse height;

            item.baseline = baseline;
        }

        // Compute the max baseline of all items in the row participating in baseline alignment
        var row_max_baseline: TotalCmpMax = .{};
        for (row_items) |item| {
            if (item.participatesInBaselineAlignment()) row_max_baseline.add(marginBoxBaseline(tree, item, inner_node_size));
        }

        // Compute the baseline shim for each item in the row participating in baseline alignment
        for (row_items) |item| {
            if (item.participatesInBaselineAlignment()) {
                item.baseline_shim = row_max_baseline.best.? - marginBoxBaseline(tree, item, inner_node_size);
                item.known_dimensions_cache = null;
            }
        }
    }
}

/// Items are aligned by the distance from the top of their margin box to their baseline
fn marginBoxBaseline(tree: anytype, item: *const GridItem, inner_node_size: Size(?f32)) f32 {
    return (item.baseline orelse 0.0) + resolveOrZero(item.margin.top, inner_node_size.width, tree);
}

/// 11.5 Resolve Intrinsic Track Sizes
fn resolveIntrinsicTrackSizes(
    tree: anytype,
    axis: AbstractAxis,
    axis_tracks: []GridTrack,
    other_axis_tracks: []const GridTrack,
    all_items: []GridItem,
    axis_available_grid_space: AvailableSpace,
    inner_node_size: Size(?f32),
    get_track_size_estimate: TrackSizeEstimate,
) LayoutError!void {
    const scratch = Scratch.allocatorOf(tree);
    // Step 1. Shim baseline-aligned items so their intrinsic size contributions reflect their baseline alignment.

    // Already done at this point. See resolveItemBaselines function.

    // Step 2.

    // The track sizing algorithm requires us to iterate through the items in ascending order of the number of
    // tracks they span (first items that span 1 track, then items that span 2 tracks, etc).
    // To avoid having to do multiple iterations of the items, we pre-sort them into this order.
    //
    // Items that cross a flexible track are all processed together in a single batch (regardless of their span), so
    // they only need to be moved to the end of the list. And the order in which items within a batch are processed
    // does not affect the result, so the remaining items only need to be sorted if any of them span more than one track.
    var partitioned_items = try FrontBackVecBuilder(*GridItem).withCapacity(scratch, all_items.len);
    var needs_sort = false;
    for (all_items) |*item| {
        if (item.crossesFlexibleTrack(axis)) {
            partitioned_items.pushBack(item);
        } else {
            needs_sort = needs_sort or item.span(axis) > 1;
            partitioned_items.pushFront(item);
        }
    }
    const items, const non_flex_item_count = partitioned_items.intoSlice();
    defer scratch.free(items);
    if (needs_sort) {
        std.mem.sort(*GridItem, items[0..non_flex_item_count], axis, lessThanSpan);
    }

    // Step 2, Step 3 and Step 4
    // 2 & 3. Iterate over items that don't cross a flex track. Items should have already been sorted in ascending order
    // of the number of tracks they span. Step 2 is the 1 track case and has an optimised implementation
    // 4. Next, repeat the previous step instead considering (together, rather than grouped by span size) all items
    // that do span a track with a flexible sizing function while

    // Compute item's intrinsic (content-based) sizes
    // Note: For items with a specified minimum size of auto (the initial value), the minimum contribution is usually equivalent
    // to the min-content contribution—but can differ in some cases, see §6.6 Automatic Minimum Size of Grid Items.
    // Also, minimum contribution <= min-content contribution <= max-content contribution.

    const axis_inner_node_size = inner_node_size.get(axis);
    var item_sizer: IntrinsicSizeMeasurer(@TypeOf(tree)) = .{
        .tree = tree,
        .other_axis_tracks = other_axis_tracks,
        .axis = axis,
        .inner_node_size = inner_node_size,
        .get_track_size_estimate = get_track_size_estimate,
    };

    var batched_item_iterator = ItemBatcher.new(axis);
    while (batched_item_iterator.next(items)) |batch_and_flex| {
        const batch, const is_flex = batch_and_flex;
        // 2. Size tracks to fit non-spanning items: For each track with an intrinsic track sizing function and not a flexible sizing function,
        // consider the items in it with a span of 1:
        const batch_span = batch[0].placement(axis).span();
        if (!is_flex and batch_span == 1) {
            for (batch) |item| {
                const track_index = item.placementIndexes(axis).start + 1;
                const track = &axis_tracks[track_index];

                // Handle base sizes
                const min_tag = track.min_track_sizing_function.inner.tag();
                const new_base_size: f32 = if (min_tag == CompactLength.min_content_tag)
                    @max(track.base_size, try item_sizer.minContentContribution(item, axis_tracks))
                else if (min_tag == CompactLength.max_content_tag)
                    @max(track.base_size, try item_sizer.maxContentContribution(item, axis_tracks))
                    // If the container size is indefinite and has not yet been resolved then percentage sized
                    // tracks are treated as auto
                else if (track.min_track_sizing_function.behavesAsAuto(axis_inner_node_size)) blk: {
                    const use_limited_min_content = (axis_available_grid_space == .min_content or axis_available_grid_space == .max_content) and
                        !item.overflow.get(axis).isScrollContainer();
                    const space = if (use_limited_min_content) inner: {
                        // QUIRK: The spec says that:
                        //
                        //   If the grid container is being sized under a min- or max-content constraint, use the items’ limited
                        //   min-content contributions in place of their minimum contributions here.
                        //
                        // However, in practice browsers only seem to apply this rule if the item is not a scroll container
                        // (note that overflow:hidden counts as a scroll container), giving the automatic minimum size of scroll
                        // containers (zero) precedence over the min-content contributions.
                        const axis_minimum_size = try item_sizer.minimumContribution(item, axis_tracks);
                        const axis_min_content_size = try item_sizer.minContentContribution(item, axis_tracks);
                        const limit = track.max_track_sizing_function.definiteLimit(axis_inner_node_size, tree);
                        break :inner @max(maybeMin(axis_min_content_size, limit), axis_minimum_size);
                    } else try item_sizer.minimumContribution(item, axis_tracks);
                    break :blk @max(track.base_size, space);
                }
                    // Do nothing as it's not an intrinsic track sizing function
                    else track.base_size;
                axis_tracks[track_index].base_size = new_base_size;

                // Handle growth limits
                //
                // Computing an item's contributions calls into the child, so they are only computed if they are used.
                // The min-content contribution is computed for every item in an intrinsic track (even where only the
                // max-content contribution determines the growth limit), as the check for whether track sizing needs
                // to be re-run compares each such item's min-content contribution against the one cached here.
                const max_track_sizing_function = track.max_track_sizing_function;
                const fit_content_limit = track.fitContentLimit();
                const min_content_contribution: ?f32 = if (track.hasIntrinsicSizingFunction())
                    try item_sizer.minContentContribution(item, axis_tracks)
                else
                    null;
                const planned_increase: ?f32 = if (max_track_sizing_function.isFitContent()) blk: {
                    // Always increase the growth limit to at least the size of the *fit-content limited*
                    // max-content contribution
                    const max_content_contribution = @min(try item_sizer.maxContentContribution(item, axis_tracks), fit_content_limit);

                    // If item is not a scroll container, then increase the growth limit to at least the
                    // size of the min-content contribution
                    if (min_content_contribution) |min_content| {
                        if (!item.overflow.get(axis).isScrollContainer()) {
                            break :blk @max(min_content, max_content_contribution);
                        }
                    }
                    break :blk max_content_contribution;
                } else if (max_track_sizing_function.isMaxContentAlike() or
                    max_track_sizing_function.usesPercentage() and axis_inner_node_size == null)
                    // If the container size is indefinite and has not yet been resolved then percentage sized
                    // tracks should be treated as auto (this matches Chrome's behaviour and seems sensible)
                    try item_sizer.maxContentContribution(item, axis_tracks)
                else if (max_track_sizing_function.isIntrinsic())
                    min_content_contribution
                else
                    null;
                if (planned_increase) |increase| {
                    const t = &axis_tracks[track_index];
                    t.growth_limit_planned_increase = @max(t.growth_limit_planned_increase, increase);
                }
            }

            for (axis_tracks) |*track| {
                if (track.growth_limit_planned_increase > 0.0) {
                    track.growth_limit = if (track.growth_limit == inf)
                        track.growth_limit_planned_increase
                    else
                        @max(track.growth_limit, track.growth_limit_planned_increase);
                }
                track.infinitely_growable = false;
                track.growth_limit_planned_increase = 0.0;
                if (track.growth_limit < track.base_size) {
                    track.growth_limit = track.base_size;
                }
            }

            continue;
        }

        // 1. For intrinsic minimums:
        // First increase the base size of tracks with an intrinsic min track sizing function
        for (batch) |item| {
            if (!item.crossesIntrinsicTrack(axis)) continue;
            // ...by distributing extra space as needed to accommodate these items’ minimum contributions.
            //
            // QUIRK: The spec says that:
            //
            //   If the grid container is being sized under a min- or max-content constraint, use the items’ limited min-content contributions
            //   in place of their minimum contributions here.
            //
            // However, in practice browsers only seem to apply this rule if the item is not a scroll container (note that overflow:hidden counts as
            // a scroll container), giving the automatic minimum size of scroll containers (zero) precedence over the min-content contributions.
            const use_limited_min_content = (axis_available_grid_space == .min_content or axis_available_grid_space == .max_content) and
                !item.overflow.get(axis).isScrollContainer();
            const space: f32 = if (use_limited_min_content) blk: {
                const axis_minimum_size = try item_sizer.minimumContribution(item, axis_tracks);
                const axis_min_content_size = try item_sizer.minContentContribution(item, axis_tracks);
                const limit = item.spannedTrackLimit(axis, axis_tracks, axis_inner_node_size, tree);
                const limited_min_content = @max(maybeMin(axis_min_content_size, limit), axis_minimum_size);

                // For items crossing flexible tracks, browsers hand the content-derived contribution to
                // the flexible tracks only in proportion to the crossed flex factor sum, clamped at one
                // (CSS Grid 2, 12.5: "if the sum is less than one, distribute that proportion of
                // space"). The proportion applies to the space left after covering the spanned
                // inflexible tracks, and the item's minimum contribution acts as a floor on the result:
                // a definite size still spreads over `0fr` tracks in full. This is what lets a `0fr`
                // track holding a `min-height: 0` item collapse to zero, which the
                // `grid-template-rows: 0fr` to `1fr` collapse animation pattern relies on.
                if (is_flex) {
                    const spanned_tracks = item.spannedTracks(axis, @as([]const GridTrack, axis_tracks));
                    const inflexible_sizes = inflexibleBaseSizeSum(spanned_tracks);
                    const scale = @min(crossedFlexFactorSum(spanned_tracks), 1.0);
                    const excess = @max(limited_min_content - inflexible_sizes, 0.0);
                    break :blk @max(axis_minimum_size, inflexible_sizes + excess * scale);
                } else {
                    break :blk limited_min_content;
                }
            } else try item_sizer.minimumContribution(item, axis_tracks);
            const tracks = item.spannedTracks(axis, axis_tracks);
            if (space > 0.0) {
                const has_intrinsic_min_track_sizing_function: HasIntrinsicMinTrackSizingFunction(@TypeOf(tree)) = .{
                    .axis_inner_node_size = axis_inner_node_size,
                    .tree = tree,
                };
                if (item.overflow.get(axis).isScrollContainer()) {
                    distributeItemSpaceToBaseSize(is_flex, space, tracks, has_intrinsic_min_track_sizing_function, FitContentLimitedGrowthLimit{}, .minimum);
                } else {
                    distributeItemSpaceToBaseSize(is_flex, space, tracks, has_intrinsic_min_track_sizing_function, GrowthLimit{}, .minimum);
                }
            }
        }
        flushPlannedBaseSizeIncreases(axis_tracks);

        // 2. For content-based minimums:
        // Next continue to increase the base size of tracks with a min track sizing function of min-content or max-content
        // by distributing extra space as needed to account for these items' min-content contributions.
        const has_min_or_max_content_min_track_sizing_function = HasMinOrMaxContentMinTrackSizingFunction{};
        for (batch) |item| {
            if (!item.spansTrackMatching(axis, axis_tracks, has_min_or_max_content_min_track_sizing_function)) {
                continue;
            }
            const space = try item_sizer.minContentContribution(item, axis_tracks);
            const tracks = item.spannedTracks(axis, axis_tracks);
            if (space > 0.0) {
                if (item.overflow.get(axis).isScrollContainer()) {
                    distributeItemSpaceToBaseSize(is_flex, space, tracks, has_min_or_max_content_min_track_sizing_function, FitContentLimitedGrowthLimit{}, .minimum);
                } else {
                    distributeItemSpaceToBaseSize(is_flex, space, tracks, has_min_or_max_content_min_track_sizing_function, GrowthLimit{}, .minimum);
                }
            }
        }
        flushPlannedBaseSizeIncreases(axis_tracks);

        // 3. For max-content minimums:

        // If the grid container is being sized under a max-content constraint, continue to increase the base size of tracks with
        // a min track sizing function of auto or max-content by distributing extra space as needed to account for these items'
        // limited max-content contributions.

        // Define fit_content_limited_growth_limit function. This is passed to the distribute_space_up_to_limits
        // helper function, and is used to compute the limit to distribute up to for each track.
        // Wrapping the method on GridTrack is necessary in order to resolve percentage fit-content arguments.
        if (axis_available_grid_space == .max_content) {
            for (batch) |item| {
                if (!item.spansTrackMatching(axis, axis_tracks, HasAutoOrMaxContentMinTrackSizingFunction{})) {
                    continue;
                }
                const axis_max_content_size = try item_sizer.maxContentContribution(item, axis_tracks);
                const limit = item.spannedTrackLimit(axis, axis_tracks, axis_inner_node_size, tree);
                var space = maybeMin(axis_max_content_size, limit);

                // As for the intrinsic minimums above: scale the space beyond the spanned inflexible
                // tracks by the crossed flex factor sum, clamped at one. Anchoring at the inflexible
                // track sizes rather than the current base sizes keeps this pass from compounding with
                // the scaling already applied to the min-content contribution.
                if (is_flex) {
                    const spanned_tracks = item.spannedTracks(axis, @as([]const GridTrack, axis_tracks));
                    const inflexible_sizes = inflexibleBaseSizeSum(spanned_tracks);
                    const scale = @min(crossedFlexFactorSum(spanned_tracks), 1.0);
                    space = inflexible_sizes + @max(space - inflexible_sizes, 0.0) * scale;
                }
                const tracks = item.spannedTracks(axis, axis_tracks);
                if (space > 0.0) {
                    // If any of the tracks spanned by the item have a MaxContent min track sizing function then
                    // distribute space only to those tracks. Otherwise distribute space to tracks with an Auto min
                    // track sizing function.
                    //
                    // Note: this prioritisation of MaxContent over Auto is not mentioned in the spec (which suggests that
                    // we ought to distribute space evenly between MaxContent and Auto tracks). But it is implemented like
                    // this in both Chrome and Firefox (and it does have a certain logic to it), so we implement it too for
                    // compatibility.
                    //
                    // See: https://www.w3.org/TR/css-grid-1/#track-size-max-content-min
                    if (anyTrack(tracks, HasMaxContentMinTrackSizingFunction{})) {
                        distributeItemSpaceToBaseSize(is_flex, space, tracks, HasMaxContentMinTrackSizingFunction{}, Infinity{}, .maximum);
                    } else {
                        distributeItemSpaceToBaseSize(is_flex, space, tracks, HasAutoMinTrackSizingFunction{}, FitContentLimitedGrowthLimit{}, .maximum);
                    }
                }
            }
            flushPlannedBaseSizeIncreases(axis_tracks);
        }

        // In all cases, continue to increase the base size of tracks with a min track sizing function of max-content by distributing
        // extra space as needed to account for these items' max-content contributions.
        for (batch) |item| {
            if (!item.spansTrackMatching(axis, axis_tracks, HasMaxContentMinTrackSizingFunction{})) {
                continue;
            }
            const axis_max_content_size = try item_sizer.maxContentContribution(item, axis_tracks);
            const space = axis_max_content_size;
            const tracks = item.spannedTracks(axis, axis_tracks);
            if (space > 0.0) {
                distributeItemSpaceToBaseSize(is_flex, space, tracks, HasMaxContentMinTrackSizingFunction{}, GrowthLimit{}, .maximum);
            }
        }
        flushPlannedBaseSizeIncreases(axis_tracks);

        // 4. If at this point any track’s growth limit is now less than its base size, increase its growth limit to match its base size.
        for (axis_tracks) |*track| {
            if (track.growth_limit < track.base_size) {
                track.growth_limit = track.base_size;
            }
        }

        // If a track is a flexible track, then it has flexible max track sizing function
        // It cannot also have an intrinsic max track sizing function, so these steps do not apply.
        if (!is_flex) {
            // 5. For intrinsic maximums: Next increase the growth limit of tracks with an intrinsic max track sizing function by
            // distributing extra space as needed to account for these items' min-content contributions.
            const has_intrinsic_max_track_sizing_function: HasIntrinsicMaxTrackSizingFunction = .{ .axis_inner_node_size = axis_inner_node_size };
            for (batch) |item| {
                if (!item.spansTrackMatching(axis, axis_tracks, has_intrinsic_max_track_sizing_function)) {
                    continue;
                }
                const axis_min_content_size = try item_sizer.minContentContribution(item, axis_tracks);
                const space = axis_min_content_size;
                const tracks = item.spannedTracks(axis, axis_tracks);
                if (space > 0.0) {
                    distributeItemSpaceToGrowthLimit(space, tracks, has_intrinsic_max_track_sizing_function);
                }
            }
            // Mark any tracks whose growth limit changed from infinite to finite in this step as infinitely growable for the next step.
            flushPlannedGrowthLimitIncreases(axis_tracks, true);

            // 6. For max-content maximums: Lastly continue to increase the growth limit of tracks with a max track sizing function of max-content
            // by distributing extra space as needed to account for these items' max-content contributions. However, limit the growth of any
            // fit-content() tracks by their fit-content() argument.
            const has_max_content_max_track_sizing_function: HasMaxContentMaxTrackSizingFunction = .{ .axis_inner_node_size = axis_inner_node_size };
            for (batch) |item| {
                if (!item.spansTrackMatching(axis, axis_tracks, has_max_content_max_track_sizing_function)) {
                    continue;
                }
                const axis_max_content_size = try item_sizer.maxContentContribution(item, axis_tracks);
                const space = axis_max_content_size;
                const tracks = item.spannedTracks(axis, axis_tracks);
                if (space > 0.0) {
                    distributeItemSpaceToGrowthLimit(space, tracks, has_max_content_max_track_sizing_function);
                }
            }
            // Mark any tracks whose growth limit changed from infinite to finite in this step as infinitely growable for the next step.
            flushPlannedGrowthLimitIncreases(axis_tracks, false);
        }
    }

    // Step 5. If any track still has an infinite growth limit (because, for example, it had no items placed
    // in it or it is a flexible track), set its growth limit to its base size.
    // NOTE: this step is super-important to ensure that the "Maximise Tracks" step doesn't affect flexible tracks
    for (axis_tracks) |*track| {
        if (track.growth_limit == inf) track.growth_limit = track.base_size;
    }
}

fn lessThanSpan(axis: AbstractAxis, a: *GridItem, b: *GridItem) bool {
    return a.span(axis) < b.span(axis);
}

/// The sum of the base sizes of the inflexible tracks in an item's spanned track range
fn inflexibleBaseSizeSum(tracks: []const GridTrack) f32 {
    var sum: f32 = -0.0;
    for (tracks) |*track| {
        if (!track.isFlexible()) sum += track.base_size;
    }
    return sum;
}

/// The sum of the flex factors of the flexible tracks in an item's spanned track range
fn crossedFlexFactorSum(tracks: []const GridTrack) f32 {
    var sum: f32 = -0.0;
    for (tracks) |*track| {
        if (track.isFlexible()) sum += track.flexFactor();
    }
    return sum;
}

// ---------------------------------------------------------------------------------------------
// Track predicates and properties (upstream closures)

/// `|track| track.is_flexible()`
const IsFlexible = struct {
    fn call(_: IsFlexible, track: *const GridTrack) bool {
        return track.isFlexible();
    }
};

/// `|track| track.has_intrinsic_sizing_function()`
const HasIntrinsicSizingFunction = struct {
    fn call(_: HasIntrinsicSizingFunction, track: *const GridTrack) bool {
        return track.hasIntrinsicSizingFunction();
    }
};

/// Whether the track's min track sizing function has no definite value (is intrinsic)
fn HasIntrinsicMinTrackSizingFunction(comptime Tree: type) type {
    return struct {
        axis_inner_node_size: ?f32,
        tree: Tree,

        fn call(self: @This(), track: *const GridTrack) bool {
            return track.min_track_sizing_function.definiteValue(self.axis_inner_node_size, self.tree) == null;
        }
    };
}

/// Whether the track has a min-content or max-content min track sizing function
const HasMinOrMaxContentMinTrackSizingFunction = struct {
    pub fn call(_: HasMinOrMaxContentMinTrackSizingFunction, track: *const GridTrack) bool {
        return track.min_track_sizing_function.isMinOrMaxContent();
    }
};

/// Whether a track:
///   - has an Auto MIN track sizing function
///   - Does not have a MinContent MAX track sizing function
///
/// The latter condition was added in order to match Chrome. But I believe it is due to the provision
/// under minmax here https://www.w3.org/TR/css-grid-1/#track-sizes which states that:
///
///    "If the max is less than the min, then the max will be floored by the min (essentially yielding minmax(min, min))"
const HasAutoMinTrackSizingFunction = struct {
    pub fn call(_: HasAutoMinTrackSizingFunction, track: *const GridTrack) bool {
        return track.min_track_sizing_function.isAuto() and !track.max_track_sizing_function.isMinContent();
    }
};

/// Whether a track has a MaxContent min track sizing function
const HasMaxContentMinTrackSizingFunction = struct {
    pub fn call(_: HasMaxContentMinTrackSizingFunction, track: *const GridTrack) bool {
        return track.min_track_sizing_function.isMaxContent();
    }
};

/// `has_auto_min_track_sizing_function(track) || has_max_content_min_track_sizing_function(track)`
const HasAutoOrMaxContentMinTrackSizingFunction = struct {
    pub fn call(_: HasAutoOrMaxContentMinTrackSizingFunction, track: *const GridTrack) bool {
        return (HasAutoMinTrackSizingFunction{}).call(track) or (HasMaxContentMinTrackSizingFunction{}).call(track);
    }
};

/// Whether the track's max track sizing function has no definite value (is intrinsic)
const HasIntrinsicMaxTrackSizingFunction = struct {
    axis_inner_node_size: ?f32,

    pub fn call(self: HasIntrinsicMaxTrackSizingFunction, track: *const GridTrack) bool {
        return !track.max_track_sizing_function.hasDefiniteValue(self.axis_inner_node_size);
    }
};

/// Whether the track's max track sizing function behaves as max-content
const HasMaxContentMaxTrackSizingFunction = struct {
    axis_inner_node_size: ?f32,

    pub fn call(self: HasMaxContentMaxTrackSizingFunction, track: *const GridTrack) bool {
        return track.max_track_sizing_function.isMaxContentAlike() or
            (track.max_track_sizing_function.usesPercentage() and self.axis_inner_node_size == null);
    }
};

/// `|_| true`
const AnyTrack = struct {
    fn call(_: AnyTrack, _: *const GridTrack) bool {
        return true;
    }
};

/// `|track| a(track) && b(track)`
fn And(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,

        fn call(self: @This(), track: *const GridTrack) bool {
            return self.a.call(track) and self.b.call(track);
        }
    };
}

/// `|track| track.is_flexible() && track_is_affected(track)`
fn FlexibleAnd(comptime P: type) type {
    return struct {
        p: P,

        fn call(self: @This(), track: *const GridTrack) bool {
            return track.isFlexible() and self.p.call(track);
        }
    };
}

/// `|track| track_is_affected(track) && (track.infinitely_growable || track.growth_limit == f32::INFINITY)`
fn GrowableAnd(comptime P: type) type {
    return struct {
        p: P,

        fn call(self: @This(), track: *const GridTrack) bool {
            return self.p.call(track) and (track.infinitely_growable or track.growth_limit == inf);
        }
    };
}

/// The filter used when distributing space beyond limits
const BeyondLimitsFilter = enum {
    /// Any affected track that happens to also have an intrinsic max track sizing function
    intrinsic_max,
    /// Any affected track that happens to also have a max-content max track sizing function
    max_or_fit_content_max,
    /// All affected tracks
    all,

    fn call(self: BeyondLimitsFilter, track: *const GridTrack) bool {
        return switch (self) {
            .intrinsic_max => track.max_track_sizing_function.isIntrinsic(),
            .max_or_fit_content_max => track.max_track_sizing_function.isMaxOrFitContent(),
            .all => true,
        };
    }
};

/// `|_| 1.0`
const EqualProportion = struct {
    fn call(_: EqualProportion, _: *const GridTrack) f32 {
        return 1.0;
    }
};

/// `|track| track.flex_factor()`
const FlexFactorProportion = struct {
    fn call(_: FlexFactorProportion, track: *const GridTrack) f32 {
        return track.flexFactor();
    }
};

/// `|track| track.base_size`
const BaseSize = struct {
    fn call(_: BaseSize, track: *const GridTrack) f32 {
        return track.base_size;
    }
};

/// `|track| track.growth_limit`
const GrowthLimit = struct {
    fn call(_: GrowthLimit, track: *const GridTrack) f32 {
        return track.growth_limit;
    }
};

/// `|track| track.fit_content_limited_growth_limit()`
const FitContentLimitedGrowthLimit = struct {
    fn call(_: FitContentLimitedGrowthLimit, track: *const GridTrack) f32 {
        return track.fitContentLimitedGrowthLimit();
    }
};

/// `|track| track.fit_content_limit()`
const FitContentLimit = struct {
    fn call(_: FitContentLimit, track: *const GridTrack) f32 {
        return track.fitContentLimit();
    }
};

/// `|_| f32::INFINITY`
const Infinity = struct {
    fn call(_: Infinity, _: *const GridTrack) f32 {
        return inf;
    }
};

/// `|track| if track.growth_limit == f32::INFINITY { track.base_size } else { track.growth_limit }`
const GrowthLimitOrBaseSize = struct {
    fn call(_: GrowthLimitOrBaseSize, track: *const GridTrack) f32 {
        return if (track.growth_limit == inf) track.base_size else track.growth_limit;
    }
};

// ---------------------------------------------------------------------------------------------
// Space distribution

/// 11.5.1. Distributing Extra Space Across Spanned Tracks
/// https://www.w3.org/TR/css-grid-1/#extra-space
fn distributeItemSpaceToBaseSize(
    is_flex: bool,
    space: f32,
    tracks: []GridTrack,
    track_is_affected: anytype,
    track_limit: anytype,
    intrinsic_contribution_type: IntrinsicContributionType,
) void {
    if (is_flex) {
        const filter: FlexibleAnd(@TypeOf(track_is_affected)) = .{ .p = track_is_affected };

        // If the sum of the flex factors of the affected tracks is greater than zero, distribute
        // space according to the ratios of the tracks' flex factors. Otherwise distribute space equally.
        //
        // Note: the spec says to compute the sum over all flexible tracks spanned by the item, and to
        // blend flex-factor-proportional and equal distribution when the sum is below one. But Chrome
        // computes the sum over only the affected tracks and uses pure flex-factor ratios whenever
        // that sum is non-zero, so we do the same for compatibility.
        var flex_factor_sum: f32 = -0.0;
        for (tracks) |*track| {
            if (filter.call(track)) flex_factor_sum += track.flexFactor();
        }
        if (flex_factor_sum > 0.0) {
            distributeItemSpaceToBaseSizeInner(space, tracks, filter, FlexFactorProportion{}, track_limit, intrinsic_contribution_type);
        } else {
            distributeItemSpaceToBaseSizeInner(space, tracks, filter, EqualProportion{}, track_limit, intrinsic_contribution_type);
        }
    } else {
        distributeItemSpaceToBaseSizeInner(space, tracks, track_is_affected, EqualProportion{}, track_limit, intrinsic_contribution_type);
    }
}

/// Inner function that doesn't account for differences due to distributing to flex items
/// This difference is handled by the filter passed in above
fn distributeItemSpaceToBaseSizeInner(
    space: f32,
    tracks: []GridTrack,
    track_is_affected: anytype,
    track_distribution_proportion: anytype,
    track_limit: anytype,
    intrinsic_contribution_type: IntrinsicContributionType,
) void {
    // Skip this distribution if there is either
    //   - no space to distribute
    //   - no affected tracks to distribute space to
    if (space == 0.0 or !anyTrack(tracks, track_is_affected)) {
        return;
    }

    // 1. Find the space to distribute
    var track_sizes: f32 = -0.0;
    for (tracks) |*track| track_sizes += track.base_size;
    const extra_space: f32 = @max(0.0, space - track_sizes);

    // 2. Distribute space up to limits:
    // Note: there are two exit conditions to this loop:
    //   - We run out of space to distribute (extra_space falls below THRESHOLD)
    //   - We run out of growable tracks to distribute to

    // Define a small constant to avoid infinite loops due to rounding errors. Rather than stopping distributing
    // extra space when it gets to exactly zero, we will stop when it falls below this amount
    const threshold: f32 = 0.000001;

    const remaining_space = distributeSpaceUpToLimits(extra_space, tracks, track_is_affected, track_distribution_proportion, BaseSize{}, track_limit);

    // 3. Distribute remaining span beyond limits (if any)
    if (remaining_space > threshold) {
        // When accommodating minimum contributions or accommodating min-content contributions:
        //   - any affected track that happens to also have an intrinsic max track sizing function;
        // When accommodating max-content contributions:
        //   - any affected track that happens to also have a max-content max track sizing function
        var filter: BeyondLimitsFilter = switch (intrinsic_contribution_type) {
            .minimum => .intrinsic_max,
            .maximum => .max_or_fit_content_max,
        };

        // If there are no such tracks (matching filter above), then use all affected tracks.
        var number_of_tracks: usize = 0;
        for (tracks) |*track| {
            if (track_is_affected.call(track) and filter.call(track)) number_of_tracks += 1;
        }
        if (number_of_tracks == 0) {
            filter = .all;
        }

        // When distributing beyond limits, growth limits are ignored, but the argument
        // to any fit-content() max track sizing function still caps growth.
        const affected_and_filtered: And(@TypeOf(track_is_affected), BeyondLimitsFilter) = .{ .a = track_is_affected, .b = filter };
        _ = distributeSpaceUpToLimits(remaining_space, tracks, affected_and_filtered, track_distribution_proportion, BaseSize{}, FitContentLimit{});
    }

    // 4. For each affected track, if the track’s item-incurred increase is larger than the track’s planned increase
    // set the track’s planned increase to that value.
    for (tracks) |*track| {
        if (track.item_incurred_increase > track.base_size_planned_increase) {
            track.base_size_planned_increase = track.item_incurred_increase;
        }

        // Reset the item_incurresed increase ready for the next space distribution
        track.item_incurred_increase = 0.0;
    }
}

/// 11.5.1. Distributing Extra Space Across Spanned Tracks
/// This is simplified (and faster) version of the algorithm for growth limits
/// https://www.w3.org/TR/css-grid-1/#extra-space
fn distributeItemSpaceToGrowthLimit(space: f32, tracks: []GridTrack, track_is_affected: anytype) void {
    // Skip this distribution if there is either
    //   - no space to distribute
    //   - no affected tracks to distribute space to
    if (space == 0.0 or !anyTrack(tracks, track_is_affected)) {
        return;
    }

    // 1. Find the space to distribute
    var track_sizes: f32 = -0.0;
    for (tracks) |*track| {
        track_sizes += if (track.growth_limit == inf) track.base_size else track.growth_limit;
    }
    const extra_space: f32 = @max(0.0, space - track_sizes);

    // 2. Distribute space up to limits:
    // For growth limits the limit is the growth limit itself unless the track is marked infinitely growable (or its
    // growth limit is still infinite), in which case it is the track's fit-content() argument if it has one, or
    // infinity if it does not. As the affected size of a track that isn't growable is its growth limit, those
    // tracks won't receive any space in this step.
    const growable: GrowableAnd(@TypeOf(track_is_affected)) = .{ .p = track_is_affected };
    const remaining_space = distributeSpaceUpToLimits(extra_space, tracks, growable, EqualProportion{}, GrowthLimitOrBaseSize{}, FitContentLimit{});

    // 3. Distribute space beyond limits
    // If space remains after all tracks are frozen, unfreeze and continue to distribute space to the item-incurred increase
    // ...when handling any intrinsic growth limit: all affected tracks.
    if (remaining_space > 0.0) {
        _ = distributeSpaceUpToLimits(remaining_space, tracks, track_is_affected, EqualProportion{}, GrowthLimitOrBaseSize{}, FitContentLimit{});
    }

    // 4. For each affected track, if the track’s item-incurred increase is larger than the track’s planned increase
    // set the track’s planned increase to that value.
    for (tracks) |*track| {
        if (track.item_incurred_increase > track.growth_limit_planned_increase) {
            track.growth_limit_planned_increase = track.item_incurred_increase;
        }

        // Reset the item_incurresed increase ready for the next space distribution
        track.item_incurred_increase = 0.0;
    }
}

/// 11.6 Maximise Tracks
/// Distributes free space (if any) to tracks with FINITE growth limits, up to their limits.
fn maximiseTracks(axis_tracks: []GridTrack, axis_available_grid_space: AvailableSpace) void {
    var used_space: f32 = -0.0;
    for (axis_tracks) |*track| used_space += track.base_size;
    const free_space = axis_available_grid_space.computeFreeSpace(used_space);
    if (free_space == inf) {
        for (axis_tracks) |*track| track.base_size = track.growth_limit;
    } else if (free_space > 0.0) {
        _ = distributeSpaceUpToLimits(free_space, axis_tracks, AnyTrack{}, EqualProportion{}, BaseSize{}, FitContentLimitedGrowthLimit{});
        for (axis_tracks) |*track| {
            track.base_size += track.item_incurred_increase;
            track.item_incurred_increase = 0.0;
        }
    }
}

/// 11.7. Expand Flexible Tracks
/// This step sizes flexible tracks using the largest value it can assign to an fr without exceeding the available space.
fn expandFlexibleTracks(
    tree: anytype,
    axis: AbstractAxis,
    axis_tracks: []GridTrack,
    other_axis_tracks: []const GridTrack,
    items: []GridItem,
    axis_min_size: ?f32,
    axis_max_size: ?f32,
    axis_available_space_for_expansion: AvailableSpace,
    inner_node_size: Size(?f32),
    get_track_size_estimate: TrackSizeEstimate,
) LayoutError!void {
    var item_sizer: IntrinsicSizeMeasurer(@TypeOf(tree)) = .{
        .tree = tree,
        .other_axis_tracks = other_axis_tracks,
        .axis = axis,
        .inner_node_size = inner_node_size,
        .get_track_size_estimate = get_track_size_estimate,
    };

    // First, find the grid’s used flex fraction:
    const flex_fraction: f32 = switch (axis_available_space_for_expansion) {
        // If the free space is zero:
        //    The used flex fraction is zero.
        // Otherwise, if the free space is a definite length:
        //   The used flex fraction is the result of finding the size of an fr using all of the grid tracks and
        //   a space to fill of the available grid space.
        .definite => |available_space| blk: {
            var used_space: f32 = -0.0;
            for (axis_tracks) |*track| used_space += track.base_size;
            const free_space = available_space - used_space;
            if (free_space <= 0.0) {
                break :blk 0.0;
            } else {
                break :blk findSizeOfFr(axis_tracks, available_space);
            }
        },
        // If ... sizing the grid container under a min-content constraint the used flex fraction is zero.
        .min_content => 0.0,
        // Otherwise, if the free space is an indefinite length:
        .max_content => blk: {
            // The used flex fraction is the maximum of:
            // For each flexible track, if the flexible track’s flex factor is greater than one,
            // the result of dividing the track’s base size by its flex factor; otherwise, the track’s base size.
            var track_fraction: TotalCmpMax = .{};
            for (axis_tracks) |*track| {
                if (!track.max_track_sizing_function.isFr()) continue;
                const flex_factor = track.flexFactor();
                track_fraction.add(if (flex_factor > 1.0) track.base_size / flex_factor else track.base_size);
            }
            // For each grid item that crosses a flexible track, the result of finding the size of an fr using all the grid tracks
            // that the item crosses and a space to fill of the item’s max-content contribution.
            var item_fraction: TotalCmpMax = .{};
            for (items) |*item| {
                if (!item.crossesFlexibleTrack(axis)) continue;
                const max_content_contribution = try item_sizer.maxContentContribution(item, axis_tracks);
                const tracks = item.spannedTracks(axis, @as([]const GridTrack, axis_tracks));
                item_fraction.add(findSizeOfFr(tracks, max_content_contribution));
            }
            const flex_fraction = @max(track_fraction.best orelse 0.0, item_fraction.best orelse 0.0);

            // If using this flex fraction would cause the grid to be smaller than the grid container’s min-width/height (or larger than the
            // grid container’s max-width/height), then redo this step, treating the free space as definite and the available grid space as equal
            // to the grid container’s inner size when it’s sized to its min-width/height (max-width/height).
            // (Note: min_size takes precedence over max_size)
            var hypothetical_grid_size: f32 = -0.0;
            for (axis_tracks) |*track| {
                hypothetical_grid_size += if (track.max_track_sizing_function.isFr()) inner: {
                    const track_flex_factor = track.max_track_sizing_function.inner.value();
                    break :inner @max(track.base_size, track_flex_factor * flex_fraction);
                } else track.base_size;
            }
            const min_size = axis_min_size orelse 0.0;
            const max_size = axis_max_size orelse inf;
            if (hypothetical_grid_size < min_size) {
                break :blk findSizeOfFr(axis_tracks, min_size);
            } else if (hypothetical_grid_size > max_size) {
                break :blk findSizeOfFr(axis_tracks, max_size);
            } else {
                break :blk flex_fraction;
            }
        },
    };

    // For each flexible track, if the product of the used flex fraction and the track’s flex factor is greater
    // than the track’s base size, set its base size to that product.
    for (axis_tracks) |*track| {
        if (!track.max_track_sizing_function.isFr()) continue;
        const track_flex_factor = track.max_track_sizing_function.inner.value();
        track.base_size = @max(track.base_size, track_flex_factor * flex_fraction);
    }
}

/// 11.7.1. Find the Size of an fr
/// This algorithm finds the largest size that an fr unit can be without exceeding the target size.
/// It must be called with a set of grid tracks and some quantity of space to fill.
fn findSizeOfFr(tracks: []const GridTrack, space_to_fill: f32) f32 {
    // Handle the trivial case where there is no space to fill
    // Do not remove as otherwise the loop below will loop infinitely
    if (space_to_fill == 0.0) {
        return 0.0;
    }

    // If the product of the hypothetical fr size (computed below) and any flexible track’s flex factor
    // is less than the track’s base size, then we must restart this algorithm treating all such tracks as inflexible.
    // We therefore wrap the entire algorithm in a loop, with an hypothetical_fr_size of INFINITY such that the above
    // condition can never be true for the first iteration.
    var hypothetical_fr_size: f32 = inf;
    var previous_iter_hypothetical_fr_size: f32 = undefined;
    // Every restart of the algorithm treats at least one more flexible track as inflexible, so a valid
    // hypothetical fr size is always found within `tracks.len + 1` iterations. Non-finite values (which
    // can arise from non-finite style inputs) break that invariant as comparisons against `NaN` are always
    // false, so we bound the iteration count to guarantee termination.
    const max_iterations = tracks.len + 1;
    for (0..max_iterations) |_| {
        // Let leftover space be the space to fill minus the base sizes of the non-flexible grid tracks.
        // Let flex factor sum be the sum of the flex factors of the flexible tracks. If this value is less than 1, set it to 1 instead.
        // We compute both of these in a single loop to avoid iterating over the data twice
        var used_space: f32 = 0.0;
        var naive_flex_factor_sum: f32 = 0.0;
        for (tracks) |*track| {
            // Tracks for which flex_factor * hypothetical_fr_size < track.base_size are treated as inflexible
            if (track.max_track_sizing_function.isFr() and
                track.max_track_sizing_function.inner.value() * hypothetical_fr_size >= track.base_size)
            {
                naive_flex_factor_sum += track.max_track_sizing_function.inner.value();
            } else {
                used_space += track.base_size;
            }
        }
        const leftover_space = space_to_fill - used_space;
        const flex_factor = @max(naive_flex_factor_sum, 1.0);

        // Let the hypothetical fr size be the leftover space divided by the flex factor sum.
        previous_iter_hypothetical_fr_size = hypothetical_fr_size;
        hypothetical_fr_size = leftover_space / flex_factor;

        // If the product of the hypothetical fr size and a flexible track’s flex factor is less than the track’s base size,
        // restart this algorithm treating all such tracks as inflexible.
        // We keep track of the hypothetical_fr_size
        const hypothetical_fr_size_is_valid = for (tracks) |*track| {
            if (track.max_track_sizing_function.isFr()) {
                const track_flex_factor = track.max_track_sizing_function.inner.value();
                if (!(track_flex_factor * hypothetical_fr_size >= track.base_size or
                    track_flex_factor * previous_iter_hypothetical_fr_size < track.base_size)) break false;
            }
        } else true;
        if (hypothetical_fr_size_is_valid) {
            break;
        }
    }

    // Return the hypothetical fr size.
    return hypothetical_fr_size;
}

/// 11.8. Stretch auto Tracks
/// This step expands tracks that have an auto max track sizing function by dividing any remaining positive, definite free space equally amongst them.
fn stretchAutoTracks(axis_tracks: []GridTrack, axis_min_size: ?f32, axis_available_space_for_expansion: AvailableSpace) void {
    var num_auto_tracks: usize = 0;
    for (axis_tracks) |*track| {
        if (track.max_track_sizing_function.isAuto()) num_auto_tracks += 1;
    }
    if (num_auto_tracks > 0) {
        var used_space: f32 = -0.0;
        for (axis_tracks) |*track| used_space += track.base_size;

        // If the free space is indefinite, but the grid container has a definite min-width/height
        // use that size to calculate the free space for this step instead.
        const free_space = if (axis_available_space_for_expansion.isDefinite())
            axis_available_space_for_expansion.computeFreeSpace(used_space)
        else if (axis_min_size) |size|
            size - used_space
        else
            0.0;
        if (free_space > 0.0) {
            const extra_space_per_auto_track = free_space / @as(f32, @floatFromInt(num_auto_tracks));
            for (axis_tracks) |*track| {
                if (track.max_track_sizing_function.isAuto()) track.base_size += extra_space_per_auto_track;
            }
        }
    }
}

/// Helper function for distributing space to tracks evenly
/// Used by both distributeItemSpaceToBaseSize and maximiseTracks steps
fn distributeSpaceUpToLimits(
    space_to_distribute_in: f32,
    tracks: []GridTrack,
    track_is_affected: anytype,
    track_distribution_proportion: anytype,
    track_affected_property: anytype,
    track_limit: anytype,
) f32 {
    // Define a small constant to avoid infinite loops due to rounding errors. Rather than stopping distributing
    // extra space when it gets to exactly zero, we will stop when it falls below this amount
    const threshold: f32 = 0.01;

    // Each iteration freezes at least one track at its limit, so the loop always completes within
    // `tracks.len + 1` iterations. Non-finite values (which can arise from non-finite style inputs) can
    // prevent any space from being distributed, so we bound the iteration count to guarantee termination.
    const max_iterations = tracks.len + 1;

    var space_to_distribute = space_to_distribute_in;
    for (0..max_iterations) |_| {
        if (space_to_distribute <= threshold) {
            break;
        }
        var track_distribution_proportion_sum: f32 = -0.0;
        for (tracks) |*track| {
            if (track_affected_property.call(track) + track.item_incurred_increase < track_limit.call(track) and track_is_affected.call(track)) {
                track_distribution_proportion_sum += track_distribution_proportion.call(track);
            }
        }

        if (track_distribution_proportion_sum == 0.0) {
            break;
        }

        // Compute item-incurred increase for this iteration
        var min_increase_limit: TotalCmpMin = .{};
        for (tracks) |*track| {
            if (track_affected_property.call(track) + track.item_incurred_increase < track_limit.call(track) and track_is_affected.call(track)) {
                min_increase_limit.add((track_limit.call(track) - track_affected_property.call(track) - track.item_incurred_increase) /
                    track_distribution_proportion.call(track));
            }
        }
        // We will never pass an empty track list to this function
        const iteration_item_incurred_increase = @min(min_increase_limit.best.?, space_to_distribute / track_distribution_proportion_sum);

        for (tracks) |*track| {
            if (!track_is_affected.call(track)) continue;
            const increase = iteration_item_incurred_increase * track_distribution_proportion.call(track);
            if (increase > 0.0 and
                track_affected_property.call(track) + track.item_incurred_increase + increase <= track_limit.call(track) + threshold)
            {
                track.item_incurred_increase += increase;
                space_to_distribute -= increase;
            }
        }
    }

    return space_to_distribute;
}

test "total cmp helpers" {
    var max: TotalCmpMax = .{};
    max.add(-0.0);
    max.add(0.0);
    try std.testing.expect(!std.math.signbit(max.best.?));
    var min: TotalCmpMin = .{};
    min.add(0.0);
    min.add(-0.0);
    min.add(-0.0);
    try std.testing.expect(std.math.signbit(min.best.?));
}
