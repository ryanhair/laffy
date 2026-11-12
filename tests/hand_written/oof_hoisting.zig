//! Tests for out-of-flow hoisting: absolute/fixed boxes are laid out by their containing
//! block (nearest positioned ancestor, or the root) rather than by their DOM parent, and
//! their `Layout.location` is relative to that containing block.
const std = @import("std");
const laffy = @import("laffy");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const NodeId = laffy.NodeId;
const Display = laffy.Display;
const Position = laffy.Position;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const length = laffy.style_helpers.length;
const auto = laffy.style_helpers.auto;
const TaffyTree = laffy.TaffyTree(void);

const max_content = Size(AvailableSpace).max_content;
const displays = [_]Display{ .block, .flex, .grid };

fn lpa(v: f32) LengthPercentageAuto {
    return LengthPercentageAuto.fromLength(v);
}

fn size(w: f32, h: f32) Size(Dimension) {
    return .{ .width = length(Dimension, w), .height = length(Dimension, h) };
}

fn leafStyle(width: f32, height: f32) Style {
    return .{ .size = size(width, height) };
}

/// Insets with only `left` and `top` set
fn insetLeftTop(left: f32, top: f32) Rect(LengthPercentageAuto) {
    return .{ .left = lpa(left), .top = lpa(top), .right = auto(LengthPercentageAuto), .bottom = auto(LengthPercentageAuto) };
}

fn point(x: f32, y: f32) Point(f32) {
    return .{ .x = x, .y = y };
}

fn expectSize(w: f32, h: f32, actual: Size(f32)) !void {
    try testing.expectEqual(Size(f32){ .width = w, .height = h }, actual);
}

// An absolute box whose parent is static is positioned relative to the nearest
// positioned ancestor, with a containing-block-relative location.
test "absolute_skips_static_parent" {
    for (displays) |display| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const abs = try tree.newLeaf(.{
            .position = .absolute,
            .inset = insetLeftTop(10.0, 20.0),
            .size = size(30.0, 30.0),
        });
        // Static in-flow parent, offset from the containing block's origin
        const static_parent = try tree.newWithChildren(
            .{
                .display = display,
                .margin = insetLeftTop(40.0, 40.0),
                .size = size(50.0, 50.0),
            },
            &.{abs},
        );
        const cb = try tree.newWithChildren(
            .{
                .display = display,
                .position = .relative,
                .size = size(200.0, 200.0),
            },
            &.{static_parent},
        );

        try tree.computeLayout(cb, max_content);

        // Location is relative to the containing block, not the static parent
        const layout = tree.layout(abs);
        try testing.expectEqual(point(10.0, 20.0), layout.location);
        try expectSize(30.0, 30.0, layout.size);
    }
}

// The containing block's hoisted children are recorded in document order: direct
// out-of-flow children interleaved with boxes hoisted out of in-flow children's subtrees.
test "hoisted_children_are_in_document_order" {
    for (displays) |display| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const abs_style: Style = .{
            .position = .absolute,
            .size = size(10.0, 10.0),
        };
        const inflow_style: Style = .{ .display = display, .size = size(20.0, 20.0) };

        // Children of `cb`, in document order:
        //   [direct_a, static_b(> nested_b), static_c(> nested_c), direct_d, static_e(> nested_e)]
        const direct_a = try tree.newLeaf(abs_style);
        const nested_b = try tree.newLeaf(abs_style);
        const static_b = try tree.newWithChildren(inflow_style, &.{nested_b});
        const nested_c = try tree.newLeaf(abs_style);
        const static_c = try tree.newWithChildren(inflow_style, &.{nested_c});
        const direct_d = try tree.newLeaf(abs_style);
        const nested_e = try tree.newLeaf(abs_style);
        const static_e = try tree.newWithChildren(inflow_style, &.{nested_e});
        const cb = try tree.newWithChildren(
            .{
                .display = display,
                .position = .relative,
                .flex_wrap = .wrap_reverse,
                .flex_direction = .row_reverse,
                .size = size(50.0, 200.0),
            },
            &.{ direct_a, static_b, static_c, direct_d, static_e },
        );

        try tree.computeLayout(cb, max_content);

        try testing.expectEqualSlices(
            NodeId,
            &.{ direct_a, nested_b, nested_c, direct_d, nested_e },
            tree.hoistedChildren(cb),
        );
    }
}

