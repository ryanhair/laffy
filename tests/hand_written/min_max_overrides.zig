const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Size = laffy.Size;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

const available: Size(laffy.AvailableSpace) = .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } };

test "min_overrides_max" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeaf(.{
        .size = .{ .width = Dimension.fromLength(50.0), .height = Dimension.fromLength(50.0) },
        .min_size = .{
            .width = LengthPercentageAuto.fromLength(100.0),
            .height = LengthPercentageAuto.fromLength(100.0),
        },
        .max_size = .{
            .width = LengthPercentageAuto.fromLength(10.0),
            .height = LengthPercentageAuto.fromLength(10.0),
        },
    });

    try taffy.computeLayout(child, available);

    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 100.0 }, taffy.layout(child).size);
}

test "max_overrides_size" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeaf(.{
        .size = .{ .width = Dimension.fromLength(50.0), .height = Dimension.fromLength(50.0) },
        .max_size = .{
            .width = LengthPercentageAuto.fromLength(10.0),
            .height = LengthPercentageAuto.fromLength(10.0),
        },
    });

    try taffy.computeLayout(child, available);

    try testing.expectEqual(Size(f32){ .width = 10.0, .height = 10.0 }, taffy.layout(child).size);
}

test "min_overrides_size" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeaf(.{
        .size = .{ .width = Dimension.fromLength(50.0), .height = Dimension.fromLength(50.0) },
        .min_size = .{
            .width = LengthPercentageAuto.fromLength(100.0),
            .height = LengthPercentageAuto.fromLength(100.0),
        },
    });

    try taffy.computeLayout(child, available);

    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 100.0 }, taffy.layout(child).size);
}
