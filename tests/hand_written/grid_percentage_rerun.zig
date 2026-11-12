//! Percentage track sizing functions resolve against the grid container's size. When that size is
//! indefinite they are treated as auto while computing the container's size and then resolved against
//! that size. This must happen regardless of whether the available space is definite (e.g. a
//! shrink-to-fit grid container).
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AvailableSpace = laffy.AvailableSpace;
const GridTemplateComponent = laffy.GridTemplateComponent;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);
const VoidTree = laffy.TaffyTree(void);

/// Returns (container width, item width)
fn layoutFitContentPercentColumn(available_width: AvailableSpace) ![2]f32 {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const item = try tree.newLeafWithContext(
        Style{},
        TestNodeContext.ahemText("HH\u{200b}HH\u{200b}HH", .horizontal),
    );
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &.{GridTemplateComponent.fitContent(LengthPercentage.fromPercent(0.5))},
            .grid_template_rows = &.{GridTemplateComponent.fromLength(40.0)},
        },
        &.{item},
    );
    try tree.computeLayoutWithMeasure(
        root,
        .{ .width = available_width, .height = .max_content },
        measure.TestMeasurer{},
    );
    return .{ tree.layout(root).size.width, tree.layout(item).size.width };
}

test "fit_content_percentage_indefinite_container_max_content_available_space" {
    try testing.expectEqual([2]f32{ 60.0, 30.0 }, try layoutFitContentPercentColumn(.max_content));
}

test "fit_content_percentage_indefinite_container_definite_available_space" {
    try testing.expectEqual([2]f32{ 60.0, 30.0 }, try layoutFitContentPercentColumn(.{ .definite = 200.0 }));
}

/// Returns (container height, row 1 height, row 2 height, row 3 height) for a grid with
/// `grid-template-rows: auto 20% auto` whose items are 20px, 60px and 20px tall respectively.
/// Mirrors WPT css/css-grid/layout-algorithm/grid-percent-rows-filled-shrinkwrap-001.html
fn layoutPercentRowShrinkwrap(available_height: AvailableSpace) ![4]f32 {
    var tree = VoidTree.init(testing.allocator) catch |e| return e;
    defer tree.deinit();
    const a = try itemWithHeight(&tree, 20.0);
    const b = try itemWithHeight(&tree, 60.0);
    const c = try itemWithHeight(&tree, 20.0);
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &.{GridTemplateComponent.auto},
            .grid_template_rows = &.{ GridTemplateComponent.auto, GridTemplateComponent.fromPercent(0.2), GridTemplateComponent.auto },
        },
        &.{ a, b, c },
    );
    try tree.computeLayout(root, .{ .width = .{ .definite = 200.0 }, .height = available_height });
    const total = tree.layout(root).size.height;
    const yb = tree.layout(b).location.y;
    const yc = tree.layout(c).location.y;
    return .{ total, yb, yc - yb, total - yc };
}

fn itemWithHeight(tree: *VoidTree, height: f32) !NodeId {
    return tree.newLeaf(.{ .size = .{ .width = Dimension.fromLength(20.0), .height = Dimension.fromLength(height) } });
}

// Percentage rows must be re-resolved against the container's (first pass) height even when column sizing
// is not re-run. The auto rows then stretch to fill the remaining space.
test "percentage_rows_indefinite_container_max_content_available_space" {
    try testing.expectEqual([4]f32{ 100.0, 40.0, 20.0, 40.0 }, try layoutPercentRowShrinkwrap(.max_content));
}

test "percentage_rows_indefinite_container_definite_available_space" {
    try testing.expectEqual([4]f32{ 100.0, 40.0, 20.0, 40.0 }, try layoutPercentRowShrinkwrap(.{ .definite = 500.0 }));
}
