//! Sizing of replaced (`item_is_replaced: true`) children of block containers.
//!
//! Block layout stretch-sizes in-flow children to the container width, but block-level
//! replaced elements are exempt: with `width: auto` they use their intrinsic size
//! (<https://www.w3.org/TR/CSS22/visudet.html#block-replaced-width>).
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);
const AvailableSpace = laffy.AvailableSpace;

// A 142x20 badge-like image (height = width * 20/142)
fn badge() TestNodeContext {
    return TestNodeContext.aspectRatio(142.0, 20.0 / 142.0);
}

fn blockContainer(width: f32) Style {
    return .{ .display = .block, .size = .{ .width = Dimension.fromLength(width), .height = Dimension.auto } };
}

fn layout(taffy: *TaffyTree, root: NodeId) !void {
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).max_content, measure.TestMeasurer{});
}

test "auto_width_uses_intrinsic_size" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(.{ .display = .block, .item_is_replaced = true }, badge());
    const root = try taffy.newWithChildren(blockContainer(600.0), &.{child});
    try layout(&taffy, root);

    const child_layout = taffy.layout(child);
    try testing.expectEqual(@as(f32, 142.0), child_layout.size.width);
    try testing.expectEqual(@as(f32, 20.0), child_layout.size.height);
}

test "non_replaced_child_is_stretch_sized" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(.{ .display = .block }, badge());
    const root = try taffy.newWithChildren(blockContainer(600.0), &.{child});
    try layout(&taffy, root);

    try testing.expectEqual(@as(f32, 600.0), taffy.layout(child).size.width);
}

test "explicit_width_is_used" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .item_is_replaced = true,
            .size = .{ .width = Dimension.fromLength(300.0), .height = Dimension.fromLength(50.0) },
        },
        badge(),
    );
    const root = try taffy.newWithChildren(blockContainer(600.0), &.{child});
    try layout(&taffy, root);

    const child_layout = taffy.layout(child);
    try testing.expectEqual(@as(f32, 300.0), child_layout.size.width);
    try testing.expectEqual(@as(f32, 50.0), child_layout.size.height);
}

test "max_width_clamps_intrinsic_size" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .item_is_replaced = true,
            .max_size = .{ .width = LengthPercentageAuto.fromPercent(1.0), .height = LengthPercentageAuto.auto },
        },
        badge(),
    );
    const root = try taffy.newWithChildren(blockContainer(100.0), &.{child});
    try layout(&taffy, root);

    const child_layout = taffy.layout(child);
    try testing.expectEqual(@as(f32, 100.0), child_layout.size.width);
}

test "auto_margins_center_replaced_child" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .item_is_replaced = true,
            .margin = .{
                .left = LengthPercentageAuto.auto,
                .right = LengthPercentageAuto.auto,
                .top = LengthPercentageAuto.zero,
                .bottom = LengthPercentageAuto.zero,
            },
        },
        badge(),
    );
    const root = try taffy.newWithChildren(blockContainer(600.0), &.{child});
    try layout(&taffy, root);

    const child_layout = taffy.layout(child);
    try testing.expectEqual(@as(f32, 142.0), child_layout.size.width);
    try testing.expectEqual((600.0 - 142.0) / 2.0, child_layout.location.x);
}

// An 8x8 image whose percentage width (or max-width) makes its min-content contribution zero
// <https://drafts.csswg.org/css-sizing-3/#replaced-percentage-min-contribution>
fn square() TestNodeContext {
    return TestNodeContext.aspectRatio(8.0, 1.0);
}

/// A `float: left` shrink-to-fit wrapper around an image, inside a block container of `container_width`.
/// Returns the widths of the wrapper and of the image.
fn shrinkToFitWrapperAroundImage(container_width: f32, image_style: Style) !struct { f32, f32 } {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const image = try taffy.newLeafWithContext(image_style, square());
    const wrapper = try taffy.newWithChildren(.{ .display = .block, .float = .left }, &.{image});
    const root = try taffy.newWithChildren(blockContainer(container_width), &.{wrapper});
    try layout(&taffy, root);
    return .{ taffy.layout(wrapper).size.width, taffy.layout(image).size.width };
}

test "percentage_width_has_zero_min_content_contribution" {
    const wrapper, const image = try shrinkToFitWrapperAroundImage(4.0, .{
        .display = .block,
        .item_is_replaced = true,
        .size = .{ .width = Dimension.fromPercent(1.0), .height = Dimension.auto },
    });
    try testing.expectEqual(@as(f32, 4.0), wrapper);
    try testing.expectEqual(@as(f32, 4.0), image);
}

test "percentage_max_width_has_zero_min_content_contribution" {
    const wrapper, const image = try shrinkToFitWrapperAroundImage(4.0, .{
        .display = .block,
        .item_is_replaced = true,
        .max_size = .{ .width = LengthPercentageAuto.fromPercent(1.0), .height = LengthPercentageAuto.auto },
    });
    try testing.expectEqual(@as(f32, 4.0), wrapper);
    try testing.expectEqual(@as(f32, 4.0), image);
}

test "percentage_width_max_content_contribution_is_intrinsic_size" {
    const wrapper, const image = try shrinkToFitWrapperAroundImage(100.0, .{
        .display = .block,
        .item_is_replaced = true,
        .size = .{ .width = Dimension.fromPercent(1.0), .height = Dimension.auto },
    });
    try testing.expectEqual(@as(f32, 8.0), wrapper);
    try testing.expectEqual(@as(f32, 8.0), image);
}

test "percentage_width_min_content_size_of_container_is_zero" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const image = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .item_is_replaced = true,
            .size = .{ .width = Dimension.fromPercent(1.0), .height = Dimension.auto },
            .padding = .{
                .left = LengthPercentage.fromLength(1.0),
                .right = LengthPercentage.fromLength(1.0),
                .top = LengthPercentage.zero,
                .bottom = LengthPercentage.zero,
            },
        },
        square(),
    );
    const root = try taffy.newWithChildren(.{ .display = .block }, &.{image});
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).min_content, measure.TestMeasurer{});
    try testing.expectEqual(@as(f32, 2.0), taffy.layout(root).size.width);
}