// An absolute box with auto insets is placed at its static position: where it would
// have been placed in the normal flow of its DOM parent, expressed relative to its
// containing block.
test "static_position_is_containing_block_relative" {
    for (displays) |display| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const abs = try tree.newLeaf(.{
            .position = .absolute,
            .size = size(30.0, 30.0),
        });
        const sibling = try tree.newLeaf(leafStyle(50.0, 50.0));
        const static_parent = try tree.newWithChildren(
            .{
                .display = display,
                .margin = insetLeftTop(40.0, 40.0),
                .size = size(100.0, 100.0),
            },
            &.{ sibling, abs },
        );
        const cb = try tree.newWithChildren(
            .{
                .display = display,
                .position = .relative,
                .size = size(200.0, 200.0),
            },
            &.{static_parent},
        );

        try tree.computeLayout(cb, max_content);

        // Static position is offset by the static parent's location within the CB
        const layout = tree.layout(abs);
        const expected: Point(f32) = switch (display) {
            // Block: below the in-flow sibling
            .block => point(40.0, 90.0),
            // Flex/grid: placed as if it were the sole item, at the content-box start
            .flex => point(40.0, 40.0),
            .grid => point(40.0, 40.0),
            else => unreachable,
        };
        try testing.expectEqual(expected, layout.location);
    }
}

// A fixed box bubbles past positioned (non-transformed) ancestors all the way to the root.
test "fixed_hoists_to_root" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const fixed = try tree.newLeaf(.{
        .position = .fixed,
        .inset = insetLeftTop(5.0, 5.0),
        .size = size(10.0, 10.0),
    });
    const positioned_parent = try tree.newWithChildren(
        .{
            .position = .relative,
            .margin = insetLeftTop(50.0, 50.0),
            .size = size(50.0, 50.0),
        },
        &.{fixed},
    );
    const root = try tree.newWithChildren(
        .{ .size = size(200.0, 200.0) },
        &.{positioned_parent},
    );

    try tree.computeLayout(root, max_content);

    // Location is relative to the root, ignoring the positioned (but not fixed-CB) parent
    try testing.expectEqual(point(5.0, 5.0), tree.layout(fixed).location);
}

// An absolute descendant of an absolute box resolves against the absolute box
// (which is positioned and therefore a containing block).
test "absolute_within_absolute" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const inner = try tree.newLeaf(.{
        .position = .absolute,
        .inset = .{ .right = lpa(0.0), .bottom = lpa(0.0), .left = auto(LengthPercentageAuto), .top = auto(LengthPercentageAuto) },
        .size = size(10.0, 10.0),
    });
    const outer = try tree.newWithChildren(
        .{
            .position = .absolute,
            .inset = insetLeftTop(20.0, 20.0),
            .size = size(50.0, 50.0),
        },
        &.{inner},
    );
    const root = try tree.newWithChildren(
        .{ .size = size(200.0, 200.0) },
        &.{outer},
    );

    try tree.computeLayout(root, max_content);

    try testing.expectEqual(point(20.0, 20.0), tree.layout(outer).location);
    // Relative to `outer`, its containing block
    try testing.expectEqual(point(40.0, 40.0), tree.layout(inner).location);
}

// A fixed descendant surfaced while laying out an absolute box (at the abspos box's
// containing block) is re-swept and continues bubbling to the root.
test "fixed_within_absolute_hoists_to_root" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const fixed = try tree.newLeaf(.{
        .position = .fixed,
        .inset = insetLeftTop(1.0, 2.0),
        .size = size(10.0, 10.0),
    });
    const abs = try tree.newWithChildren(
        .{
            .position = .absolute,
            .inset = insetLeftTop(20.0, 20.0),
            .size = size(50.0, 50.0),
        },
        &.{fixed},
    );
    const cb = try tree.newWithChildren(
        .{
            .position = .relative,
            .margin = insetLeftTop(30.0, 30.0),
            .size = size(100.0, 100.0),
        },
        &.{abs},
    );
    const root = try tree.newWithChildren(
        .{ .size = size(200.0, 200.0) },
        &.{cb},
    );

    try tree.computeLayout(root, max_content);

    try testing.expectEqual(point(20.0, 20.0), tree.layout(abs).location);
    // Root-relative, unaffected by `cb` or `abs` offsets
    try testing.expectEqual(point(1.0, 2.0), tree.layout(fixed).location);
}

