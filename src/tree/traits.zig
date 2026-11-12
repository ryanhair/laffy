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
//!   - Style return types (`CoreStyle`, `OofItemStyle`, ...) are any value implementing the
//!     corresponding style interface documented at the top of `src/style.zig`; `*const Style` is
//!     the usual choice. Upstream's associated types (`CoreContainerStyle<'a>`, `CustomIdent`,
//!     `ChildIter<'a>`) become whatever the method returns.
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
//!     that outlives a single algorithm invocation: `LayoutOutput.oof_candidates`, cached final
//!     layouts and detailed grid info. It must be a general-purpose allocator and must not be
//!     reset between nested child layouts.
//!   - `scratch(self) *Scratch`: optional (laffy addition). A `util.Scratch` allocator for the
//!     temporary lists of the algorithms, which release everything they took from it when they
//!     return. Without it those lists come from `allocator()` and are freed individually.
//!   - `getCoreContainerStyle(self, node_id: NodeId) CoreStyle`: required. Only called for the node
//!     being laid out, never for its children (those go through the `get*ChildStyle` methods), so
//!     it may be expressed in the node's own axes while child styles are expressed in the axes of
//!     the node laying them out.
//!   - `resolveCalcValue(self, val: *const anyopaque, basis: f32) f32`: default
//!     (`LayoutPartialTreeDefaults.resolveCalcValue`, returns `0.0`). Resolves a `calc()` value.
//!     Because of this method, the tree itself is the `calc` resolver passed to `maybeResolve`
//!     and `resolveOrZero`.
//!   - `setUnroundedLayout(self, node_id: NodeId, layout: *const Layout) void`: required.
//!   - `computeChildLayout(self, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput`:
//!     required. Compute the specified node's size or full layout given the specified
//!     constraints. The caller owns the returned output (see `LayoutOutput.deinit`).
//!
//! ## LayoutContainingBlock (requires LayoutPartialTree)
//!
//! The operations needed by the out-of-flow positioning pass (`computeOofLayout`), which lays out
//! the absolute/fixed boxes for which a node acts as the containing block. Required by
//! `computeOofLayout` and `computeRootLayout`.
//!
//!   - `getOofItemStyle(self, node_id: NodeId) OofItemStyle`: required. The style of an
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
//! implements a per-node cache compatible with this interface (pass it `self.allocator()`).
//!
//!   - `cacheGet(self, node_id: NodeId, input: *const LayoutInput) LayoutError!?LayoutOutput`:
//!     required. Returns a copy owned by the caller.
//!   - `cacheStore(self, node_id: NodeId, input: *const LayoutInput, layout_output: LayoutOutput) void`:
//!     required. Takes ownership of `layout_output`.
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
//!   - `getFlexboxContainerStyle(self, node_id: NodeId) FlexboxContainerStyle`: required.
//!   - `getFlexboxChildStyle(self, child_node_id: NodeId) FlexboxItemStyle`: required.
//!     Interpreted in the container's axes.
//!
//! ## LayoutGridContainer (requires LayoutPartialTree)
//!
//!   - `getGridContainerStyle(self, node_id: NodeId) GridContainerStyle`: required.
//!   - `getGridChildStyle(self, child_node_id: NodeId) GridItemStyle`: required. Interpreted in
//!     the container's axes.
//!   - `setDetailedGridInfo(self, node_id: NodeId, detailed_grid_info: DetailedGridInfo) LayoutError!void`:
//!     default (`LayoutGridContainerDefaults.setDetailedGridInfo`, discards the info). Optional
//!     upstream; implementing it gives access to the computed size of each grid track and the
//!     placement of each grid item. The tree takes ownership of `detailed_grid_info` (allocated
//!     with `self.allocator()`) in all cases, including when it returns an error: it must free
//!     the info with `DetailedGridInfo.deinit` when discarding or replacing it. (Upstream boxes
//!     the info, which is why storing it may need an allocation.) The info borrows line and
//!     area names from the grid container's style.
//!
//! ## LayoutBlockContainer (requires LayoutPartialTree)
//!
//!   - `getBlockContainerStyle(self, node_id: NodeId) BlockContainerStyle`: required.
//!   - `getBlockChildStyle(self, child_node_id: NodeId) BlockItemStyle`: required. Interpreted
//!     in the container's axes.
//!   - `computeBlockChildLayout(self, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput`:
//!     default (`LayoutBlockContainerDefaults.computeBlockChildLayout`, ignores `block_ctx` and
//!     calls `computeChildLayout`). `BlockContext` is defined in `compute/block.zig`. The block
//!     algorithm calls this for children that participate in the parent's block formatting
//!     context, so that floats are positioned in the shared context; the caller owns the output.
//!
//! ## Provided methods (upstream `LayoutPartialTreeExt`)
//!
//! Free functions taking `tree: anytype`: `measureChildSize`, `measureChildSizeBoth`,
//! `performChildLayout` and `calc`.
const std = @import("std");
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
    pub fn resolveCalcValue(self: anytype, val: *const anyopaque, basis: f32) f32 {
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
    /// Set the node's detailed grid information (default: discard (free) it)
    pub fn setDetailedGridInfo(self: anytype, node_id: NodeId, detailed_grid_info: DetailedGridInfo) LayoutError!void {
        _ = node_id;
        var info = detailed_grid_info;
        info.deinit(self.allocator());
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
        const layout_partial = traverse ++ &[_][]const u8{ "allocator", "getCoreContainerStyle", "resolveCalcValue", "setUnroundedLayout", "computeChildLayout" };
        return switch (self) {
            .traverse_partial_tree, .traverse_tree => traverse,
            .layout_partial_tree => layout_partial,
            .layout_containing_block => layout_partial ++ &[_][]const u8{ "getOofItemStyle", "clearHoistedChildren", "addHoistedChildren", "getDetailedLayoutInfo" },
            .cache_tree => &.{ "cacheGet", "cacheStore", "cacheClear" },
            .round_tree => traverse ++ &[_][]const u8{ "getUnroundedLayout", "setFinalLayout", "isOutOfFlow", "hoistedChildCount", "getHoistedChildId" },
            .print_tree => traverse ++ &[_][]const u8{ "getDebugLabel", "getFinalLayout" },
            .layout_flexbox_container => layout_partial ++ &[_][]const u8{ "getFlexboxContainerStyle", "getFlexboxChildStyle" },
            .layout_grid_container => layout_partial ++ &[_][]const u8{ "getGridContainerStyle", "getGridChildStyle", "setDetailedGridInfo" },
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
    var output = try tree.computeChildLayout(node_id, .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = parent_size,
        .available_space = available_space,
        .sizing_mode = sizing_mode,
        .axis = RequestedAxis.fromAbsoluteAxis(axis),
        .run_mode = .compute_size,
        .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
    });
    defer output.deinit(tree.allocator());
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
    var output = try tree.computeChildLayout(node_id, .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = parent_size,
        .available_space = available_space,
        .sizing_mode = sizing_mode,
        .axis = .both,
        .run_mode = .compute_size,
        .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
    });
    defer output.deinit(tree.allocator());
    return output.size;
}

