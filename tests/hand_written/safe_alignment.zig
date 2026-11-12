//! Tests for the `safe` and `unsafe` overflow-position keywords on align-* and justify-*.
//!
//! Spec: <https://www.w3.org/TR/css-align-3/#overflow-values>
//!
//! When the alignment subject overflows the alignment container, a `safe` value behaves
//! as logical `start`; an `unsafe` value (the default) keeps its requested position even
//! when that causes data loss at the start edge.
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Dimension = laffy.Dimension;
const AlignSelf = laffy.AlignSelf;
const JustifySelf = laffy.JustifySelf;
const AlignContent = laffy.AlignContent;
const JustifyContent = laffy.JustifyContent;
const AvailableSpace = laffy.AvailableSpace;
const GridTemplateComponent = laffy.GridTemplateComponent;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

fn sz(w: f32, h: f32) Size(Dimension) {
    return .{ .width = dim(w), .height = dim(h) };
}

fn gridTrack(v: f32) GridTemplateComponent {
    return GridTemplateComponent.fromLength(v);
}

test "grid_safe_align_self_falls_back_to_start_on_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(50.0, 150.0),
        .align_self = AlignSelf.safe_end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{gridTrack(100.0)},
            .grid_template_columns = &.{gridTrack(100.0)},
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Child overflows the 100-tall grid area, so safe end falls back to start (y == 0).
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child).location.y);
}

test "grid_safe_align_self_behaves_as_end_when_no_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(50.0, 40.0),
        .align_self = AlignSelf.safe_end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{gridTrack(100.0)},
            .grid_template_columns = &.{gridTrack(100.0)},
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // No overflow, so safe end behaves as end: y == 100 - 40 == 60
    try testing.expectEqual(@as(f32, 60.0), taffy.layout(child).location.y);
}

test "grid_unsafe_align_self_keeps_overflowing_position" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(50.0, 150.0),
        .align_self = AlignSelf.end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{gridTrack(100.0)},
            .grid_template_columns = &.{gridTrack(100.0)},
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Plain End with overflow keeps end alignment: y == 100 - 150 == -50
    try testing.expectEqual(@as(f32, -50.0), taffy.layout(child).location.y);
}

test "grid_safe_justify_self_falls_back_to_start_on_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(150.0, 50.0),
        .justify_self = JustifySelf.safe_end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{gridTrack(100.0)},
            .grid_template_columns = &.{gridTrack(100.0)},
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child).location.x);
}

test "grid_safe_justify_self_rtl_falls_back_to_rtl_start_edge" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(150.0, 50.0),
        .justify_self = JustifySelf.safe_end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .direction = .rtl,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{gridTrack(100.0)},
            .grid_template_columns = &.{gridTrack(100.0)},
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // In RTL the inline-start edge is the right side. The 150-wide child in the
    // 100-wide container, anchored at the RTL Start edge, sits at x == -50.
    try testing.expectEqual(@as(f32, -50.0), taffy.layout(child).location.x);
}

test "grid_safe_align_content_overflow_falls_back_to_start" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child_a = try taffy.newLeaf(.{ .size = sz(40.0, 80.0) });
    const child_b = try taffy.newLeaf(.{ .size = sz(40.0, 80.0) });
    const root = try taffy.newWithChildren(
        .{
            .display = .grid,
            .size = sz(100.0, 100.0),
            .grid_template_rows = &.{ gridTrack(80.0), gridTrack(80.0) },
            .grid_template_columns = &.{gridTrack(40.0)},
            .align_content = AlignContent.safe_end,
        },
        &.{ child_a, child_b },
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Tracks total 160 in a 100-tall container — overflow. Safe end falls back to
    // start: first track at y == 0.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child_a).location.y);
}

test "flex_safe_align_self_falls_back_to_start_on_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(50.0, 150.0),
        .align_self = AlignSelf.safe_end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .size = sz(100.0, 100.0),
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Cross-axis overflow: safe end falls back to start (y == 0).
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child).location.y);
}

test "flex_unsafe_align_self_keeps_overflowing_position" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{
        .size = sz(50.0, 150.0),
        .align_self = AlignSelf.end,
    });
    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .size = sz(100.0, 100.0),
        },
        &.{child},
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Plain End with cross-axis overflow keeps end alignment: y == 100 - 150 == -50
    try testing.expectEqual(@as(f32, -50.0), taffy.layout(child).location.y);
}

test "flex_safe_justify_content_falls_back_to_start_on_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child_a = try taffy.newLeaf(.{ .size = sz(80.0, 50.0) });
    const child_b = try taffy.newLeaf(.{ .size = sz(80.0, 50.0) });
    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .size = sz(100.0, 100.0),
            .justify_content = JustifyContent.safe_end,
        },
        &.{ child_a, child_b },
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Items total 160 in a 100-wide container — overflow. Safe end falls back to
    // start: first item anchored at x == 0.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child_a).location.x);
}

test "flex_safe_align_content_falls_back_to_start_on_multiline_overflow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child_a = try taffy.newLeaf(.{ .size = sz(60.0, 80.0) });
    const child_b = try taffy.newLeaf(.{ .size = sz(60.0, 80.0) });
    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_wrap = .wrap,
            .size = sz(100.0, 100.0),
            .align_content = AlignContent.safe_end,
        },
        &.{ child_a, child_b },
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // Two 80-tall lines wrap and overflow the 100-tall container. Safe end falls back
    // to start: first line at y == 0.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child_a).location.y);
}
