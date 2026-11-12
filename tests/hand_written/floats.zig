const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const NodeId = laffy.NodeId;
const Float = laffy.Float;
const Clear = laffy.Clear;
const Direction = laffy.Direction;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn point(x: f32, y: f32) Point(f32) {
    return .{ .x = x, .y = y };
}

// Regression test for <https://wpt.live/css/CSS2/floats-clear/floats-146.xht>
//
// A right float placed after two left floats must not be placed higher than the
// outer top of the earlier floats (CSS2 float rule 5). This scenario previously
// panicked in `FloatContext::subdivide_segment` when the float's end coincided
// with an existing segment boundary due to floating point imprecision.
test "float_no_higher_than_earlier_floats" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // Spacer block advancing the flow position to a fractional y offset (43.2)
    const spacer = try taffy.newLeaf(floatBlock(400.0, 43.2, .none));
    const float_a = try taffy.newLeaf(floatBlock(258.0, 42.0, .left));
    const float_b = try taffy.newLeaf(floatBlock(298.0, 42.0, .left));
    const float_c = try taffy.newLeaf(floatBlock(98.0, 42.0, .right));

    const root = try taffy.newWithChildren(
        .{
            .display = .block,
            .size = .{ .width = Dimension.fromLength(400.0), .height = Dimension.auto },
        },
        &.{ spacer, float_a, float_b, float_c },
    );

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    const layout_a = taffy.layout(float_a);
    const layout_b = taffy.layout(float_b);
    const layout_c = taffy.layout(float_c);

    // A is placed below the spacer
    try testing.expectEqual(point(0.0, 43.0), layout_a.location);
    // B does not fit next to A, so is placed below it
    try testing.expectEqual(point(0.0, 85.0), layout_b.location);
    // C must not be placed higher than B (it fits next to B on the right)
    try testing.expectEqual(point(302.0, 85.0), layout_c.location);
}

// Regression test for <https://wpt.live/css/CSS2/floats-clear/margin-collapse-033.xht>
//
// Floats that occupy no horizontal space (e.g. a zero-width float) still affect
// `clear`: a cleared block must be placed past the bottom of all floats on the
// relevant side, regardless of their width.
test "clear_past_zero_width_float" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // float: left with auto width resolving to 0
    const floated = try taffy.newLeaf(.{
        .display = .block,
        .float = .left,
        .size = .{ .width = Dimension.auto, .height = Dimension.fromLength(1.0) },
    });
    const cleared = try taffy.newLeaf(.{ .display = .block, .clear = .left });
    var sibling_margin = Rect(LengthPercentageAuto).zero;
    sibling_margin.top = LengthPercentageAuto.fromLength(99.0);
    const sibling = try taffy.newLeaf(.{ .display = .block, .margin = sibling_margin });

    const container = try taffy.newWithChildren(
        .{
            .display = .block,
            .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.auto },
        },
        &.{ floated, cleared, sibling },
    );
    const root = try taffy.newWithChildren(.{ .display = .block }, &.{container});

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // The cleared (self-collapsing) block is placed below the float (y=1). Its clearance
    // prevents the sibling's 99px margin from collapsing with preceding margins, so the
    // container's height is 1 + 99 = 100.
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(container).size.height);
}

fn floatBlock(width: f32, height: f32, float: Float) Style {
    return .{
        .display = .block,
        .float = float,
        .size = .{ .width = Dimension.fromLength(width), .height = Dimension.fromLength(height) },
    };
}

fn rootStyle(width: f32) Style {
    return .{ .display = .block, .size = .{ .width = Dimension.fromLength(width), .height = Dimension.auto } };
}

// Regression test for <https://wpt.live/css/CSS2/floats/floats-rule3-outside-left-001.xht>
//
// CSS2 float rule 7: a float that is wider than its containing block and has no other
// float beside it may overflow the containing block's edge rather than being pushed down.
test "oversized_float_overflows_containing_block" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const float_a = try taffy.newLeaf(floatBlock(150.0, 50.0, .left));
    const root = try taffy.newWithChildren(rootStyle(100.0), &.{float_a});

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    try testing.expectEqual(point(0.0, 0.0), taffy.layout(float_a).location);
}

