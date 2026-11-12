const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Size = laffy.Size;
const Rect = laffy.Rect;
const AvailableSpace = laffy.AvailableSpace;
const LengthPercentage = laffy.LengthPercentage;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn arrToRect(comptime T: type, items: [4]T) Rect(T) {
    return .{ .left = items[0], .right = items[1], .top = items[2], .bottom = items[3] };
}

// Upstream marks all four tests in this file `#[ignore]`; they are ported as-is.

test "border_on_a_single_axis_doesnt_increase_size" {
    for (0..4) |i| {
        var taffy = try TaffyTree.init(testing.allocator);
        defer taffy.deinit();
        const node = try taffy.newLeaf(.{
            .border = blk: {
                var lengths: [4]LengthPercentage = @splat(LengthPercentage.zero);
                lengths[i] = LengthPercentage.fromLength(10.0);
                break :blk arrToRect(LengthPercentage, lengths);
            },
        });

        try taffy.computeLayout(
            node,
            .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } },
        );

        const layout = taffy.layout(node);
        try testing.expectEqual(@as(f32, 0.0), layout.size.width * layout.size.height);
    }
}

test "padding_on_a_single_axis_doesnt_increase_size" {
    for (0..4) |i| {
        var taffy = try TaffyTree.init(testing.allocator);
        defer taffy.deinit();
        const node = try taffy.newLeaf(.{
            .padding = blk: {
                var lengths: [4]LengthPercentage = @splat(LengthPercentage.zero);
                lengths[i] = LengthPercentage.fromLength(10.0);
                break :blk arrToRect(LengthPercentage, lengths);
            },
        });

        try taffy.computeLayout(
            node,
            .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } },
        );

        const layout = taffy.layout(node);
        try testing.expectEqual(@as(f32, 0.0), layout.size.width * layout.size.height);
    }
}

test "border_and_padding_on_a_single_axis_doesnt_increase_size" {
    for (0..4) |i| {
        var taffy = try TaffyTree.init(testing.allocator);
        defer taffy.deinit();
        const rect = blk: {
            var lengths: [4]LengthPercentage = @splat(LengthPercentage.zero);
            lengths[i] = LengthPercentage.fromLength(10.0);
            break :blk arrToRect(LengthPercentage, lengths);
        };
        const node = try taffy.newLeaf(.{ .border = rect, .padding = rect });

        try taffy.computeLayout(
            node,
            .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } },
        );
        const layout = taffy.layout(node);
        try testing.expectEqual(@as(f32, 0.0), layout.size.width * layout.size.height);
    }
}

test "vertical_border_and_padding_percentage_values_use_available_space_correctly" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    var padding = Rect(LengthPercentage).zero;
    padding.left = LengthPercentage.fromPercent(1.0);
    padding.top = LengthPercentage.fromPercent(1.0);
    const node = try taffy.newLeaf(.{ .padding = padding });

    try taffy.computeLayout(node, .{ .width = .{ .definite = 200.0 }, .height = .{ .definite = 100.0 } });

    const layout = taffy.layout(node);
    try testing.expectEqual(@as(f32, 200.0), layout.size.width);
    try testing.expectEqual(@as(f32, 200.0), layout.size.height);
}
