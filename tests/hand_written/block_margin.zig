const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn block(margin_top: f32, margin_bottom: f32, height: Dimension) Style {
    return .{
        .display = .block,
        .size = .{ .width = Dimension.auto, .height = height },
        .margin = .{
            .left = LengthPercentageAuto.zero,
            .right = LengthPercentageAuto.zero,
            .top = LengthPercentageAuto.fromLength(margin_top),
            .bottom = LengthPercentageAuto.fromLength(margin_bottom),
        },
    };
}

// Margin collapsing changes where boxes are placed, but `Layout::margin` is each box's own margin
test "layout_margin_excludes_collapsed_margins" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const inner = try taffy.newLeaf(block(13.0, 20.0, Dimension.fromLength(10.0)));
    const outer = try taffy.newWithChildren(block(8.0, 5.0, Dimension.auto), &.{inner});
    const sibling = try taffy.newLeaf(block(30.0, 0.0, Dimension.fromLength(10.0)));
    const root = try taffy.newWithChildren(
        .{
            .display = .flow_root,
            .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.auto },
        },
        &.{ outer, sibling },
    );

    try taffy.computeLayout(root, Size(laffy.AvailableSpace).max_content);

    // The inner box's margins collapse through the outer box's edges
    const outer_layout = taffy.layout(outer);
    try testing.expectEqual(@as(f32, 13.0), outer_layout.location.y);
    try testing.expectEqual(@as(f32, 10.0), outer_layout.size.height);
    try testing.expectEqual(@as(f32, 8.0), outer_layout.margin.top);
    try testing.expectEqual(@as(f32, 5.0), outer_layout.margin.bottom);

    const inner_layout = taffy.layout(inner);
    try testing.expectEqual(@as(f32, 0.0), inner_layout.location.y);
    try testing.expectEqual(@as(f32, 13.0), inner_layout.margin.top);
    try testing.expectEqual(@as(f32, 20.0), inner_layout.margin.bottom);

    // The sibling is placed after the largest of the adjoining margins (5, 20, 30)
    const sibling_layout = taffy.layout(sibling);
    try testing.expectEqual(@as(f32, 53.0), sibling_layout.location.y);
    try testing.expectEqual(@as(f32, 30.0), sibling_layout.margin.top);
}