// CSS2 float rules 3 & 7: a float with another float beside it must not overlap that float
// (rule 3) nor extend past the containing block's opposite edge (rule 7) - it must move down.
test "float_beside_existing_float_moves_down_instead_of_overflowing" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // Rule 3: an opposite-direction float that doesn't fit must move down, not overlap
    const left = try taffy.newLeaf(floatBlock(60.0, 50.0, .left));
    const right = try taffy.newLeaf(floatBlock(60.0, 50.0, .right));
    // Rule 7: a same-direction float that doesn't fit must move down, not overflow the
    // containing block's trailing edge
    const left2 = try taffy.newLeaf(floatBlock(60.0, 50.0, .left));

    const root = try taffy.newWithChildren(rootStyle(100.0), &.{ left, right, left2 });

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    try testing.expectEqual(point(0.0, 0.0), taffy.layout(left).location);
    try testing.expectEqual(point(40.0, 50.0), taffy.layout(right).location);
    try testing.expectEqual(point(0.0, 100.0), taffy.layout(left2).location);
}

// Regression test for auto-margins-used-values-with-floats.tentative.html.
test "auto_margins_include_float_avoidance_offsets" {
    const float_widths = [_][2]f32{ .{ 0.0, 20.0 }, .{ 20.0, 0.0 }, .{ 20.0, 20.0 }, .{ 0.0, 0.0 } };
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        for (float_widths) |widths| {
            const left_float_width = widths[0];
            const right_float_width = widths[1];
            var taffy = try TaffyTree.init(testing.allocator);
            defer taffy.deinit();
            const left_float = try taffy.newLeaf(floatBlock(left_float_width, 40.0, .left));
            const right_float = try taffy.newLeaf(floatBlock(right_float_width, 40.0, .right));
            const auto_sides = [_][2]bool{ .{ true, true }, .{ true, false }, .{ false, true } };
            var boxes: [auto_sides.len]NodeId = undefined;
            for (auto_sides, 0..) |sides, i| {
                const left_auto = sides[0];
                const right_auto = sides[1];
                boxes[i] = try taffy.newLeaf(.{
                    .display = .flow_root,
                    .direction = direction,
                    .size = .{ .width = Dimension.fromLength(40.0), .height = Dimension.fromLength(10.0) },
                    .margin = .{
                        .left = if (left_auto) LengthPercentageAuto.auto else LengthPercentageAuto.zero,
                        .right = if (right_auto) LengthPercentageAuto.auto else LengthPercentageAuto.zero,
                        .top = LengthPercentageAuto.auto,
                        .bottom = LengthPercentageAuto.auto,
                    },
                });
            }
            const children = [_]NodeId{ left_float, right_float } ++ boxes;
            const root = try taffy.newWithChildren(
                .{
                    .display = .flow_root,
                    .direction = direction,
                    .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.auto },
                    .padding = Rect(LengthPercentage).fromLength(5.0),
                },
                &children,
            );

            try taffy.computeLayout(root, Size(AvailableSpace).max_content);

            for (boxes, auto_sides, 0..) |node, sides, index| {
                const left_auto = sides[0];
                const right_auto = sides[1];
                const layout = taffy.layout(node);
                const free_space = 90.0 - left_float_width - right_float_width - 40.0;
                const auto_count: f32 = @floatFromInt(@as(u8, @intFromBool(left_auto)) + @as(u8, @intFromBool(right_auto)));
                const alignment_margin = free_space / auto_count;
                const left_gap: f32 = if (left_auto) alignment_margin else 0.0;
                const index_f: f32 = @floatFromInt(index);
                try testing.expectEqual(
                    point(5.0 + left_float_width + left_gap, 5.0 + index_f * 10.0),
                    layout.location,
                );
                try testing.expectEqual(Size(f32){ .width = 40.0, .height = 10.0 }, layout.size);
                try testing.expectEqual(if (left_auto) left_float_width + alignment_margin else @as(f32, 0.0), layout.margin.left);
                try testing.expectEqual(if (right_auto) right_float_width + alignment_margin else @as(f32, 0.0), layout.margin.right);
                try testing.expectEqual(@as(f32, 0.0), layout.margin.top);
                try testing.expectEqual(@as(f32, 0.0), layout.margin.bottom);
            }
        }
    }
}

