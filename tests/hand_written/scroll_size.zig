//! The maximum scroll offset is the content size less the size of the padding
//! box, so it must not depend on which side a border sits on, and must agree
//! across the layout algorithms.
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const Layout = laffy.Layout;
const Display = laffy.Display;
const Overflow = laffy.Overflow;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AvailableSpace = laffy.AvailableSpace;
const length = laffy.style_helpers.length;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

const CONTENT: f32 = 1000.0;
const CONTAINER: f32 = 200.0;
const BORDER: f32 = 20.0;
const PADDING: f32 = 20.0;

const displays = [_]Display{ .block, .flex, .grid };

fn scrollerWithPadding(display: Display, border: Rect(LengthPercentage), padding: Rect(LengthPercentage)) !Layout {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{ .size = .{ .width = length(Dimension, 100.0), .height = length(Dimension, CONTENT) } });
    const node = try tree.newWithChildren(
        .{
            .display = display,
            .box_sizing = .border_box,
            .size = .{ .width = length(Dimension, 300.0), .height = length(Dimension, CONTAINER) },
            .border = border,
            .padding = padding,
            .overflow = .{ .x = .scroll, .y = .scroll },
        },
        &.{child},
    );

    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    return tree.layout(node).*;
}

fn scroller(display: Display, border: Rect(LengthPercentage)) !Layout {
    return scrollerWithPadding(display, border, edge(0.0, 0.0));
}

fn edge(top: f32, bottom: f32) Rect(LengthPercentage) {
    return .{
        .left = LengthPercentage.fromLength(0.0),
        .right = LengthPercentage.fromLength(0.0),
        .top = LengthPercentage.fromLength(top),
        .bottom = LengthPercentage.fromLength(bottom),
    };
}

fn expectF(expected: f32, actual: f32) !void {
    try testing.expectEqual(expected, actual);
}

const border_pairs = [_][2]f32{ .{ BORDER, 0.0 }, .{ 0.0, BORDER }, .{ BORDER, BORDER }, .{ 0.0, 0.0 } };
const padding_pairs = [_][2]f32{ .{ PADDING, 0.0 }, .{ 0.0, PADDING }, .{ PADDING, PADDING }, .{ 0.0, 0.0 } };

test "scroll_height_does_not_depend_on_which_edge_the_border_is_on" {
    for (displays) |display| {
        const top = try scroller(display, edge(BORDER, 0.0));
        const bottom = try scroller(display, edge(0.0, BORDER));

        try expectF(top.scrollHeight(), bottom.scrollHeight());
    }
}

test "scroll_height_is_the_content_beyond_the_padding_box" {
    for (displays) |display| {
        for (border_pairs) |pair| {
            const top = pair[0];
            const bottom = pair[1];
            const layout = try scroller(display, edge(top, bottom));
            const padding_box = CONTAINER - top - bottom;

            try expectF(CONTENT - padding_box, layout.scrollHeight());
        }
    }
}

test "scrollable_overflow_excludes_the_containers_own_border" {
    for (displays) |display| {
        for (border_pairs) |pair| {
            const layout = try scroller(display, edge(pair[0], pair[1]));

            try expectF(CONTENT, layout.scrollable_overflow_rect.bottom());
        }
    }
}

test "scrollable_overflow_includes_the_containers_own_padding" {
    for (displays) |display| {
        for (padding_pairs) |pair| {
            const top = pair[0];
            const bottom = pair[1];
            const layout = try scrollerWithPadding(display, edge(0.0, 0.0), edge(top, bottom));

            try expectF(CONTENT + top + bottom, layout.scrollable_overflow_rect.bottom());
        }
    }
}

