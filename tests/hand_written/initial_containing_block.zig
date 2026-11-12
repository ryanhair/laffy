//! Tests for the initial containing block: boxes with no nearer containing block are positioned
//! against a viewport-sized rectangle at the canvas origin, not against the root element's box.
const std = @import("std");
const laffy = @import("laffy");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const Position = laffy.Position;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const TaffyTree = laffy.TaffyTree(void);

const VIEWPORT: Size(AvailableSpace) = .{ .width = .{ .definite = 800.0 }, .height = .{ .definite = 600.0 } };

fn point(x: f32, y: f32) Point(f32) {
    return .{ .x = x, .y = y };
}

fn rootStyle() Style {
    return .{
        .display = .block,
        .margin = .{
            .left = LengthPercentageAuto.fromLength(10.0),
            .right = LengthPercentageAuto.fromLength(10.0),
            .top = LengthPercentageAuto.fromLength(20.0),
            .bottom = LengthPercentageAuto.fromLength(20.0),
        },
        .border = Rect(LengthPercentage).fromLength(5.0),
    };
}

fn oofStyle(position: Position, inset: Rect(LengthPercentageAuto), size: Size(Dimension)) Style {
    return .{ .position = position, .inset = inset, .size = size };
}

test "root_is_placed_at_its_margin" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.newLeaf(rootStyle());
    try tree.computeLayout(root, VIEWPORT);

    const layout = tree.layout(root);
    try testing.expectEqual(point(10.0, 20.0), layout.location);
    try testing.expectEqual(@as(f32, 780.0), layout.size.width);
}

test "inset_zero_fills_viewport" {
    for ([_]Position{ .absolute, .fixed }) |position| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const oof = try tree.newLeaf(oofStyle(position, Rect(LengthPercentageAuto).fromLength(0.0), Size(Dimension).auto));
        const root = try tree.newWithChildren(rootStyle(), &.{oof});
        try tree.computeLayout(root, VIEWPORT);

        // Location is relative to the root's border box, which sits at (10, 20) in the viewport
        const layout = tree.layout(oof);
        try testing.expectEqual(point(-10.0, -20.0), layout.location);
        try testing.expectEqual(Size(f32){ .width = 800.0, .height = 600.0 }, layout.size);
    }
}

test "bottom_right_insets_resolve_against_viewport" {
    for ([_]Position{ .absolute, .fixed }) |position| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const oof = try tree.newLeaf(oofStyle(
            position,
            .{
                .left = .auto,
                .top = .auto,
                .right = LengthPercentageAuto.fromLength(0.0),
                .bottom = LengthPercentageAuto.fromLength(0.0),
            },
            .{ .width = Dimension.fromLength(50.0), .height = Dimension.fromLength(50.0) },
        ));
        // The root has no in-flow content, so its border box is much shorter than the viewport
        const root = try tree.newWithChildren(rootStyle(), &.{oof});
        try tree.computeLayout(root, VIEWPORT);

        const layout = tree.layout(oof);
        try testing.expectEqual(point(800.0 - 50.0 - 10.0, 600.0 - 50.0 - 20.0), layout.location);
    }
}

test "static_position_is_unaffected" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const oof = try tree.newLeaf(oofStyle(
        .absolute,
        Rect(LengthPercentageAuto).auto,
        .{ .width = Dimension.fromLength(50.0), .height = Dimension.fromLength(50.0) },
    ));
    const root = try tree.newWithChildren(rootStyle(), &.{oof});
    try tree.computeLayout(root, VIEWPORT);

    try testing.expectEqual(point(5.0, 5.0), tree.layout(oof).location);
}

test "fixed_root_is_positioned_by_its_insets" {
    // `position: fixed` roots cannot be covered by the generated tests (Chrome positions them
    // against the browser window rather than the `.viewport` wrapper), so check that they are
    // positioned like absolutely positioned roots against the initial containing block.
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.newLeaf(.{
        .display = .block,
        .position = .fixed,
        .inset = .{
            .left = .auto,
            .top = LengthPercentageAuto.fromPercent(0.1),
            .right = LengthPercentageAuto.fromLength(10.0),
            .bottom = .auto,
        },
        .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.fromLength(50.0) },
    });
    try tree.computeLayout(root, VIEWPORT);

    const layout = tree.layout(root);
    try testing.expectEqual(point(800.0 - 100.0 - 10.0, 60.0), layout.location);
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 50.0 }, layout.size);
}