test "float_avoiding_auto_margins_in_nested_block_ignore_relative_insets_and_clearance" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        var taffy = try TaffyTree.init(testing.allocator);
        defer taffy.deinit();
        const left_float = try taffy.newLeaf(floatBlock(40.0, 40.0, .left));
        const right_float = try taffy.newLeaf(floatBlock(60.0, 40.0, .right));
        const box_style: Style = .{
            .display = .flow_root,
            .direction = direction,
            .size = .{ .width = Dimension.fromLength(40.0), .height = Dimension.fromLength(10.0) },
            .margin = .{
                .left = LengthPercentageAuto.auto,
                .right = LengthPercentageAuto.auto,
                .top = LengthPercentageAuto.zero,
                .bottom = LengthPercentageAuto.zero,
            },
        };
        var relative_inset = Rect(LengthPercentageAuto).auto;
        relative_inset.left = LengthPercentageAuto.fromLength(7.0);
        var relative_style = box_style;
        relative_style.position = .relative;
        relative_style.inset = relative_inset;
        const relative_box = try taffy.newLeaf(relative_style);
        var cleared_style = box_style;
        cleared_style.clear = .both;
        const cleared_box = try taffy.newLeaf(cleared_style);

        var nested_margin = Rect(LengthPercentageAuto).zero;
        nested_margin.left = LengthPercentageAuto.fromLength(20.0);
        nested_margin.right = LengthPercentageAuto.fromLength(30.0);
        var nested_padding = Rect(LengthPercentage).zero;
        nested_padding.left = LengthPercentage.fromLength(5.0);
        nested_padding.right = LengthPercentage.fromLength(7.0);
        var nested_border = Rect(LengthPercentage).zero;
        nested_border.left = LengthPercentage.fromLength(3.0);
        nested_border.right = LengthPercentage.fromLength(5.0);
        const nested = try taffy.newWithChildren(
            .{
                .display = .block,
                .direction = direction,
                .margin = nested_margin,
                .padding = nested_padding,
                .border = nested_border,
            },
            &.{ relative_box, cleared_box },
        );
        const root = try taffy.newWithChildren(
            .{
                .display = .flow_root,
                .direction = direction,
                .size = .{ .width = Dimension.fromLength(200.0), .height = Dimension.auto },
                .padding = Rect(LengthPercentage).fromLength(10.0),
            },
            &.{ left_float, right_float, nested },
        );

        try taffy.computeLayout(root, Size(AvailableSpace).max_content);

        const relative_layout = taffy.layout(relative_box);
        try testing.expectEqual(point(47.0, 0.0), relative_layout.location);
        try testing.expectEqual(@as(f32, 32.0), relative_layout.margin.left);
        try testing.expectEqual(@as(f32, 38.0), relative_layout.margin.right);
        const cleared_layout = taffy.layout(cleared_box);
        try testing.expectEqual(point(43.0, 40.0), cleared_layout.location);
        try testing.expectEqual(@as(f32, 35.0), cleared_layout.margin.left);
        try testing.expectEqual(@as(f32, 35.0), cleared_layout.margin.right);
        const nested_layout = taffy.layout(nested);
        try testing.expectEqual(point(30.0, 10.0), nested_layout.location);
        try testing.expectEqual(@as(f32, 20.0), nested_layout.margin.left);
        try testing.expectEqual(@as(f32, 30.0), nested_layout.margin.right);
    }
}
