//! Contains GridItem used to represent a single grid item during layout
const std = @import("std");
const Style = @import("../../../style.zig").Style;
const geometry = @import("../../../geometry.zig");
const AbstractAxis = geometry.AbstractAxis;
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../../../style.zig");
const AlignItems = style_mod.AlignItems;
const AlignSelf = style_mod.AlignSelf;
const AvailableSpace = style_mod.AvailableSpace;
const BoxSizing = style_mod.BoxSizing;
const Dimension = style_mod.Dimension;
const LengthPercentage = style_mod.LengthPercentage;
const LengthPercentageAuto = style_mod.LengthPercentageAuto;
const Overflow = style_mod.Overflow;
const layout = @import("../../../tree/layout.zig");
const LayoutError = layout.LayoutError;
const OofCandidate = layout.OofCandidate;
const NodeId = @import("../../../tree/node.zig").NodeId;
const traits = @import("../../../tree/traits.zig");
const math = @import("../../../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const maybeMin = math.maybeMin;
const maybeSub = math.maybeSub;
const resolve = @import("../../../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../../../util/sys.zig");
const sizing_keyword = @import("../../common/sizing_keyword.zig");
const resolveSizingKeyword = sizing_keyword.resolveSizingKeyword;
const OriginZeroLine = @import("coordinates.zig").OriginZeroLine;
const GridTrack = @import("grid_track.zig").GridTrack;
const Range = @import("grid_track_counts.zig").Range;

/// How to estimate the size of a track in the axis opposite to the one being sized, when computing
/// an item's grid area (upstream passes a `fn(&GridTrack, Option<f32>, &Tree) -> Option<f32>`)
pub const TrackSizeEstimate = enum {
    /// The definite value of the track's max track sizing function (used for the first column sizing pass)
    max_track_sizing_function,
    /// The track's base size (used once the other axis has been sized)
    base_size,

    /// Estimate the size of `track`
    pub fn estimate(self: TrackSizeEstimate, track: *const GridTrack, parent_size: ?f32, tree: anytype) ?f32 {
        return switch (self) {
            .max_track_sizing_function => track.max_track_sizing_function.definiteValue(parent_size, tree),
            .base_size => track.base_size,
        };
    }
};

/// `Option<f32>` equality (upstream `PartialEq`: float comparison of the payloads)
pub fn optionalEql(a: ?f32, b: ?f32) bool {
    if (a) |av| {
        if (b) |bv| return av == bv;
        return false;
    }
    return b == null;
}

/// The known_dimensions computed for a grid item for a given grid area size
pub const KnownDimensionsCacheEntry = struct {
    /// The grid area size that `known_dimensions` was computed for
    grid_area_size: Size(?f32),
    /// The cached known_dimensions
    known_dimensions: Size(?f32),
};

/// Represents a single grid item
pub const GridItem = struct {
    /// The id of the node that this item represents
    node: NodeId,

    /// The index of the item in the children array
    source_order: u16,

    /// The item's definite row-start and row-end, as resolved by the placement algorithm
    /// (in origin-zero coordinates). Set by the placement algorithm.
    row: Line(OriginZeroLine),
    /// The items definite column-start and column-end, as resolved by the placement algorithm
    /// (in origin-zero coordinates). Set by the placement algorithm.
    column: Line(OriginZeroLine),

    /// Is it a compressible replaced element?
    /// https://drafts.csswg.org/css-sizing-3/#min-content-zero
    is_compressible_replaced: bool,
    /// Whether the item is a replaced element. Such items are not stretched by `normal` alignment.
    is_replaced: bool,
    /// The item's overflow style
    overflow: Point(Overflow),
    /// The item's box_sizing style
    box_sizing: BoxSizing,
    /// The item's size style
    size: Size(Dimension),
    /// The item's min_size style
    min_size: Size(LengthPercentageAuto),
    /// The item's max_size style
    max_size: Size(LengthPercentageAuto),
    /// The item's aspect_ratio style
    aspect_ratio: ?f32,
    /// The item's padding style
    padding: Rect(LengthPercentage),
    /// The item's border style
    border: Rect(LengthPercentage),
    /// The item's margin style
    margin: Rect(LengthPercentageAuto),
    /// The item's align_self property, or the parent's align_items property if it is `null`
    align_self: AlignSelf,
    /// The item's justify_self property, or the parent's justify_items property if it is `null`
    justify_self: AlignSelf,
    /// The item's first baseline (horizontal), measured from the top of its border box. Set from the item's
    /// intrinsic layout when resolving baseline alignment during track sizing, then from its final layout.
    baseline: ?f32,
    /// Shim for baseline alignment that acts like an extra top margin
    /// TODO: Support last baseline and vertical text baselines
    baseline_shim: f32,

    /// The item's definite row-start and row-end (same as `row` field, except in a different coordinate system)
    /// (as indexes into the list of GridTrack stored in a grid's AbstractAxisTracks)
    row_indexes: Line(u16),
    /// The items definite column-start and column-end (same as `column` field, except in a different coordinate system)
    /// (as indexes into the list of GridTrack stored in a grid's AbstractAxisTracks)
    column_indexes: Line(u16),

    /// Whether the item crosses a flexible row
    crosses_flexible_row: bool,
    /// Whether the item crosses a flexible column
    crosses_flexible_column: bool,
    /// Whether the item crosses a intrinsic row
    crosses_intrinsic_row: bool,
    /// Whether the item crosses a intrinsic column
    crosses_intrinsic_column: bool,

    // Caches for intrinsic size computation. These caches are only valid for a single run of the track-sizing algorithm.
    /// Cache for the known_dimensions input to intrinsic sizing computation
    grid_area_size_cache: ?Size(?f32),
    /// Cache for the known_dimensions passed to the child when computing its intrinsic contributions, stored along with
    /// the grid area size it was computed for. Must be cleared whenever `baseline_shim` changes.
    known_dimensions_cache: ?KnownDimensionsCacheEntry,
    /// Cache for the min-content size
    min_content_contribution_cache: Size(?f32),
    /// Cache for the minimum contribution
    minimum_contribution_cache: Size(?f32),
    /// Cache for the max-content size
    max_content_contribution_cache: Size(?f32),

    /// Final y position, excluding any relative offset (which does not affect the container's baseline).
    /// Used to compute baseline alignment for the container.
    y_position: f32,
    /// Final height. Used to compute baseline alignment for the container.
    height: f32,

    /// Out-of-flow candidates bubbled out of this item's subtree (anchors relative to the
    /// container's border box). Scratch memory.
    oof_candidates: std.ArrayList(OofCandidate) = .empty,

    /// Create a new item from its style. Its placement (`row`/`column`) is filled in by the placement algorithm.
    pub fn newWithStyleAndOrder(
        node: NodeId,
        style: *const Style,
        parent_align_items: AlignItems,
        parent_justify_items: AlignItems,
        source_order: u16,
    ) GridItem {
        const unplaced: Line(OriginZeroLine) = .{ .start = OriginZeroLine.from(0), .end = OriginZeroLine.from(0) };
        return .{
            .node = node,
            .source_order = source_order,
            .row = unplaced,
            .column = unplaced,
            .is_compressible_replaced = style.isCompressibleReplaced(),
            .is_replaced = style.item_is_replaced,
            .overflow = style.overflow,
            .box_sizing = style.box_sizing,
            .size = style.size,
            .min_size = style.min_size,
            .max_size = style.max_size,
            .aspect_ratio = style.aspect_ratio,
            .padding = style.padding,
            .border = style.border,
            .margin = style.margin,
            .align_self = style.align_self orelse parent_align_items,
            .justify_self = style.justify_self orelse parent_justify_items,
            .baseline = null,
            .baseline_shim = 0.0,
            .row_indexes = .{ .start = 0, .end = 0 }, // Properly initialised later
            .column_indexes = .{ .start = 0, .end = 0 }, // Properly initialised later
            .crosses_flexible_row = false, // Properly initialised later
            .crosses_flexible_column = false, // Properly initialised later
            .crosses_intrinsic_row = false, // Properly initialised later
            .crosses_intrinsic_column = false, // Properly initialised later
            .grid_area_size_cache = null,
            .min_content_contribution_cache = Size(?f32).none,
            .max_content_contribution_cache = Size(?f32).none,
            .known_dimensions_cache = null,
            .minimum_contribution_cache = Size(?f32).none,
            .y_position = 0.0,
            .height = 0.0,
        };
    }

    /// Whether the item has an auto margin in the block axis
    pub fn hasAutoBlockMargin(self: *const GridItem) bool {
        return self.margin.top.isAuto() or self.margin.bottom.isAuto();
    }

    /// Whether the item's block size depends on the size of its row(s), creating a cyclic
    /// dependency with baseline alignment (which affects row sizing). Per
    /// <https://www.w3.org/TR/css-grid-1/#row-align> such items do not participate in baseline
    /// alignment and are aligned using their fallback alignment instead.
    pub fn hasCyclicBlockSizeDependency(self: *const GridItem) bool {
        return self.size.height.inner.usesPercentage() and (self.crosses_intrinsic_row or self.crosses_flexible_row);
    }

    /// Returns true if the item participates in baseline alignment: it has `align-self: baseline`
    /// and neither of its block-axis margins are `auto`.
    /// See <https://www.w3.org/TR/css-align-3/#baseline-align-self>
    pub fn participatesInBaselineAlignment(self: *const GridItem) bool {
        return self.align_self.keyword == .baseline and
            !self.hasAutoBlockMargin() and
            !self.hasCyclicBlockSizeDependency();
    }

    /// This item's placement in the specified axis in OriginZero coordinates
    pub fn placement(self: *const GridItem, axis: AbstractAxis) Line(OriginZeroLine) {
        return switch (axis) {
            .block => self.row,
            .@"inline" => self.column,
        };
    }

    /// This item's placement in the specified axis as GridTrackVec indices
    pub fn placementIndexes(self: *const GridItem, axis: AbstractAxis) Line(u16) {
        return switch (axis) {
            .block => self.row_indexes,
            .@"inline" => self.column_indexes,
        };
    }

    /// Returns a range which can be used as an index into the GridTrackVec in the specified axis
    /// which will produce a sub-slice of covering all the tracks and lines that this item spans
    /// excluding the lines that bound it.
    pub fn trackRangeExcludingLines(self: *const GridItem, axis: AbstractAxis) Range(usize) {
        const indexes = self.placementIndexes(axis);
        return .{ .start = @as(usize, indexes.start) + 1, .end = @as(usize, indexes.end) };
    }

    /// The tracks (and gutters) spanned by this item in the specified axis, excluding the lines that bound it
    pub fn spannedTracks(self: *const GridItem, axis: AbstractAxis, axis_tracks: anytype) @TypeOf(axis_tracks) {
        const range = self.trackRangeExcludingLines(axis);
        return axis_tracks[range.start..range.end];
    }

    /// Whether any track spanned by this item in the specified axis satisfies `predicate`
    /// (`predicate` is any value with a `call(self, *const GridTrack) bool` method)
    pub fn spansTrackMatching(self: *const GridItem, axis: AbstractAxis, axis_tracks: []const GridTrack, predicate: anytype) bool {
        for (self.spannedTracks(axis, axis_tracks)) |*track| {
            if (predicate.call(track)) return true;
        }
        return false;
    }

    /// Returns the number of tracks that this item spans in the specified axis
    pub fn span(self: *const GridItem, axis: AbstractAxis) u16 {
        return switch (axis) {
            .block => self.row.span(),
            .@"inline" => self.column.span(),
        };
    }

    /// Returns the pre-computed value indicating whether the grid item crosses a flexible track in
    /// the specified axis
    pub fn crossesFlexibleTrack(self: *const GridItem, axis: AbstractAxis) bool {
        return switch (axis) {
            .@"inline" => self.crosses_flexible_column,
            .block => self.crosses_flexible_row,
        };
    }

    /// Returns the pre-computed value indicating whether the grid item crosses an intrinsic track in
    /// the specified axis
    pub fn crossesIntrinsicTrack(self: *const GridItem, axis: AbstractAxis) bool {
        return switch (axis) {
            .@"inline" => self.crosses_intrinsic_column,
            .block => self.crosses_intrinsic_row,
        };
    }

    /// For an item spanning multiple tracks, the upper limit used to calculate its limited min-/max-content contribution is the
    /// sum of the fixed max track sizing functions of any tracks it spans, and is applied if it only spans such tracks.
    pub fn spannedTrackLimit(
        self: *const GridItem,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        axis_parent_size: ?f32,
        calc_resolver: anytype,
    ) ?f32 {
        const spanned_tracks = self.spannedTracks(axis, axis_tracks);
        for (spanned_tracks) |*track| {
            if (track.max_track_sizing_function.definiteLimit(axis_parent_size, calc_resolver) == null) return null;
        }
        var limit: f32 = -0.0;
        for (spanned_tracks) |*track| {
            limit += track.max_track_sizing_function.definiteLimit(axis_parent_size, calc_resolver).?;
        }
        return limit;
    }

    /// Similar to the spannedTrackLimit, but excludes FitContent arguments from the limit.
    /// Used to clamp the automatic minimum contributions of an item
    pub fn spannedFixedTrackLimit(
        self: *const GridItem,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        axis_parent_size: ?f32,
        calc_resolver: anytype,
    ) ?f32 {
        const spanned_tracks = self.spannedTracks(axis, axis_tracks);
        for (spanned_tracks) |*track| {
            if (track.max_track_sizing_function.definiteValue(axis_parent_size, calc_resolver) == null) return null;
        }
        var limit: f32 = -0.0;
        for (spanned_tracks) |*track| {
            limit += track.max_track_sizing_function.definiteValue(axis_parent_size, calc_resolver).?;
        }
        return limit;
    }

    /// Retrieve the known_dimensions for the given grid area size from the cache or compute them.
    /// The min-content and max-content contributions of an item are both computed from the same known_dimensions.
    fn knownDimensionsCached(self: *GridItem, tree: anytype, grid_area_size: Size(?f32)) Size(?f32) {
        if (self.known_dimensions_cache) |entry| {
            if (optionalEql(entry.grid_area_size.width, grid_area_size.width) and
                optionalEql(entry.grid_area_size.height, grid_area_size.height))
            {
                return entry.known_dimensions;
            }
        }
        const known_dimensions = self.knownDimensions(tree, grid_area_size);
        self.known_dimensions_cache = .{ .grid_area_size = grid_area_size, .known_dimensions = known_dimensions };
        return known_dimensions;
    }

    /// Whether the given self-alignment stretches the item: `stretch`, or `normal` unless the item is replaced
    fn isStretchAligned(self: *const GridItem, alignment: AlignSelf) bool {
        return switch (alignment.keyword) {
            .stretch => true,
            .normal => !self.is_replaced,
            else => false,
        };
    }

    /// Compute the known_dimensions to be passed to the child sizing functions
    /// The key thing that is being done here is applying stretch alignment, which is necessary to
    /// allow percentage sizes further down the tree to resolve properly in some cases
    fn knownDimensions(self: *const GridItem, tree: anytype, grid_area_size: Size(?f32)) Size(?f32) {
        const margins = self.marginsAxisSumsWithBaselineShims(grid_area_size.width, tree);

        const aspect_ratio = self.aspect_ratio;
        // CSS resolves percentage padding and border against the inline size of the containing
        // block. For a grid item under intrinsic measurement, that inline-size basis is the grid
        // area's width when it is definite.
        // Spec:
        // https://www.w3.org/TR/css-grid-1/#item-margins
        // https://www.w3.org/TR/CSS22/box.html#padding-properties
        const padding = resolveOrZero(self.padding, grid_area_size.width, tree);
        const border = resolveOrZero(self.border, grid_area_size.width, tree);
        const padding_border_size = padding.add(border).sumAxes();
        const box_sizing_adjustment = if (self.box_sizing == .content_box) padding_border_size else Size(f32).zero;
        const inherent_size = maybeAdd(maybeResolve(self.size, grid_area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
        const min_size = maybeMax(
            maybeAdd(maybeResolve(self.min_size, grid_area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment)
                // The size of the item is floored by its padding and border
                .@"or"(.{ .width = padding_border_size.width, .height = padding_border_size.height }),
            padding_border_size,
        );
        const max_size = maybeAdd(maybeResolve(self.max_size, grid_area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);

        const grid_area_minus_item_margins_size = maybeMax(maybeSub(grid_area_size, margins), Size(f32).zero);

        // If node is absolutely positioned and width is not set explicitly, then deduce it
        // from left, right and container_content_box if both are set.
        const width: ?f32 = inherent_size.width orelse blk: {
            // A width that is a sizing keyword is not auto, so it does not stretch. The stretch
            // keyword resolves to an exact width; the others resolve during content measurement.
            if (self.size.width.isSizingKeyword()) {
                if (resolveSizingKeyword(self.size.width, grid_area_minus_item_margins_size.width, grid_area_size.width, tree)) |resolution| {
                    break :blk switch (resolution) {
                        .exact => |w| w,
                        .measure => null,
                    };
                }
                break :blk null;
            }

            // Apply width based on stretch alignment if:
            //  - Alignment style is "stretch" or "normal". Note that "normal" is treated as "stretch"
            //    here regardless of whether the item has a preferred size or aspect ratio in this axis,
            //    which differs from the rule used when the item is finally aligned (see `alignAndPositionItem`).
            //    Replaced elements are not stretched by "normal".
            //  - The node is not absolutely positioned
            //  - The node does not have auto margins in this axis.
            if (!self.margin.left.isAuto() and !self.margin.right.isAuto() and self.isStretchAligned(self.justify_self)) {
                break :blk grid_area_minus_item_margins_size.width;
            }

            break :blk null;
        };
        // Reapply aspect ratio after stretch and absolute position width adjustments
        const size_a = (Size(?f32){ .width = width, .height = inherent_size.height }).maybeApplyAspectRatio(aspect_ratio);

        const height: ?f32 = size_a.height orelse blk: {
            // A height that is a sizing keyword is not auto, so it does not stretch. The stretch
            // keyword resolves to an exact height; the others resolve during content measurement.
            if (self.size.height.isSizingKeyword()) {
                if (resolveSizingKeyword(self.size.height, grid_area_minus_item_margins_size.height, grid_area_size.height, tree)) |resolution| {
                    break :blk switch (resolution) {
                        .exact => |h| h,
                        .measure => null,
                    };
                }
                break :blk null;
            }

            // Apply height based on stretch alignment if:
            //  - Alignment style is "stretch" or "normal" (see the note on width above)
            //  - The node is not absolutely positioned
            //  - The node does not have auto margins in this axis.
            if (!self.margin.top.isAuto() and !self.margin.bottom.isAuto() and self.isStretchAligned(self.align_self)) {
                break :blk grid_area_minus_item_margins_size.height;
            }

            break :blk null;
        };
        // Reapply aspect ratio after stretch and absolute position height adjustments
        const size_b = (Size(?f32){ .width = size_a.width, .height = height }).maybeApplyAspectRatio(aspect_ratio);

        // Clamp size by min and max width/height
        return maybeClamp(size_b, min_size, max_size);
    }

    /// Returns the grid area's size in the specified axis when every spanned track has a definite fixed size.
    ///
    /// During intrinsic sizing, percentages on grid items resolve against the size of the grid area,
    /// not the grid container. If the spanned tracks in an axis are not all definite yet, the grid
    /// area is still indefinite in that axis and percentage-dependent values must stay unresolved here.
    ///
    /// Spec:
    /// https://www.w3.org/TR/css-grid-1/#grid-item-sizing
    /// https://www.w3.org/TR/css-grid-1/#algo-overview
    ///
    /// Compute the available_space to be passed to the child sizing functions
    /// These are estimates based on either the max track sizing function or the provisional base size in the opposite
    /// axis to the one currently being sized.
    /// https://www.w3.org/TR/css-grid-1/#algo-overview
    pub fn gridAreaSize(
        self: *const GridItem,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        other_axis_tracks: []const GridTrack,
        available_space: Size(?f32),
        get_track_size_estimate: TrackSizeEstimate,
        tree: anytype,
    ) Size(?f32) {
        var size = Size(?f32).none;
        size.set(axis, blk: {
            var sum: f32 = -0.0;
            for (self.spannedTracks(axis, axis_tracks)) |*track| {
                const min_size = track.min_track_sizing_function.definiteValue(available_space.get(axis), tree) orelse break :blk null;
                const max_size = track.max_track_sizing_function.definiteValue(available_space.get(axis), tree) orelse break :blk null;

                if (min_size == max_size) {
                    sum += track.base_size;
                } else {
                    break :blk null;
                }
            }
            break :blk sum;
        });

        size.set(axis.other(), blk: {
            var sum: f32 = -0.0;
            for (self.spannedTracks(axis.other(), other_axis_tracks)) |*track| {
                const estimate = get_track_size_estimate.estimate(track, available_space.get(axis.other()), tree) orelse break :blk null;
                sum += estimate + track.content_alignment_adjustment;
            }
            break :blk sum;
        });

        return size;
    }

    /// Retrieve the available_space from the cache or compute them using the passed parameters
    pub fn gridAreaSizeCached(
        self: *GridItem,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        other_axis_tracks: []const GridTrack,
        available_space: Size(?f32),
        get_track_size_estimate: TrackSizeEstimate,
        tree: anytype,
    ) Size(?f32) {
        if (self.grid_area_size_cache) |cached| return cached;
        const grid_area_size = self.gridAreaSize(axis, axis_tracks, other_axis_tracks, available_space, get_track_size_estimate, tree);
        self.grid_area_size_cache = grid_area_size;
        return grid_area_size;
    }

    /// Compute the item's resolved margins for size contributions. Horizontal percentage margins always resolve
    /// to zero if the container size is indefinite as otherwise this would introduce a cyclic dependency.
    pub fn marginsAxisSumsWithBaselineShims(self: *const GridItem, inner_node_width: ?f32, tree: anytype) Size(f32) {
        const rect: Rect(f32) = .{
            .left = resolveOrZero(self.margin.left, @as(?f32, 0.0), tree),
            .right = resolveOrZero(self.margin.right, @as(?f32, 0.0), tree),
            .top = resolveOrZero(self.margin.top, inner_node_width, tree) + self.baseline_shim,
            .bottom = resolveOrZero(self.margin.bottom, inner_node_width, tree),
        };
        return rect.sumAxes();
    }

    /// Compute the item's min content contribution from the provided parameters
    pub fn minContentContribution(
        self: *GridItem,
        axis: AbstractAxis,
        tree: anytype,
        grid_area_size: Size(?f32),
        available_space: Size(?f32),
    ) LayoutError!f32 {
        const known_dimensions = self.knownDimensionsCached(tree, grid_area_size);
        // If the item's size in the axis being measured is already known then that size is its contribution,
        // and we can avoid calling into the child entirely.
        if (known_dimensions.get(axis)) |size| {
            return size;
        }
        // The child sees the grid area as its containing block during intrinsic measurement, so
        // percentage box properties resolve against the grid area when that size is definite.
        // Spec:
        // https://www.w3.org/TR/css-grid-1/#grid-item-sizing
        // https://www.w3.org/TR/css-grid-1/#algo-overview
        const minus_margins = self.availableSpaceMinusMargins(grid_area_size, available_space, tree);
        return traits.measureChildSize(
            tree,
            self.node,
            known_dimensions,
            grid_area_size,
            self.keywordAdjustedAvailableSpace(grid_area_size, .{
                .width = if (minus_margins.width) |s| .{ .definite = s } else .min_content,
                .height = if (minus_margins.height) |s| .{ .definite = s } else .min_content,
            }, tree),
            .inherent_size,
            axis.asAbsNaive(),
            Line(bool).false,
        );
    }

    /// Retrieve the item's min content contribution from the cache or compute it using the provided parameters
    pub fn minContentContributionCached(
        self: *GridItem,
        axis: AbstractAxis,
        tree: anytype,
        grid_area_size: Size(?f32),
        available_space: Size(?f32),
    ) LayoutError!f32 {
        if (self.min_content_contribution_cache.get(axis)) |cached| return cached;
        const size = try self.minContentContribution(axis, tree, grid_area_size, available_space);
        self.min_content_contribution_cache.set(axis, size);
        return size;
    }

    /// Compute the item's max content contribution from the provided parameters
    pub fn maxContentContribution(
        self: *GridItem,
        axis: AbstractAxis,
        tree: anytype,
        grid_area_size: Size(?f32),
        available_space: Size(?f32),
    ) LayoutError!f32 {
        const known_dimensions = self.knownDimensionsCached(tree, grid_area_size);
        // If the item's size in the axis being measured is already known then that size is its contribution,
        // and we can avoid calling into the child entirely.
        if (known_dimensions.get(axis)) |size| {
            return size;
        }
        // See the min-content path above. Max-content measurement uses the same containing-block
        // basis so percentage-dependent item geometry is measured from the grid area rather than
        // from the container.
        const minus_margins = self.availableSpaceMinusMargins(grid_area_size, available_space, tree);
        return traits.measureChildSize(
            tree,
            self.node,
            known_dimensions,
            grid_area_size,
            self.keywordAdjustedAvailableSpace(grid_area_size, .{
                .width = if (minus_margins.width) |s| .{ .definite = s } else .max_content,
                .height = if (minus_margins.height) |s| .{ .definite = s } else .max_content,
            }, tree),
            .inherent_size,
            axis.asAbsNaive(),
            Line(bool).false,
        );
    }

    /// Subtract the item's margins (and baseline shim) from the definite axes of the space available
    /// to the item's margin box, giving the available space that is passed to the item.
    /// As when the item is laid out into its final position, margins resolve against the width
    /// of the grid area and `auto` margins are treated as zero.
    fn availableSpaceMinusMargins(
        self: *const GridItem,
        grid_area_size: Size(?f32),
        available_space: Size(?f32),
        tree: anytype,
    ) Size(?f32) {
        if (available_space.width == null and available_space.height == null) {
            return available_space;
        }
        const margin = resolveOrZero(self.margin, grid_area_size.width, tree);
        return .{
            .width = if (available_space.width) |width| @max(width - margin.horizontalAxisSum(), 0.0) else null,
            .height = if (available_space.height) |height| @max(height - margin.verticalAxisSum() - self.baseline_shim, 0.0) else null,
        };
    }

    /// Override the available space in each axis whose size style is a sizing keyword that
    /// measures the item under a specific available space constraint
    /// (min-content, max-content, fit-content, fit-content(...))
    fn keywordAdjustedAvailableSpace(
        self: *const GridItem,
        grid_area_size: Size(?f32),
        available_space: Size(AvailableSpace),
        tree: anytype,
    ) Size(AvailableSpace) {
        if (!self.size.width.isSizingKeyword() and !self.size.height.isSizingKeyword()) {
            return available_space;
        }
        const margins = self.marginsAxisSumsWithBaselineShims(grid_area_size.width, tree);
        var adjusted = available_space;
        for ([_]AbstractAxis{ .@"inline", .block }) |axis| {
            const size_style = self.size.get(axis);
            if (!size_style.isSizingKeyword()) {
                continue;
            }
            const stretch_size = maybeMax(maybeSub(grid_area_size.get(axis), margins.get(axis)), @as(f32, 0.0));
            if (resolveSizingKeyword(size_style, stretch_size, grid_area_size.get(axis), tree)) |resolution| {
                switch (resolution) {
                    .measure => |available| adjusted.set(axis, available),
                    .exact => {},
                }
            }
        }
        return adjusted;
    }

    /// Retrieve the item's max content contribution from the cache or compute it using the provided parameters
    pub fn maxContentContributionCached(
        self: *GridItem,
        axis: AbstractAxis,
        tree: anytype,
        grid_area_size: Size(?f32),
        available_space: Size(?f32),
    ) LayoutError!f32 {
        if (self.max_content_contribution_cache.get(axis)) |cached| return cached;
        const size = try self.maxContentContribution(axis, tree, grid_area_size, available_space);
        self.max_content_contribution_cache.set(axis, size);
        return size;
    }

    /// The minimum contribution of an item is the smallest outer size it can have.
    /// Specifically:
    ///   - If the item’s computed preferred size behaves as auto or depends on the size of its containing block in the relevant axis:
    ///     Its minimum contribution is the outer size that would result from assuming the item’s used minimum size as its preferred size;
    ///   - Else the item’s minimum contribution is its min-content contribution.
    ///
    /// Because the minimum contribution often depends on the size of the item’s content, it is considered a type of intrinsic size contribution.
    /// See: https://www.w3.org/TR/css-grid-1/#min-size-auto
    pub fn minimumContribution(
        self: *GridItem,
        tree: anytype,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        grid_area_size: Size(?f32),
        inner_node_size: Size(?f32),
    ) LayoutError!f32 {
        const padding = resolveOrZero(self.padding, grid_area_size.width, tree);
        const border = resolveOrZero(self.border, grid_area_size.width, tree);
        const padding_border_size = padding.add(border).sumAxes();
        const box_sizing_adjustment = if (self.box_sizing == .content_box) padding_border_size else Size(f32).zero;
        const preferred = maybeAdd(maybeResolve(self.size, grid_area_size, tree).maybeApplyAspectRatio(self.aspect_ratio), box_sizing_adjustment).get(axis);
        if (preferred) |size| {
            // A definite preferred size is clamped by the minimum and maximum sizes. For a replaced element (but
            // not a form control), an indefinite percentage maximum size is resolved against zero. The spec also
            // applies this to form controls (https://drafts.csswg.org/css-sizing-3/#min-content-zero) but no
            // browser does (https://github.com/w3c/csswg-drafts/issues/6348).
            const min_size_style = self.min_size.get(axis);
            const max_size_style = self.max_size.get(axis);
            if (min_size_style.isAuto() and max_size_style.isAuto()) {
                return size;
            }
            const basis = grid_area_size.get(axis);
            const max_size_basis: ?f32 = if (self.is_replaced) (basis orelse 0.0) else basis;
            const adjustment = box_sizing_adjustment.get(axis);
            const min_size = maybeResolve(min_size_style, basis, tree);
            const max_size = maybeResolve(max_size_style, max_size_basis, tree);
            return maybeClamp(size, maybeAdd(min_size, adjustment), maybeAdd(max_size, adjustment));
        }

        // A preferred size that is a sizing keyword other than `stretch` does not behave as auto,
        // so the minimum contribution is the min-content contribution.
        const size_style = self.size.get(axis);
        if (size_style.isSizingKeyword() and !size_style.isStretch()) {
            return self.minContentContributionCached(axis, tree, grid_area_size, grid_area_size);
        }

        const zeroed_area_size: Size(?f32) = .{ .width = grid_area_size.width orelse 0.0, .height = grid_area_size.height orelse 0.0 };
        if (maybeAdd(maybeResolve(self.min_size, zeroed_area_size, tree).maybeApplyAspectRatio(self.aspect_ratio), box_sizing_adjustment).get(axis)) |min_size| {
            return min_size;
        }

        if (self.overflow.get(axis).maybeIntoAutomaticMinSize()) |min_size| {
            return min_size;
        }

        // Automatic minimum size. See https://www.w3.org/TR/css-grid-1/#min-size-auto

        // To provide a more reasonable default minimum size for grid items, the used value of its automatic minimum size
        // in a given axis is the content-based minimum size if all of the following are true:
        const item_axis_tracks = self.spannedTracks(axis, axis_tracks);

        // it is not a scroll container (handled above)

        // it spans at least one track in that axis whose min track sizing function is auto
        var spans_auto_min_track = false;
        for (item_axis_tracks) |*track| {
            if (track.min_track_sizing_function.behavesAsAuto(inner_node_size.get(axis))) {
                spans_auto_min_track = true;
                break;
            }
        }

        // if it spans more than one track in that axis, none of those tracks are flexible
        const only_span_one_track = item_axis_tracks.len == 1;
        var spans_fr_track = false;
        for (item_axis_tracks) |*track| {
            if (track.max_track_sizing_function.isFr()) {
                spans_fr_track = true;
                break;
            }
        }
        const use_content_based_minimum = spans_auto_min_track and (only_span_one_track or !spans_fr_track);

        // Otherwise, the automatic minimum size is zero, as usual.
        if (use_content_based_minimum) {
            var minimum_contribution = try self.minContentContributionCached(axis, tree, grid_area_size, grid_area_size);

            // If the item is a compressible replaced element, and has a definite preferred size or maximum size in the
            // relevant axis, the size suggestion is capped by those sizes; for this purpose, any indefinite percentages
            // in these sizes are resolved against zero (and considered definite).
            if (self.is_compressible_replaced) {
                const size = maybeResolve(self.size.get(axis), @as(?f32, 0.0), tree);
                const max_size = maybeResolve(self.max_size.get(axis), @as(?f32, 0.0), tree);
                minimum_contribution = maybeMin(maybeMin(minimum_contribution, size), max_size);
            }

            // The content-based minimum size is additionally clamped by the sum of any fixed max track sizing
            // functions of the tracks the item spans. Note that this clamp does not apply to explicitly specified
            // preferred or minimum sizes, and that the argument to fit-content() does not clamp the content-based
            // minimum size in the same way as a fixed max track sizing function. The clamp is a stretch fit of
            // the item's margin box (including its baseline shim) into the limit, so it does not shrink the
            // item below its padding + border.
            const limit = self.spannedFixedTrackLimit(axis, axis_tracks, inner_node_size.get(axis), tree);
            const margins = self.marginsAxisSumsWithBaselineShims(grid_area_size.width, tree);
            const stretched_limit: ?f32 = if (limit) |l| @max(l - margins.get(axis), padding_border_size.get(axis)) else null;
            return maybeMin(minimum_contribution, stretched_limit);
        } else {
            return 0.0;
        }
    }

    /// Retrieve the item's minimum contribution from the cache or compute it using the provided parameters
    pub fn minimumContributionCached(
        self: *GridItem,
        tree: anytype,
        axis: AbstractAxis,
        axis_tracks: []const GridTrack,
        grid_area_size: Size(?f32),
        inner_node_size: Size(?f32),
    ) LayoutError!f32 {
        if (self.minimum_contribution_cache.get(axis)) |cached| return cached;
        const size = try self.minimumContribution(tree, axis, axis_tracks, grid_area_size, inner_node_size);
        self.minimum_contribution_cache.set(axis, size);
        return size;
    }
};
