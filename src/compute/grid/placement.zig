//! Implements placing items in the grid and resolving the implicit grid.
//! <https://www.w3.org/TR/css-grid-1/#placement>
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const InBothAbsAxis = geometry.InBothAbsAxis;
const Line = geometry.Line;
const style_mod = @import("../../style.zig");
const GridAutoFlow = style_mod.GridAutoFlow;
const OriginZeroGridPlacement = style_mod.OriginZeroGridPlacement;
const LayoutError = @import("../../tree/layout.zig").LayoutError;
const types = @import("types.zig");
const CellOccupancyMatrix = types.CellOccupancyMatrix;
const CellOccupancyState = types.CellOccupancyState;
const GridItem = types.GridItem;
const OriginZeroLine = types.OriginZeroLine;
const max_oz_line = types.max_oz_line;
const min_oz_line = types.min_oz_line;

/// Advances the cursor by one track.
inline fn advancePosition(position: OriginZeroLine) OriginZeroLine {
    return OriginZeroLine.from(position.inner +| 1);
}

/// Resolves an indefinite span starting at `position`.
inline fn resolveIndefiniteGridSpan(position: OriginZeroLine, span: u16) Line(OriginZeroLine) {
    const start: i32 = position.inner;
    const span_i32: i32 = span;
    return .{ .start = clampedLine(start), .end = clampedLine(start + span_i32) };
}

inline fn clampedLine(value: i32) OriginZeroLine {
    return OriginZeroLine.from(@intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16))));
}

/// A grid item's `grid-row`/`grid-column` styles with named lines resolved, in origin-zero coordinates
pub const ItemPlacement = InBothAbsAxis(Line(OriginZeroGridPlacement));

/// A placement as a pair of spans
const Spans = struct { Line(OriginZeroLine), Line(OriginZeroLine) };

/// 8.5. Grid Item Placement Algorithm
/// Place items into the grid, generating new rows/column into the implicit grid as required
///
/// `items` and `placements` are parallel slices in document order: `placements[i]` holds the `grid-row`/`grid-column`
/// styles of `items[i]`, with named lines already resolved. The placement passes run over these (small) values rather
/// than re-reading the children's styles.
///
/// [Specification](https://www.w3.org/TR/css-grid-2/#auto-placement-algo)
pub fn placeGridItems(
    gpa: Allocator,
    cell_occupancy_matrix: *CellOccupancyMatrix,
    items: []GridItem,
    placements: []const ItemPlacement,
    grid_auto_flow: GridAutoFlow,
) LayoutError!void {
    std.debug.assert(items.len == placements.len);
    const primary_axis = grid_auto_flow.primaryAxis();
    const secondary_axis = primary_axis.otherAxis();

    // 1. Place children with definite positions
    for (items, placements) |*item, placement| {
        if (!(placement.horizontal.isDefinite() and placement.vertical.isDefinite())) {
            continue;
        }

        const row_span, const col_span = placeDefiniteGridItem(placement, primary_axis);
        try recordGridPlacement(gpa, cell_occupancy_matrix, item, primary_axis, row_span, col_span, .definitely_placed);
    }

    // 2. Place remaining children with definite secondary axis positions
    for (items, placements) |*item, placement| {
        if (!(placement.get(secondary_axis).isDefinite() and !placement.get(primary_axis).isDefinite())) {
            continue;
        }

        const primary_span, const secondary_span = placeDefiniteSecondaryAxisItem(cell_occupancy_matrix, placement, grid_auto_flow);

        try recordGridPlacement(gpa, cell_occupancy_matrix, item, primary_axis, primary_span, secondary_span, .auto_placed);
    }

    // 3. Determine the number of columns in the implicit grid
    // By the time we get to this point in the execution, this is actually already accounted for:
    //
    // 3.1 Start with the columns from the explicit grid
    //        => Handled by grid size estimate which is used to pre-size the GridOccupancyMatrix
    //
    // 3.2 Among all the items with a definite column position (explicitly positioned items, items positioned in the previous step,
    //     and items not yet positioned but with a definite column) add columns to the beginning and end of the implicit grid as necessary
    //     to accommodate those items.
    //        => Handled by expandToFitRange which expands the GridOccupancyMatrix as necessary
    //            -> Called by markAreaAs
    //            -> Called by recordGridPlacement
    //
    // 3.3 If the largest column span among all the items without a definite column position is larger than the width of
    //     the implicit grid, add columns to the end of the implicit grid to accommodate that column span.
    //        => Handled by grid size estimate which is used to pre-size the GridOccupancyMatrix

    // 4. Position the remaining grid items
    // (which either have definite position only in the secondary axis or indefinite positions in both axis)
    const primary_axis_grid_start_line = cell_occupancy_matrix.trackCounts(primary_axis).implicitStartLine();
    const secondary_axis_grid_start_line = cell_occupancy_matrix.trackCounts(secondary_axis).implicitStartLine();
    const grid_start_position: GridPosition = .{ primary_axis_grid_start_line, secondary_axis_grid_start_line };
    var grid_position = grid_start_position;
    for (items, placements) |*item, placement| {
        if (placement.get(secondary_axis).isDefinite()) {
            continue;
        }

        // Compute placement
        const primary_span, const secondary_span = placeIndefinitelyPositionedItem(cell_occupancy_matrix, placement, grid_auto_flow, grid_position);

        // Record item
        try recordGridPlacement(gpa, cell_occupancy_matrix, item, primary_axis, primary_span, secondary_span, .auto_placed);

        // If using the "dense" placement algorithm then reset the grid position back to grid_start_position ready for the next item
        // Otherwise set it to the position of the current item so that the next item it placed after it.
        grid_position = if (grid_auto_flow.isDense())
            grid_start_position
        else
            .{ primary_span.end, secondary_span.start };
    }
}

