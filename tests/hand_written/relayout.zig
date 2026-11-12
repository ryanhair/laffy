const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const NodeId = laffy.NodeId;
const Layout = laffy.Layout;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AlignSelf = laffy.AlignSelf;
const JustifyContent = laffy.JustifyContent;
const AvailableSpace = laffy.AvailableSpace;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

fn lpa(v: f32) LengthPercentageAuto {
    return LengthPercentageAuto.fromLength(v);
}

fn maxContent() Size(AvailableSpace) {
    return Size(AvailableSpace).max_content;
}

test "relayout" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node1 = try taffy.newLeaf(.{
        .size = .{ .width = dim(8.0), .height = dim(80.0) },
    });
    const node0 = try taffy.newWithChildren(
        .{
            .align_self = AlignSelf.center,
            .size = .{ .width = Dimension.auto, .height = Dimension.auto },
            // size: taffy::geometry::Size { width: Dimension::Percent(1.0), height: Dimension::Percent(1.0) },
        },
        &.{node1},
    );
    const node = try taffy.newWithChildren(
        .{
            .size = .{
                .width = Dimension.fromPercent(1.0),
                .height = Dimension.fromPercent(1.0),
            },
        },
        &.{node0},
    );
    try taffy.computeLayout(node, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } });
    const initial = taffy.layout(node).location;
    const initial0 = taffy.layout(node0).location;
    const initial1 = taffy.layout(node1).location;
    var i: usize = 1;
    while (i < 10) : (i += 1) {
        try taffy.computeLayout(node, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } });
        try testing.expectEqual(initial, taffy.layout(node).location);
        try testing.expectEqual(initial0, taffy.layout(node0).location);
        try testing.expectEqual(initial1, taffy.layout(node1).location);
    }
}

/// Checks the four layout results of the `Layout 1 / 2 / 3` toggle sequences: a node, then its
/// restyled versions (the hidden style, the shown style, the hidden style).
fn expectLayout(taffy: *const TaffyTree, node: NodeId, width: f32, height: f32) !void {
    const layout = taffy.layout(node);
    try testing.expectEqual(@as(f32, 0.0), layout.location.x);
    try testing.expectEqual(@as(f32, 0.0), layout.location.y);
    try testing.expectEqual(width, layout.size.width);
    try testing.expectEqual(height, layout.size.height);
}

fn hiddenStyle() Style {
    return .{
        .display = .none,
        .size = .{ .width = dim(100.0), .height = dim(100.0) },
    };
}

fn shownStyle(display: laffy.Display) Style {
    return .{
        .display = display,
        .size = .{ .width = dim(100.0), .height = dim(100.0) },
    };
}

test "toggle_root_display_none" {
    const hidden_style = hiddenStyle();
    const flex_style = shownStyle(.flex);

    // Setup
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(hidden_style);

    // Layout 1 (None)
    try taffy.computeLayout(node, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);

    // Layout 2 (Flex)
    taffy.setStyle(node, flex_style);
    try taffy.computeLayout(node, maxContent());
    try expectLayout(&taffy, node, 100.0, 100.0);

    // Layout 3 (None)
    taffy.setStyle(node, hidden_style);
    try taffy.computeLayout(node, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);
}

test "toggle_root_display_none_with_children" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeaf(.{ .size = .{ .width = dim(800.0), .height = dim(100.0) } });

    const parent = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(800.0), .height = dim(100.0) } },
        &.{child},
    );

    const root = try taffy.newWithChildren(Style{}, &.{parent});
    try taffy.computeLayout(root, maxContent());
    try testing.expectEqual(@as(f32, 800.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);

    taffy.setStyle(root, .{ .display = .none });
    try taffy.computeLayout(root, maxContent());
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(child).size.height);

    taffy.setStyle(root, Style{});
    try taffy.computeLayout(root, maxContent());
    try testing.expectEqual(@as(f32, 800.0), taffy.layout(parent).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(parent).size.height);
    try testing.expectEqual(@as(f32, 800.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "toggle_flex_child_display_none" {
    const hidden_style = hiddenStyle();
    const flex_style = shownStyle(.flex);

    // Setup
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(hidden_style);
    const root = try taffy.newWithChildren(flex_style, &.{node});

    // Layout 1 (None)
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);

    // Layout 2 (Flex)
    taffy.setStyle(node, flex_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 100.0, 100.0);

    // Layout 3 (None)
    taffy.setStyle(node, hidden_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);
}

test "toggle_flex_container_display_none" {
    const hidden_style = hiddenStyle();
    const flex_style = shownStyle(.flex);

    // Setup
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(hidden_style);
    const root = try taffy.newWithChildren(hidden_style, &.{node});

    // Layout 1 (None)
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 0.0, 0.0);

    // Layout 2 (Flex)
    taffy.setStyle(root, flex_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 100.0, 100.0);

    // Layout 3 (None)
    taffy.setStyle(root, hidden_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 0.0, 0.0);
}

