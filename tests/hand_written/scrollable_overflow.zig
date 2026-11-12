//! The scrollable overflow rectangle captures start-side (negative) overflow as well as
//! end-side overflow. Boxes wholly in the unreachable scrollable overflow region are
//! excluded for scroll containers, while boxes only partially in the unreachable region
//! contribute their border box, clipped to the reachable side of each scroll origin.
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const Layout = laffy.Layout;
const NodeId = laffy.NodeId;
const Display = laffy.Display;
const Overflow = laffy.Overflow;
const Direction = laffy.Direction;
const FlexDirection = laffy.FlexDirection;
const FlexWrap = laffy.FlexWrap;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

const CONTAINER: f32 = 200.0;
const CHILD: f32 = 50.0;

const displays = [_]Display{ .block, .flex, .grid };
const directions = [_]Direction{ .ltr, .rtl };
const flex_directions = [_]FlexDirection{ .row, .row_reverse, .column, .column_reverse };

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

fn lpa(v: f32) LengthPercentageAuto {
    return LengthPercentageAuto.fromLength(v);
}

fn size(w: f32, h: f32) Size(Dimension) {
    return .{ .width = dim(w), .height = dim(h) };
}

fn expectF(expected: f32, actual: f32) !void {
    try testing.expectEqual(expected, actual);
}

fn expectReversed(x: bool, y: bool, actual: Point(bool)) !void {
    try testing.expectEqual(Point(bool){ .x = x, .y = y }, actual);
}

test "block_end_margins_do_not_extend_scrollable_overflow" {
    for (directions) |direction| {
        for ([_]f32{ -100.0, 0.0, 150.0 }) |bottom_margin| {
            for ([_]f32{ 0.0, 8.0 }) |padding| {
                var tree = try TaffyTree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.newLeaf(.{
                    .size = size(50.0, 50.0),
                    .margin = .{ .left = lpa(0.0), .right = lpa(0.0), .top = lpa(150.0), .bottom = lpa(bottom_margin) },
                });
                const node = try tree.newWithChildren(
                    .{
                        .display = .block,
                        .direction = direction,
                        .size = size(200.0, 200.0),
                        .padding = .{
                            .left = laffy.LengthPercentage.fromLength(0.0),
                            .right = laffy.LengthPercentage.fromLength(0.0),
                            .top = laffy.LengthPercentage.fromLength(0.0),
                            .bottom = laffy.LengthPercentage.fromLength(padding),
                        },
                        .overflow = .{ .x = .scroll, .y = .scroll },
                    },
                    &.{child},
                );
                try tree.computeLayout(node, Size(AvailableSpace).max_content);
                const layout = tree.layout(node);
                const expected_end: f32 = 200.0 + if (bottom_margin < 0.0) @as(f32, 0.0) else padding;
                try expectF(expected_end, layout.scrollable_overflow_rect.bottom());
            }
        }
    }
}

test "negative_margins_do_not_add_padding_to_overflow_edges" {
    for (displays) |display| {
        for (directions) |direction| {
            for ([_]FlexDirection{ .row, .row_reverse, .column_reverse }) |flex_direction| {
                var tree = try TaffyTree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.newLeaf(.{
                    .size = size(300.0, 300.0),
                    .margin = .{ .left = lpa(-100.0), .right = lpa(-100.0), .top = lpa(-100.0), .bottom = lpa(-100.0) },
                });
                const node = try tree.newWithChildren(
                    .{
                        .display = display,
                        .direction = direction,
                        .flex_direction = flex_direction,
                        .box_sizing = .content_box,
                        .size = size(80.0, 80.0),
                        .padding = .{
                            .left = laffy.LengthPercentage.fromLength(16.0),
                            .right = laffy.LengthPercentage.fromLength(4.0),
                            .top = laffy.LengthPercentage.fromLength(1.0),
                            .bottom = laffy.LengthPercentage.fromLength(8.0),
                        },
                        .border = .{
                            .left = laffy.LengthPercentage.fromLength(4.0),
                            .right = laffy.LengthPercentage.fromLength(50.0),
                            .top = laffy.LengthPercentage.fromLength(1.0),
                            .bottom = laffy.LengthPercentage.fromLength(40.0),
                        },
                        .overflow = .{ .x = .hidden, .y = .hidden },
                    },
                    &.{child},
                );
                try tree.computeLayout(node, Size(AvailableSpace).max_content);
                const layout = tree.layout(node);
                const reversed_x = (direction == .rtl) != (display == .flex and flex_direction == .row_reverse);
                const expected_width: f32 = (if (reversed_x) @as(f32, 204.0) else 216.0) -
                    (if (display == .flex and flex_direction != .column_reverse) @as(f32, 20.0) else 0.0);
                const expected_height: f32 = if (display == .flex and flex_direction == .column_reverse) 188.0 else 201.0;
                try expectF(expected_width, 100.0 + layout.scrollWidth());
                try expectF(expected_height, 89.0 + layout.scrollHeight());
            }
        }
    }
}