/// A (primary axis, secondary axis) search position
const GridPosition = struct { OriginZeroLine, OriginZeroLine };

/// 8.5. Grid Item Placement Algorithm
/// Place a single definitely placed item into the grid
fn placeDefiniteGridItem(placement: ItemPlacement, primary_axis: AbsoluteAxis) Spans {
    // Resolve spans to tracks
    const primary_span = placement.get(primary_axis).resolveDefiniteGridLines();
    const secondary_span = placement.get(primary_axis.otherAxis()).resolveDefiniteGridLines();

    return .{ primary_span, secondary_span };
}

/// 8.5. Grid Item Placement Algorithm
/// Step 2. Place remaining children with definite secondary axis positions
fn placeDefiniteSecondaryAxisItem(
    cell_occupancy_matrix: *const CellOccupancyMatrix,
    placement: ItemPlacement,
    auto_flow: GridAutoFlow,
) Spans {
    const primary_axis = auto_flow.primaryAxis();
    const secondary_axis = primary_axis.otherAxis();
    const primary_axis_grid_start_line = cell_occupancy_matrix.trackCounts(primary_axis).implicitStartLine();

    const secondary_axis_placement = placement.get(secondary_axis).resolveDefiniteGridLines();
    const starting_position = if (auto_flow.isDense())
        primary_axis_grid_start_line
    else
        cell_occupancy_matrix.autoPlacementCursor(primary_axis, secondary_axis_placement.start) orelse primary_axis_grid_start_line;
    const primary_axis_span = placement.get(primary_axis).indefiniteSpan();

    var position: OriginZeroLine = starting_position;
    while (true) {
        const primary_axis_placement = resolveIndefiniteGridSpan(position, primary_axis_span);

        const collision = cell_occupancy_matrix.lineAreaCollisionJump(primary_axis, primary_axis_placement, secondary_axis_placement);

        if (collision) |next_position| {
            position = next_position;
        } else {
            return .{ primary_axis_placement, secondary_axis_placement };
        }
    }
}

