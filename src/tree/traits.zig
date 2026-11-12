//! The abstractions that make up the core of laffy's low-level API
//!
//! Upstream expresses the tree interface as Rust traits. In laffy they are duck-typed: layout
//! functions take `tree: anytype` (a pointer to the caller's tree type) and call the methods
//! listed below on it. This file is the contract: it documents, for each upstream trait, the exact
//! method names and signatures a tree type must provide, holds the reusable default method bodies
//! (in `*Defaults` namespaces, adopted with a declaration such as
//! `pub const resolveCalcValue = traits.LayoutPartialTreeDefaults.resolveCalcValue;`), ports the
//! provided extension methods (`LayoutPartialTreeExt`) as free functions, and offers cheap comptime
//! checks (`assertImplements`) that report a missing method with a clear message.
//!
//! Conventions used below:
//!
//!   - `Self` is the tree type. Layout functions receive `*Self`, so methods may take
//!     `self: *Self` or `self: *const Self` (or `Self` for small handle types).
//!   - `LayoutError` is `error{OutOfMemory}`, declared in `tree/layout.zig`. It is the explicit
//!     error set of every function in the layout call graph.
//!   - A method marked "default" has an upstream default implementation, available in the named
//!     `*Defaults` namespace. A method marked "required" has none.
//!   - Styles are returned as `*const Style`. A tree whose nodes store something else keeps a
//!     `Style` per node, or builds one on demand in memory that outlives the call.
//!
//! ## Trait dependency tree
//!
//! ```text
//! TraversePartialTree     - Access a node's children
//! ├──  LayoutPartialTree  - Run layout algorithms on a node and it's direct children
//! └──  TraverseTree       - Recursively access a node's descendants
//!     ├──  RoundTree      - Round a float-valued`  layout to integer pixels
//!     └──  PrintTree      - Print a debug representation of a node tree
//! ```
//!
//! | Interface             | Requires                | Enables                                                     |
//! | ---                   | ---                     | ---                                                         |
//! | `LayoutPartialTree`   | `TraversePartialTree`   | flexbox/grid/block layout, `computeLeafLayout`, `computeHiddenLayout`, `computeCachedLayout` (with `CacheTree`) |
//! | `LayoutContainingBlock` | `LayoutPartialTree`   | `computeOofLayout`, `computeRootLayout` (with `CacheTree`)  |
//! | `RoundTree`           | `TraverseTree`          | `roundLayout`                                               |
//! | `PrintTree`           | `TraverseTree`          | `printTree` / `writeTree`                                   |
//!
//! ## TraversePartialTree
//!
//! laffy's abstraction for downward tree traversal. It does *not* require access to any node other
//! than a single container node's immediate children unless the tree also intends to be a
//! `TraverseTree`.
//!
//!   - `childIds(self, parent_node_id: NodeId) ChildIter`: required. Returns an iterator over the
//!     ids of the node's children: any value with a `next(*ChildIter) ?NodeId` method.
//!   - `childCount(self, parent_node_id: NodeId) usize`: required.
//!   - `getChildId(self, parent_node_id: NodeId, child_index: usize) NodeId`: required.
//!
//! ## TraverseTree
//!
//! A marker interface with the same methods as `TraversePartialTree`. Providing it implies the
//! additional guarantee that the child methods can be used to recurse infinitely down the tree. It
//! is required by `RoundTree` and `PrintTree`. There is nothing to declare in Zig.
//!
//! ## LayoutPartialTree (requires TraversePartialTree)
//!
//! Any type that implements `LayoutPartialTree` can be laid out using laffy's algorithms. It
//! extends `TraversePartialTree` (not `TraverseTree`): the algorithms are designed to lay out a
//! single node that only has access to it's immediate children.
//!
//!   - `allocator(self) std.mem.Allocator`: required (laffy addition). The allocator for memory
//!     that outlives a single algorithm invocation: detailed grid info and the float context of a
//!     block formatting context. It must be a general-purpose allocator.
//!   - `scratch(self) *Scratch`: required (laffy addition). A `util.Scratch` allocator for the
//!     temporary lists of the algorithms, which release everything they took from it when they
//!     return. A tree normally just owns one and returns a pointer to it.
//!   - `oofCandidates(self, node_id: NodeId) []const OofCandidate`: required (laffy addition).
//!     The out-of-flow candidates most recently stored for the node (see `OofCandidate`). The
//!     slice must stay valid until the next `setOofCandidates` call for the same node.
//!   - `setOofCandidates(self, node_id: NodeId, candidates: []const OofCandidate) LayoutError!void`:
//!     required (laffy addition). Replace the node's stored candidates with a copy of
//!     `candidates`. Called for every node whose final layout is computed, so a tree that keeps
//!     one list per node always holds the candidates that belong to the node's current layout.
//!   - `getCoreContainerStyle(self, node_id: NodeId) *const Style`: required. Only called for the node
//!     being laid out, never for its children (those go through the `get*ChildStyle` methods), so
//!     it may be expressed in the node's own axes while child styles are expressed in the axes of
//!     the node laying them out.
//!   - `resolveCalcValue(self, val: CalcHandle, basis: f32) f32`: default
//!     (`LayoutPartialTreeDefaults.resolveCalcValue`, returns `0.0`). Resolves a `calc()` value.
//!     Because of this method, the tree itself is the `calc` resolver passed to `maybeResolve`
//!     and `resolveOrZero`.
//!   - `setUnroundedLayout(self, node_id: NodeId, layout: *const Layout) void`: required.
//!   - `computeChildLayout(self, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput`:
//!     required. Compute the specified node's size or full layout given the specified
//!     constraints.
//!
//! ## LayoutContainingBlock (requires LayoutPartialTree)
//!
//! The operations needed by the out-of-flow positioning pass (`computeOofLayout`), which lays out
//! the absolute/fixed boxes for which a node acts as the containing block. Required by
//! `computeOofLayout` and `computeRootLayout`.
//!
//!   - `getOofItemStyle(self, node_id: NodeId) *const Style`: required. The style of an
//!     out-of-flow box being positioned by its containing block, interpreted in the containing
//!     block's axes.
//!   - `clearHoistedChildren(self, node_id: NodeId) void`: required. Clear the list of
//!     out-of-flow boxes whose containing block is `node_id`. Called (exactly once) for each node
//!     laid out with `RunMode.perform_layout`, before the boxes it lays out are recorded with
//!     `addHoistedChildren`, so that lists recorded by previous layout runs do not persist.
//!   - `addHoistedChildren(self, node_id: NodeId, hoisted: []const NodeId) LayoutError!void`:
//!     required. Append to the list of out-of-flow boxes whose containing block is `node_id`.
//!     Called by each containing block for the boxes it lays out, and by `computeRootLayout` to
//!     record boxes (e.g. `position: fixed` boxes) positioned by the final root positioning pass.
//!     The recorded lists are consumed by `roundLayout` (out-of-flow boxes are rounded via their
//!     containing block rather than via their parent), and are also useful for consumers
//!     implementing paint/hit-testing traversals.
//!   - `getDetailedLayoutInfo(self, node_id: NodeId) *const DetailedLayoutInfo`: default
//!     (`LayoutContainingBlockDefaults.getDetailedLayoutInfo`, returns `.none`). Read back the
//!     detailed layout information most recently recorded for the node; used by the positioning
//!     pass to resolve the grid area of boxes whose containing block is a grid container.
//!
//! ## CacheTree
//!
//! Used by `computeCachedLayout` to store and retrieve cached layout results. The `Cache` struct
//! implements a per-node cache compatible with this interface.
//!
//!   - `cacheGet(self, node_id: NodeId, input: *const LayoutInput) ?LayoutOutput`: required.
//!   - `cacheStore(self, node_id: NodeId, input: *const LayoutInput, layout_output: LayoutOutput) void`:
//!     required.
//!   - `cacheClear(self, node_id: NodeId) void`: required.
//!
//! ## RoundTree (requires TraverseTree)
//!
//! Used by `roundLayout`, which takes a tree of unrounded float-valued layouts and performs
//! rounding to snap the values to the pixel grid. It requires full recursive access to the tree.
//!
//!   - `getUnroundedLayout(self, node_id: NodeId) Layout`: required.
//!   - `setFinalLayout(self, node_id: NodeId, layout: *const Layout) void`: required.
//!   - `isOutOfFlow(self, node_id: NodeId) bool`: required. Whether the node is an out-of-flow
//!     (absolute/fixed) box. Out-of-flow boxes are hoisted to their containing block, so
//!     `roundLayout` skips them when visiting a node's children and instead visits them via their
//!     containing block's hoisted child list. Return `true` for box-generating nodes whose
//!     position style is `absolute` or `fixed`, and `false` otherwise (including for
//!     `display: none` nodes).
//!   - `isRoundingCurrent(self, node_id: NodeId, parent_x: f32, parent_y: f32) bool`,
//!     `markRounded(self, node_id: NodeId, parent_x: f32, parent_y: f32) void` and
//!     `finishRounding(self) void`: optional (laffy addition), all three or none. They let
//!     `roundLayout` skip subtrees that have not changed since they were last rounded.
//!     `markRounded` is called after `setFinalLayout` for every node that is rounded, with the
//!     cumulative offset of the node's parent. `isRoundingCurrent` is called before a node is
//!     rounded and must return true only if rounding the node and everything below it against
//!     that offset would reproduce the final layouts they already hold. `finishRounding` is
//!     called once when `roundLayout` returns. See `TaffyTree` for an implementation.
//!   - `hoistedChildCount(self, node_id: NodeId) usize`: required. The number of out-of-flow
//!     boxes whose containing block is `node_id` (as recorded by `addHoistedChildren`).
//!   - `getHoistedChildId(self, node_id: NodeId, index: usize) NodeId`: required.
//!
//! ## PrintTree (requires TraverseTree)
//!
//! Used by `printTree` / `writeTree` to print a debug representation.
//!
//!   - `getDebugLabel(self, node_id: NodeId) []const u8`: required. A debug label for the node
//!     (typically the type of node: flexbox, grid, text, image, etc).
//!   - `getFinalLayout(self, node_id: NodeId) Layout`: required.
//!
//! ## LayoutFlexboxContainer (requires LayoutPartialTree)
//!
//!   - `getFlexboxContainerStyle(self, node_id: NodeId) *const Style`: required.
//!   - `getFlexboxChildStyle(self, child_node_id: NodeId) *const Style`: required.
//!     Interpreted in the container's axes.
//!
//! ## LayoutGridContainer (requires LayoutPartialTree)
//!
//!   - `getGridContainerStyle(self, node_id: NodeId) *const Style`: required.
//!   - `getGridChildStyle(self, child_node_id: NodeId) *const Style`: required. Interpreted in
//!     the container's axes.
//!   - `detailedGridInfo(self, node_id: NodeId, required: bool) LayoutError!?*DetailedGridInfo`:
//!     default (`LayoutGridContainerDefaults.detailedGridInfo`, returns `null`). The storage
//!     that the grid algorithm records the node's detailed grid info in (the computed size of
//!     each grid track and the placement of each grid item), or `null` to not record it.
//!     `required` is true when the grid has out-of-flow boxes to position: their grid areas
//!     are resolved from this info (through `getDetailedLayoutInfo`), and without it they are
//!     positioned against the grid's padding box. The algorithm
//!     refills the same `DetailedGridInfo` on every full layout, reusing its memory, so return
//!     the same pointer each time. Its lists are allocated with `self.allocator()`; the tree
//!     frees them with `DetailedGridInfo.deinit`. The info borrows line and area names from
//!     the grid container's style.
//!
//! ## LayoutBlockContainer (requires LayoutPartialTree)
//!
//!   - `getBlockContainerStyle(self, node_id: NodeId) *const Style`: required.
//!   - `getBlockChildStyle(self, child_node_id: NodeId) *const Style`: required. Interpreted
//!     in the container's axes.
//!   - `computeBlockChildLayout(self, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput`:
//!     default (`LayoutBlockContainerDefaults.computeBlockChildLayout`, ignores `block_ctx` and
//!     calls `computeChildLayout`). `BlockContext` is defined in `compute/block.zig`. The block
//!     algorithm calls this for children that participate in the parent's block formatting
//!     context, so that floats are positioned in the shared context.
//!
//! ## Provided methods (upstream `LayoutPartialTreeExt`)
//!
//! Free functions taking `tree: anytype`: `measureChildSize`, `measureChildSizeBoth`,
//! `performChildLayout` and `calc`.
const std = @import("std");
const CalcHandle = @import("../style/compact_length.zig").CalcHandle;
const geometry = @import("../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const Line = geometry.Line;
const Size = geometry.Size;
const AvailableSpace = @import("../style.zig").AvailableSpace;
const layout = @import("layout.zig");
const DetailedLayoutInfo = layout.DetailedLayoutInfo;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const SizingMode = layout.SizingMode;
const RequestedAxis = layout.RequestedAxis;
const NodeId = @import("node.zig").NodeId;
const BlockContext = @import("../compute/block.zig").BlockContext;
const DetailedGridInfo = @import("../compute/grid.zig").DetailedGridInfo;

// --- Default method bodies

/// Default methods of `LayoutPartialTree`
pub const LayoutPartialTreeDefaults = struct {
    /// Resolve calc value (default: `0.0`)
    pub fn resolveCalcValue(self: anytype, val: CalcHandle, basis: f32) f32 {
        _ = self;
        _ = val;
        _ = basis;
        return 0.0;
    }
};

/// Default methods of `LayoutContainingBlock`
pub const LayoutContainingBlockDefaults = struct {
    const none_info: DetailedLayoutInfo = .none;

    /// Read back the detailed layout information for `node_id` (default: `.none`, in which case
    /// absolutely positioned children of a grid container are positioned relative to the grid
    /// container's padding box instead of their grid area)
    pub fn getDetailedLayoutInfo(self: anytype, node_id: NodeId) *const DetailedLayoutInfo {
        _ = self;
        _ = node_id;
        return &none_info;
    }
};

/// Default methods of `LayoutGridContainer`
pub const LayoutGridContainerDefaults = struct {
    /// The storage for the node's detailed grid information (default: `null`, do not record it)
    pub fn detailedGridInfo(self: anytype, node_id: NodeId, required: bool) LayoutError!?*DetailedGridInfo {
        _ = self;
        _ = node_id;
        _ = required;
        return null;
    }
};

/// Default methods of `LayoutBlockContainer`
pub const LayoutBlockContainerDefaults = struct {
    /// Compute the specified node's size or full layout given the specified constraints
    /// (default: ignore `block_ctx` and call `computeChildLayout`)
    pub fn computeBlockChildLayout(self: anytype, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput {
        _ = block_ctx;
        return self.computeChildLayout(node_id, inputs);
    }
};

// --- Comptime interface checks

/// The interfaces that `assertImplements` can check
pub const Interface = enum {
    traverse_partial_tree,
    traverse_tree,
    layout_partial_tree,
    layout_containing_block,
    cache_tree,
    round_tree,
    print_tree,
    layout_flexbox_container,
    layout_grid_container,
    layout_block_container,

    /// The method names that the interface requires (including those of the interfaces it extends)
    pub fn methods(comptime self: Interface) []const []const u8 {
        const traverse = &[_][]const u8{ "childIds", "childCount", "getChildId" };
        const layout_partial = traverse ++ &[_][]const u8{ "allocator", "scratch", "oofCandidates", "setOofCandidates", "getCoreContainerStyle", "resolveCalcValue", "setUnroundedLayout", "computeChildLayout" };
        return switch (self) {
            .traverse_partial_tree, .traverse_tree => traverse,
            .layout_partial_tree => layout_partial,
            .layout_containing_block => layout_partial ++ &[_][]const u8{ "getOofItemStyle", "clearHoistedChildren", "addHoistedChildren", "getDetailedLayoutInfo" },
            .cache_tree => &.{ "cacheGet", "cacheStore", "cacheClear" },
            .round_tree => traverse ++ &[_][]const u8{ "getUnroundedLayout", "setFinalLayout", "isOutOfFlow", "hoistedChildCount", "getHoistedChildId" },
            .print_tree => traverse ++ &[_][]const u8{ "getDebugLabel", "getFinalLayout" },
            .layout_flexbox_container => layout_partial ++ &[_][]const u8{ "getFlexboxContainerStyle", "getFlexboxChildStyle" },
            .layout_grid_container => layout_partial ++ &[_][]const u8{ "getGridContainerStyle", "getGridChildStyle", "detailedGridInfo" },
            .layout_block_container => layout_partial ++ &[_][]const u8{ "getBlockContainerStyle", "getBlockChildStyle", "computeBlockChildLayout" },
        };
    }
};

/// The tree type behind a `tree: anytype` argument (pointers are dereferenced)
pub fn TreeType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |info| info.child,
        else => T,
    };
}