fn containerWithAbsoluteChild(
    display: Display,
    overflow: Overflow,
    direction: Direction,
    inset_left: ?f32,
    inset_right: ?f32,
) !Layout {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{
        .position = .absolute,
        .inset = .{
            .left = if (inset_left) |v| lpa(v) else LengthPercentageAuto.auto,
            .right = if (inset_right) |v| lpa(v) else LengthPercentageAuto.auto,
            .top = lpa(0.0),
            .bottom = LengthPercentageAuto.auto,
        },
        .size = size(CHILD, CHILD),
    });
    const node = try tree.newWithChildren(
        .{
            .display = display,
            .direction = direction,
            .position = .relative,
            .size = size(CONTAINER, CONTAINER),
            .overflow = .{ .x = overflow, .y = overflow },
        },
        &.{child},
    );

    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    return tree.layout(node).*;
}

test "wholly_unreachable_boxes_are_excluded_for_scroll_containers" {
    for (displays) |display| {
        // Child entirely before the scroll origin (x from -100 to -50)
        const layout = try containerWithAbsoluteChild(display, .scroll, .ltr, -100.0, null);

        try testing.expectEqual(Rect(f32).zero, layout.scrollable_overflow_rect.rect());
        try expectF(0.0, layout.scrollWidth());
    }
}

test "wholly_unreachable_boxes_contribute_to_non_scroll_containers" {
    for (displays) |display| {
        // A box that is not a scroll container has no unreachable region of its own, so
        // start-side overflow is captured in its scrollable overflow rect.
        const layout = try containerWithAbsoluteChild(display, .visible, .ltr, -100.0, null);

        try expectF(-100.0, layout.scrollable_overflow_rect.left());
    }
}

test "partially_unreachable_boxes_are_clipped_at_the_normal_origin" {
    for (displays) |display| {
        // Child straddling the scroll origin (x from -25 to 25): the unreachable part is clipped.
        const layout = try containerWithAbsoluteChild(display, .scroll, .ltr, -25.0, null);

        try expectF(0.0, layout.scrollable_overflow_rect.left());
        try expectF(25.0, layout.scrollable_overflow_rect.right());
        // Only the reachable extent counts towards the scroll width
        try expectF(0.0, layout.scrollWidth());
    }
}

test "end_side_overflow_is_captured_and_scrollable" {
    for (displays) |display| {
        // Child extending past the end edge (x from 200 to 250)
        const layout = try containerWithAbsoluteChild(display, .scroll, .ltr, CONTAINER, null);

        try expectF(CONTAINER + CHILD, layout.scrollable_overflow_rect.right());
        try expectF(CHILD, layout.scrollWidth());
    }
}

test "absolute_only_containers_include_scroll_container_end_padding" {
    for (displays) |display| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const abs = try tree.newLeaf(.{
            .position = .absolute,
            .inset = .{ .left = lpa(0.0), .right = LengthPercentageAuto.auto, .top = lpa(0.0), .bottom = LengthPercentageAuto.auto },
            .size = size(5.0, 5.0),
        });
        const node = try tree.newWithChildren(
            .{
                .display = display,
                .position = .relative,
                .overflow = .{ .x = .scroll, .y = .scroll },
                .padding = .{
                    .left = laffy.LengthPercentage.fromLength(0.0),
                    .right = laffy.LengthPercentage.fromLength(20.0),
                    .top = laffy.LengthPercentage.fromLength(0.0),
                    .bottom = laffy.LengthPercentage.fromLength(30.0),
                },
                .size = size(CONTAINER, CONTAINER),
            },
            &.{abs},
        );

        try tree.computeLayout(node, Size(AvailableSpace).max_content);
        const layout = tree.layout(node);

        try expectF(20.0, layout.scrollable_overflow_rect.right());
        try expectF(30.0, layout.scrollable_overflow_rect.bottom());
    }
}

fn nestedOverflowLayout(display: Display, child_overflow: Point(Overflow)) !Layout {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    // Grandchild overflowing the child in the y axis (extends to y=300 in a 200-high child)
    const grandchild = try tree.newLeaf(.{
        .position = .absolute,
        .inset = .{ .left = lpa(0.0), .right = LengthPercentageAuto.auto, .top = lpa(CONTAINER), .bottom = LengthPercentageAuto.auto },
        .size = size(CHILD, CHILD),
    });
    const child = try tree.newWithChildren(
        .{
            .display = display,
            .position = .relative,
            .size = size(CONTAINER, CONTAINER),
            .overflow = child_overflow,
        },
        &.{grandchild},
    );
    const node = try tree.newWithChildren(
        .{ .display = display, .size = size(CONTAINER, CONTAINER) },
        &.{child},
    );

    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    return tree.layout(node).*;
}