test "toggle_grid_child_display_none" {
    const hidden_style = hiddenStyle();
    const grid_style = shownStyle(.grid);

    // Setup
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(hidden_style);
    const root = try taffy.newWithChildren(grid_style, &.{node});

    // Layout 1 (None)
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);

    // Layout 2 (Flex)
    taffy.setStyle(node, grid_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 100.0, 100.0);

    // Layout 3 (None)
    taffy.setStyle(node, hidden_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, node, 0.0, 0.0);
}

test "toggle_grid_container_display_none" {
    const hidden_style = hiddenStyle();
    const grid_style = shownStyle(.grid);

    // Setup
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(hidden_style);
    const root = try taffy.newWithChildren(hidden_style, &.{node});

    // Layout 1 (None)
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 0.0, 0.0);

    // Layout 2 (Flex)
    taffy.setStyle(root, grid_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 100.0, 100.0);

    // Layout 3 (None)
    taffy.setStyle(root, hidden_style);
    try taffy.computeLayout(root, maxContent());
    try expectLayout(&taffy, root, 0.0, 0.0);
}

test "relayout_is_stable_with_rounding" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    taffy.enableRounding();

    // <div style="width: 1920px; height: 1080px">
    //     <div style="width: 100%; left: 1.5px">
    //         <div style="width: 150px; justify-content: end">
    //             <div style="min-width: 300px" />
    //         </div>
    //     </div>
    // </div>

    const inner = try taffy.newLeaf(.{ .min_size = .{ .width = LengthPercentageAuto.fromLength(300.0), .height = LengthPercentageAuto.auto } });
    const wrapper = try taffy.newWithChildren(
        .{
            .size = .{ .width = dim(150.0), .height = Dimension.auto },
            .justify_content = JustifyContent.end,
        },
        &.{inner},
    );
    const outer = try taffy.newWithChildren(
        .{
            .size = .{ .width = Dimension.fromPercent(1.0), .height = Dimension.auto },
            .position = .relative,
            .inset = .{ .left = lpa(1.5), .right = LengthPercentageAuto.auto, .top = LengthPercentageAuto.auto, .bottom = LengthPercentageAuto.auto },
        },
        &.{wrapper},
    );
    const root = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(1920.0), .height = dim(1080.0) } },
        &.{outer},
    );

    // Compute and assert initial layout.

    try taffy.computeLayout(root, maxContent());

    const initial_root_layout = taffy.layout(root).*;
    try testing.expectEqual(@as(f32, 0.0), initial_root_layout.location.x);
    try testing.expectEqual(@as(f32, 0.0), initial_root_layout.location.y);
    try testing.expectEqual(@as(f32, 1920.0), initial_root_layout.size.width);
    try testing.expectEqual(@as(f32, 1080.0), initial_root_layout.size.height);

    const initial_outer_layout = taffy.layout(outer).*;
    try testing.expectEqual(@as(f32, 2.0), initial_outer_layout.location.x);
    try testing.expectEqual(@as(f32, 0.0), initial_outer_layout.location.y);
    try testing.expectEqual(@as(f32, 1920.0), initial_outer_layout.size.width);
    try testing.expectEqual(@as(f32, 1080.0), initial_outer_layout.size.height);

    const initial_wrapper_layout = taffy.layout(wrapper).*;
    try testing.expectEqual(@as(f32, 0.0), initial_wrapper_layout.location.x);
    try testing.expectEqual(@as(f32, 0.0), initial_wrapper_layout.location.y);
    try testing.expectEqual(@as(f32, 150.0), initial_wrapper_layout.size.width);
    try testing.expectEqual(@as(f32, 1080.0), initial_wrapper_layout.size.height);

    const initial_inner_layout = taffy.layout(inner).*;
    try testing.expectEqual(@as(f32, -150.0), initial_inner_layout.location.x);
    try testing.expectEqual(@as(f32, 0.0), initial_inner_layout.location.y);
    try testing.expectEqual(@as(f32, 300.0), initial_inner_layout.size.width);
    try testing.expectEqual(@as(f32, 1080.0), initial_inner_layout.size.height);

    // Recompute and assert that new layout marks initial layout each time
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        taffy.markDirty(root);
        try taffy.computeLayout(root, maxContent());

        const root_layout = taffy.layout(root);
        try testing.expectEqual(initial_root_layout.location.x, root_layout.location.x);
        try testing.expectEqual(initial_root_layout.location.y, root_layout.location.y);
        try testing.expectEqual(initial_root_layout.size.width, root_layout.size.width);
        try testing.expectEqual(initial_root_layout.size.height, root_layout.size.height);
        const outer_layout = taffy.layout(outer);
        try testing.expectEqual(initial_outer_layout.location.x, outer_layout.location.x);
        try testing.expectEqual(initial_outer_layout.location.y, outer_layout.location.y);
        try testing.expectEqual(initial_outer_layout.size.width, outer_layout.size.width);
        try testing.expectEqual(initial_outer_layout.size.height, outer_layout.size.height);
        const wrapper_layout = taffy.layout(wrapper);
        try testing.expectEqual(initial_wrapper_layout.location.x, wrapper_layout.location.x);
        try testing.expectEqual(initial_wrapper_layout.location.x, wrapper_layout.location.y);
        try testing.expectEqual(initial_wrapper_layout.size.width, wrapper_layout.size.width);
        try testing.expectEqual(initial_wrapper_layout.size.height, wrapper_layout.size.height);
        const inner_layout = taffy.layout(inner);
        try testing.expectEqual(initial_inner_layout.location.x, inner_layout.location.x);
        try testing.expectEqual(initial_inner_layout.location.y, inner_layout.location.y);
        try testing.expectEqual(initial_inner_layout.size.width, inner_layout.size.width);
        try testing.expectEqual(initial_inner_layout.size.height, inner_layout.size.height);
    }
}

