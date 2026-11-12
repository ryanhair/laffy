//! This module is a partial implementation of the CSS Grid Level 1 specification
//! <https://www.w3.org/TR/css-grid-1>
//!
//! # Memory
//!
//! Temporary lists (items, placements, tracks, the occupancy matrix and the named line maps) are
//! allocated with `tree.allocator()` and freed before `computeGridLayout` returns. The
//! `DetailedGridInfo` produced by a full layout is handed to the tree with
//! `tree.setDetailedGridInfo`, which takes ownership of it (see `DetailedGridInfo.deinit`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const AbstractAxis = geometry.AbstractAxis;
const InBothAbsAxis = geometry.InBothAbsAxis;
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../style.zig");
const AlignContent = style_mod.AlignContent;
const AlignItems = style_mod.AlignItems;
const AvailableSpace = style_mod.AvailableSpace;
const Contain = style_mod.Contain;
const ContainingBlockClaims = style_mod.ContainingBlockClaims;
const Direction = style_mod.Direction;
const GridAreaAxis = style_mod.GridAreaAxis;
const GridPlacement = style_mod.GridPlacement;
const layout = @import("../tree/layout.zig");
const AxisStaticPosition = layout.AxisStaticPosition;
const Baselines = layout.Baselines;
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidates = layout.OofCandidates;
const OofPositioningArea = layout.OofPositioningArea;
const NodeId = @import("../tree/node.zig").NodeId;
const traits = @import("../tree/traits.zig");
const math = @import("../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const maybeSub = math.maybeSub;
const resolve = @import("../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../util/sys.zig");
const f32Max = sys.f32Max;
const f32Min = sys.f32Min;
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const finalizeScrollableOverflow = scrollable_overflow.finalizeScrollableOverflow;
const ScrollableOverflowContainer = scrollable_overflow.ScrollableOverflowContainer;

pub const alignment = @import("grid/alignment.zig");
pub const explicit_grid = @import("grid/explicit_grid.zig");
pub const implicit_grid = @import("grid/implicit_grid.zig");
pub const placement = @import("grid/placement.zig");
pub const track_sizing = @import("grid/track_sizing.zig");
pub const types = @import("grid/types.zig");
pub const util = @import("grid/util.zig");

const alignAndPositionItem = alignment.alignAndPositionItem;
const alignTracks = alignment.alignTracks;
const computeExplicitGridSizeInAxis = explicit_grid.computeExplicitGridSizeInAxis;
const initializeGridTracks = explicit_grid.initializeGridTracks;
const AutoRepeatStrategy = explicit_grid.AutoRepeatStrategy;
const computeGridSizeEstimate = implicit_grid.computeGridSizeEstimate;
const placeGridItems = placement.placeGridItems;
const ItemPlacement = placement.ItemPlacement;
const determineIfItemCrossesFlexibleOrIntrinsicTracks = track_sizing.determineIfItemCrossesFlexibleOrIntrinsicTracks;
const resolveItemTrackIndexes = track_sizing.resolveItemTrackIndexes;
const trackSizingAlgorithm = track_sizing.trackSizingAlgorithm;
const CellOccupancyMatrix = types.CellOccupancyMatrix;
const GridAreasMap = types.GridAreasMap;
const GridItem = types.GridItem;
const GridTrack = types.GridTrack;
const NamedLineResolver = types.NamedLineResolver;
const OriginZeroLine = types.OriginZeroLine;
const Range = types.Range;
const TrackCounts = types.TrackCounts;
const optionalEql = types.grid_item.optionalEql;

pub const GridLine = types.GridLine;
pub const max_grid_tracks = types.max_grid_tracks;
pub const max_oz_line = types.max_oz_line;
pub const min_oz_line = types.min_oz_line;
pub const GridLineNames = types.GridLineNames;
pub const GridLineNamesIter = types.GridLineNamesIter;

/// The grid container's resolved box, size constraints, alignment styles and available space,
/// computed once from the container's style and the layout inputs before the grid is laid out
const GridContainerConstants = struct {
    /// The container's `direction` style
    direction: Direction,
    /// The container's `contain` style
    contain: Contain,
    /// Which positioning schemes the container is a containing block for
    containing_block_claims: ContainingBlockClaims,
    /// The container's resolved padding
    padding: Rect(f32),
    /// The container's resolved border
    border: Rect(f32),
    /// The sum of padding and border in each axis
    padding_border_size: Size(f32),
    /// The container's border-box min size, if definite
    min_size: Size(?f32),
    /// The container's border-box max size, if definite
    max_size: Size(?f32),
    /// The container's border-box preferred size, if definite
    preferred_size: Size(?f32),
    /// The space reserved for scrollbars in each axis
    scrollbar_gutter: Point(f32),
    /// Whether the container's overflow makes it a scroll container
    is_scroll_container: bool,
    /// Padding, border and scrollbar gutter combined
    content_box_inset: Rect(f32),
    /// The container's `align-content` style
    align_content: AlignContent,
    /// The container's `justify-content` style
    justify_content: AlignContent,
    /// The container's `align-items` style
    align_items: AlignItems,
    /// The container's `justify-items` style
    justify_items: AlignItems,
    /// The space available to size the grid tracks in each axis
    available_grid_space: Size(AvailableSpace),
    /// The container's border-box size, if definite
    outer_node_size: Size(?f32),
    /// The container's content-box min size, if definite
    inner_min_size: Size(?f32),
    /// The container's content-box max size, if definite
    inner_max_size: Size(?f32),
    /// The container's content-box size, if definite
    inner_node_size: Size(?f32),
};

/// Resolve the grid container's style against the layout inputs (step 1 of `computeGridLayout`)
fn computeContainerConstants(tree: anytype, style: anytype, inputs: LayoutInput) GridContainerConstants {
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const available_space = inputs.available_space;

    const direction = style.getDirection();
    const contain = style.getContain();
    const containing_block_claims = style.isContainingBlock();

    // 1. Compute "available grid space"
    // https://www.w3.org/TR/css-grid-1/#available-grid-space
    const aspect_ratio = style.getAspectRatio();
    const padding = resolveOrZero(style.getPadding(), parent_size.width, tree);
    const border = resolveOrZero(style.getBorder(), parent_size.width, tree);
    const padding_border = padding.add(border);
    const padding_border_size = padding_border.sumAxes();
    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_size else Size(f32).zero;

    const min_size = maybeAdd(maybeResolve(style.getMinSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const max_size = maybeAdd(maybeResolve(style.getMaxSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const preferred_size: Size(?f32) = if (inputs.sizing_mode == .inherent_size)
        maybeAdd(maybeResolve(style.getSize(), parent_size, tree).maybeApplyAspectRatio(style.getAspectRatio()), box_sizing_adjustment)
    else
        Size(?f32).none;

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow.scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const overflow = style.getOverflow();
    const scrollbar_gutter: Point(f32) = .{
        .x = if (overflow.y == .scroll) style.getScrollbarWidth() else 0.0,
        .y = if (overflow.x == .scroll) style.getScrollbarWidth() else 0.0,
    };
    const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
    var content_box_inset = padding_border;
    content_box_inset.bottom += scrollbar_gutter.y;

    switch (direction) {
        .ltr => content_box_inset.right += scrollbar_gutter.x,
        .rtl => content_box_inset.left += scrollbar_gutter.x,
    }

    // `normal` behaves as `stretch` for grid containers
    const align_content = style.getGridAlignContent(.block);
    const justify_content = style.getGridAlignContent(.@"inline");
    const align_items = style.getAlignItems();
    const justify_items = style.getJustifyItems();
    const style_size = known_dimensions.@"or"(preferred_size);
    const unclamped_available_space: Size(AvailableSpace) = .{
        .width = if (style_size.width) |w| .{ .definite = w } else available_space.width,
        .height = if (style_size.height) |h| .{ .definite = h } else available_space.height,
    };
    const constrained_available_space = maybeMax(maybeClamp(unclamped_available_space, min_size, max_size), padding_border_size);

    const available_grid_space: Size(AvailableSpace) = .{
        .width = switch (constrained_available_space.width) {
            .definite => |space| .{ .definite = space - content_box_inset.horizontalAxisSum() },
            else => |other| other,
        },
        .height = switch (constrained_available_space.height) {
            .definite => |space| .{ .definite = space - content_box_inset.verticalAxisSum() },
            else => |other| other,
        },
    };

    const outer_node_size = maybeMax(maybeClamp(known_dimensions.@"or"(preferred_size), min_size, max_size), padding_border_size);

    // The track sizing algorithm operates on the grid container's content box, so the min/max sizes
    // (which are border-box sizes) need converting to content-box sizes before being passed to it
    const inner_min_size = maybeSub(min_size, content_box_inset.sumAxes());
    const inner_max_size = maybeSub(max_size, content_box_inset.sumAxes());
    const inner_node_size: Size(?f32) = .{
        .width = if (outer_node_size.width) |space| space - content_box_inset.horizontalAxisSum() else null,
        .height = if (outer_node_size.height) |space| space - content_box_inset.verticalAxisSum() else null,
    };

    return .{
        .direction = direction,
        .contain = contain,
        .containing_block_claims = containing_block_claims,
        .padding = padding,
        .border = border,
        .padding_border_size = padding_border_size,
        .min_size = min_size,
        .max_size = max_size,
        .preferred_size = preferred_size,
        .scrollbar_gutter = scrollbar_gutter,
        .is_scroll_container = is_scroll_container,
        .content_box_inset = content_box_inset,
        .align_content = align_content,
        .justify_content = justify_content,
        .align_items = align_items,
        .justify_items = justify_items,
        .available_grid_space = available_grid_space,
        .outer_node_size = outer_node_size,
        .inner_min_size = inner_min_size,
        .inner_max_size = inner_max_size,
        .inner_node_size = inner_node_size,
    };
}

/// Free the grid items (and any out-of-flow candidates they still own)
fn freeItems(gpa: Allocator, items: *std.ArrayList(GridItem)) void {
    for (items.items) |*item| item.oof_candidates.deinit(gpa);
    items.deinit(gpa);
}

/// The sum of the base sizes of `tracks`
fn baseSizeSum(tracks: []const GridTrack) f32 {
    var sum: f32 = -0.0;
    for (tracks) |*track| sum += track.base_size;
    return sum;
}

/// `track_has_items` for `initializeGridTracks`: whether a track of the occupancy matrix is occupied
const TrackIsOccupied = struct {
    matrix: *const CellOccupancyMatrix,
    axis: AbsoluteAxis,

    pub fn call(self: TrackIsOccupied, index: usize) bool {
        return switch (self.axis) {
            .horizontal => self.matrix.columnIsOccupied(index),
            .vertical => self.matrix.rowIsOccupied(index),
        };
    }
};

/// Grid layout algorithm
/// This consists of a few phases:
///   - Resolving the explicit grid
///   - Placing items (which also resolves the implicit grid)
///   - Track (row/column) sizing
///   - Alignment & Final item placement
///
/// `tree` implements `LayoutGridContainer` (see `src/tree/traits.zig`). The caller owns the
/// returned output.
pub fn computeGridLayout(tree: anytype, node: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
    traits.assertImplements(@TypeOf(tree), &.{.layout_grid_container});
    const gpa = tree.allocator();
    const known_dimensions = inputs.known_dimensions;
    const run_mode = inputs.run_mode;

    const style = tree.getGridContainerStyle(node);
    const constants = computeContainerConstants(tree, style, inputs);
    const direction = constants.direction;
    const contain = constants.contain;
    const containing_block_claims = constants.containing_block_claims;
    const padding = constants.padding;
    const border = constants.border;
    const padding_border_size = constants.padding_border_size;
    const min_size = constants.min_size;
    const max_size = constants.max_size;
    const preferred_size = constants.preferred_size;
    const scrollbar_gutter = constants.scrollbar_gutter;
    const is_scroll_container = constants.is_scroll_container;
    const content_box_inset = constants.content_box_inset;
    const align_content = constants.align_content;
    const justify_content = constants.justify_content;
    const align_items = constants.align_items;
    const justify_items = constants.justify_items;
    const available_grid_space = constants.available_grid_space;
    const outer_node_size = constants.outer_node_size;
    const inner_min_size = constants.inner_min_size;
    const inner_max_size = constants.inner_max_size;
    var inner_node_size = constants.inner_node_size;

    // Short-circuit layout if the container's size is fully determined by the container's size and the run mode
    // is ComputeSize (and thus the container's size is all that we're interested in)
    if (run_mode == .compute_size) {
        if (outer_node_size.width) |width| {
            if (outer_node_size.height) |height| {
                return LayoutOutput.fromOuterSize(.{ .width = width, .height = height });
            }
        }

        // We can also short-circuit if the width is known and only the width has been requested.
        if (inputs.axis == .horizontal) {
            if (outer_node_size.width) |width| {
                return LayoutOutput.fromOuterSize(.{ .width = width, .height = 0.0 });
            }
        }
    }

    // 2. Resolve the explicit grid

    // This is very similar to the inner_node_size except if the inner_node_size is not definite but the node
    // has a min- or max- size style then that will be used in it's place.
    const auto_fit_container_size = maybeSub(
        maybeMax(maybeClamp(outer_node_size.@"or"(max_size).@"or"(min_size), min_size, max_size), padding_border_size),
        content_box_inset.sumAxes(),
    );

    // If the grid container has a definite size or max size in the relevant axis:
    //   - then the number of repetitions is the largest possible positive integer that does not cause the grid to overflow the content
    //     box of its grid container.
    // Otherwise, if the grid container has a definite min size in the relevant axis:
    //   - then the number of repetitions is the smallest possible positive integer that fulfills that minimum requirement
    // Otherwise, the specified track list repeats only once.
    const size_or_max = outer_node_size.@"or"(max_size);
    const auto_repeat_fit_strategy: Size(AutoRepeatStrategy) = .{
        .width = if (size_or_max.width != null) .max_repetitions_that_do_not_overflow else .min_repetitions_that_do_overflow,
        .height = if (size_or_max.height != null) .max_repetitions_that_do_not_overflow else .min_repetitions_that_do_overflow,
    };

    // Compute the number of rows and columns in the explicit grid *template*
    // (explicit tracks from grid_areas are computed separately below)
    const col_auto_repetition_count, const grid_template_col_count = computeExplicitGridSizeInAxis(
        style,
        auto_fit_container_size.width,
        auto_repeat_fit_strategy.width,
        tree,
        .horizontal,
    );
    const row_auto_repetition_count, const grid_template_row_count = computeExplicitGridSizeInAxis(
        style,
        auto_fit_container_size.height,
        auto_repeat_fit_strategy.height,
        tree,
        .vertical,
    );

    var name_resolver = try NamedLineResolver.new(gpa, style, col_auto_repetition_count, row_auto_repetition_count);
    defer name_resolver.deinit(gpa);

    // Clamp the explicit grid to MAX_GRID_TRACKS tracks in each axis
    // https://www.w3.org/TR/css-grid-1/#overlarge-grids
    const explicit_col_count = @min(@max(grid_template_col_count, name_resolver.areaColumnCount()), max_grid_tracks);
    const explicit_row_count = @min(@max(grid_template_row_count, name_resolver.areaRowCount()), max_grid_tracks);

    name_resolver.setExplicitColumnCount(explicit_col_count);
    name_resolver.setExplicitRowCount(explicit_row_count);

    // Build the per-line names of the explicit grid from the name resolver's collected pairs
    var detailed_column_line_names = try name_resolver.detailedLineNames(gpa, .horizontal);
    defer detailed_column_line_names.deinit(gpa);
    var detailed_row_line_names = try name_resolver.detailedLineNames(gpa, .vertical);
    defer detailed_row_line_names.deinit(gpa);

    // 3. Create the grid items (in document order) and resolve the named lines in their `grid-row`/`grid-column` styles
    // Absolutely positioned children do not take part in grid placement and do not create implicit tracks,
    // so they are excluded here. Each child's style is read and its named lines resolved exactly once; the
    // results drive both the grid size estimate and item placement below.
    const child_count = tree.childCount(node);
    var items: std.ArrayList(GridItem) = .empty;
    defer freeItems(gpa, &items);
    try items.ensureTotalCapacity(gpa, child_count);
    var placements: std.ArrayList(ItemPlacement) = .empty;
    defer placements.deinit(gpa);
    try placements.ensureTotalCapacity(gpa, child_count);
    {
        var child_iter = tree.childIds(node);
        var index: usize = 0;
        while (child_iter.next()) |child_node| : (index += 1) {
            const child_style = tree.getGridChildStyle(child_node);
            if (child_style.getBoxGenerationMode() == .none or child_style.getPosition().isOutOfFlow()) {
                continue;
            }
            placements.appendAssumeCapacity(.{
                .horizontal = name_resolver.resolveColumnNames(child_style.getGridColumn()).intoOriginZero(explicit_col_count),
                .vertical = name_resolver.resolveRowNames(child_style.getGridRow()).intoOriginZero(explicit_row_count),
            });
            items.appendAssumeCapacity(GridItem.newWithStyleAndOrder(
                child_node,
                child_style,
                align_items,
                justify_items,
                @truncate(index),
            ));
        }
    }

    // 4. Implicit Grid: Estimate Track Counts
    // Estimate the number of rows and columns in the implicit grid (= the entire grid)
    // This is necessary as part of placement. Doing it early here is a perf optimisation to reduce allocations.
    const est_col_counts, const est_row_counts = computeGridSizeEstimate(explicit_col_count, explicit_row_count, placements.items);

    // 5. Grid Item Placement
    // Match items (children) to a definite grid position (row start/end and column start/end position)
    var cell_occupancy_matrix = try CellOccupancyMatrix.withTrackCounts(gpa, est_col_counts, est_row_counts);
    defer cell_occupancy_matrix.deinit(gpa);
    // `items` is in document order from here on (placement only fills in each item's grid area). The track
    // sizing and baseline passes sort references to the items rather than the items themselves.
    try placeGridItems(gpa, &cell_occupancy_matrix, items.items, placements.items, style.getGridAutoFlow());

    // Extract track counts from previous step (auto-placement can expand the number of tracks)
    const final_col_counts = cell_occupancy_matrix.trackCounts(.horizontal);
    const final_row_counts = cell_occupancy_matrix.trackCounts(.vertical);

    // 5. Initialize Tracks
    // Initialize (explicit and implicit) grid tracks (and gutters)
    // This resolves the min and max track sizing functions for all tracks and gutters
    var columns: std.ArrayList(GridTrack) = .empty;
    defer columns.deinit(gpa);
    var rows: std.ArrayList(GridTrack) = .empty;
    defer rows.deinit(gpa);
    try initializeGridTracks(
        gpa,
        &columns,
        final_col_counts,
        style,
        .horizontal,
        col_auto_repetition_count,
        TrackIsOccupied{ .matrix = &cell_occupancy_matrix, .axis = .horizontal },
    );
    try initializeGridTracks(
        gpa,
        &rows,
        final_row_counts,
        style,
        .vertical,
        row_auto_repetition_count,
        TrackIsOccupied{ .matrix = &cell_occupancy_matrix, .axis = .vertical },
    );

    // 6. Track Sizing

    // Convert grid placements in origin-zero coordinates to indexes into the GridTrack (rows and columns) vectors
    // This computation is relatively trivial, but it requires the final number of negative (implicit) tracks in
    // each axis, and doing it up-front here means we don't have to keep repeating that calculation
    resolveItemTrackIndexes(items.items, final_col_counts, final_row_counts);
    // For each item, and in each axis, determine whether the item crosses any flexible (fr) tracks
    // Record this as a boolean (per-axis) on each item for later use in the track-sizing algorithm
    determineIfItemCrossesFlexibleOrIntrinsicTracks(items.items, columns.items, rows.items);

    // Determine if the grid has any baseline aligned items
    const has_baseline_aligned_item = for (items.items) |*item| {
        if (item.participatesInBaselineAlignment()) break true;
    } else false;

    // Run track sizing algorithm for Inline axis
    try trackSizingAlgorithm(
        tree,
        .@"inline",
        inner_min_size.get(.@"inline"),
        inner_max_size.get(.@"inline"),
        justify_content,
        align_content,
        available_grid_space,
        inner_node_size,
        columns.items,
        rows.items,
        items.items,
        .max_track_sizing_function,
        has_baseline_aligned_item,
    );
    const initial_column_sum = baseSizeSum(columns.items);
    inner_node_size.width = inner_node_size.width orelse initial_column_sum;

    // If only the container's width has been requested then we can skip sizing the rows entirely (which avoids
    // measuring the height of every item), as column sizing is not re-run when only computing the container's size.
    // Note: the short-circuit above has already handled the case where the container's width is known.
    if (run_mode == .compute_size and inputs.axis == .horizontal) {
        const width = f32Max(maybeClamp(initial_column_sum + content_box_inset.horizontalAxisSum(), min_size.width, max_size.width), padding_border_size.width);
        return LayoutOutput.fromOuterSize(.{ .width = width, .height = 0.0 });
    }

    for (items.items) |*item| item.grid_area_size_cache = null;

    // Run track sizing algorithm for Block axis
    try trackSizingAlgorithm(
        tree,
        .block,
        inner_min_size.get(.block),
        inner_max_size.get(.block),
        align_content,
        justify_content,
        available_grid_space,
        inner_node_size,
        rows.items,
        columns.items,
        items.items,
        .base_size,
        false, // TODO: Support baseline alignment in the vertical axis
    );
    const initial_row_sum = baseSizeSum(rows.items);

    // 6. Compute container size
    const resolved_style_size = known_dimensions.@"or"(preferred_size);
    var container_border_box: Size(f32) = .{
        .width = f32Max(
            maybeClamp(resolved_style_size.get(.@"inline") orelse initial_column_sum + content_box_inset.horizontalAxisSum(), min_size.width, max_size.width),
            padding_border_size.width,
        ),
        .height = f32Max(
            maybeClamp(resolved_style_size.get(.block) orelse initial_row_sum + content_box_inset.verticalAxisSum(), min_size.height, max_size.height),
            padding_border_size.height,
        ),
    };
    var container_content_box: Size(f32) = .{
        .width = f32Max(0.0, container_border_box.width - content_box_inset.horizontalAxisSum()),
        .height = f32Max(0.0, container_border_box.height - content_box_inset.verticalAxisSum()),
    };

    // If only the container's size has been requested
    if (run_mode == .compute_size) {
        return LayoutOutput.fromOuterSize(container_border_box);
    }

    // The container's size is now determined, so percentages resolve against its content box when re-running track sizing.
    // This may be a no-op if the container's size was known upfront (in which case it already equals `inner_node_size`).
    inner_node_size = .{ .width = container_content_box.width, .height = container_content_box.height };

    // Column sizing must be re-run (once) if:
    //   - The grid container's width was initially indefinite and there are any columns with percentage track sizing functions
    //   - Any grid item crossing an intrinsically sized track's min content contribution width has changed
    // TODO: Only rerun sizing for tracks that actually require it rather than for all tracks if any need it.
    var rerun_column_sizing: bool = undefined;
    var intrinsic_column_contribution_changed = false;

    const has_percentage_column = for (columns.items) |*track| {
        if (track.usesPercentage()) break true;
    } else false;
    const has_percentage_row = for (rows.items) |*track| {
        if (track.usesPercentage()) break true;
    } else false;
    const parent_width_indefinite = outer_node_size.width == null;
    rerun_column_sizing = parent_width_indefinite and has_percentage_column;

    if (!rerun_column_sizing) {
        // Note: every item must be visited (no short-circuiting) as the loop updates each item's caches
        var any_changed = false;
        for (items.items) |*item| {
            if (!item.crosses_intrinsic_column) continue;
            const grid_area_size = item.gridAreaSize(.@"inline", columns.items, rows.items, inner_node_size, .base_size, tree);
            const available_space = grid_area_size.with(.@"inline", null);
            const new_min_content_contribution = try item.minContentContribution(.@"inline", tree, grid_area_size, available_space);

            const has_changed = !optionalEql(new_min_content_contribution, item.min_content_contribution_cache.width);

            item.grid_area_size_cache = grid_area_size;
            item.min_content_contribution_cache.width = new_min_content_contribution;
            item.max_content_contribution_cache.width = null;
            item.minimum_contribution_cache.width = null;

            any_changed = any_changed or has_changed;
        }
        intrinsic_column_contribution_changed = any_changed;
        rerun_column_sizing = intrinsic_column_contribution_changed;
    } else {
        // Clear intrinsic width caches
        for (items.items) |*item| {
            item.grid_area_size_cache = null;
            item.min_content_contribution_cache.width = null;
            item.max_content_contribution_cache.width = null;
            item.minimum_contribution_cache.width = null;
        }
    }

    // Row sizing must be re-run (once) if:
    //   - The grid container's height was initially indefinite and there are any rows with percentage track sizing functions
    //   - Column sizing was re-run and any grid item crossing an intrinsically sized track's min content contribution height has changed
    // TODO: Only rerun sizing for tracks that actually require it rather than for all tracks if any need it.
    const parent_height_indefinite = outer_node_size.height == null;
    var rerun_row_sizing = parent_height_indefinite and has_percentage_row;
    var intrinsic_row_contribution_changed = false;

    if (rerun_row_sizing) {
        // Clear intrinsic height caches
        for (items.items) |*item| {
            item.grid_area_size_cache = null;
            item.min_content_contribution_cache.height = null;
            item.max_content_contribution_cache.height = null;
            item.minimum_contribution_cache.height = null;
        }
    }

    if (rerun_column_sizing) {
        // Re-run track sizing algorithm for Inline axis
        try trackSizingAlgorithm(
            tree,
            .@"inline",
            inner_min_size.get(.@"inline"),
            inner_max_size.get(.@"inline"),
            justify_content,
            align_content,
            available_grid_space,
            inner_node_size,
            columns.items,
            rows.items,
            items.items,
            .base_size,
            has_baseline_aligned_item,
        );

        // The column widths may have changed, so the items' intrinsic height contributions need to be recomputed
        // (unless row sizing is being re-run anyway, in which case the caches have already been cleared).
        if (!rerun_row_sizing) {
            // Note: every item must be visited (no short-circuiting) as the loop updates each item's caches
            var any_changed = false;
            for (items.items) |*item| {
                if (!item.crosses_intrinsic_row) continue;
                const grid_area_size = item.gridAreaSize(.block, rows.items, columns.items, inner_node_size, .base_size, tree);
                const available_space = grid_area_size.with(.block, null);
                const new_min_content_contribution = try item.minContentContribution(.block, tree, grid_area_size, available_space);

                const has_changed = !optionalEql(new_min_content_contribution, item.min_content_contribution_cache.height);

                item.grid_area_size_cache = grid_area_size;
                item.min_content_contribution_cache.height = new_min_content_contribution;
                item.max_content_contribution_cache.height = null;
                item.minimum_contribution_cache.height = null;

                any_changed = any_changed or has_changed;
            }
            intrinsic_row_contribution_changed = any_changed;
            rerun_row_sizing = intrinsic_row_contribution_changed;
        }
    }

    if (rerun_row_sizing) {
        // Re-run track sizing algorithm for Block axis
        try trackSizingAlgorithm(
            tree,
            .block,
            inner_min_size.get(.block),
            inner_max_size.get(.block),
            align_content,
            justify_content,
            available_grid_space,
            inner_node_size,
            rows.items,
            columns.items,
            items.items,
            .base_size,
            false, // TODO: Support baseline alignment in the vertical axis
        );
    }

    if ((intrinsic_column_contribution_changed and !has_percentage_column) or
        (intrinsic_row_contribution_changed and !has_percentage_row))
    {
        const final_column_sum = baseSizeSum(columns.items);
        const final_row_sum = baseSizeSum(rows.items);

        if (intrinsic_column_contribution_changed and !has_percentage_column) {
            container_border_box.width = f32Max(
                maybeClamp(resolved_style_size.get(.@"inline") orelse final_column_sum + content_box_inset.horizontalAxisSum(), min_size.width, max_size.width),
                padding_border_size.width,
            );
            container_content_box.width = f32Max(0.0, container_border_box.width - content_box_inset.horizontalAxisSum());
        }

        if (intrinsic_row_contribution_changed and !has_percentage_row) {
            container_border_box.height = f32Max(
                maybeClamp(resolved_style_size.get(.block) orelse final_row_sum + content_box_inset.verticalAxisSum(), min_size.height, max_size.height),
                padding_border_size.height,
            );
            container_content_box.height = f32Max(0.0, container_border_box.height - content_box_inset.verticalAxisSum());
        }
    }

    // If only the container's size has been requested
    if (run_mode == .compute_size) {
        return LayoutOutput.fromOuterSize(container_border_box);
    }

    // 8. Track Alignment

    // Align columns
    const inline_size_without_scrollbar = f32Max(container_border_box.width - padding_border_size.width, 0.0);
    const inline_scrollbar_gutter_for_alignment = f32Min(scrollbar_gutter.x, inline_size_without_scrollbar);
    alignTracks(
        container_content_box.get(.@"inline"),
        .{
            .start = padding.left + if (direction.isRtl()) inline_scrollbar_gutter_for_alignment else 0.0,
            .end = padding.right + if (direction.isRtl()) 0.0 else inline_scrollbar_gutter_for_alignment,
        },
        .{ .start = border.left, .end = border.right },
        columns.items,
        justify_content,
        direction.isRtl(),
    );
    // Align rows
    alignTracks(
        container_content_box.get(.block),
        .{ .start = padding.top, .end = padding.bottom },
        .{ .start = border.top, .end = border.bottom },
        rows.items,
        align_content,
        false,
    );

    // 9. Size, Align, and Position Grid Items

    var item_overflow_rect = Rect(f32).zero;

    // Out-of-flow candidates in document order: direct out-of-flow children of the grid
    // interleaved with candidates bubbled from in-flow children's subtrees. These are laid out
    // by the out-of-flow positioning pass (`computeOofLayout`), which runs after this algorithm.
    var oof_candidates: OofCandidates = .none;
    errdefer oof_candidates.deinit(gpa);

    const container_alignment_styles: InBothAbsAxis(AlignItems) = .{ .horizontal = justify_items, .vertical = align_items };

    const padding_box_inset = border.add(.{
        .left = if (direction.isRtl()) scrollbar_gutter.x else 0.0,
        .right = if (direction.isRtl()) 0.0 else scrollbar_gutter.x,
        .top = 0.0,
        .bottom = scrollbar_gutter.y,
    });
    const overflow_container: ScrollableOverflowContainer = .{
        .parent_is_scroll_container = is_scroll_container,
        .parent_size = .{ .width = container_border_box.width - padding_box_inset.horizontalAxisSum(), .height = 0.0 },
        .reversed = .{ .x = direction.isRtl(), .y = false },
        .padding = padding,
    };

    // Position in-flow children (stored in items vector)
    for (items.items, 0..) |*item, index| {
        // Tracks are stored in logical order. In RTL the physical offsets are assigned
        // right-to-left, so an item's physical left edge is derived from its logical end
        // line and its physical right edge from its logical start line.
        const grid_area: Rect(f32) = .{
            .top = rows.items[@as(usize, item.row_indexes.start) + 1].offset,
            .bottom = rows.items[item.row_indexes.end].offset,
            .left = if (direction.isRtl())
                columns.items[@as(usize, item.column_indexes.end) - 1].offset
            else
                columns.items[@as(usize, item.column_indexes.start) + 1].offset,
            .right = if (direction.isRtl())
                columns.items[item.column_indexes.start].offset
            else
                columns.items[item.column_indexes.end].offset,
        };
        const positioned = try alignAndPositionItem(
            tree,
            item.node,
            @intCast(index),
            grid_area,
            .{ .width = grid_area.right - grid_area.left, .height = grid_area.bottom - grid_area.top },
            container_alignment_styles,
            item.baseline_shim,
            direction,
            padding_box_inset,
            &overflow_container,
            &item.oof_candidates,
        );
        item.y_position = positioned.y_position;
        item.height = positioned.height;
        item.baseline = positioned.baseline;

        item_overflow_rect = item_overflow_rect.@"union"(positioned.overflow_contribution);
    }

    // Position hidden and absolutely positioned children, merging in the candidates bubbled out
    // of in-flow children's subtrees (`items` is sorted by `source_order`, i.e. child index)
    var order: u32 = @intCast(items.items.len);
    var in_flow_index: usize = 0;
    for (0..tree.childCount(node)) |index| {
        if (in_flow_index < items.items.len and items.items[in_flow_index].source_order == index) {
            try oof_candidates.append(gpa, &items.items[in_flow_index].oof_candidates);
            in_flow_index += 1;
            continue;
        }

        const child = tree.getChildId(node, index);
        const child_style = tree.getGridChildStyle(child);

        // Position hidden child
        if (child_style.getBoxGenerationMode() == .none) {
            tree.setUnroundedLayout(child, &Layout.withOrder(order));
            var hidden_output = try traits.performChildLayout(
                tree,
                child,
                Size(?f32).none,
                Size(?f32).none,
                Size(AvailableSpace).max_content,
                .inherent_size,
                Line(bool).false,
            );
            hidden_output.deinit(gpa);
            order += 1;
            continue;
        }

        // Emit out-of-flow children as candidates for the out-of-flow positioning pass
        // (`computeOofLayout`), which lays out those for which this grid is the containing
        // block after this algorithm has run (resolving their grid areas from the detailed grid
        // info recorded below).
        if (child_style.getPosition().isOutOfFlow()) {
            const position = child_style.getPosition();
            const item_direction = child_style.getDirection();
            const justify_self = (child_style.getJustifySelf() orelse justify_items).resolveSelfRelative(item_direction, direction, true);
            const align_self = (child_style.getAlignSelf() orelse align_items).resolveSelfRelative(item_direction, direction, false);

            // The static-position rectangle: the grid area determined by the grid-placement
            // properties when this grid is the child's containing block, and otherwise the
            // grid's content box, as if the child were the sole grid item in a grid area
            // coinciding with the grid's content edges (grid placement does not apply when the
            // grid is not the containing block).
            // https://www.w3.org/TR/css-grid-1/#static-position
            const area: Rect(f32) = if (containing_block_claims.forPosition(position))
                resolveStaticPositionGridArea(
                    child_style,
                    &name_resolver,
                    final_row_counts,
                    final_col_counts,
                    rows.items,
                    columns.items,
                    direction,
                    border,
                    scrollbar_gutter,
                    container_border_box,
                )
            else
                .{
                    .left = border.left + padding.left + if (direction.isRtl()) scrollbar_gutter.x else 0.0,
                    .right = container_border_box.width -
                        border.right -
                        padding.right -
                        if (direction.isRtl()) 0.0 else scrollbar_gutter.x,
                    .top = border.top + padding.top,
                    .bottom = container_border_box.height - border.bottom - padding.bottom - scrollbar_gutter.y,
                };

            try oof_candidates.push(gpa, .{
                .node = child,
                .order = order,
                .position = position,
                .static_position = .{
                    .x = AxisStaticPosition.fromAlignment(justify_self, .{ .start = area.left, .end = area.right }, direction.isRtl()),
                    .y = AxisStaticPosition.fromAlignment(align_self, .{ .start = area.top, .end = area.bottom }, false),
                },
            });

            order += 1;
        }
    }

    const absolute_position_area = container_border_box.sub(padding_box_inset.sumAxes());
    const absolute_position_offset: Point(f32) = .{ .x = padding_box_inset.left, .y = padding_box_inset.top };
    // Store the detailed grid info before the out-of-flow positioning pass so that the pass can
    // resolve the grid areas of out-of-flow boxes whose containing block is this grid
    const detailed_grid_info = try buildDetailedGridInfo(
        gpa,
        &name_resolver,
        final_row_counts,
        rows.items,
        &detailed_row_line_names,
        final_col_counts,
        columns.items,
        &detailed_column_line_names,
        items.items,
    );
    try tree.setDetailedGridInfo(node, detailed_grid_info);

    const oof_positioning_area: ?OofPositioningArea = .{ .size = absolute_position_area, .offset = absolute_position_offset };

    // If there are no in-flow items then return the container size and the overflow (no baseline)
    if (items.items.len == 0) {
        const client_width = f32Max(container_border_box.width - border.horizontalAxisSum() - scrollbar_gutter.x, 0.0);
        const overflow_rect = if (is_scroll_container)
            item_overflow_rect.@"union"(.{
                .left = if (direction.isRtl()) f32Min(client_width - padding.left, 0.0) else 0.0,
                .right = if (direction.isRtl()) client_width else padding.right,
                .top = 0.0,
                .bottom = padding.bottom,
            })
        else
            item_overflow_rect.@"union"(.{ .left = 0.0, .right = if (direction.isRtl()) client_width else 0.0, .top = 0.0, .bottom = 0.0 });
        var output = LayoutOutput.fromSizes(
            container_border_box,
            finalizeScrollableOverflow(
                overflow_rect,
                container_border_box
                    .sub(border.sumAxes())
                    .sub(.{ .width = scrollbar_gutter.x, .height = scrollbar_gutter.y }),
                .{ .x = direction.isRtl(), .y = false },
                is_scroll_container,
            ),
        );
        output.oof_candidates = oof_candidates;
        output.oof_positioning_area = oof_positioning_area;
        return output;
    }

    // Determine the grid container baseline(s) (currently we only compute the first baseline)
    // Layout containment suppresses the box's baseline for baseline-alignment purposes
    const grid_container_baseline: ?f32 = if (contain.suppressesBaseline()) null else blk: {
        // Get the row index of the first row containing items
        var first_row: u16 = items.items[0].row_indexes.start;
        for (items.items[1..]) |*item| first_row = @min(first_row, item.row_indexes.start);

        // Check if any items in *this row* participate in baseline alignment
        // (items with an auto block-axis margin do not participate: https://www.w3.org/TR/css-align-3/#baseline-align-self)
        var first_item: ?*const GridItem = null;
        var baseline_item: ?*const GridItem = null;
        for (items.items) |*item| {
            if (item.row_indexes.start != first_row) continue;
            if (first_item == null) {
                first_item = item;
                if (item.participatesInBaselineAlignment()) {
                    baseline_item = item;
                    break;
                }
            } else if (item.participatesInBaselineAlignment()) {
                baseline_item = item;
                break;
            }
        }
        const item = baseline_item orelse first_item.?;

        break :blk item.y_position + (item.baseline orelse item.height);
    };

    // A scroll container's own padding at the end of the content is part of its scrollable
    // overflow region, so it is included in the in-flow overflow rect. Boxes that are not
    // scroll containers do not extend their overflow region by their own padding.
    const scrollable_overflow_rect = blk: {
        const client_width = f32Max(container_border_box.width - border.horizontalAxisSum() - scrollbar_gutter.x, 0.0);
        const overflow_rect = if (is_scroll_container)
            item_overflow_rect.@"union"(.{
                .left = if (direction.isRtl()) f32Min(client_width - padding.left, 0.0) else 0.0,
                .right = if (direction.isRtl()) client_width else padding.right,
                .top = 0.0,
                .bottom = padding.bottom,
            })
        else
            item_overflow_rect.@"union"(.{ .left = 0.0, .right = if (direction.isRtl()) client_width else 0.0, .top = 0.0, .bottom = 0.0 });
        break :blk finalizeScrollableOverflow(
            overflow_rect,
            container_border_box.sub(border.sumAxes()).sub(.{ .width = scrollbar_gutter.x, .height = scrollbar_gutter.y }),
            .{ .x = direction.isRtl(), .y = false },
            is_scroll_container,
        );
    };

    var output = LayoutOutput.fromSizesAndBaselines(
        container_border_box,
        scrollable_overflow_rect,
        Baselines.fromFirst(grid_container_baseline),
    );
    output.oof_candidates = oof_candidates;
    output.oof_positioning_area = oof_positioning_area;
    return output;
}

/// Build the `DetailedGridInfo` of a laid-out grid, moving the line names and the name resolver's
/// line maps into it
fn buildDetailedGridInfo(
    gpa: Allocator,
    name_resolver: *NamedLineResolver,
    final_row_counts: TrackCounts,
    rows: []const GridTrack,
    detailed_row_line_names: *GridLineNames,
    final_col_counts: TrackCounts,
    columns: []const GridTrack,
    detailed_column_line_names: *GridLineNames,
    items: []const GridItem,
) LayoutError!DetailedGridInfo {
    var info: DetailedGridInfo = .{};
    errdefer info.deinit(gpa);
    info.areas = name_resolver.populateDetailedLineResolvers(gpa, detailed_row_line_names, detailed_column_line_names);
    info.rows = try DetailedGridTracksInfo.fromGridTracksAndTrackCount(gpa, final_row_counts, rows, detailed_row_line_names);
    info.columns = try DetailedGridTracksInfo.fromGridTracksAndTrackCount(gpa, final_col_counts, columns, detailed_column_line_names);
    const item_infos = try gpa.alloc(DetailedGridItemsInfo, items.len);
    for (item_infos, items) |*item_info, *item| item_info.* = DetailedGridItemsInfo.fromGridItem(item);
    info.items = item_infos;
    return info;
}

/// Resolve a grid line (by track vector index) used as a start edge to a position
fn lineAsStartEdge(tracks: []const GridTrack, index: usize) f32 {
    return if (index + 1 < tracks.len) tracks[index + 1].offset else tracks[index].offset;
}

/// Resolve a grid line (by track vector index) used as an end edge to a position
fn lineAsEndEdge(tracks: []const GridTrack, index: usize) f32 {
    if (index == 0) {
        return if (tracks.len > 1) tracks[1].offset else tracks[0].offset;
    } else {
        return tracks[index].offset;
    }
}

// In RTL, tracks remain in logical order but physical offsets are assigned
// right-to-left: a line used as an inline-start edge resolves to the physical
// *right* edge of the track that follows it (its gutter's offset), and a line
// used as an inline-end edge resolves to the physical *left* edge (offset) of
// the track that precedes it.

/// Resolve a grid line used as an inline-start edge to a physical right x-position (RTL)
fn rtlLineAsStartEdge(tracks: []const GridTrack, index: usize) f32 {
    if (tracks.len > index + 1) {
        // The gutter's offset is the physical right edge of the track that follows the line
        return tracks[index].offset;
    } else if (index == 0) {
        return tracks[0].offset;
    } else {
        // No track follows the line: resolve to the line itself, which is the physical
        // left edge of the track that precedes it (the trailing gutter is assigned its
        // offset before any alignment offset is applied, so it cannot be used here)
        return tracks[index - 1].offset;
    }
}

/// Resolve a grid line used as an inline-end edge to a physical left x-position (RTL)
fn rtlLineAsEndEdge(tracks: []const GridTrack, index: usize) f32 {
    if (index == 0) {
        return tracks[0].offset;
    } else {
        return tracks[index - 1].offset;
    }
}

/// Convert an absolutely positioned placement into optional indexes into a track vector
fn absolutelyPositionedTrackIndexes(resolved: Line(?OriginZeroLine), counts: TrackCounts) Line(?usize) {
    return .{
        .start = if (resolved.start) |line| line.tryIntoTrackVecIndex(counts) else null,
        .end = if (resolved.end) |line| line.tryIntoTrackVecIndex(counts) else null,
    };
}

/// Resolve the static-position rectangle (the grid area determined by the grid-placement
/// properties) for an out-of-flow child of a positioned grid container.
///
/// Content alignment (align-content/justify-content) may distribute free space before, between,
/// or after tracks. Grid lines used by absolutely positioned items resolve to the edges of the
/// tracks adjacent to the line rather than to the raw gutter offset:
///   - As a start edge, a line resolves to the start of the track that follows it
///   - As an end edge, a line resolves to the end of the track that precedes it
fn resolveStaticPositionGridArea(
    child_style: anytype,
    name_resolver: *const NamedLineResolver,
    final_row_counts: TrackCounts,
    final_col_counts: TrackCounts,
    rows: []const GridTrack,
    columns: []const GridTrack,
    direction: Direction,
    border: Rect(f32),
    scrollbar_gutter: Point(f32),
    container_border_box: Size(f32),
) Rect(f32) {
    // Convert grid-col-{start/end} into optional indexes into the columns vector
    // The index is null if the style property is Auto and an unresolvable Span
    const maybe_col_indexes = absolutelyPositionedTrackIndexes(
        name_resolver.resolveColumnNames(child_style.getGridColumn()).intoOriginZero(final_col_counts.explicit).resolveAbsolutelyPositionedGridTracks(),
        final_col_counts,
    );
    // Convert grid-row-{start/end} into optional indexes into the row vector
    // The index is null if the style property is Auto and an unresolvable Span
    const maybe_row_indexes = absolutelyPositionedTrackIndexes(
        name_resolver.resolveRowNames(child_style.getGridRow()).intoOriginZero(final_row_counts.explicit).resolveAbsolutelyPositionedGridTracks(),
        final_row_counts,
    );

    // In RTL the item's physical left edge derives from its logical end line and its
    // physical right edge from its logical start line.
    const grid_area_left: f32, const grid_area_right: f32 = if (direction.isRtl())
        .{
            if (maybe_col_indexes.end) |index| rtlLineAsEndEdge(columns, index) else border.left + scrollbar_gutter.x,
            if (maybe_col_indexes.start) |index| rtlLineAsStartEdge(columns, index) else container_border_box.width - border.right,
        }
    else
        .{
            if (maybe_col_indexes.start) |index| lineAsStartEdge(columns, index) else border.left,
            if (maybe_col_indexes.end) |index| lineAsEndEdge(columns, index) else container_border_box.width - border.right - scrollbar_gutter.x,
        };

    return .{
        .top = if (maybe_row_indexes.start) |index| lineAsStartEdge(rows, index) else border.top,
        .bottom = if (maybe_row_indexes.end) |index| lineAsEndEdge(rows, index) else container_border_box.height - border.bottom - scrollbar_gutter.y,
        .left = grid_area_left,
        .right = grid_area_right,
    };
}

/// Information from the computation of grid
///
/// Owns its lists and maps (allocated with the tree's allocator); free with `deinit`. Line and
/// area names are borrowed from the grid container's style, so they are only valid while the
/// style's name memory is alive.
pub const DetailedGridInfo = struct {
    /// <https://drafts.csswg.org/css-grid-1/#grid-row>
    rows: DetailedGridTracksInfo = .{},
    /// <https://drafts.csswg.org/css-grid-1/#grid-column>
    columns: DetailedGridTracksInfo = .{},
    /// <https://drafts.csswg.org/css-grid-1/#grid-items>
    items: []DetailedGridItemsInfo = &.{},
    /// Grid area edge lookup used to resolve the grid placements of absolutely positioned children
    areas: GridAreasMap = .empty,

    /// Free the info's memory
    pub fn deinit(self: *DetailedGridInfo, gpa: Allocator) void {
        self.rows.deinit(gpa);
        self.columns.deinit(gpa);
        gpa.free(self.items);
        self.areas.deinit(gpa);
        self.* = .{};
    }

    /// Write the used row track sizes and line names to the passed writer in the resolved value
    /// format of the `grid-template-rows` property
    /// (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    pub fn writeGridTemplateRows(self: *const DetailedGridInfo, out: *std.Io.Writer, zoom: f32) std.Io.Writer.Error!void {
        return self.rows.writeTrackList(out, zoom);
    }

    /// Write the used column track sizes and line names to the passed writer in the resolved value
    /// format of the `grid-template-columns` property
    /// (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    pub fn writeGridTemplateColumns(self: *const DetailedGridInfo, out: *std.Io.Writer, zoom: f32) std.Io.Writer.Error!void {
        return self.columns.writeTrackList(out, zoom);
    }

    /// Serialize the used row track sizes and line names in the resolved value format of the
    /// `grid-template-rows` property (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    /// The caller owns the returned string.
    pub fn gridTemplateRows(self: *const DetailedGridInfo, gpa: Allocator, zoom: f32) Allocator.Error![]u8 {
        return self.rows.toTrackListString(gpa, zoom);
    }

    /// Serialize the used column track sizes and line names in the resolved value format of the
    /// `grid-template-columns` property (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    /// The caller owns the returned string.
    pub fn gridTemplateColumns(self: *const DetailedGridInfo, gpa: Allocator, zoom: f32) Allocator.Error![]u8 {
        return self.columns.toTrackListString(gpa, zoom);
    }

    /// Resolve the physical grid area for an absolutely positioned box from its grid placement.
    /// The padding box and returned area use coordinates relative to the grid container's border box.
    pub fn resolveAbsoluteGridArea(
        self: *const DetailedGridInfo,
        grid_row: Line(GridPlacement),
        grid_column: Line(GridPlacement),
        direction: Direction,
        padding_box: Rect(f32),
    ) Rect(f32) {
        const column_line = self.columns.resolveAbsoluteGridAxis(
            grid_column,
            &self.areas,
            .column,
            padding_box.left,
            padding_box.right,
            direction.isRtl(),
        );
        const row_line = self.rows.resolveAbsoluteGridAxis(
            grid_row,
            &self.areas,
            .row,
            padding_box.top,
            padding_box.bottom,
            false,
        );
        return .{ .left = column_line.start, .right = column_line.end, .top = row_line.start, .bottom = row_line.end };
    }

    /// The location and size of a grid area
    pub const ItemGridArea = struct { location: Point(f32), size: Size(f32) };

    /// Compute the location and size of the grid area occupied by the item at `item_index` (an
    /// index into `DetailedGridInfo.items`), relative to the grid container's border box.
    ///
    /// The edges resolve to the edges of the tracks bounding the item's grid area (a start line
    /// resolves to the start of the track that follows it and an end line to the end of the track
    /// that precedes it), so the area excludes any gutter or content-alignment spacing around it.
    ///
    /// Returns `null` if `item_index` is out of bounds.
    pub fn itemGridArea(self: *const DetailedGridInfo, item_index: usize) ?ItemGridArea {
        if (item_index >= self.items.len) return null;
        const item = self.items[item_index];
        const start_col = self.columns.positions.items[@as(usize, item.column_start) - 1];
        const end_col = self.columns.positions.items[@as(usize, item.column_end) - 2];
        const left = f32Min(start_col.start, end_col.start);
        const right = f32Max(start_col.end, end_col.end);
        const top = self.rows.positions.items[@as(usize, item.row_start) - 1].start;
        const bottom = self.rows.positions.items[@as(usize, item.row_end) - 2].end;
        return .{ .location = .{ .x = left, .y = top }, .size = .{ .width = right - left, .height = bottom - top } };
    }
};

/// Information from the computation of grids tracks
pub const DetailedGridTracksInfo = struct {
    /// Number of leading implicit grid tracks
    negative_implicit_tracks: u16 = 0,
    /// Number of explicit grid tracks
    explicit_tracks: u16 = 0,
    /// Number of trailing implicit grid tracks
    positive_implicit_tracks: u16 = 0,

    /// The start and end position of each track relative to the grid container's border box.
    /// These positions account for the container's border and padding, the `gap` property,
    /// content alignment (`align-content`/`justify-content`), and collapsed tracks.
    positions: std.ArrayList(Line(f32)) = .empty,

    /// Sorted, disjoint ranges of collapsed `auto-fit` tracks (indices into `positions`), whose
    /// adjacent gutters overlap when resolving absolute grid-area edges. Empty (and never
    /// allocated) unless a track collapsed.
    collapsed_tracks: std.ArrayList(Range(usize)) = .empty,

    /// The position of the axis' single grid line relative to the grid container's border box
    /// when the axis has no tracks (an empty grid still contains one grid line in each axis,
    /// positioned by content alignment). `null` when the axis has tracks.
    empty_axis_line: ?f32 = null,

    /// The names of each *explicit* grid line. Stored line `i` (0-indexed) bounds the start of
    /// explicit track `i`; use `DetailedGridTracksInfo.namesForLine` or
    /// `DetailedGridTracksInfo.iterLineNames` for indices relative to the full grid
    /// (including implicit tracks). Empty if the grid has no named lines.
    line_names: GridLineNames = .{},

    /// Free the info's memory
    pub fn deinit(self: *DetailedGridTracksInfo, gpa: Allocator) void {
        self.positions.deinit(gpa);
        self.collapsed_tracks.deinit(gpa);
        self.line_names.deinit(gpa);
        self.* = .{};
    }

    /// Resolve an absolute placement in this axis to physical start and end coordinates
    fn resolveAbsoluteGridAxis(
        self: *const DetailedGridTracksInfo,
        grid_placement: Line(GridPlacement),
        areas: *const GridAreasMap,
        axis: GridAreaAxis,
        padding_start: f32,
        padding_end: f32,
        is_reversed: bool,
    ) Line(f32) {
        const track_counts: TrackCounts = .{
            .negative_implicit = self.negative_implicit_tracks,
            .explicit = self.explicit_tracks,
            .positive_implicit = self.positive_implicit_tracks,
        };
        const min_line: i16 = -@as(i16, @bitCast(track_counts.negative_implicit));
        const max_line: i16 = @bitCast(track_counts.explicit + track_counts.positive_implicit);
        // Resolve the placement to a pair of (sorted) lines first, and only then treat lines
        // that fall outside the grid as `auto`. A placement whose lines end up swapped (e.g.
        // `grid-column: 3 / 1`, or a non-existent named line which resolves past the end of the
        // explicit grid) is normalized before the out-of-grid check, so e.g. `foo / 3` on a
        // 2-column grid resolves to the area between line 3 and the end padding edge.
        const resolved = self.line_names
            .resolveLineNames(grid_placement, areas, axis, self.explicit_tracks)
            .intoOriginZero(self.explicit_tracks)
            .resolveAbsolutelyPositionedGridTracks();
        const resolved_placement: Line(?usize) = .{
            .start = trackIndexWithinGrid(resolved.start, min_line, max_line, track_counts),
            .end = trackIndexWithinGrid(resolved.end, min_line, max_line, track_counts),
        };
        const positions = self.positions.items;
        const start_position: f32 = blk: {
            if (resolved_placement.start) |line| {
                if (line < positions.len) break :blk self.absoluteTrackEdge(line, true, is_reversed);
                if (positions.len > 0) {
                    const track = positions[positions.len - 1];
                    break :blk if (is_reversed) track.start else track.end;
                }
                if (self.empty_axis_line) |empty_line| break :blk empty_line;
            }
            break :blk if (is_reversed) padding_end else padding_start;
        };
        const end_position: f32 = blk: {
            if (resolved_placement.end) |line| {
                if (line >= 1 and line - 1 < positions.len) break :blk self.absoluteTrackEdge(line - 1, false, is_reversed);
                if (positions.len > 0) {
                    const track = positions[0];
                    break :blk if (is_reversed) track.end else track.start;
                }
                if (self.empty_axis_line) |empty_line| break :blk empty_line;
            }
            break :blk if (is_reversed) padding_start else padding_end;
        };

        // An area whose lines all fall within a collapsed run is zero-sized and anchored at its
        // logical start edge (as in Chrome; Gecko anchors it before the shared gutter instead).
        if (is_reversed) {
            return .{ .start = f32Min(start_position, end_position), .end = start_position };
        } else {
            return .{ .start = start_position, .end = f32Max(start_position, end_position) };
        }
    }

    /// Filter a resolved line to the lines of the grid and convert it to a track index
    fn trackIndexWithinGrid(maybe_line: ?OriginZeroLine, min_line: i16, max_line: i16, track_counts: TrackCounts) ?usize {
        const line = maybe_line orelse return null;
        if (!(line.inner >= min_line and line.inner <= max_line)) return null;
        const index = line.tryIntoTrackVecIndex(track_counts) orelse return null;
        return index / 2;
    }

    /// Resolve a track edge, excluding gutters that overlap across a collapsed track run.
    fn absoluteTrackEdge(self: *const DetailedGridTracksInfo, index: usize, is_start: bool, is_reversed: bool) f32 {
        const collapsed = self.collapsed_tracks.items;
        const positions = self.positions.items;
        // partition_point(|range| range.end <= index)
        var range_index: usize = 0;
        while (range_index < collapsed.len and collapsed[range_index].end <= index) range_index += 1;
        var track = positions[index];
        if (range_index < collapsed.len and collapsed[range_index].contains(index)) {
            const range = collapsed[range_index];
            const adjacent: ?usize = if (is_start) range.end else if (range.start >= 1) range.start - 1 else null;
            if (adjacent) |adjacent_index| {
                if (adjacent_index < positions.len) track = positions[adjacent_index];
            }
        }
        // Collapsed gutters overlap: a start edge follows the shared gutter, while an end
        // edge precedes it.
        if (is_start != is_reversed) {
            return track.start;
        } else {
            return track.end;
        }
    }

    /// Get the start and end position of each track relative to the grid container's border box,
    /// along with the index ranges of any runs of collapsed `auto-fit` tracks
    fn positionsFromGridTrackLayout(self: *DetailedGridTracksInfo, gpa: Allocator, grid_tracks: []const GridTrack) LayoutError!void {
        try self.positions.ensureTotalCapacity(gpa, grid_tracks.len / 2);
        for (grid_tracks) |*track| {
            if (track.kind != .track) continue;
            if (track.is_collapsed) {
                const index = self.positions.items.len;
                const ranges = self.collapsed_tracks.items;
                if (ranges.len > 0 and ranges[ranges.len - 1].end == index) {
                    ranges[ranges.len - 1].end += 1;
                } else {
                    try self.collapsed_tracks.append(gpa, .{ .start = index, .end = index + 1 });
                }
            }
            try self.positions.append(gpa, .{ .start = track.offset, .end = track.offset + track.base_size });
        }
    }

    /// Construct DetailedGridTracksInfo from TrackCounts and GridTracks. Moves `line_names.*` into
    /// the result (leaving it empty) on success.
    fn fromGridTracksAndTrackCount(
        gpa: Allocator,
        track_count: TrackCounts,
        grid_tracks: []const GridTrack,
        line_names: *GridLineNames,
    ) LayoutError!DetailedGridTracksInfo {
        var self: DetailedGridTracksInfo = .{
            .negative_implicit_tracks = track_count.negative_implicit,
            .explicit_tracks = track_count.explicit,
            .positive_implicit_tracks = track_count.positive_implicit,
        };
        errdefer self.deinit(gpa);
        try self.positionsFromGridTrackLayout(gpa, grid_tracks);
        // An axis with no tracks consists of a single gutter whose offset is where the axis'
        // single grid line was positioned by content alignment
        self.empty_axis_line = if (self.positions.items.len == 0 and grid_tracks.len > 0) grid_tracks[0].offset else null;
        self.line_names = line_names.*;
        line_names.* = .{};
        return self;
    }

    /// The names of the grid line with the passed 0-indexed line index, where line `i` bounds
    /// the start of track `i` of the full grid (including implicit tracks).
    /// Returns an empty slice if the line has no names or the index is out of range.
    pub fn namesForLine(self: *const DetailedGridTracksInfo, line_index: usize) []const []const u8 {
        if (line_index >= self.negative_implicit_tracks) {
            return self.line_names.line(line_index - self.negative_implicit_tracks);
        }
        return &.{};
    }

    /// Iterate over the name group of each grid line of the full grid (including implicit
    /// tracks) in line order, yielding empty groups for unnamed (implicit) lines.
    /// Yields nothing if the grid has no named lines.
    pub fn iterLineNames(self: *const DetailedGridTracksInfo) GridLineNamesIter {
        if (self.line_names.isEmpty()) {
            return self.line_names.iter();
        }
        const total_line_count = self.positions.items.len + 1;
        const leading_empty: usize = self.negative_implicit_tracks;
        const trailing_empty = total_line_count -| (leading_empty + self.line_names.lineCount());
        return self.line_names.iterPadded(leading_empty, trailing_empty);
    }

    /// Write a bracketed line name group (e.g. `[foo bar]`)
    fn writeLineNames(out: *std.Io.Writer, names: []const []const u8) std.Io.Writer.Error!void {
        try out.writeByte('[');
        for (names, 0..) |name, i| {
            if (i != 0) {
                try out.writeByte(' ');
            }
            try out.writeAll(name);
        }
        try out.writeByte(']');
    }

    /// Write the used track sizes and line names of this axis to the passed writer in the
    /// resolved value format of the `grid-template-rows`/`grid-template-columns` properties
    /// (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    pub fn writeTrackList(self: *const DetailedGridTracksInfo, out: *std.Io.Writer, zoom: f32) std.Io.Writer.Error!void {
        const positions = self.positions.items;
        if (positions.len == 0) {
            return out.writeAll("none");
        }

        var needs_space = false;
        for (positions, 0..) |position, track_index| {
            const names = self.namesForLine(track_index);
            if (names.len != 0) {
                if (needs_space) {
                    try out.writeByte(' ');
                }
                try writeLineNames(out, names);
                needs_space = true;
            }
            if (needs_space) {
                try out.writeByte(' ');
            }
            try out.print("{d}px", .{(position.end - position.start) / zoom});
            needs_space = true;
        }
        const trailing_names = self.namesForLine(positions.len);
        if (trailing_names.len != 0) {
            try out.writeByte(' ');
            try writeLineNames(out, trailing_names);
        }
    }

    /// Serialize the used track sizes and line names of this axis in the resolved value format of
    /// the `grid-template-rows`/`grid-template-columns` properties
    /// (see <https://www.w3.org/TR/css-grid-1/#resolved-track-list>)
    /// Track sizes are divided by `zoom` (the container's effective CSS `zoom`, or `1.0`) to give unzoomed px.
    /// The caller owns the returned string.
    pub fn toTrackListString(self: *const DetailedGridTracksInfo, gpa: Allocator, zoom: f32) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        self.writeTrackList(&out.writer, zoom) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// Grid area information from the placement algorithm
///
/// The values is 1-indexed grid line numbers bounding the area.
/// This matches the Chrome and Firefox's format as of 2nd Jan 2024.
pub const DetailedGridItemsInfo = struct {
    /// row-start with 1-indexed grid line numbers
    row_start: u16,
    /// row-end with 1-indexed grid line numbers
    row_end: u16,
    /// column-start with 1-indexed grid line numbers
    column_start: u16,
    /// column-end with 1-indexed grid line numbers
    column_end: u16,

    /// Conversion from the indexes of the track list into 1-indexed grid line numbers. See `GridItem.row_indexes` or `GridItem.column_indexes`
    inline fn toOneIndexedGridLine(grid_track_index: u16) u16 {
        return grid_track_index / 2 + 1;
    }

    /// Construct from GridItems
    fn fromGridItem(grid_item: *const GridItem) DetailedGridItemsInfo {
        return .{
            .row_start = toOneIndexedGridLine(grid_item.row_indexes.start),
            .row_end = toOneIndexedGridLine(grid_item.row_indexes.end),
            .column_start = toOneIndexedGridLine(grid_item.column_indexes.start),
            .column_end = toOneIndexedGridLine(grid_item.column_indexes.end),
        };
    }
};

test {
    _ = alignment;
    _ = explicit_grid;
    _ = implicit_grid;
    _ = placement;
    _ = track_sizing;
    _ = types;
}

// ---------------------------------------------------------------------------------------------
// Tests (laffy additions: leak checks of multi-level layouts under the testing allocator)

const testing = std.testing;
const TaffyTree = @import("../tree/taffy_tree.zig").TaffyTree;
const Style = style_mod.Style;
const AlignSelf = style_mod.AlignSelf;
const Dimension = style_mod.Dimension;
const GridTemplateArea = style_mod.GridTemplateArea;
const GridTemplateComponent = style_mod.GridTemplateComponent;
const LengthPercentage = style_mod.LengthPercentage;
const LengthPercentageAuto = style_mod.LengthPercentageAuto;
const MaxTrackSizingFunction = style_mod.MaxTrackSizingFunction;
const MinTrackSizingFunction = style_mod.MinTrackSizingFunction;
const TrackSizingFunction = style_mod.TrackSizingFunction;

fn testNamedLine(name: []const u8, index: i16) GridPlacement {
    return .{ .named_line = .{ .name = name, .index = index } };
}

/// Build a multi-level grid tree with auto-placed (sparse and dense) and named-line placed items,
/// named areas, intrinsic, flexible, `auto-fill`/`auto-fit` and percentage tracks, baseline-aligned
/// items, hidden children and absolutely positioned / fixed children at several depths (some
/// claimed by an intermediate relatively positioned grid, whose grid areas they are positioned
/// against, some bubbling to the root), then lay it out several times.
fn layoutNestedGrid(gpa: Allocator) !void {
    var taffy = try TaffyTree(void).init(gpa);
    defer taffy.deinit();

    var leaf_style: Style = .{};
    leaf_style.size = Size(Dimension).fromLengths(20.0, 10.0);
    var hidden_style: Style = .{};
    hidden_style.display = .none;
    var fixed_style: Style = .{};
    fixed_style.position = .fixed;
    fixed_style.size = Size(Dimension).fromLengths(2.0, 3.0);

    // Inner grid: `[a] 1fr [b] minmax(min-content, 2fr) [c]` columns, auto and percentage rows, a
    // named area, baseline-aligned items and absolutely positioned children placed against its
    // grid areas
    const inner_columns = [_]GridTemplateComponent{
        GridTemplateComponent.fromFr(1.0),
        GridTemplateComponent.fromMinMax(.{ .min = MinTrackSizingFunction.min_content, .max = MaxTrackSizingFunction.fr(2.0) }),
    };
    const inner_rows = [_]GridTemplateComponent{ GridTemplateComponent.auto, GridTemplateComponent.fromPercent(0.25) };
    const inner_areas = [_]GridTemplateArea{.{ .name = "hdr", .row_start = 1, .row_end = 2, .column_start = 1, .column_end = 3 }};
    var inner_style: Style = .{ .display = .grid };
    inner_style.position = .relative;
    inner_style.grid_template_columns = &inner_columns;
    inner_style.grid_template_rows = &inner_rows;
    inner_style.grid_template_column_names = &.{ &.{"a"}, &.{"b"}, &.{"c"} };
    inner_style.grid_template_areas = .{ .areas = &inner_areas, .row_count = 1, .column_count = 2 };
    inner_style.gap = Size(LengthPercentage).length(3.0);
    inner_style.padding = Rect(LengthPercentage).length(2.0);

    var baseline_style = leaf_style;
    baseline_style.align_self = AlignSelf.baseline;
    baseline_style.margin = .{ .left = .length(0.0), .right = .length(0.0), .top = .length(4.0), .bottom = .length(0.0) };
    var abs_named_style: Style = .{};
    abs_named_style.position = .absolute;
    abs_named_style.grid_column = .{ .start = testNamedLine("b", 0), .end = testNamedLine("c", 0) };
    abs_named_style.grid_row = .{ .start = testNamedLine("hdr", 0), .end = .auto };
    abs_named_style.inset = .{ .left = .length(1.0), .right = .auto, .top = .auto, .bottom = .length(2.0) };
    abs_named_style.size = Size(Dimension).fromLengths(5.0, 4.0);
    var abs_stretch_style: Style = .{};
    abs_stretch_style.position = .absolute;
    abs_stretch_style.grid_column = .{ .start = .{ .line = GridLine.from(1) }, .end = .{ .span = 2 } };
    abs_stretch_style.inset = Rect(LengthPercentageAuto).length(1.0);
    var header_style: Style = .{};
    header_style.grid_row = .{ .start = testNamedLine("hdr", 0), .end = testNamedLine("hdr", 0) };
    header_style.grid_column = .{ .start = testNamedLine("hdr", 0), .end = testNamedLine("hdr", 0) };
    header_style.size = .{ .width = .auto, .height = .length(6.0) };

    const deep_leaf = try taffy.newLeaf(leaf_style);
    const deep_fixed = try taffy.newLeaf(fixed_style);
    const deep_abs = try taffy.newLeaf(abs_named_style);
    const deep_wrapper = try taffy.newWithChildren(.{ .display = .grid }, &.{ deep_leaf, deep_abs, deep_fixed });
    const inner_children = [_]NodeId{
        try taffy.newLeaf(header_style),
        try taffy.newWithChildren(baseline_style, &.{try taffy.newLeaf(leaf_style)}),
        try taffy.newLeaf(baseline_style),
        try taffy.newLeaf(abs_named_style),
        deep_wrapper,
        try taffy.newLeaf(abs_stretch_style),
        try taffy.newWithChildren(hidden_style, &.{try taffy.newLeaf(leaf_style)}),
    };
    const inner = try taffy.newWithChildren(inner_style, &inner_children);

    // A flex container nested in the grid (grid item with a non-grid layout)
    var flex_style: Style = .{ .display = .flex };
    flex_style.size = .{ .width = .percent(0.5), .height = .auto };
    const flex_child = try taffy.newWithChildren(flex_style, &.{ try taffy.newLeaf(leaf_style), try taffy.newLeaf(fixed_style) });

    // Root grid: `[start col] repeat(auto-fill, 40px) [end] 30px` columns, dense auto flow,
    // auto-fit rows, RTL, a scroll container
    const auto_fill_tracks = [_]TrackSizingFunction{TrackSizingFunction.fromLength(40.0)};
    const root_columns = [_]GridTemplateComponent{
        .{ .repeat = .{ .count = .auto_fill, .tracks = &auto_fill_tracks, .line_names = &.{ &.{"col"}, &.{} } } },
        GridTemplateComponent.fromLength(30.0),
    };
    const auto_fit_tracks = [_]TrackSizingFunction{TrackSizingFunction.fromLength(30.0)};
    const root_rows = [_]GridTemplateComponent{.{ .repeat = .{ .count = .auto_fit, .tracks = &auto_fit_tracks } }};
    const auto_rows = [_]TrackSizingFunction{ TrackSizingFunction.auto, TrackSizingFunction.max_content };
    var root_style: Style = .{ .display = .grid };
    root_style.size = Size(Dimension).fromLengths(200.0, 150.0);
    root_style.grid_template_columns = &root_columns;
    root_style.grid_template_column_names = &.{ &.{"start"}, &.{"end"} };
    root_style.grid_template_rows = &root_rows;
    root_style.grid_auto_rows = &auto_rows;
    root_style.grid_auto_flow = .row_dense;
    root_style.direction = .rtl;
    root_style.overflow = .{ .x = .scroll, .y = .scroll };
    root_style.scrollbar_width = 5.0;
    root_style.justify_content = AlignContent.space_between;

    var wide_style = leaf_style;
    wide_style.grid_column = .{ .start = .{ .span = 2 }, .end = .auto };
    var named_style = leaf_style;
    named_style.grid_column = .{ .start = testNamedLine("col", 2), .end = testNamedLine("end", 0) };
    var root_abs_style: Style = .{};
    root_abs_style.position = .absolute;
    root_abs_style.grid_column = .{ .start = testNamedLine("col", 1), .end = .{ .span = 2 } };
    root_abs_style.grid_row = .{ .start = .{ .line = GridLine.from(-1) }, .end = .auto };
    root_abs_style.size = Size(Dimension).fromLengths(7.0, 4.0);

    const root_children = [_]NodeId{
        inner,
        try taffy.newLeaf(wide_style),
        try taffy.newLeaf(named_style),
        try taffy.newLeaf(root_abs_style),
        flex_child,
        try taffy.newLeaf(leaf_style),
        try taffy.newLeaf(hidden_style),
    };
    const root = try taffy.newWithChildren(root_style, &root_children);

    try taffy.computeLayout(root, .{ .width = .{ .definite = 300.0 }, .height = .{ .definite = 200.0 } });

    // The inner grid is the containing block of its own absolutely positioned descendants; the
    // fixed boxes and the root's own absolutely positioned child are laid out by the root
    try testing.expectEqualSlices(NodeId, &.{ inner_children[3], deep_abs, inner_children[5] }, taffy.hoistedChildren(inner));
    try testing.expectEqual(@as(usize, 3), taffy.hoistedChildren(root).len);
    try testing.expectEqual(Size(f32){ .width = 5.0, .height = 4.0 }, taffy.layout(deep_abs).size);
    // Both grids record their detailed grid info
    try testing.expect(taffy.detailedLayoutInfo(inner).* == .grid);
    const root_info = taffy.detailedLayoutInfo(root).grid;
    try testing.expect(root_info.columns.positions.items.len >= 2);
    const columns_text = try root_info.gridTemplateColumns(gpa, 1.0);
    defer gpa.free(columns_text);
    try testing.expectEqualStrings("[start col] 40px [col] 40px [col] 40px [col] 40px [end] 30px", columns_text);

    // A relayout after a style change exercises the cache, the hoisted-list bookkeeping and the
    // replacement of the stored detailed grid info
    var narrow_style = leaf_style;
    narrow_style.size = .{ .width = .percent(0.25), .height = .length(5.0) };
    taffy.setStyle(root_children[5], narrow_style);
    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try taffy.computeLayout(root, Size(AvailableSpace).min_content);
    try testing.expectEqualSlices(NodeId, &.{ inner_children[3], deep_abs, inner_children[5] }, taffy.hoistedChildren(inner));

    // Removing a grid container frees its detailed grid info
    _ = taffy.remove(inner);
}

test "multi-level grid trees with absolutely positioned children do not leak" {
    try layoutNestedGrid(testing.allocator);
}

test "multi-level grid layout frees everything when allocations fail" {
    try testing.checkAllAllocationFailures(testing.allocator, layoutNestedGrid, .{});
}

test "grid places items and records detailed grid info" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const columns = [_]GridTemplateComponent{ GridTemplateComponent.fromLength(50.0), GridTemplateComponent.fromFr(1.0) };
    var grid_style: Style = .{ .display = .grid };
    grid_style.size = Size(Dimension).fromLengths(150.0, 100.0);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_column_names = &.{ &.{"a"}, &.{}, &.{ "z", "end" } };
    grid_style.gap = .{ .width = .length(10.0), .height = .zero };
    var item_style: Style = .{};
    item_style.size = .{ .width = .auto, .height = .length(20.0) };
    const a = try taffy.newLeaf(item_style);
    const b = try taffy.newLeaf(item_style);
    const c = try taffy.newLeaf(item_style);
    const root = try taffy.newWithChildren(grid_style, &.{ a, b, c });

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 0.0 }, taffy.layout(a).location);
    try testing.expectEqual(Size(f32){ .width = 50.0, .height = 20.0 }, taffy.layout(a).size);
    try testing.expectEqual(Point(f32){ .x = 60.0, .y = 0.0 }, taffy.layout(b).location);
    try testing.expectEqual(Size(f32){ .width = 90.0, .height = 20.0 }, taffy.layout(b).size);
    // The two auto rows stretch to fill the container's height
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 50.0 }, taffy.layout(c).location);

    const info = taffy.detailedLayoutInfo(root).grid;
    const columns_text = try info.gridTemplateColumns(testing.allocator, 1.0);
    defer testing.allocator.free(columns_text);
    try testing.expectEqualStrings("[a] 50px 90px [z end]", columns_text);
    const rows_text = try info.gridTemplateRows(testing.allocator, 1.0);
    defer testing.allocator.free(rows_text);
    try testing.expectEqualStrings("50px 50px", rows_text);
    try testing.expectEqual(@as(usize, 3), info.items.len);
    try testing.expectEqual(DetailedGridItemsInfo{ .row_start = 2, .row_end = 3, .column_start = 1, .column_end = 2 }, info.items[2]);
    const area = info.itemGridArea(1).?;
    try testing.expectEqual(Point(f32){ .x = 60.0, .y = 0.0 }, area.location);
    try testing.expectEqual(Size(f32){ .width = 90.0, .height = 50.0 }, area.size);
    try testing.expectEqual(@as(?DetailedGridInfo.ItemGridArea, null), info.itemGridArea(3));

    var names = info.columns.iterLineNames();
    try testing.expectEqual(@as(usize, 3), names.len());
    try testing.expectEqualStrings("a", names.next().?[0]);
    try testing.expectEqual(@as(usize, 0), names.next().?.len);
    try testing.expectEqual(@as(usize, 2), names.next().?.len);
    try testing.expectEqual(@as(?[]const []const u8, null), names.next());
}