/// 8.5. Grid Item Placement Algorithm
/// Step 4. Position the remaining grid items.
fn placeIndefinitelyPositionedItem(
    cell_occupancy_matrix: *const CellOccupancyMatrix,
    placement: ItemPlacement,
    auto_flow: GridAutoFlow,
    grid_position: GridPosition,
) Spans {
    const primary_axis = auto_flow.primaryAxis();
    const secondary_axis = primary_axis.otherAxis();

    const primary_placement_style = placement.get(primary_axis);
    const secondary_placement_style = placement.get(secondary_axis);

    const secondary_span_count = secondary_placement_style.indefiniteSpan();
    const has_definite_primary_axis_position = primary_placement_style.isDefinite();
    const primary_axis_grid_start_line = cell_occupancy_matrix.trackCounts(primary_axis).implicitStartLine();
    const primary_axis_grid_end_line = cell_occupancy_matrix.trackCounts(primary_axis).implicitEndLine();
    const secondary_axis_grid_start_line = cell_occupancy_matrix.trackCounts(secondary_axis).implicitStartLine();

    var primary_idx, var secondary_idx = grid_position;

    if (has_definite_primary_axis_position) {
        const primary_span = primary_placement_style.resolveDefiniteGridLines();

        // Compute secondary axis starting position for search
        secondary_idx = if (auto_flow.isDense())
            // If auto-flow is dense then we always search from the first track
            secondary_axis_grid_start_line
        else if (primary_span.start.inner < primary_idx.inner)
            advancePosition(secondary_idx)
        else
            secondary_idx;

        // Item has fixed primary axis position: so we simply increment the secondary axis position
        // until we find a space that the item fits in
        while (true) {
            const secondary_span = resolveIndefiniteGridSpan(secondary_idx, secondary_span_count);

            // If area is occupied, jump the index past the collision and try again
            const collision = cell_occupancy_matrix.lineAreaCollisionJump(secondary_axis, secondary_span, primary_span);
            if (collision) |next_position| {
                secondary_idx = next_position;
                continue;
            }

            // Once we find a free space, return that position
            return .{ primary_span, secondary_span };
        }
    } else {
        const primary_span_count = primary_placement_style.indefiniteSpan();

        // Whether the item spans every track in the primary axis. Such an item can only be
        // placed at the primary axis grid start, in a stripe of entirely unoccupied tracks.
        const spans_all_primary_tracks = @as(usize, primary_span_count) >= cell_occupancy_matrix.trackCounts(primary_axis).len();

        // Item does not have any fixed axis, so we search along the primary axis until we hit the end of the already
        // existent tracks, and then we reset the primary axis back to zero and increment the secondary axis index.
        // We continue in this vein until we find a space that the item fits in.
        while (true) {
            const primary_span = resolveIndefiniteGridSpan(primary_idx, primary_span_count);
            const secondary_span = resolveIndefiniteGridSpan(secondary_idx, secondary_span_count);

            // If the primary index is out of bounds, then increment the secondary index and reset the primary
            // index back to the start of the grid
            const primary_out_of_bounds = primary_span.end.inner > primary_axis_grid_end_line.inner;
            if (primary_out_of_bounds) {
                // If the span is out of bounds even at the search start position then it can never fit,
                // as searching only ever moves the span further away from the start of the grid. Bail out
                // and let `recordGridPlacement` clamp the placement into the limited grid
                if (primary_idx == primary_axis_grid_start_line) {
                    return .{ primary_span, secondary_span };
                }
                secondary_idx = advancePosition(secondary_idx);
                primary_idx = primary_axis_grid_start_line;
                continue;
            }

            // If the item spans every primary axis track, it fits if and only if all of the
            // secondary axis tracks it spans are entirely unoccupied. Jump the secondary index
            // past any non-empty tracks in the spanned stripe.
            if (spans_all_primary_tracks) {
                if (cell_occupancy_matrix.occupiedTrackJump(secondary_axis, secondary_span)) |next_position| {
                    secondary_idx = next_position;
                    primary_idx = primary_axis_grid_start_line;
                    continue;
                } else {
                    return .{ primary_span, secondary_span };
                }
            }

            // If area is occupied, jump the primary index past the collision and try again
            const collision = cell_occupancy_matrix.lineAreaCollisionJump(primary_axis, primary_span, secondary_span);
            if (collision) |next_position| {
                primary_idx = next_position;
                continue;
            }

            // Once we find a free space that's in bounds, return that position
            return .{ primary_span, secondary_span };
        }
    }
}

/// Clamp a placement into the limited grid, preserving a span of at least 1 track.
/// Items placed outside of the limited grid are clamped into it.
///
/// See: <https://www.w3.org/TR/css-grid-1/#overlarge-grids>
fn clampSpanToLimitedGrid(span: Line(OriginZeroLine)) Line(OriginZeroLine) {
    const start = std.math.clamp(span.start.inner, min_oz_line, max_oz_line - 1);
    const end = std.math.clamp(span.end.inner, start + 1, max_oz_line);
    return .{ .start = OriginZeroLine.from(start), .end = OriginZeroLine.from(end) };
}