/// Fail compilation with a clear message if `Tree` (a tree type or a pointer to one) is missing a
/// method required by one of `interfaces`. Only names are checked; signatures are checked by the
/// compiler at the call sites.
pub fn assertImplements(comptime Tree: type, comptime interfaces: []const Interface) void {
    const T = TreeType(Tree);
    comptime {
        for (interfaces) |interface| {
            for (interface.methods()) |name| {
                if (!@hasDecl(T, name)) {
                    @compileError("tree type '" ++ @typeName(T) ++ "' does not implement '" ++ @tagName(interface) ++
                        "': missing method '" ++ name ++ "' (see src/tree/traits.zig)");
                }
            }
        }
    }
}

// --- Provided methods (upstream `LayoutPartialTreeExt`)

/// Compute the size of the node given the specified constraints
pub fn measureChildSize(
    tree: anytype,
    node_id: NodeId,
    known_dimensions: Size(?f32),
    parent_size: Size(?f32),
    available_space: Size(AvailableSpace),
    sizing_mode: SizingMode,
    axis: AbsoluteAxis,
    vertical_margins_are_collapsible: Line(bool),
) LayoutError!f32 {
    const output = try tree.computeChildLayout(node_id, .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = parent_size,
        .available_space = available_space,
        .sizing_mode = sizing_mode,
        .axis = RequestedAxis.fromAbsoluteAxis(axis),
        .run_mode = .compute_size,
        .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
    });
    return output.size.getAbs(axis);
}

