const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Line = laffy.Line;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const AvailableSpace = laffy.AvailableSpace;
const FlexDirection = laffy.FlexDirection;
const GridPlacement = laffy.GridPlacement;
const GridTemplateComponent = laffy.GridTemplateComponent;
const MinTrackSizingFunction = laffy.MinTrackSizingFunction;
const MaxTrackSizingFunction = laffy.MaxTrackSizingFunction;
const JustifySelf = laffy.JustifySelf;
const minmax = laffy.style_helpers.minmax;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

fn nodeContext() TestNodeContext {
    return TestNodeContext.fixed(50.0, 50.0);
}

fn ahem() TestNodeContext {
    return TestNodeContext.ahemText("HH\u{200B}HH\u{200B}HH\u{200B}HH", .horizontal);
}

fn maxContent() Size(AvailableSpace) {
    return Size(AvailableSpace).max_content;
}

fn compute(taffy: *TaffyTree, node: NodeId) !void {
    try taffy.computeLayoutWithMeasure(node, maxContent(), measure.TestMeasurer{});
}

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

fn gridCol(index: i16) Line(GridPlacement) {
    return Line(GridPlacement).fromLineIndex(index);
}

test "measure_count_flexbox" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const leaf = try taffy.newLeafWithContext(Style{}, nodeContext());

    var node = try taffy.newWithChildren(Style{}, &.{leaf});
    for (0..100) |_| {
        node = try taffy.newWithChildren(Style{}, &.{node});
    }

    try compute(&taffy, node);

    try testing.expectEqual(@as(usize, 6), taffy.getNodeContextMut(leaf).?.count);
}

test "measure_count_grid" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const style: Style = .{ .display = .grid };
    const leaf = try taffy.newLeafWithContext(style, nodeContext());

    var node = try taffy.newWithChildren(Style{}, &.{leaf});
    for (0..100) |_| {
        node = try taffy.newWithChildren(Style{}, &.{node});
    }

    try compute(&taffy, node);
    try testing.expectEqual(@as(usize, 6), taffy.getNodeContextMut(leaf).?.count);
}

// A grid container that is only asked for its width (e.g. because it is an item of another
// grid whose columns are being sized) must not size its rows, as that measures the height of
// all of its items and, recursively, of everything below them.
test "measure_count_nested_grid" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const style: Style = .{ .display = .grid };
    // The leaf's min-content width (20), max-content width (80) and final width (50) all differ, so
    // measuring its height at each of the first two widths can never be served from the cache.
    const leaf = try taffy.newLeafWithContext(Style{}, ahem());
    const inner = try taffy.newWithChildren(style, &.{leaf});
    const middle = try taffy.newWithChildren(style, &.{inner});
    var outer_style = style;
    outer_style.size = .{ .width = dim(50.0), .height = Dimension.auto };
    const outer = try taffy.newWithChildren(outer_style, &.{middle});

    try compute(&taffy, outer);
    try testing.expectEqual(Size(f32){ .width = 50.0, .height = 20.0 }, taffy.layout(leaf).size);
    try testing.expectEqual(@as(usize, 6), taffy.getNodeContextMut(leaf).?.count);
}

// A grid item whose size in the axis being measured is already known (here: a definite width) does not
// need to be measured to determine its contribution to the size of the tracks in that axis.
// (Without that short-circuit the leaf is measured 5 times)
test "measure_count_grid_item_with_known_width" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const leaf = try taffy.newLeafWithContext(
        .{ .size = .{ .width = dim(40.0), .height = Dimension.auto } },
        ahem(),
    );
    const grid = try taffy.newWithChildren(.{ .display = .grid }, &.{leaf});

    try compute(&taffy, grid);
    try testing.expectEqual(Size(f32){ .width = 40.0, .height = 20.0 }, taffy.layout(grid).size);
    try testing.expectEqual(Size(f32){ .width = 40.0, .height = 20.0 }, taffy.layout(leaf).size);
    try testing.expectEqual(@as(usize, 3), taffy.getNodeContextMut(leaf).?.count);
}

// A grid item in a track that is not intrinsically sized does not contribute to the size of that track, so
// it does not need to be measured when sizing the tracks (even if another track in the axis is intrinsic).
// (Without that short-circuit the leaf is measured 5 times)
test "measure_count_grid_item_in_fixed_track" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const leaf = try taffy.newLeafWithContext(
        .{ .justify_self = JustifySelf.start, .grid_column = gridCol(1) },
        ahem(),
    );
    const sibling = try taffy.newLeaf(.{
        .size = .{ .width = dim(50.0), .height = dim(50.0) },
        .grid_column = gridCol(2),
    });
    const columns = [_]GridTemplateComponent{ GridTemplateComponent.fromLength(100.0), GridTemplateComponent.auto };
    const grid = try taffy.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &columns,
        },
        &.{ leaf, sibling },
    );

    try compute(&taffy, grid);
    try testing.expectEqual(Size(f32){ .width = 150.0, .height = 50.0 }, taffy.layout(grid).size);
    try testing.expectEqual(Size(f32){ .width = 80.0, .height = 50.0 }, taffy.layout(leaf).size);
    try testing.expectEqual(@as(usize, 3), taffy.getNodeContextMut(leaf).?.count);
}

