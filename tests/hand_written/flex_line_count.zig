const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AlignItems = laffy.AlignItems;
const AlignContent = laffy.AlignContent;
const FlexWrap = laffy.FlexWrap;
const AvailableSpace = laffy.AvailableSpace;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

const TEXT = "HHHHHHHHHH\u{200B}HHHHHHHHHH\u{200B}HHHHHHHHHH";

fn containerStyle(flex_wrap: FlexWrap) Style {
    return .{
        .display = .flex,
        .flex_direction = .column,
        .flex_wrap = flex_wrap,
        .flex_line_count = 2,
        .size = .{ .width = Dimension.fromLength(210.0), .height = Dimension.fromLength(100.0) },
        .gap = .{ .width = LengthPercentage.fromLength(10.0), .height = LengthPercentage.zero },
        .align_items = AlignItems.start,
        .align_content = AlignContent.start,
    };
}

fn measureTextChild(flex_wrap: FlexWrap) !Size(f32) {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const text = TestNodeContext.ahemText(TEXT, .horizontal);
    const child = try taffy.newLeafWithContext(.{}, text);
    const container = try taffy.newWithChildren(containerStyle(flex_wrap), &.{child});
    try taffy.computeLayoutWithMeasure(container, Size(AvailableSpace).max_content, measure.TestMeasurer{});
    return taffy.layout(child).size;
}

// A multi-line container with `flex-line-count: 2` measures content against the cross-axis
// available space divided between the requested number of lines (after subtracting the
// cross-axis gaps): (210 - 10) / 2 = 100.
test "wrap_line_count_divides_cross_available_space" {
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 30.0 }, try measureTextChild(.wrap));
}

test "wrap_reverse_line_count_divides_cross_available_space" {
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 30.0 }, try measureTextChild(.wrap_reverse));
}

// `flex-line-count` has no effect on `nowrap` containers.
test "nowrap_line_count_has_no_effect" {
    try testing.expectEqual(Size(f32){ .width = 210.0, .height = 20.0 }, try measureTextChild(.no_wrap));
}

fn measureFitContentChild(flex_wrap: FlexWrap) !Size(f32) {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const text = TestNodeContext.ahemText(TEXT, .horizontal);
    const child_style: Style = .{ .size = .{ .width = .fit_content, .height = .auto } };
    const child = try taffy.newLeafWithContext(child_style, text);
    const container = try taffy.newWithChildren(containerStyle(flex_wrap), &.{child});
    try taffy.computeLayoutWithMeasure(container, Size(AvailableSpace).max_content, measure.TestMeasurer{});
    return taffy.layout(child).size;
}

// A bare `fit-content` cross size is also measured against the divided cross-axis
// available space, not the full container cross size.
test "wrap_line_count_divides_fit_content_cross_size" {
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 30.0 }, try measureFitContentChild(.wrap));
}

test "nowrap_line_count_does_not_divide_fit_content_cross_size" {
    try testing.expectEqual(Size(f32){ .width = 210.0, .height = 20.0 }, try measureFitContentChild(.no_wrap));
}