/// Lays out the tree that `build` makes with `before`, restyles the node that `build` returns first
/// with `after` and lays the tree out again. Returns the unrounded layout of every node that `build`
/// returns, alongside those of a fresh tree built with `after` directly. `build` returns the root last.
const Built = [4]NodeId;
const Layouts = [4]Layout;
const RelayoutPair = struct { relaid: Layouts, fresh: Layouts };

fn unroundedLayouts(tree: *const TaffyTree, ids: Built) Layouts {
    var result: Layouts = undefined;
    for (ids, 0..) |id, i| result[i] = tree.unroundedLayout(id).*;
    return result;
}

fn relayoutAndFresh(
    before: Style,
    after: Style,
    build: *const fn (*TaffyTree, Style) error{OutOfMemory}!Built,
) !RelayoutPair {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const ids = try build(&tree, before);
    const root = ids[ids.len - 1];
    try tree.computeLayout(root, maxContent());
    tree.setStyle(ids[0], after);
    try tree.computeLayout(root, maxContent());

    var fresh = try TaffyTree.init(testing.allocator);
    defer fresh.deinit();
    const fresh_ids = try build(&fresh, after);
    try fresh.computeLayout(fresh_ids[fresh_ids.len - 1], maxContent());

    return .{ .relaid = unroundedLayouts(&tree, ids), .fresh = unroundedLayouts(&fresh, fresh_ids) };
}

/// ```html
/// <div style="display: block; width: 100px; height: 200px">
///   <div style="display: block; height: 50px">
///     <div style="display: block; height: 10px; margin-top: 20px"></div>
///   </div>
/// </div>
/// ```
///
/// The outer box then becomes `container`. The inner box's margin collapses through the middle box
/// only while the middle box is in a block formatting context with its parent: as a flex or grid item
/// the middle box establishes an independent formatting context, which contains the margin.
fn relayoutBlockParentAs(container_style: Style) !void {
    const size: Size(Dimension) = .{ .width = dim(100.0), .height = dim(200.0) };
    const block: Style = .{ .display = .block, .size = size };
    var container = container_style;
    container.size = size;

    const BuildTree = struct {
        fn build(tree: *TaffyTree, root_style: Style) error{OutOfMemory}!Built {
            var inner_margin = Rect(LengthPercentageAuto).zero;
            inner_margin.top = lpa(20.0);
            const inner = try tree.newLeaf(.{
                .display = .block,
                .size = .{ .width = Dimension.auto, .height = dim(10.0) },
                .margin = inner_margin,
            });
            const middle = try tree.newWithChildren(
                .{
                    .display = .block,
                    .size = .{ .width = Dimension.auto, .height = dim(50.0) },
                },
                &.{inner},
            );
            const root = try tree.newWithChildren(root_style, &.{middle});
            return .{ root, middle, inner, root };
        }
    };

    const result = try relayoutAndFresh(block, container, BuildTree.build);

    // the item is at the top of its container
    try testing.expectEqual(@as(f32, 0.0), result.fresh[1].location.y);
    // the item contains its child's margin
    try testing.expectEqual(@as(f32, 20.0), result.fresh[2].location.y);
    try testing.expectEqualDeep(result.fresh, result.relaid);
}

