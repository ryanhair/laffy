const std = @import("std");
const laffy = @import("laffy");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Point = laffy.Point;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AlignItems = laffy.AlignItems;
const Baselines = laffy.tree.Baselines;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const NodeId = laffy.NodeId;

/// A node context that pairs an intrinsic size with a first-baseline offset
/// (measured from the node's top edge in the block axis).
const BaselineContext = struct {
    size: Size(f32),
    baseline_y: ?f32,
};

const TaffyTree = laffy.TaffyTree(BaselineContext);

const BaselineMeasurer = struct {
    pub fn measure(_: BaselineMeasurer, _: LayoutInput, _: NodeId, context: ?*BaselineContext, _: *const Style) LayoutOutput {
        const ctx = context orelse return LayoutOutput.hidden;
        return LayoutOutput.fromSizesAndBaselines(
            ctx.size,
            laffy.tree.ScrollableOverflow.zero,
            Baselines.fromFirst(ctx.baseline_y),
        );
    }
};

fn computeLayout(taffy: *TaffyTree, root: NodeId) !void {
    try taffy.computeLayoutWithMeasure(root, Size(laffy.AvailableSpace).max_content, BaselineMeasurer{});
}

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

fn bottomPadding(v: f32) Rect(LengthPercentage) {
    return .{
        .left = LengthPercentage.zero,
        .right = LengthPercentage.zero,
        .top = LengthPercentage.zero,
        .bottom = LengthPercentage.fromLength(v),
    };
}

// Two flex items with different intrinsic baselines are aligned along their baselines
// when the container uses `align-items: baseline`. The item with the smaller distance
// from its top to its baseline should be shifted down so that both baselines coincide.
test "flex_baseline_alignment_uses_measure_function_baseline" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // Child A: 50x50 box with baseline 40px from the top
    const child_a = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 50.0, .height = 50.0 }, .baseline_y = 40.0 },
    );

    // Child B: 30x30 box with baseline 20px from the top
    const child_b = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 30.0, .height = 30.0 }, .baseline_y = 20.0 },
    );

    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .row,
            .align_items = AlignItems.baseline,
            .size = .{ .width = dim(200.0), .height = dim(100.0) },
        },
        &.{ child_a, child_b },
    );

    try computeLayout(&taffy, root);

    const layout_a = taffy.layout(child_a);
    const layout_b = taffy.layout(child_b);

    // Child A sets the max baseline (40 px from its top), so it sits at the top of the line.
    try testing.expectEqual(@as(f32, 0.0), layout_a.location.y);
    // Child B is shifted down by (40 - 20) = 20 px so its baseline aligns with child A's.
    try testing.expectEqual(@as(f32, 20.0), layout_b.location.y);

    // Sanity-check: both children's baselines now sit at y = 40 in the container.
    try testing.expectEqual(layout_b.location.y + 20.0, layout_a.location.y + 40.0);
}

// A block container child that is a scroll container and has no baseline of its own
// synthesizes a baseline from its border-box bottom edge, which propagates to the
// block container's first baseline.
// See <https://github.com/w3c/csswg-drafts/issues/7660>
test "block_scroll_container_child_without_baseline_synthesizes_from_border_box" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // An empty `overflow: hidden` block, 30x30
    const scroll_child = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .overflow = .{ .x = .hidden, .y = .hidden },
            .size = .{ .width = dim(30.0), .height = dim(30.0) },
        },
        .{ .size = .{ .width = 30.0, .height = 30.0 }, .baseline_y = null },
    );

    // A block container wrapping the scroll container, with bottom padding so that the
    // synthesized baseline (30) differs from the wrapper's border-box bottom edge (50).
    const item_a = try taffy.newWithChildren(
        .{
            .display = .block,
            .size = .{ .width = dim(40.0), .height = .auto },
            .padding = bottomPadding(20.0),
        },
        &.{scroll_child},
    );

    // Reference item: 40x80 box with baseline 10px from the top
    const item_b = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 40.0, .height = 80.0 }, .baseline_y = 10.0 },
    );

    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .row,
            .align_items = AlignItems.baseline,
            .size = .{ .width = dim(200.0), .height = dim(120.0) },
        },
        &.{ item_a, item_b },
    );

    try computeLayout(&taffy, root);

    // Item A's baseline is synthesized at the scroll container's bottom border edge (30),
    // not at item A's own bottom edge (50). Item A sets the max baseline, so it sits at
    // the top and item B is shifted down by (30 - 10) = 20px.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(item_a).location.y);
    try testing.expectEqual(@as(f32, 20.0), taffy.layout(item_b).location.y);
}

