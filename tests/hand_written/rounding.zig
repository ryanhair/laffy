const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Size = laffy.Size;
const Dimension = laffy.Dimension;
const JustifyContent = laffy.JustifyContent;
const AvailableSpace = laffy.AvailableSpace;
const length = laffy.style_helpers.length;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

test "rounding_doesnt_leave_gaps" {
    // First create an instance of TaffyTree
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const w_square: Size(Dimension) = .{ .width = length(Dimension, 100.3), .height = length(Dimension, 100.3) };
    const child_a = try taffy.newLeaf(.{ .size = w_square });
    const child_b = try taffy.newLeaf(.{ .size = w_square });

    const root_node = try taffy.newWithChildren(
        .{
            .size = .{ .width = length(Dimension, 963.3333), .height = length(Dimension, 1000.0) },
            .justify_content = JustifyContent.center,
        },
        &.{ child_a, child_b },
    );

    try taffy.computeLayout(root_node, Size(AvailableSpace).max_content);

    const layout_a = taffy.layout(child_a);
    const layout_b = taffy.layout(child_b);
    try testing.expectEqual(layout_b.location.x, layout_a.location.x + layout_a.size.width);
}
