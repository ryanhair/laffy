//! Sizing of absolutely positioned replaced (`item_is_replaced: true`) boxes.
//!
//! An `auto` width/height of an absolutely positioned replaced element resolves to its
//! intrinsic size rather than being stretched between its insets
//! (<https://www.w3.org/TR/CSS22/visudet.html#abs-replaced-width>,
//! <https://www.w3.org/TR/CSS22/visudet.html#abs-replaced-height>).
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const Layout = laffy.Layout;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

// A 100x50 image (height = width * 0.5)
fn image() TestNodeContext {
    return TestNodeContext.aspectRatio(100.0, 0.5);
}

fn container() Style {
    return .{
        .display = .block,
        .position = .relative,
        .size = .{ .width = Dimension.fromLength(400.0), .height = Dimension.fromLength(300.0) },
    };
}

fn allInsets(value: f32) Rect(LengthPercentageAuto) {
    return .{
        .left = LengthPercentageAuto.fromLength(value),
        .right = LengthPercentageAuto.fromLength(value),
        .top = LengthPercentageAuto.fromLength(value),
        .bottom = LengthPercentageAuto.fromLength(value),
    };
}

fn layoutChild(child_style: Style) !Layout {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(child_style, image());
    const root = try taffy.newWithChildren(container(), &.{child});
    try taffy.computeLayoutWithMeasure(root, Size(laffy.AvailableSpace).max_content, measure.TestMeasurer{});
    return taffy.layout(child).*;
}

test "auto_size_uses_intrinsic_size_despite_insets" {
    const layout = try layoutChild(.{
        .position = .absolute,
        .item_is_replaced = true,
        .inset = allInsets(10.0),
    });
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 50.0 }, layout.size);
    try testing.expectEqual(Point(f32){ .x = 10.0, .y = 10.0 }, layout.location);
}

test "auto_height_uses_aspect_ratio_despite_insets" {
    const layout = try layoutChild(.{
        .position = .absolute,
        .item_is_replaced = true,
        .inset = allInsets(10.0),
        .size = .{ .width = Dimension.fromLength(200.0), .height = .auto },
    });
    try testing.expectEqual(Size(f32){ .width = 200.0, .height = 100.0 }, layout.size);
}

test "non_replaced_auto_size_is_stretched_between_insets" {
    const layout = try layoutChild(.{ .position = .absolute, .inset = allInsets(10.0) });
    try testing.expectEqual(Size(f32){ .width = 380.0, .height = 280.0 }, layout.size);
}