/// Record the grid item's placement in both the CellOccupancyMatrix and the item itself
/// once a definite placement has been determined
fn recordGridPlacement(
    gpa: Allocator,
    cell_occupancy_matrix: *CellOccupancyMatrix,
    item: *GridItem,
    primary_axis: AbsoluteAxis,
    primary_span_in: Line(OriginZeroLine),
    secondary_span_in: Line(OriginZeroLine),
    placement_type: CellOccupancyState,
) LayoutError!void {
    // Clamp placements into the limited grid to prevent arithmetic overflow when growing the
    // implicit grid (https://www.w3.org/TR/css-grid-1/#overlarge-grids)
    const primary_span = clampSpanToLimitedGrid(primary_span_in);
    const secondary_span = clampSpanToLimitedGrid(secondary_span_in);

    // Mark area of grid as occupied
    try cell_occupancy_matrix.markAreaAs(gpa, primary_axis, primary_span, secondary_span, placement_type);

    // Record placement on the item
    const col_span: Line(OriginZeroLine), const row_span: Line(OriginZeroLine) = switch (primary_axis) {
        .horizontal => .{ primary_span, secondary_span },
        .vertical => .{ secondary_span, primary_span },
    };
    item.column = col_span;
    item.row = row_span;
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Style = style_mod.Style;
const GridPlacement = style_mod.GridPlacement;
const NodeId = @import("../../tree/node.zig").NodeId;
const TrackCounts = types.TrackCounts;
const NamedLineResolver = types.NamedLineResolver;
const computeGridSizeEstimate = @import("implicit_grid.zig").computeGridSizeEstimate;
const test_helpers = @import("util/test_helpers.zig");
const intoGridChild = test_helpers.intoGridChild;
const gridLine = test_helpers.line;
const gridSpan = test_helpers.span;
const auto = GridPlacement.auto;

const ExpectedPlacement = struct { i16, i16, i16, i16 };
const TestChild = struct { usize, Style, ExpectedPlacement };

fn placementTestRunner(
    explicit_col_count: u16,
    explicit_row_count: u16,
    children: []const TestChild,
    expected_col_counts: TrackCounts,
    expected_row_counts: TrackCounts,
    flow: GridAutoFlow,
) !void {
    const gpa = testing.allocator;
    // Setup test
    var name_resolver = try NamedLineResolver.new(gpa, &Style.default, 0, 0);
    defer name_resolver.deinit(gpa);
    name_resolver.setExplicitColumnCount(explicit_col_count);
    name_resolver.setExplicitRowCount(explicit_row_count);
    var styles: [16]Style = undefined;
    var indexes: [16]usize = undefined;
    for (children, 0..) |child, i| {
        indexes[i] = child[0];
        styles[i] = child[1];
    }
    const items = try test_helpers.gridItems(gpa, indexes[0..children.len], styles[0..children.len]);
    defer gpa.free(items);
    const placements = try test_helpers.resolveNamedLines(gpa, styles[0..children.len], &name_resolver, explicit_col_count, explicit_row_count);
    defer gpa.free(placements);
    const estimated_cols, const estimated_rows = computeGridSizeEstimate(explicit_col_count, explicit_row_count, placements);
    var cell_occupancy_matrix = try CellOccupancyMatrix.withTrackCounts(gpa, estimated_cols, estimated_rows);
    defer cell_occupancy_matrix.deinit(gpa);

    // Run placement algorithm
    try placeGridItems(gpa, &cell_occupancy_matrix, items, placements, flow);

    // Assert that each item has been placed in the right location (items are in the same order as children)
    try testing.expectEqual(children.len, items.len);
    for (children, items) |child, item| {
        try testing.expectEqual(NodeId.fromUsize(child[0]), item.node);
        const expected = test_helpers.intoOz(child[2]);
        try testing.expectEqual(expected[0], item.column.start);
        try testing.expectEqual(expected[1], item.column.end);
        try testing.expectEqual(expected[2], item.row.start);
        try testing.expectEqual(expected[3], item.row.end);
    }

    // Assert that the correct number of implicit rows have been generated
    try testing.expectEqual(expected_row_counts, cell_occupancy_matrix.trackCounts(.vertical));
    try testing.expectEqual(expected_col_counts, cell_occupancy_matrix.trackCounts(.horizontal));
}

test "only fixed placement" {
    // node, style (grid coords), expected_placement (oz coords)
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridLine(1), auto, gridLine(1), auto), .{ 0, 1, 0, 1 } },
        .{ 2, intoGridChild(gridLine(-4), auto, gridLine(-3), auto), .{ -1, 0, 0, 1 } },
        .{ 3, intoGridChild(gridLine(-3), auto, gridLine(-4), auto), .{ 0, 1, -1, 0 } },
        .{ 4, intoGridChild(gridLine(3), gridSpan(2), gridLine(5), auto), .{ 2, 4, 4, 5 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 1, .explicit = 2, .positive_implicit = 2 }, .{ .negative_implicit = 1, .explicit = 2, .positive_implicit = 3 }, .row);
}