// A block container child that is NOT a scroll container and has no baseline
// contributes no baseline to its block container parent.
test "block_non_scroll_container_child_without_baseline_contributes_nothing" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // An empty `overflow: visible` block, 30x30
    const plain_child = try taffy.newLeafWithContext(
        .{
            .display = .block,
            .size = .{ .width = dim(30.0), .height = dim(30.0) },
        },
        .{ .size = .{ .width = 30.0, .height = 30.0 }, .baseline_y = null },
    );

    const item_a = try taffy.newWithChildren(
        .{
            .display = .block,
            .size = .{ .width = dim(40.0), .height = .auto },
            .padding = bottomPadding(20.0),
        },
        &.{plain_child},
    );

    // Reference item: 40x80 box with baseline 10px from the top
    const item_b = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 40.0, .height = 80.0 }, .baseline_y = 10.0 },
    );

    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .row,
            .align_items = AlignItems.baseline,
            .size = .{ .width = dim(200.0), .height = dim(120.0) },
        },
        &.{ item_a, item_b },
    );

    try computeLayout(&taffy, root);

    // Item A has no baseline, so the flexbox algorithm synthesizes one at its border-box
    // bottom edge (50). Item B is shifted down by (50 - 10) = 40px.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(item_a).location.y);
    try testing.expectEqual(@as(f32, 40.0), taffy.layout(item_b).location.y);
}

// A block container child that is a scroll container contributes its content baseline
// clamped to its border box, so baselines of clipped content cannot leak below the
// child's border-box bottom edge.
// See <https://github.com/w3c/csswg-drafts/issues/7660>
test "block_scroll_container_child_baseline_is_clamped_to_border_box" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    // Content with a baseline 48px from the top, inside a 30px tall scroll container
    const content = try taffy.newLeafWithContext(
        .{ .display = .block },
        .{ .size = .{ .width = 30.0, .height = 60.0 }, .baseline_y = 48.0 },
    );

    const scroll_child = try taffy.newWithChildren(
        .{
            .display = .block,
            .overflow = .{ .x = .hidden, .y = .hidden },
            .size = .{ .width = dim(30.0), .height = dim(30.0) },
        },
        &.{content},
    );

    const item_a = try taffy.newWithChildren(
        .{
            .display = .block,
            .size = .{ .width = dim(40.0), .height = .auto },
            .padding = bottomPadding(20.0),
        },
        &.{scroll_child},
    );

    // Reference item: 40x80 box with baseline 10px from the top
    const item_b = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 40.0, .height = 80.0 }, .baseline_y = 10.0 },
    );

    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .row,
            .align_items = AlignItems.baseline,
            .size = .{ .width = dim(200.0), .height = dim(120.0) },
        },
        &.{ item_a, item_b },
    );

    try computeLayout(&taffy, root);

    // The content baseline (48) is clamped to the scroll container's border-box height (30).
    // Item A's baseline is 30, so item B is shifted down by (30 - 10) = 20px.
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(item_a).location.y);
    try testing.expectEqual(@as(f32, 20.0), taffy.layout(item_b).location.y);
}

// Sanity-check: without `align-items: baseline`, items align at the cross-start edge
// regardless of the baseline reported by the measure function.
test "flex_baseline_is_ignored_when_alignment_is_not_baseline" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child_a = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 50.0, .height = 50.0 }, .baseline_y = 40.0 },
    );
    const child_b = try taffy.newLeafWithContext(
        .{},
        .{ .size = .{ .width = 30.0, .height = 30.0 }, .baseline_y = 20.0 },
    );

    const root = try taffy.newWithChildren(
        .{
            .display = .flex,
            .flex_direction = .row,
            .align_items = AlignItems.flex_start,
            .size = .{ .width = dim(200.0), .height = dim(100.0) },
        },
        &.{ child_a, child_b },
    );

    try computeLayout(&taffy, root);

    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child_a).location.y);
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child_b).location.y);
}
