const std = @import("std");
const laffy = @import("laffy");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const Display = laffy.Display;
const Position = laffy.Position;
const AvailableSpace = laffy.AvailableSpace;
const auto = laffy.style_helpers.auto;
const TaffyTree = laffy.TaffyTree(void);

fn lpa(v: f32) LengthPercentageAuto {
    return LengthPercentageAuto.fromLength(v);
}

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

const LeafWithInset = struct {
    taffy: TaffyTree,
    child: NodeId,
};

fn leafWithInset(position: Position, display: Display) !LeafWithInset {
    var taffy = try TaffyTree.init(testing.allocator);
    errdefer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .position = position,
        .size = .{ .width = dim(10.0), .height = dim(10.0) },
        .inset = .{ .left = lpa(5.0), .right = auto(LengthPercentageAuto), .top = lpa(7.0), .bottom = auto(LengthPercentageAuto) },
    });
    const root = try taffy.newWithChildren(
        .{ .display = display, .size = .{ .width = dim(100.0), .height = dim(100.0) } },
        &.{child},
    );
    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    return .{ .taffy = taffy, .child = child };
}

test "static_and_sticky_ignore_inset" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Position{ .static, .sticky }) |position| {
            errdefer std.debug.print("{t} in {t}\n", .{ position, display });
            var result = try leafWithInset(position, display);
            defer result.taffy.deinit();
            const layout = result.taffy.layout(result.child);
            try testing.expectEqual(Point(f32){ .x = 0.0, .y = 0.0 }, layout.location);
        }
        errdefer std.debug.print("Relative in {t}\n", .{display});
        var result = try leafWithInset(.relative, display);
        defer result.taffy.deinit();
        try testing.expectEqual(Point(f32){ .x = 5.0, .y = 7.0 }, result.taffy.layout(result.child).location);
    }
}

test "sticky_is_positioned_but_in_flow" {
    try testing.expect(Position.sticky.isPositioned());
    try testing.expect(!Position.sticky.isOutOfFlow());
    try testing.expect(!Position.static.isPositioned());
}
