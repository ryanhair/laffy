//! `fit-content()` with a `calc()` limit. laffy stores the calc() as an opaque pointer which is resolved
//! through `LayoutPartialTree.resolveCalcValue`, so these tests use a minimal custom tree whose calc
//! values are `pct * basis + px`.
const std = @import("std");
const laffy = @import("laffy");

const testing = std.testing;
const traits = laffy.traits;
const Style = laffy.Style;
const Size = laffy.Size;
const Cache = laffy.Cache;
const Layout = laffy.Layout;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const LayoutError = laffy.tree.LayoutError;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const LengthPercentage = laffy.LengthPercentage;
const AvailableSpace = laffy.AvailableSpace;
const GridTemplateComponent = laffy.GridTemplateComponent;
const BlockContext = laffy.BlockContext;
const DetailedLayoutInfo = laffy.DetailedLayoutInfo;

/// A calc() value of the form `pct * basis + px`. 8-byte aligned so that its address can be tagged.
const Calc = struct {
    px: f32 align(8),
    pct: f32,
};

/// Upstream leaks the calc value with `Box::leak`; the page allocator is not leak-checked.
fn calc(px: f32, pct: f32) LengthPercentage {
    const ptr = std.heap.page_allocator.create(Calc) catch @panic("OOM");
    ptr.* = .{ .px = px, .pct = pct };
    return LengthPercentage.calc(ptr);
}

fn resolveCalc(val: *const anyopaque, basis: f32) f32 {
    const c: *const Calc = @ptrCast(@alignCast(val));
    return c.pct * basis + c.px;
}

/// The `calc` resolver handed to `computeLeafLayout`
const CalcResolver = struct {
    pub fn resolveCalcValue(_: CalcResolver, val: *const anyopaque, basis: f32) f32 {
        return resolveCalc(val, basis);
    }
};

const Kind = union(enum) {
    block,
    grid,
    /// A leaf with the given min-content width, max-content width and height
    leaf: struct {
        min_width: f32,
        max_width: f32,
        height: f32,
    },
};

const root_id = NodeId.new(std.math.maxInt(u64));