// Hoisting still works when the intermediate (static) ancestors hit the layout cache:
// the cached `LayoutOutput` re-propagates the candidates without descending into
// the skipped subtree.
test "hoisting_survives_cache_hits" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const abs = try tree.newLeaf(.{
        .position = .absolute,
        .inset = insetLeftTop(10.0, 20.0),
        .size = size(30.0, 30.0),
    });
    var static_ancestor = try tree.newWithChildren(leafStyle(50.0, 50.0), &.{abs});
    for (0..3) |_| {
        static_ancestor = try tree.newWithChildren(leafStyle(50.0, 50.0), &.{static_ancestor});
    }
    const cb = try tree.newWithChildren(
        .{
            .position = .relative,
            .size = size(200.0, 200.0),
        },
        &.{static_ancestor},
    );

    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);

    // Recompute without dirtying anything: everything hits the cache
    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);

    // Relayout with the same constraints: intermediate nodes hit the cache
    tree.markDirty(cb);
    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);

    // Changing the abspos box's styles relays it out through its containing block
    var new_style = tree.style(abs).*;
    new_style.inset.left = lpa(15.0);
    tree.setStyle(abs, new_style);
    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(15.0, 20.0), tree.layout(abs).location);
}

// When the root's layout is served from the cache, the root positioning pass must not
// re-add fixed boxes to the root's (still valid) hoisted-children list.
test "cached_root_does_not_duplicate_hoisted_children" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const fixed = try tree.newLeaf(.{
        .position = .fixed,
        .size = size(30.0, 30.0),
    });
    const inner = try tree.newWithChildren(leafStyle(50.0, 50.0), &.{fixed});
    const root = try tree.newWithChildren(leafStyle(200.0, 200.0), &.{inner});

    try tree.computeLayout(root, max_content);
    try testing.expectEqualSlices(NodeId, &.{fixed}, tree.hoistedChildren(root));

    try tree.computeLayout(root, max_content);
    try testing.expectEqualSlices(NodeId, &.{fixed}, tree.hoistedChildren(root));

    tree.markDirty(root);
    try tree.computeLayout(root, max_content);
    try testing.expectEqualSlices(NodeId, &.{fixed}, tree.hoistedChildren(root));
}

// Rounding recurses into hoisted boxes via their containing block, so a hoisted box's
// rounded location is computed against the containing block's cumulative offset.
test "rounding_uses_containing_block_offsets" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    tree.enableRounding();
    const abs = try tree.newLeaf(.{
        .position = .absolute,
        .inset = insetLeftTop(10.6, 10.6),
        .size = size(10.0, 10.0),
    });
    const static_parent = try tree.newWithChildren(leafStyle(50.0, 50.0), &.{abs});
    const cb = try tree.newWithChildren(
        .{
            .position = .relative,
            .margin = insetLeftTop(20.3, 20.3),
            .size = size(100.0, 100.0),
        },
        &.{static_parent},
    );
    const root = try tree.newWithChildren(
        .{ .size = size(200.0, 200.0) },
        &.{cb},
    );

    try tree.computeLayout(root, max_content);

    // cb rounds to x=20; abs at cumulative 20.3+10.6=30.9 rounds to 31, i.e. 11 relative to cb
    try testing.expectEqual(point(20.0, 20.0), tree.layout(cb).location);
    try testing.expectEqual(point(11.0, 11.0), tree.layout(abs).location);
}

// When an intermediate ancestor becomes positioned (with a hot cache), it claims
// the hoisted box away from the outer containing block, and vice versa when it
// becomes static again.
test "claim_change_relayouts_with_hot_cache" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const abs = try tree.newLeaf(.{
        .position = .absolute,
        .inset = insetLeftTop(10.0, 20.0),
        .size = size(30.0, 30.0),
    });
    const middle_style: Style = .{
        .margin = insetLeftTop(40.0, 40.0),
        .size = size(50.0, 50.0),
    };
    const middle = try tree.newWithChildren(middle_style, &.{abs});
    const cb = try tree.newWithChildren(
        .{
            .position = .relative,
            .size = size(200.0, 200.0),
        },
        &.{middle},
    );

    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);

    // Make the middle node positioned: it now claims the abspos box, whose
    // location becomes relative to the middle node.
    var positioned_middle = middle_style;
    positioned_middle.position = .relative;
    tree.setStyle(middle, positioned_middle);
    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);
    // Page position moved by the middle node's offset
    try testing.expectEqual(point(40.0, 40.0), tree.layout(middle).location);

    // Back to static: the outer containing block claims it again.
    tree.setStyle(middle, middle_style);
    try tree.computeLayout(cb, max_content);
    try testing.expectEqual(point(10.0, 20.0), tree.layout(abs).location);
    try testing.expectEqual(point(40.0, 40.0), tree.layout(middle).location);
}