test "placement spanning origin" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridLine(-1), gridLine(-1), gridLine(-1), gridLine(-1)), .{ 2, 3, 2, 3 } },
        .{ 2, intoGridChild(gridLine(-1), gridSpan(2), gridLine(-1), gridSpan(2)), .{ 2, 4, 2, 4 } },
        .{ 3, intoGridChild(gridLine(-4), gridLine(-4), gridLine(-4), gridLine(-4)), .{ -1, 0, -1, 0 } },
        .{ 4, intoGridChild(gridLine(-4), gridSpan(2), gridLine(-4), gridSpan(2)), .{ -1, 1, -1, 1 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 1, .explicit = 2, .positive_implicit = 2 }, .{ .negative_implicit = 1, .explicit = 2, .positive_implicit = 2 }, .row);
}

test "only auto placement row flow" {
    const auto_child = intoGridChild(auto, auto, auto, auto);
    const children = [_]TestChild{
        .{ 1, auto_child, .{ 0, 1, 0, 1 } },
        .{ 2, auto_child, .{ 1, 2, 0, 1 } },
        .{ 3, auto_child, .{ 0, 1, 1, 2 } },
        .{ 4, auto_child, .{ 1, 2, 1, 2 } },
        .{ 5, auto_child, .{ 0, 1, 2, 3 } },
        .{ 6, auto_child, .{ 1, 2, 2, 3 } },
        .{ 7, auto_child, .{ 0, 1, 3, 4 } },
        .{ 8, auto_child, .{ 1, 2, 3, 4 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 0 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 2 }, .row);
}

test "only auto placement column flow" {
    const auto_child = intoGridChild(auto, auto, auto, auto);
    const children = [_]TestChild{
        .{ 1, auto_child, .{ 0, 1, 0, 1 } },
        .{ 2, auto_child, .{ 0, 1, 1, 2 } },
        .{ 3, auto_child, .{ 1, 2, 0, 1 } },
        .{ 4, auto_child, .{ 1, 2, 1, 2 } },
        .{ 5, auto_child, .{ 2, 3, 0, 1 } },
        .{ 6, auto_child, .{ 2, 3, 1, 2 } },
        .{ 7, auto_child, .{ 3, 4, 0, 1 } },
        .{ 8, auto_child, .{ 3, 4, 1, 2 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 2 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 0 }, .column);
}

test "oversized item" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridSpan(5), auto, auto, auto), .{ 0, 5, 0, 1 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 3 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 0 }, .row);
}

test "fixed in secondary axis" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridSpan(2), auto, gridLine(1), auto), .{ 0, 2, 0, 1 } },
        .{ 2, intoGridChild(auto, auto, gridLine(2), auto), .{ 0, 1, 1, 2 } },
        .{ 3, intoGridChild(auto, auto, gridLine(1), auto), .{ 2, 3, 0, 1 } },
        .{ 4, intoGridChild(auto, auto, gridLine(4), auto), .{ 0, 1, 3, 4 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 1 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 2 }, .row);
}

test "definite in secondary axis with fully definite negative" {
    const children = [_]TestChild{
        .{ 2, intoGridChild(auto, auto, gridLine(2), auto), .{ 0, 1, 1, 2 } },
        .{ 1, intoGridChild(gridLine(-4), auto, gridLine(2), auto), .{ -1, 0, 1, 2 } },
        .{ 3, intoGridChild(auto, auto, gridLine(1), auto), .{ -1, 0, 0, 1 } },
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 1, .explicit = 2, .positive_implicit = 0 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 0 }, .row);
}