const Node = struct {
    kind: Kind,
    style: Style,
    cache: Cache = .{},
    layout: Layout = Layout.withOrder(0),
    children: []Node,
    hoisted_children: std.ArrayList(NodeId) = .empty,

    fn new(kind: Kind, style: Style, children: []Node) Node {
        return .{ .kind = kind, .style = style, .children = children };
    }

    fn leaf(min_width: f32, max_width: f32, height: f32, style: Style) Node {
        return new(.{ .leaf = .{ .min_width = min_width, .max_width = max_width, .height = height } }, style, &.{});
    }

    fn deinit(self: *Node) void {
        self.cache.deinit(testing.allocator);
        self.hoisted_children.deinit(testing.allocator);
        for (self.children) |*child| child.deinit();
    }

    fn nodeFromId(self: *const Node, node_id: NodeId) *const Node {
        if (node_id.inner == root_id.inner) {
            return self;
        } else {
            return &self.children[node_id.toUsize()];
        }
    }

    fn nodeFromIdMut(self: *Node, node_id: NodeId) *Node {
        if (node_id.inner == root_id.inner) {
            return self;
        } else {
            return &self.children[node_id.toUsize()];
        }
    }

    fn computeLayout(self: *Node, available_space: Size(AvailableSpace)) !void {
        try laffy.computeRootLayout(self, root_id, available_space);
    }

    const ChildIter = struct {
        index: usize,
        end: usize,

        pub fn next(self: *ChildIter) ?NodeId {
            if (self.index >= self.end) return null;
            defer self.index += 1;
            return NodeId.fromUsize(self.index);
        }
    };

    // TraversePartialTree

    pub fn childIds(self: *const Node, _: NodeId) ChildIter {
        return .{ .index = 0, .end = self.children.len };
    }

    pub fn childCount(self: *const Node, _: NodeId) usize {
        return self.children.len;
    }

    pub fn getChildId(_: *const Node, _: NodeId, index: usize) NodeId {
        return NodeId.fromUsize(index);
    }

    // LayoutPartialTree

    pub fn allocator(_: *const Node) std.mem.Allocator {
        return testing.allocator;
    }

    pub fn getCoreContainerStyle(self: *const Node, node_id: NodeId) *const Style {
        return &self.nodeFromId(node_id).style;
    }

    pub fn setUnroundedLayout(self: *Node, node_id: NodeId, l: *const Layout) void {
        self.nodeFromIdMut(node_id).layout = l.*;
    }

    pub fn resolveCalcValue(_: *const Node, val: *const anyopaque, basis: f32) f32 {
        return resolveCalc(val, basis);
    }

    const Uncached = struct {
        pub fn compute(_: Uncached, parent: *Node, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
            const node = parent.nodeFromIdMut(node_id);
            switch (node.kind) {
                .block => return laffy.computeBlockLayout(node, node_id, inputs, null),
                .grid => return laffy.computeGridLayout(node, node_id, inputs),
                .leaf => |l| return laffy.computeLeafLayout(inputs, &node.style, CalcResolver{}, LeafContent{
                    .min_width = l.min_width,
                    .max_width = l.max_width,
                    .height = l.height,
                }),
            }
        }
    };

    const LeafContent = struct {
        min_width: f32,
        max_width: f32,
        height: f32,

        pub fn measure(self: LeafContent, known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
            const width = known_dimensions.width orelse switch (available_space.width) {
                .definite => |width| std.math.clamp(width, self.min_width, self.max_width),
                .min_content => self.min_width,
                .max_content => self.max_width,
            };
            return .{ .width = width, .height = known_dimensions.height orelse self.height };
        }
    };

    pub fn computeChildLayout(self: *Node, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
        return laffy.computeCachedLayout(self, node_id, inputs, Uncached{});
    }

    // LayoutContainingBlock

    pub fn getOofItemStyle(self: *const Node, node_id: NodeId) *const Style {
        return &self.nodeFromId(node_id).style;
    }

    pub fn clearHoistedChildren(self: *Node, node_id: NodeId) void {
        self.nodeFromIdMut(node_id).hoisted_children.clearRetainingCapacity();
    }

    pub fn addHoistedChildren(self: *Node, node_id: NodeId, hoisted: []const NodeId) LayoutError!void {
        try self.nodeFromIdMut(node_id).hoisted_children.appendSlice(testing.allocator, hoisted);
    }

    pub const getDetailedLayoutInfo = traits.LayoutContainingBlockDefaults.getDetailedLayoutInfo;

    // CacheTree

    pub fn cacheGet(self: *Node, node_id: NodeId, inputs: *const LayoutInput) LayoutError!?LayoutOutput {
        return self.nodeFromIdMut(node_id).cache.get(testing.allocator, inputs);
    }

    pub fn cacheStore(self: *Node, node_id: NodeId, inputs: *const LayoutInput, layout_output: LayoutOutput) void {
        self.nodeFromIdMut(node_id).cache.store(testing.allocator, inputs, layout_output);
    }

    pub fn cacheClear(self: *Node, node_id: NodeId) void {
        _ = self.nodeFromIdMut(node_id).cache.clear(testing.allocator);
    }

    // LayoutBlockContainer

    pub fn getBlockContainerStyle(self: *const Node, node_id: NodeId) *const Style {
        return &self.nodeFromId(node_id).style;
    }

    pub fn getBlockChildStyle(self: *const Node, child_node_id: NodeId) *const Style {
        return &self.nodeFromId(child_node_id).style;
    }

    pub const computeBlockChildLayout = traits.LayoutBlockContainerDefaults.computeBlockChildLayout;

    // LayoutGridContainer

    pub fn getGridContainerStyle(self: *const Node, node_id: NodeId) *const Style {
        return &self.nodeFromId(node_id).style;
    }

    pub fn getGridChildStyle(self: *const Node, child_node_id: NodeId) *const Style {
        return &self.nodeFromId(child_node_id).style;
    }

    pub const setDetailedGridInfo = traits.LayoutGridContainerDefaults.setDetailedGridInfo;
};