// A fixed box hoisted to the root moves to an intermediate ancestor when that
// ancestor starts claiming fixed boxes (position change with a hot cache), and back.
test "fixed_claim_change_relayouts_with_hot_cache" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const fixed = try tree.newLeaf(.{
        .position = .fixed,
        .inset = insetLeftTop(5.0, 5.0),
        .size = size(10.0, 10.0),
    });
    const abs_style: Style = .{
        .position = .absolute,
        .inset = insetLeftTop(50.0, 50.0),
        .size = size(80.0, 80.0),
    };
    const abs = try tree.newWithChildren(abs_style, &.{fixed});
    const root = try tree.newWithChildren(
        .{ .size = size(200.0, 200.0) },
        &.{abs},
    );

    try tree.computeLayout(root, max_content);
    // Fixed box is claimed by the root, not the abspos ancestor
    try testing.expectEqual(point(5.0, 5.0), tree.layout(fixed).location);
    try testing.expectEqual(point(50.0, 50.0), tree.layout(abs).location);

    // Dirty only the fixed box: it must still be re-laid out via the root
    var new_fixed_style = tree.style(fixed).*;
    new_fixed_style.inset.left = lpa(7.0);
    tree.setStyle(fixed, new_fixed_style);
    try tree.computeLayout(root, max_content);
    try testing.expectEqual(point(7.0, 5.0), tree.layout(fixed).location);
}

// Content changes inside a hoisted subtree relayout correctly through the
// containing block even when unrelated siblings hit the cache.
test "content_change_inside_hoisted_subtree" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const inner = try tree.newLeaf(leafStyle(10.0, 10.0));
    const abs = try tree.newWithChildren(
        .{
            .position = .absolute,
            .inset = insetLeftTop(10.0, 10.0),
        },
        &.{inner},
    );
    const static_parent = try tree.newWithChildren(leafStyle(50.0, 50.0), &.{abs});
    const cb = try tree.newWithChildren(
        .{
            .position = .relative,
            .size = size(200.0, 200.0),
        },
        &.{static_parent},
    );

    try tree.computeLayout(cb, max_content);
    try expectSize(10.0, 10.0, tree.layout(abs).size);

    // Grow the inner leaf: the hoisted abspos box must resize
    tree.setStyle(inner, leafStyle(20.0, 30.0));
    try tree.computeLayout(cb, max_content);
    try expectSize(20.0, 30.0, tree.layout(abs).size);
}

// Hiding an ancestor of an out-of-flow box zeroes the box's rounded layout, whether or not
// the hidden ancestor is the box's containing block.
test "hiding_an_ancestor_zeroes_out_of_flow_layout" {
    for ([_]Position{ .absolute, .fixed }) |position| {
        for ([_]Position{ .static, .relative }) |parent_position| {
            var tree = try TaffyTree.init(testing.allocator);
            defer tree.deinit();
            var oof_style = leafStyle(30.0, 30.0);
            oof_style.position = position;
            const oof = try tree.newLeaf(oof_style);
            var parent_style = leafStyle(50.0, 50.0);
            parent_style.position = parent_position;
            const parent = try tree.newWithChildren(parent_style, &.{oof});
            const root = try tree.newWithChildren(leafStyle(200.0, 200.0), &.{parent});

            try tree.computeLayout(root, max_content);
            try expectSize(30.0, 30.0, tree.layout(oof).size);

            var hidden_style = parent_style;
            hidden_style.display = .none;
            tree.setStyle(parent, hidden_style);
            try tree.computeLayout(root, max_content);
            try testing.expectEqual(Size(f32).zero, tree.unroundedLayout(oof).size);
            try testing.expectEqual(Size(f32).zero, tree.layout(oof).size);
        }
    }
}