test "scrollable_overflow_excludes_the_own_padding_of_a_non_scroll_container" {
    for (displays) |display| {
        for (padding_pairs) |pair| {
            const top = pair[0];
            const bottom = pair[1];
            var tree = try TaffyTree.init(testing.allocator);
            defer tree.deinit();
            const child = try tree.newLeaf(.{ .size = .{ .width = length(Dimension, 100.0), .height = length(Dimension, CONTENT) } });
            const node = try tree.newWithChildren(
                .{
                    .display = display,
                    .box_sizing = .border_box,
                    .size = .{ .width = length(Dimension, 300.0), .height = length(Dimension, CONTAINER) },
                    .padding = edge(top, bottom),
                },
                &.{child},
            );

            try tree.computeLayout(node, Size(AvailableSpace).max_content);
            const layout = tree.layout(node);

            // A box that is not a scroll container does not extend its scrollable overflow
            // region by its own padding: only the content contributes.
            try expectF(top + CONTENT, layout.scrollable_overflow_rect.bottom());
        }
    }
}

fn measuredLeaf(overflow: Overflow, padding: Rect(LengthPercentage)) !Layout {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const node = try tree.newLeafWithContext(
        .{
            .box_sizing = .border_box,
            .size = .{ .width = length(Dimension, 300.0), .height = length(Dimension, CONTAINER) },
            .padding = padding,
            .overflow = .{ .x = overflow, .y = overflow },
        },
        TestNodeContext.fixed(100.0, CONTENT),
    );

    try tree.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, measure.TestMeasurer{});
    return tree.layout(node).*;
}

test "leaf_content_size_includes_the_containers_own_padding" {
    for (padding_pairs) |pair| {
        const top = pair[0];
        const bottom = pair[1];
        const layout = try measuredLeaf(.scroll, edge(top, bottom));

        try expectF(top + CONTENT + bottom, layout.scrollable_overflow_rect.bottom());
    }
}

test "leaf_content_size_excludes_the_own_padding_of_a_non_scroll_container" {
    for (padding_pairs) |pair| {
        const top = pair[0];
        const bottom = pair[1];
        const layout = try measuredLeaf(.visible, edge(top, bottom));

        // A box that is not a scroll container does not extend its scrollable overflow
        // region by its own padding: only the content contributes.
        try expectF(top + CONTENT, layout.scrollable_overflow_rect.bottom());
    }
}

test "scroll_height_accounts_for_the_containers_own_padding" {
    for (displays) |display| {
        for (padding_pairs) |pair| {
            const top = pair[0];
            const bottom = pair[1];
            const layout = try scrollerWithPadding(display, edge(0.0, 0.0), edge(top, bottom));

            // The scrollable overflow region runs from the padding-box origin to the end of
            // the content plus the container's end-side padding.
            const expected = (top + CONTENT + bottom) - CONTAINER;
            try expectF(expected, layout.scrollHeight());
        }
    }
}

// Items in overflowing rows must contribute their position within the container (not just
// their size) to the container's content size.
test "grid_scrollable_overflow_includes_item_positions_in_overflowing_tracks" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child_style: Style = .{ .size = .{ .width = length(Dimension, 100.0), .height = length(Dimension, 500.0) } };
    const c1 = try tree.newLeaf(child_style);
    const c2 = try tree.newLeaf(child_style);
    const node = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = .{ .width = length(Dimension, 300.0), .height = length(Dimension, CONTAINER) },
            .overflow = .{ .x = .scroll, .y = .scroll },
        },
        &.{ c1, c2 },
    );

    try tree.computeLayout(node, Size(AvailableSpace).max_content);
    const layout = tree.layout(node);

    try expectF(1000.0, layout.scrollable_overflow_rect.bottom());
    try expectF(1000.0 - CONTAINER, layout.scrollHeight());
}

test "scroll_height_agrees_with_borders_and_padding_combined" {
    for (displays) |display| {
        const layout = try scrollerWithPadding(display, edge(BORDER, BORDER), edge(PADDING, PADDING));

        const padding_box = CONTAINER - BORDER - BORDER;
        const expected = (PADDING + CONTENT + PADDING) - padding_box;
        try expectF(expected, layout.scrollHeight());
    }
}