// Mirrors WPT css/css-grid/grid-definition/fit-content-track-sizing.html (`calculatedArgument`):
// a 300px tall grid with `grid-template-rows: fit-content(calc(10% + 5px))` and a 400px tall item
// with `min-height: 0` sizes the row to 35px.
test "grid_track_fit_content_calc_limit" {
    const rows = [_]GridTemplateComponent{GridTemplateComponent.fitContent(calc(5.0, 0.1))};
    var children = [_]Node{Node.leaf(
        0.0,
        0.0,
        400.0,
        .{ .min_size = .{ .width = LengthPercentageAuto.auto, .height = LengthPercentageAuto.fromLength(0.0) } },
    )};
    var root = Node.new(
        .grid,
        .{
            .display = .grid,
            .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.fromLength(300.0) },
            .grid_template_rows = &rows,
        },
        &children,
    );
    defer root.deinit();
    try root.computeLayout(Size(AvailableSpace).max_content);
    try testing.expectEqual(@as(f32, 35.0), root.children[0].layout.size.height);
}

// `width: fit-content(calc(10% + 70px))` on a block-level box in a 300px wide container is
// `fit-content(100px)`: the max-content width clamped by the limit and floored by the min-content width.
test "block_item_fit_content_calc_width" {
    const limit = Dimension.fitContentCalc(calc(70.0, 0.1).intoRaw().calcValue());
    var children = [_]Node{Node.leaf(
        50.0,
        400.0,
        10.0,
        .{ .size = .{ .width = limit, .height = Dimension.auto } },
    )};
    var root = Node.new(
        .block,
        .{
            .display = .block,
            .size = .{ .width = Dimension.fromLength(300.0), .height = Dimension.auto },
        },
        &children,
    );
    defer root.deinit();
    try root.computeLayout(Size(AvailableSpace).max_content);
    try testing.expectEqual(@as(f32, 100.0), root.children[0].layout.size.width);
}

/// Returns (container width, item width) for a single-column grid with the given column sizing
fn layoutSingleColumnGrid(
    column: GridTemplateComponent,
    container_width: Dimension,
    available_width: AvailableSpace,
) ![2]f32 {
    const columns = [_]GridTemplateComponent{column};
    var children = [_]Node{Node.leaf(50.0, 150.0, 10.0, Style{})};
    var root = Node.new(
        .grid,
        .{
            .display = .grid,
            .size = .{ .width = container_width, .height = Dimension.fromLength(40.0) },
            .grid_template_columns = &columns,
        },
        &children,
    );
    defer root.deinit();
    try root.computeLayout(.{ .width = available_width, .height = .max_content });
    return .{ root.layout.size.width, root.children[0].layout.size.width };
}

// A calc() limit resolves to the same value as the equivalent length or percentage limit, including
// when the container's width is indefinite (which re-runs track sizing against the container's own width).
test "grid_track_fit_content_calc_matches_equivalent_length_and_percentage" {
    // Definite container: calc(20% + 10px) of 200px == 50px
    const calc_result = try layoutSingleColumnGrid(
        GridTemplateComponent.fitContent(calc(10.0, 0.2)),
        Dimension.fromLength(200.0),
        .max_content,
    );
    const px_result = try layoutSingleColumnGrid(
        GridTemplateComponent.fitContent(LengthPercentage.fromLength(50.0)),
        Dimension.fromLength(200.0),
        .max_content,
    );
    try testing.expectEqual(px_result, calc_result);
    try testing.expectEqual(@as(f32, 50.0), calc_result[1]);

    // Indefinite (shrink-to-fit) container: calc(50% + 0px) == 50%
    for ([_]AvailableSpace{ .{ .definite = 200.0 }, .max_content, .min_content }) |available_width| {
        errdefer std.debug.print("available width: {any}\n", .{available_width});
        const calc_r = try layoutSingleColumnGrid(GridTemplateComponent.fitContent(calc(0.0, 0.5)), Dimension.auto, available_width);
        const pct_r = try layoutSingleColumnGrid(
            GridTemplateComponent.fitContent(LengthPercentage.fromPercent(0.5)),
            Dimension.auto,
            available_width,
        );
        try testing.expectEqual(pct_r, calc_r);
    }
    // ... and the percentage really is resolved against the container's width
    const container_width, const item_width =
        try layoutSingleColumnGrid(GridTemplateComponent.fitContent(calc(0.0, 0.5)), Dimension.auto, .max_content);
    try testing.expectEqual(@as(f32, 150.0), container_width);
    try testing.expectEqual(@as(f32, 75.0), item_width);
}