// A flex container that is only asked for its main size (e.g. because it is an item of a grid
// whose tracks are being sized) must not measure the cross size of its items.
// (Without that short-circuit the leaf is measured 13 times in the row case and 12 times in the column case)
test "measure_count_flex_in_grid" {
    const cases = [_]struct { FlexDirection, usize }{ .{ .row, 9 }, .{ .column, 10 } };
    for (cases) |case| {
        const flex_direction, const expected_count = case;
        var taffy = try TaffyTree.init(testing.allocator);
        defer taffy.deinit();

        const leaf = try taffy.newLeafWithContext(Style{}, ahem());
        const flex = try taffy.newWithChildren(
            .{ .display = .flex, .flex_direction = flex_direction },
            &.{leaf},
        );
        const grid = try taffy.newWithChildren(
            .{
                .display = .grid,
                .size = .{ .width = dim(50.0), .height = Dimension.auto },
            },
            &.{flex},
        );

        try compute(&taffy, grid);
        const count = taffy.getNodeContextMut(leaf).?.count;
        try testing.expectEqual(Size(f32){ .width = 50.0, .height = 20.0 }, taffy.layout(leaf).size);
        try testing.expectEqual(expected_count, count);
    }
}

// A node's size measured for one axis must not be returned from the cache when the other
// axis is queried, as the size in the non-requested axis is not guaranteed to be valid.
test "grid_block_item_height_not_polluted_by_width_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const ItemBuilder = struct {
        fn itemStyle(row: i16) Style {
            return .{
                .display = .block,
                .grid_row = .{ .start = GridPlacement.fromLineIndex(row), .end = GridPlacement.fromLineIndex(row + 1) },
                .grid_column = .{ .start = GridPlacement.fromLineIndex(1), .end = GridPlacement.fromLineIndex(2) },
            };
        }

        // Each grid item is a block container wrapping a measured leaf. The block layout
        // algorithm short-circuits width-only measures without computing a height, so a
        // subsequent height query must not reuse that cached result.
        fn makeItem(tree: *TaffyTree, row: i16) !NodeId {
            const leaf = try tree.newLeafWithContext(Style{}, TestNodeContext.fixed(100.0, 19.0));
            return tree.newWithChildren(itemStyle(row), &.{leaf});
        }
    };
    const a = try ItemBuilder.makeItem(&taffy, 1);
    const b = try ItemBuilder.makeItem(&taffy, 2);
    const c = try ItemBuilder.makeItem(&taffy, 3);

    // The `auto` column is required to trigger intrinsic (width) sizing of the
    // items before the row-sizing (height) pass.
    const columns = [_]GridTemplateComponent{ GridTemplateComponent.fromPercent(0.6), GridTemplateComponent.auto };
    const container = try taffy.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &columns,
            .size = .{ .width = dim(1000.0), .height = Dimension.auto },
        },
        &.{ a, b, c },
    );

    try taffy.computeLayoutWithMeasure(
        container,
        .{ .width = .{ .definite = 1000.0 }, .height = .{ .definite = 1000.0 } },
        measure.TestMeasurer{},
    );

    for ([_]NodeId{ a, b, c }, 0..) |node, index| {
        const layout = taffy.layout(node);
        try testing.expectEqual(@as(f32, 19.0), layout.size.height);
        try testing.expectEqual(19.0 * @as(f32, @floatFromInt(index)), layout.location.y);
    }
}

// An item whose spanned tracks cannot receive its min-/max-content contribution in any
// intrinsic track sizing step (definite min, flexible max) must not be measured for it.
test "grid_item_spanning_only_unaffected_tracks_is_not_measured" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const text = TestNodeContext.ahemText("HH HH HH HH", .horizontal);
    const leaf_style: Style = .{ .grid_column = .{ .start = GridPlacement.fromLineIndex(2), .end = GridPlacement.fromLineIndex(3) } };
    const leaf = try taffy.newLeafWithContext(leaf_style, text);
    const columns = [_]GridTemplateComponent{
        GridTemplateComponent.fromLength(100.0),
        minmax(GridTemplateComponent, MinTrackSizingFunction.zero, MaxTrackSizingFunction.fromFr(1.0)),
    };
    const rows = [_]GridTemplateComponent{GridTemplateComponent.fromLength(50.0)};
    const grid = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = .{ .width = dim(400.0), .height = dim(50.0) },
            .grid_template_columns = &columns,
            .grid_template_rows = &rows,
        },
        &.{leaf},
    );

    try compute(&taffy, grid);

    // Only the final layout pass measures the leaf; track sizing does not.
    try testing.expectEqual(@as(f32, 300.0), taffy.layout(leaf).size.width);
    try testing.expectEqual(@as(usize, 1), taffy.getNodeContextMut(leaf).?.count);
}
