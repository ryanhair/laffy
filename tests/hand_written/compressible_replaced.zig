//! Sizing of compressible replaced boxes that are not replaced elements
//! (`item_is_compressible_replaced: true`, e.g. form controls such as `<input>`).
//!
//! Like replaced elements, block-level form controls with `width: auto` take their intrinsic
//! width rather than being stretched to the container (css-sizing-3 "compressible replaced
//! elements"). Unlike replaced elements, an absolutely positioned form control with both insets
//! set *is* stretched between them (CSS2 §10.3.7 applies, not §10.3.8).
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
const AlignItems = laffy.AlignItems;
const AvailableSpace = laffy.AvailableSpace;
const auto = laffy.style_helpers.auto;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

/// A 150x20 text input (height = width * 20/150)
fn input() TestNodeContext {
    return TestNodeContext.aspectRatio(150.0, 20.0 / 150.0);
}

fn layoutChild(container: Style, child_style: Style) !Layout {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(child_style, input());
    const root = try taffy.newWithChildren(container, &.{child});
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).max_content, measure.TestMeasurer{});
    return taffy.layout(child).*;
}

fn blockContainer() Style {
    return .{ .display = .block, .size = .{ .width = dim(400.0), .height = auto(Dimension) } };
}

fn positionedContainer() Style {
    return .{
        .display = .block,
        .position = .relative,
        .size = .{ .width = dim(400.0), .height = dim(300.0) },
    };
}

fn allInsets(value: f32) Rect(LengthPercentageAuto) {
    const v = LengthPercentageAuto.fromLength(value);
    return .{ .left = v, .right = v, .top = v, .bottom = v };
}

test "block_level_auto_width_uses_intrinsic_size" {
    const layout = try layoutChild(
        blockContainer(),
        .{ .display = .block, .item_is_compressible_replaced = true },
    );
    try testing.expectEqual(Size(f32){ .width = 150.0, .height = 20.0 }, layout.size);
}

test "block_level_justify_self_stretch_stretches" {
    const layout = try layoutChild(
        blockContainer(),
        .{
            .display = .block,
            .item_is_compressible_replaced = true,
            .justify_self = AlignItems.stretch,
        },
    );
    try testing.expectEqual(@as(f32, 400.0), layout.size.width);
}

test "absolute_auto_size_is_stretched_between_insets" {
    const layout = try layoutChild(
        positionedContainer(),
        .{
            .position = .absolute,
            .item_is_compressible_replaced = true,
            .inset = allInsets(10.0),
        },
    );
    try testing.expectEqual(Size(f32){ .width = 380.0, .height = 280.0 }, layout.size);
    try testing.expectEqual(Point(f32){ .x = 10.0, .y = 10.0 }, layout.location);
}

/// A `width: 100px; max-width: 100%` item in a zero-width grid's `1fr` column.
fn gridItemWidthWithPercentMaxWidth(replaced: bool, compressible_replaced: bool) !f32 {
    const columns = [_]laffy.GridTemplateComponent{laffy.style_helpers.fr(laffy.GridTemplateComponent, 1.0)};
    const container: Style = .{
        .display = .grid,
        .size = .{ .width = dim(0.0), .height = auto(Dimension) },
        .grid_template_columns = &columns,
    };
    const child: Style = .{
        .item_is_replaced = replaced,
        .item_is_compressible_replaced = compressible_replaced,
        .size = .{ .width = dim(100.0), .height = dim(20.0) },
        .min_size = .{ .width = LengthPercentageAuto.fromLength(0.0), .height = LengthPercentageAuto.auto },
        .max_size = .{ .width = LengthPercentageAuto.fromPercent(1.0), .height = LengthPercentageAuto.auto },
    };
    return (try layoutChild(container, child)).size.width;
}

test "grid_percent_max_width_does_not_compress_minimum_contribution" {
    try testing.expectEqual(@as(f32, 100.0), try gridItemWidthWithPercentMaxWidth(false, true));
}

test "grid_percent_max_width_compresses_replaced_minimum_contribution" {
    try testing.expectEqual(@as(f32, 0.0), try gridItemWidthWithPercentMaxWidth(true, false));
}

test "replaced_implies_compressible_replaced" {
    var style: Style = .{ .item_is_replaced = true };
    try testing.expect(style.isCompressibleReplaced());
    try testing.expect(style.isReplaced());
    style = .{ .item_is_compressible_replaced = true };
    try testing.expect(style.isCompressibleReplaced());
    try testing.expect(!style.isReplaced());
}