/// Compute the size of the node given the specified constraints
pub fn measureChildSizeBoth(
    tree: anytype,
    node_id: NodeId,
    known_dimensions: Size(?f32),
    parent_size: Size(?f32),
    available_space: Size(AvailableSpace),
    sizing_mode: SizingMode,
    vertical_margins_are_collapsible: Line(bool),
) LayoutError!Size(f32) {
    const output = try tree.computeChildLayout(node_id, .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = parent_size,
        .available_space = available_space,
        .sizing_mode = sizing_mode,
        .axis = .both,
        .run_mode = .compute_size,
        .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
    });
    return output.size;
}

/// Perform a full layout on the node given the specified constraints
pub fn performChildLayout(
    tree: anytype,
    node_id: NodeId,
    known_dimensions: Size(?f32),
    parent_size: Size(?f32),
    available_space: Size(AvailableSpace),
    sizing_mode: SizingMode,
    vertical_margins_are_collapsible: Line(bool),
) LayoutError!LayoutOutput {
    return tree.computeChildLayout(node_id, .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = parent_size,
        .available_space = available_space,
        .sizing_mode = sizing_mode,
        .axis = .both,
        .run_mode = .perform_layout,
        .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
    });
}

/// Alias to `resolveCalcValue` with a shorter function name
pub fn calc(tree: anytype, val: CalcHandle, basis: f32) f32 {
    return tree.resolveCalcValue(val, basis);
}

test "interface method lists" {
    try std.testing.expectEqual(@as(usize, 3), Interface.traverse_tree.methods().len);
    try std.testing.expectEqual(@as(usize, 15), Interface.layout_containing_block.methods().len);
    const Dummy = struct {
        pub const resolveCalcValue = LayoutPartialTreeDefaults.resolveCalcValue;
        pub const getDetailedLayoutInfo = LayoutContainingBlockDefaults.getDetailedLayoutInfo;
        pub const detailedGridInfo = LayoutGridContainerDefaults.detailedGridInfo;
    };
    var dummy: Dummy = .{};
    try std.testing.expectEqual(@as(f32, 0.0), dummy.resolveCalcValue(1, 10.0));
    try std.testing.expectEqual(@as(f32, 0.0), calc(&dummy, 1, 10.0));
    try std.testing.expect(dummy.getDetailedLayoutInfo(NodeId.new(0)).* == .none);
    try std.testing.expect(try dummy.detailedGridInfo(NodeId.new(0), true) == null);
    try std.testing.expect(TreeType(*Dummy) == Dummy);
}
