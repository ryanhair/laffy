const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AvailableSpace = laffy.AvailableSpace;

test "root_with_percentage_size" {
    var taffy = try laffy.TaffyTree(measure.TestNodeContext).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{
        .size = .{
            .width = Dimension.fromPercent(1.0),
            .height = Dimension.fromPercent(1.0),
        },
    });

    try taffy.computeLayout(node, .{
        .width = .{ .definite = 100.0 },
        .height = .{ .definite = 200.0 },
    });
    const layout = taffy.layout(node);

    try testing.expectEqual(@as(f32, 100.0), layout.size.width);
    try testing.expectEqual(@as(f32, 200.0), layout.size.height);
}

test "root_with_no_size" {
    var taffy = try laffy.TaffyTree(measure.TestNodeContext).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(Style{});

    try taffy.computeLayout(node, .{
        .width = .{ .definite = 100.0 },
        .height = .{ .definite = 100.0 },
    });
    const layout = taffy.layout(node);

    try testing.expectEqual(@as(f32, 0.0), layout.size.width);
    try testing.expectEqual(@as(f32, 0.0), layout.size.height);
}

test "root_with_larger_size" {
    var taffy = try laffy.TaffyTree(measure.TestNodeContext).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{
        .size = .{
            .width = Dimension.fromLength(200.0),
            .height = Dimension.fromLength(200.0),
        },
    });

    try taffy.computeLayout(node, .{
        .width = .{ .definite = 100.0 },
        .height = .{ .definite = 100.0 },
    });
    const layout = taffy.layout(node);

    try testing.expectEqual(@as(f32, 200.0), layout.size.width);
    try testing.expectEqual(@as(f32, 200.0), layout.size.height);
}

test "root_padding_and_border_larger_than_definite_size" {
    var tree = try laffy.TaffyTree(void).withCapacity(testing.allocator, 16);
    defer tree.deinit();

    const child = try tree.newLeaf(Style{});

    const root = try tree.newWithChildren(
        .{
            .size = .{ .width = Dimension.fromLength(10.0), .height = Dimension.fromLength(10.0) },
            .padding = Rect(LengthPercentage).length(10.0),
            .border = Rect(LengthPercentage).length(10.0),
        },
        &.{child},
    );

    try tree.computeLayout(root, Size(AvailableSpace).max_content);

    const layout = tree.layout(root);

    try testing.expectEqual(@as(f32, 40.0), layout.size.width);
    try testing.expectEqual(@as(f32, 40.0), layout.size.height);
}