// A flex container lays its items out with `SizingMode::ContentSize` and without collapsible
// margins. The block container it was before used `SizingMode::InherentSize` and collapsible margins.
test "block_child_does_not_keep_collapsed_margin_as_flex_item" {
    try relayoutBlockParentAs(.{
        .display = .flex,
        .flex_direction = .column,
    });
}

// A grid container lays its items out with `SizingMode::InherentSize`, as the block container it
// was before did: only `vertical_margins_are_collapsible` differs between the two layout inputs.
test "block_child_does_not_keep_collapsed_margin_as_grid_item" {
    try relayoutBlockParentAs(.{ .display = .grid });
}

// ```html
// <div style="display: grid; width: 100px">
//   <div style="display: grid; flex-grow: 1; min-width: 40px; height: 20px"></div>
//   <div style="display: block; flex-grow: 1; height: 20px"></div>
// </div>
// ```
//
// The outer box then becomes `display: flex`. The grid container measured the first item with
// `SizingMode::InherentSize`, which applies the item's `min-width`. The flex container measures
// the same item's flex base size with `SizingMode::ContentSize`, which does not: both items
// have a flex base size of zero and grow equally.
test "flex_base_size_is_not_answered_by_an_inherent_size_measurement" {
    const BuildTree = struct {
        fn container(display: laffy.Display) Style {
            return .{ .display = display, .size = .{ .width = dim(100.0), .height = Dimension.auto } };
        }

        fn build(tree: *TaffyTree, root_style: Style) error{OutOfMemory}!Built {
            const first = try tree.newLeaf(.{
                .display = .grid,
                .flex_grow = 1.0,
                .size = .{ .width = Dimension.auto, .height = dim(20.0) },
                .min_size = .{ .width = LengthPercentageAuto.fromLength(40.0), .height = LengthPercentageAuto.auto },
            });
            const second = try tree.newLeaf(.{
                .display = .block,
                .flex_grow = 1.0,
                .size = .{ .width = Dimension.auto, .height = dim(20.0) },
            });
            const root = try tree.newWithChildren(root_style, &.{ first, second });
            return .{ root, first, second, root };
        }
    };

    const result = try relayoutAndFresh(BuildTree.container(.grid), BuildTree.container(.flex), BuildTree.build);

    try testing.expectEqual(@as(f32, 50.0), result.fresh[1].size.width);
    try testing.expectEqual(@as(f32, 50.0), result.fresh[2].size.width);
    try testing.expectEqualDeep(result.fresh, result.relaid);
}

test "a_percentage_height_is_not_reused_after_its_containing_block_loses_its_height" {
    // <div style="display:flex;flex-direction:column;width:78px">
    //   <div style="width:78px;height:62px">
    //     <div style="display:flex;width:31px;height:86%"> <div style="height:19px"></div>
    // </div></div></div>, then the middle block's height becomes auto: the item's
    // percentage no longer resolves (CSS 2.1 §10.5) and it is 19px tall, not 53.32px.
    const BuildTree = struct {
        fn block(height: Dimension) Style {
            return .{
                .display = .block,
                .size = .{ .width = Dimension.fromLength(78.0), .height = height },
            };
        }

        fn build(tree: *TaffyTree, middle_style: Style) error{OutOfMemory}!Built {
            const leaf = try tree.newLeaf(.{
                .display = .block,
                .size = .{ .width = Dimension.auto, .height = Dimension.fromLength(19.0) },
            });
            const item = try tree.newWithChildren(
                .{
                    .display = .flex,
                    .size = .{ .width = Dimension.fromLength(31.0), .height = Dimension.fromPercent(0.86) },
                },
                &.{leaf},
            );
            const middle = try tree.newWithChildren(middle_style, &.{item});
            const root = try tree.newWithChildren(
                .{
                    .display = .flex,
                    .flex_direction = .column,
                    .size = .{ .width = Dimension.fromLength(78.0), .height = Dimension.auto },
                },
                &.{middle},
            );
            return .{ middle, item, leaf, root };
        }
    };

    const result = try relayoutAndFresh(
        BuildTree.block(Dimension.fromLength(62.0)),
        BuildTree.block(Dimension.auto),
        BuildTree.build,
    );
    try testing.expectEqual(@as(f32, 19.0), result.fresh[1].size.height);
    try testing.expectEqualDeep(result.fresh, result.relaid);
}