test "scroll_container_in_one_axis_clips_both_axes" {
    for (displays) |display| {
        // `hidden`/`scroll` in either axis makes the child a scroll container, which clips
        // overflow in both axes: the grandchild's y overflow must not propagate.
        const layout = try nestedOverflowLayout(display, .{ .x = .hidden, .y = .visible });

        try expectF(CONTAINER, layout.scrollable_overflow_rect.bottom());
    }
}

test "clip_in_one_axis_does_not_clip_the_other" {
    for (displays) |display| {
        // `clip` does not establish a scroll container: overflow in the other (visible) axis
        // still propagates.
        const layout = try nestedOverflowLayout(display, .{ .x = .clip, .y = .visible });

        try expectF(CONTAINER + CHILD, layout.scrollable_overflow_rect.bottom());
    }
}

test "wholly_unreachable_boxes_are_excluded_for_rtl_scroll_containers" {
    for (displays) |display| {
        // In RTL the scroll origin is the top-right corner: a child entirely past the
        // *right* edge is wholly unreachable.
        const layout = try containerWithAbsoluteChild(display, .scroll, .rtl, null, -100.0);

        try expectF(0.0, layout.scrollable_overflow_rect.left());
        try expectReversed(true, false, layout.scrollable_overflow_rect.isReversed());
        try expectF(0.0, layout.scrollWidth());
    }
}

test "end_side_overflow_is_captured_for_rtl_scroll_containers" {
    for (displays) |display| {
        // In RTL, overflow past the *left* edge is reachable end-side overflow.
        const layout = try containerWithAbsoluteChild(display, .scroll, .rtl, -CHILD, null);

        try expectF(-CHILD, layout.scrollable_overflow_rect.left());
        try expectF(CHILD, layout.scrollWidth());
    }
}

fn flexOverflowLayout(direction: Direction, flex_direction: FlexDirection, wrap: FlexWrap, absolute: bool) !Layout {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{
        .position = if (absolute) .absolute else .relative,
        .flex_shrink = 0.0,
        .size = size(300.0, 300.0),
    });
    const node = try tree.newWithChildren(
        .{
            .display = .flex,
            .direction = direction,
            .flex_direction = flex_direction,
            .flex_wrap = wrap,
            .position = .relative,
            .overflow = .{ .x = .scroll, .y = .scroll },
            .size = size(CONTAINER, CONTAINER),
        },
        &.{child},
    );
    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    return tree.layout(node).*;
}

test "flex_reversed_origins_include_negative_overflow" {
    for (directions) |direction| {
        for (flex_directions) |flex_direction| {
            for ([_]FlexWrap{ .no_wrap, .wrap_reverse }) |wrap| {
                // Exercise the same origins for in-flow and absolutely positioned flex children.
                for ([_]bool{ false, true }) |absolute| {
                    const layout = try flexOverflowLayout(direction, flex_direction, wrap, absolute);
                    const main_reversed = flex_direction == .row_reverse or flex_direction == .column_reverse;
                    var x: bool = undefined;
                    var y: bool = undefined;
                    if (flex_direction == .row or flex_direction == .row_reverse) {
                        x = main_reversed;
                        y = wrap == .wrap_reverse;
                    } else {
                        x = wrap == .wrap_reverse;
                        y = main_reversed;
                    }
                    const reversed = Point(bool){ .x = x != direction.isRtl(), .y = y };
                    try testing.expectEqual(reversed, layout.scrollable_overflow_rect.isReversed());
                    const overflow = layout.scrollable_overflow_rect;
                    try expectF(if (reversed.x) -100.0 else 0.0, overflow.left());
                    try expectF(if (reversed.y) -100.0 else 0.0, overflow.top());
                    try expectF(100.0, layout.scrollWidth());
                    try expectF(100.0, layout.scrollHeight());
                }
            }
        }
    }
}

test "wrap_reverse_lines_overflow_above_the_scrollport" {
    for (directions) |direction| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        var children: [3]NodeId = undefined;
        for (&children) |*c| {
            c.* = try tree.newLeaf(.{
                .flex_shrink = 0.0,
                .size = size(100.0, 100.0),
            });
        }
        const node = try tree.newWithChildren(
            .{
                .display = .flex,
                .direction = direction,
                .flex_wrap = .wrap_reverse,
                .size = size(200.0, 100.0),
                .overflow = .{ .x = .scroll, .y = .scroll },
            },
            &children,
        );
        try tree.computeLayout(node, Size(AvailableSpace).max_content);
        const layout = tree.layout(node);
        try expectF(-100.0, tree.layout(children[2]).location.y);
        try expectF(-100.0, layout.scrollable_overflow_rect.top());
        try expectReversed(direction.isRtl(), true, layout.scrollable_overflow_rect.isReversed());
        try expectF(100.0, layout.scrollHeight());
    }
}