/// Perform a full layout on the node given the specified constraints. The caller owns the
/// returned output.
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
pub fn calc(tree: anytype, val: *const anyopaque, basis: f32) f32 {
    return tree.resolveCalcValue(val, basis);
}

test "interface method lists" {
    try std.testing.expectEqual(@as(usize, 3), Interface.traverse_tree.methods().len);
    try std.testing.expectEqual(@as(usize, 12), Interface.layout_containing_block.methods().len);
    const Dummy = struct {
        pub const resolveCalcValue = LayoutPartialTreeDefaults.resolveCalcValue;
        pub const getDetailedLayoutInfo = LayoutContainingBlockDefaults.getDetailedLayoutInfo;
        pub const setDetailedGridInfo = LayoutGridContainerDefaults.setDetailedGridInfo;
        pub fn allocator(_: *const @This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };
    var dummy: Dummy = .{};
    var x: u8 = 0;
    try std.testing.expectEqual(@as(f32, 0.0), dummy.resolveCalcValue(@ptrCast(&x), 10.0));
    try std.testing.expectEqual(@as(f32, 0.0), calc(&dummy, @ptrCast(&x), 10.0));
    try std.testing.expect(dummy.getDetailedLayoutInfo(NodeId.new(0)).* == .none);
    // The default takes ownership of the info and frees it
    var info: DetailedGridInfo = .{};
    info.items = try std.testing.allocator.alloc(@import("../compute/grid.zig").DetailedGridItemsInfo, 1);
    try dummy.setDetailedGridInfo(NodeId.new(0), info);
    try std.testing.expect(TreeType(*Dummy) == Dummy);
}