test "dense packing algorithm" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridLine(2), auto, gridLine(1), auto), .{ 1, 2, 0, 1 } }, // Definitely positioned in column 2
        .{ 2, intoGridChild(gridSpan(2), auto, auto, auto), .{ 2, 4, 0, 1 } }, // Spans 2 columns, so positioned after item 1
        .{ 3, intoGridChild(auto, auto, auto, auto), .{ 0, 1, 0, 1 } }, // Spans 1 column, so should be positioned before item 1
    };
    try placementTestRunner(4, 4, &children, .{ .negative_implicit = 0, .explicit = 4, .positive_implicit = 0 }, .{ .negative_implicit = 0, .explicit = 4, .positive_implicit = 0 }, .row_dense);
}

test "sparse packing algorithm" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(auto, gridSpan(3), auto, auto), .{ 0, 3, 0, 1 } }, // Width 3
        .{ 2, intoGridChild(auto, gridSpan(3), auto, auto), .{ 0, 3, 1, 2 } }, // Width 3 (wraps to next row)
        .{ 3, intoGridChild(auto, gridSpan(1), auto, auto), .{ 3, 4, 1, 2 } }, // Width 1 (uses second row as we're already on it)
    };
    try placementTestRunner(4, 4, &children, .{ .negative_implicit = 0, .explicit = 4, .positive_implicit = 0 }, .{ .negative_implicit = 0, .explicit = 4, .positive_implicit = 0 }, .row);
}

test "auto placement in negative tracks" {
    const children = [_]TestChild{
        .{ 1, intoGridChild(gridLine(-5), auto, gridLine(1), auto), .{ -2, -1, 0, 1 } }, // Row 1. Definitely positioned in column -2
        .{ 2, intoGridChild(auto, auto, gridLine(2), auto), .{ -2, -1, 1, 2 } }, // Row 2. Auto positioned in column -2
        .{ 3, intoGridChild(auto, auto, auto, auto), .{ -1, 0, 0, 1 } }, // Row 1. Auto positioned in column -1
    };
    try placementTestRunner(2, 2, &children, .{ .negative_implicit = 2, .explicit = 2, .positive_implicit = 0 }, .{ .negative_implicit = 0, .explicit = 2, .positive_implicit = 0 }, .row_dense);
}

test "overlarge placement is clamped" {
    const gpa = testing.allocator;
    const explicit_col_count = 9_000;
    const explicit_row_count = 0;
    const styles = [_]Style{intoGridChild(gridLine(-19_005), auto, auto, auto)};
    var name_resolver = try NamedLineResolver.new(gpa, &Style.default, 0, 0);
    defer name_resolver.deinit(gpa);
    name_resolver.setExplicitColumnCount(explicit_col_count);
    name_resolver.setExplicitRowCount(explicit_row_count);
    const items = try test_helpers.gridItems(gpa, &.{0}, &styles);
    defer gpa.free(items);
    const placements = try test_helpers.resolveNamedLines(gpa, &styles, &name_resolver, explicit_col_count, explicit_row_count);
    defer gpa.free(placements);
    const estimated_cols, const estimated_rows = computeGridSizeEstimate(explicit_col_count, explicit_row_count, placements);
    var cell_occupancy_matrix = try CellOccupancyMatrix.withTrackCounts(gpa, estimated_cols, estimated_rows);
    defer cell_occupancy_matrix.deinit(gpa);
    try placeGridItems(gpa, &cell_occupancy_matrix, items, placements, .row);
    try testing.expectEqual(Line(OriginZeroLine){ .start = OriginZeroLine.from(-10_000), .end = OriginZeroLine.from(-9_999) }, items[0].column);
}

test "auto placement cursor saturates at integer bounds" {
    try testing.expectEqual(OriginZeroLine.from(std.math.maxInt(i16)), advancePosition(OriginZeroLine.from(std.math.maxInt(i16))));
}

test "indefinite spans saturate at integer bounds" {
    try testing.expectEqual(
        Line(OriginZeroLine){ .start = OriginZeroLine.from(std.math.maxInt(i16)), .end = OriginZeroLine.from(std.math.maxInt(i16)) },
        resolveIndefiniteGridSpan(OriginZeroLine.from(std.math.maxInt(i16)), 1),
    );
}