test "empty_scroll_ranges_and_visible_container_origins" {
    for (displays) |display| {
        for ([_]Overflow{ .visible, .scroll }) |overflow| {
            var tree = try TaffyTree.init(testing.allocator);
            defer tree.deinit();
            const node = try tree.newLeaf(.{
                .display = display,
                .direction = .rtl,
                .flex_direction = .column_reverse,
                .flex_wrap = .wrap_reverse,
                .size = size(CONTAINER, CONTAINER),
                .overflow = .{ .x = overflow, .y = overflow },
            });
            try tree.computeLayout(node, Size(AvailableSpace).max_content);
            const layout = tree.layout(node);
            if (overflow == .visible) {
                try expectReversed(false, false, layout.scrollable_overflow_rect.isReversed());
            }
            try expectF(0.0, layout.scrollWidth());
            try expectF(0.0, layout.scrollHeight());
        }
    }
}

test "negative_overflow_is_preserved_for_visible_flex_containers" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{
        .flex_shrink = 0.0,
        .size = size(300.0, 300.0),
    });
    const node = try tree.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .column_reverse,
            .flex_wrap = .wrap_reverse,
            .size = size(CONTAINER, CONTAINER),
        },
        &.{child},
    );
    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    const overflow = tree.layout(node).scrollable_overflow_rect;
    try expectReversed(false, false, overflow.isReversed());
    try expectF(-100.0, overflow.left());
    try expectF(-100.0, overflow.top());
}

test "reversed_flex_origins_clip_unreachable_absolute_overflow" {
    for ([_]FlexDirection{ .row_reverse, .column_reverse }) |flex_direction| {
        for ([_]f32{ -100.0, -25.0, 175.0, 200.0 }) |offset| {
            var tree = try TaffyTree.init(testing.allocator);
            defer tree.deinit();
            const row = flex_direction == .row_reverse;
            const child = try tree.newLeaf(.{
                .position = .absolute,
                .inset = .{
                    .left = lpa(if (row) offset else 0.0),
                    .top = lpa(if (row) 0.0 else offset),
                    .right = LengthPercentageAuto.auto,
                    .bottom = LengthPercentageAuto.auto,
                },
                .size = size(CHILD, CHILD),
            });
            const node = try tree.newWithChildren(
                .{
                    .display = .flex,
                    .flex_direction = flex_direction,
                    .position = .relative,
                    .size = size(CONTAINER, CONTAINER),
                    .overflow = .{ .x = .scroll, .y = .scroll },
                },
                &.{child},
            );
            try tree.computeLayout(node, Size(AvailableSpace).max_content);
            const layout = tree.layout(node);
            const overflow = layout.scrollable_overflow_rect;
            try testing.expect(overflow.right() <= CONTAINER and overflow.bottom() <= CONTAINER);
            try expectF(@max(-offset, 0.0), if (row) layout.scrollWidth() else layout.scrollHeight());
        }
    }
}

test "reversed_flex_scroll_ranges_include_padding_and_exclude_borders" {
    for (directions) |direction| {
        for (flex_directions) |flex_direction| {
            for ([_]FlexWrap{ .no_wrap, .wrap_reverse }) |wrap| {
                var tree = try TaffyTree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.newLeaf(.{
                    .flex_shrink = 0.0,
                    .size = size(300.0, 300.0),
                });
                const node = try tree.newWithChildren(
                    .{
                        .display = .flex,
                        .direction = direction,
                        .flex_direction = flex_direction,
                        .flex_wrap = wrap,
                        .size = size(CONTAINER, CONTAINER),
                        .border = .{
                            .left = laffy.LengthPercentage.fromLength(20.0),
                            .right = laffy.LengthPercentage.fromLength(20.0),
                            .top = laffy.LengthPercentage.fromLength(20.0),
                            .bottom = laffy.LengthPercentage.fromLength(20.0),
                        },
                        .padding = .{
                            .left = laffy.LengthPercentage.fromLength(10.0),
                            .right = laffy.LengthPercentage.fromLength(20.0),
                            .top = laffy.LengthPercentage.fromLength(30.0),
                            .bottom = laffy.LengthPercentage.fromLength(40.0),
                        },
                        .overflow = .{ .x = .scroll, .y = .scroll },
                    },
                    &.{child},
                );
                try tree.computeLayout(node, Size(AvailableSpace).max_content);
                const layout = tree.layout(node);
                try expectF(170.0, layout.scrollWidth());
                try expectF(210.0, layout.scrollHeight());
            }
        }
    }
}
