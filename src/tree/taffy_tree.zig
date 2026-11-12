//! Contains `TaffyTree`: the default implementation of the tree interfaces, and the error type for laffy.
//!
//! # Differences from upstream
//!
//!   - `TaffyTree(NodeContext)` takes an allocator at construction (`init` / `withCapacity`) and must
//!     be freed with `deinit`. Node contexts are plain values owned by the tree: they are discarded
//!     (not deinitialized) when their node is removed or the tree is cleared, so a context that owns
//!     resources must be cleaned up by the caller first.
//!   - Node storage uses `util/slot_map.zig` instead of the `slotmap` crate. A `NodeId` packs the
//!     slot index and generation, so ids of removed nodes are detected as stale.
//!   - As upstream, using an id that is not (or no longer) in the tree panics. Methods whose
//!     upstream body can never return an error return plain values here; methods that may allocate
//!     return `error.OutOfMemory`.
//!   - `children` returns a borrowed slice (upstream returns a copy). It is invalidated by any
//!     change to the parent's children.
//!   - `compute_layout_with_measure` takes a "measurer" value instead of a closure (see
//!     `computeLayoutWithMeasure`).
const std = @import("std");
const CalcHandle = @import("../style/compact_length.zig").CalcHandle;
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const Size = geometry.Size;
const style_mod = @import("../style.zig");
const AvailableSpace = style_mod.AvailableSpace;
const Display = style_mod.Display;
const Style = style_mod.Style;
const layout_mod = @import("layout.zig");
const DetailedLayoutInfo = layout_mod.DetailedLayoutInfo;
const DetailedGridInfo = @import("../compute/grid.zig").DetailedGridInfo;
const Layout = layout_mod.Layout;
const LayoutError = layout_mod.LayoutError;
const Scratch = @import("../util/scratch.zig");

/// The most scratch memory (in bytes) that a tree keeps between layout passes
const scratch_retain_limit = 1024 * 1024;
const LayoutInput = layout_mod.LayoutInput;
const LayoutOutput = layout_mod.LayoutOutput;
const OofCandidate = layout_mod.OofCandidate;
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const NodeId = @import("node.zig").NodeId;
const compute_mod = @import("../compute.zig");
const BlockContext = compute_mod.BlockContext;
const SlotMap = @import("../util/slot_map.zig").SlotMap;
const print = @import("../util/print.zig");

/// An error that occurs while trying to access or modify a node's children by index.
///
/// Upstream variants carry data (the parent id, the index and the child count); Zig errors cannot,
/// so only the variant is reported.
pub const TaffyError = error{
    /// The parent node does not have a child at `child_index`. It only has `child_count` children
    ChildIndexOutOfBounds,
    /// The parent node was not found in the `TaffyTree` instance.
    InvalidParentNode,
    /// The child node was not found in the `TaffyTree` instance.
    InvalidChildNode,
    /// The supplied node was not found in the `TaffyTree` instance.
    InvalidInputNode,
};

/// Global configuration values for a TaffyTree instance
const TaffyConfig = struct {
    /// Whether to round layout values
    use_rounding: bool = true,
};

/// The default measurer of `TaffyTree.computeLayout`: every leaf has a zero-sized content box
pub fn LeafMeasurer(comptime NodeContext: type) type {
    return struct {
        pub fn measure(_: @This(), inputs: LayoutInput, node_id: NodeId, node_context: ?*NodeContext, style: *const Style) LayoutOutput {
            _ = node_id;
            _ = node_context;
            return compute_mod.computeLeafLayout(inputs, style, style_mod.NoCalc{}, ZeroMeasure{});
        }
    };
}

/// A leaf measure function (see `computeLeafLayout`) whose content is always zero-sized
pub const ZeroMeasure = struct {
    pub fn measure(_: ZeroMeasure, known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
        _ = known_dimensions;
        _ = available_space;
        return Size(f32).zero;
    }
};

/// Iterator over a slice of node ids (the `ChildIter` of `TaffyTree` and its views)
pub const ChildIter = struct {
    ids: []const NodeId,
    index: usize = 0,

    pub fn next(self: *ChildIter) ?NodeId {
        if (self.index >= self.ids.len) return null;
        defer self.index += 1;
        return self.ids[self.index];
    }
};

/// An entire tree of UI nodes. The entry point to laffy's high-level API.
///
/// Allows you to build a tree of UI nodes, run laffy's layout algorithms over that tree, and then access the resultant layout.
///
/// `NodeContext` is arbitrary per-node data passed to the measure function (use `void` for none).
pub fn TaffyTree(comptime NodeContext: type) type {
    return struct {
        const Self = @This();

        /// Layout information for a given node
        const NodeData = struct {
            /// The layout strategy used by this node
            style: Style,
            /// The always unrounded results of the layout computation. We must store this separately from the rounded
            /// layout to avoid errors from rounding already-rounded values. See <https://github.com/DioxusLabs/taffy/issues/501>.
            unrounded_layout: Layout = .{},
            /// The final results of the layout computation.
            /// These may be rounded or unrounded depending on what the `use_rounding` config setting is set to.
            final_layout: Layout = .{},
            /// The node's context data, if any (upstream `has_context` plus `node_context_data`)
            context: ?NodeContext = null,
            /// The children of the node
            children: std.ArrayList(NodeId) = .empty,
            /// The parent of the node
            parent: ?NodeId = null,
            /// Out-of-flow (absolute/fixed) boxes whose containing block is this node,
            /// as recorded by the out-of-flow positioning pass
            hoisted_children: std.ArrayList(NodeId) = .empty,
            /// Out-of-flow descendants of the node that it did not lay out itself, as of its most
            /// recent final layout (see `OofCandidate`). Owned by the node.
            oof_candidates: []OofCandidate = &.{},
            /// The cached results of the layout computation
            cache: Cache = .{},
            /// The computation result from layout algorithm
            detailed_layout_info: DetailedLayoutInfo = .none,
            /// The layout pass (see `TaffyTree.layout_pass`) in which the unrounded layout or
            /// the hoisted child list of this node, or of any of its descendants, last changed
            layout_stamp: u64 = 1,
            /// The layout pass in which this node's final layout was last rounded, or 0 if its
            /// final layout does not come from rounding
            rounded_pass: u64 = 0,
            /// The bits of the cumulative offset of the node's parent that the node was last
            /// rounded against
            rounded_origin: [2]u32 = .{ 0, 0 },

            fn deinit(self: *NodeData, gpa: Allocator) void {
                self.children.deinit(gpa);
                self.hoisted_children.deinit(gpa);
                gpa.free(self.oof_candidates);
                self.detailed_layout_info.deinit(gpa);
            }
        };

        /// The allocator for all of the tree's memory
        gpa: Allocator,
        /// The `NodeData` for each node stored in this tree
        nodes: SlotMap(NodeData),
        /// Layout mode configuration
        config: TaffyConfig = .{},
        /// Temporary memory for layout algorithms, reused between layout passes
        scratch_allocator: Scratch,
        /// A counter that advances every time the tree's layouts are rounded. Changes to a node's
        /// layout are stamped with it, which lets rounding skip subtrees that have not changed
        /// since they were last rounded.
        layout_pass: u64 = 1,

        /// Creates a new `TaffyTree`
        ///
        /// The default capacity of a `TaffyTree` is 16 nodes.
        pub fn init(gpa: Allocator) Allocator.Error!Self {
            return withCapacity(gpa, 16);
        }

        /// Creates a new `TaffyTree` that can store `capacity` nodes before reallocation
        pub fn withCapacity(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            return .{ .gpa = gpa, .nodes = try .initCapacity(gpa, capacity), .scratch_allocator = .init(gpa) };
        }

        /// Frees all memory owned by the tree
        pub fn deinit(self: *Self) void {
            var iter = self.nodes.iterator();
            while (iter.next()) |entry| entry.value.deinit(self.gpa);
            self.nodes.deinit(self.gpa);
            self.scratch_allocator.deinit();
        }

        /// The data of a node; panics if the id is not in the tree
        /// Record that the unrounded layout or the hoisted child list of `node_id` changed, on
        /// the node and its ancestors. Stops at the first ancestor that already has the stamp of
        /// the current pass, so stamping costs one step per node per pass on average.
        fn stampLayoutChange(self: *const Self, node_id: NodeId) void {
            var data = self.nodeData(node_id);
            while (data.layout_stamp != self.layout_pass) {
                data.layout_stamp = self.layout_pass;
                data = self.nodeData(data.parent orelse return);
            }
        }

        fn nodeData(self: *const Self, node_id: NodeId) *NodeData {
            return self.nodes.get(node_id.inner) orelse
                std.debug.panic("invalid {f}: the node is not in this TaffyTree (it was removed, or belongs to another tree)", .{node_id});
        }

        // --- TraversePartialTree / TraverseTree

        /// Get the list of children IDs for the given node
        pub fn childIds(self: *const Self, parent_node_id: NodeId) ChildIter {
            return .{ .ids = self.nodeData(parent_node_id).children.items };
        }

        /// Get the number of children for the given node
        pub fn childCount(self: *const Self, parent_node_id: NodeId) usize {
            return self.nodeData(parent_node_id).children.items.len;
        }

        /// Get a specific child of a node, where the index represents the nth child
        pub fn getChildId(self: *const Self, parent_node_id: NodeId, child_index: usize) NodeId {
            return self.nodeData(parent_node_id).children.items[child_index];
        }

        // --- CacheTree

        pub fn cacheGet(self: *Self, node_id: NodeId, input: *const LayoutInput) ?LayoutOutput {
            return self.nodeData(node_id).cache.get(input);
        }

        pub fn cacheStore(self: *Self, node_id: NodeId, input: *const LayoutInput, layout_output: LayoutOutput) void {
            self.nodeData(node_id).cache.store(input, layout_output);
        }

        pub fn cacheClear(self: *Self, node_id: NodeId) void {
            _ = self.nodeData(node_id).cache.clear();
        }

        // --- PrintTree

        pub fn getDebugLabel(self: *const Self, node_id: NodeId) []const u8 {
            const node = self.nodeData(node_id);
            const display = node.style.display;
            const num_children = self.childCount(node_id);

            if (display == .none) return "NONE";
            if (num_children == 0) return "LEAF";
            return switch (display) {
                .block => "BLOCK",
                .flow_root => "FLOW-ROOT",
                .flex => switch (node.style.flex_direction) {
                    .row, .row_reverse => "FLEX ROW",
                    .column, .column_reverse => "FLEX COL",
                },
                .grid => "GRID",
                .none => unreachable,
            };
        }

        pub fn getFinalLayout(self: *const Self, node_id: NodeId) Layout {
            if (self.config.use_rounding) {
                return self.nodeData(node_id).final_layout;
            } else {
                return self.nodeData(node_id).unrounded_layout;
            }
        }

        // --- Public API

        /// Enable rounding of layout values. Rounding is enabled by default.
        pub fn enableRounding(self: *Self) void {
            self.config.use_rounding = true;
        }

        /// Disable rounding of layout values. Rounding is enabled by default.
        pub fn disableRounding(self: *Self) void {
            self.config.use_rounding = false;
        }

        /// Creates and adds a new unattached leaf node to the tree, and returns the node of the new node
        pub fn newLeaf(self: *Self, node_style: Style) Allocator.Error!NodeId {
            return .{ .inner = try self.nodes.insert(self.gpa, .{ .style = node_style }) };
        }

        /// Creates and adds a new unattached leaf node to the tree, and returns the `NodeId` of the new node
        ///
        /// Creates and adds a new leaf node with a supplied context
        pub fn newLeafWithContext(self: *Self, node_style: Style, context: NodeContext) Allocator.Error!NodeId {
            return .{ .inner = try self.nodes.insert(self.gpa, .{ .style = node_style, .context = context }) };
        }

        /// Creates and adds a new node, which may have any number of `children`
        pub fn newWithChildren(self: *Self, node_style: Style, child_ids: []const NodeId) Allocator.Error!NodeId {
            var list: std.ArrayList(NodeId) = .empty;
            errdefer list.deinit(self.gpa);
            try list.appendSlice(self.gpa, child_ids);
            const id: NodeId = .{ .inner = try self.nodes.insert(self.gpa, .{ .style = node_style, .children = list }) };

            for (child_ids) |child| {
                self.nodeData(child).parent = id;
            }

            return id;
        }

        /// Drops all nodes in the tree
        pub fn clear(self: *Self) void {
            // A context belongs to the node that owns it, so it is dropped with the node.
            var iter = self.nodes.iterator();
            while (iter.next()) |entry| entry.value.deinit(self.gpa);
            self.nodes.clear();
        }

        /// Remove a specific node from the tree and drop it
        ///
        /// Returns the id of the node removed.
        pub fn remove(self: *Self, node: NodeId) NodeId {
            const data = self.nodeData(node);
            if (data.parent) |parent_id| {
                if (self.nodes.get(parent_id.inner)) |parent_data| {
                    var i: usize = 0;
                    while (i < parent_data.children.items.len) {
                        if (parent_data.children.items[i] == node) {
                            _ = parent_data.children.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }
                self.markDirty(parent_id);
            }

            // Remove "parent" references to a node when removing that node
            for (data.children.items) |child| {
                self.nodeData(child).parent = null;
            }

            var removed = self.nodes.remove(node.inner).?;
            removed.deinit(self.gpa);

            return node;
        }

        /// Sets the context data associated with the node
        pub fn setNodeContext(self: *Self, node: NodeId, measure: ?NodeContext) void {
            self.nodeData(node).context = measure;
            self.markDirty(node);
        }

        /// Gets a reference to the the context data associated with the node (null if the node has
        /// no context or is not in the tree)
        pub fn getNodeContext(self: *const Self, node: NodeId) ?*const NodeContext {
            const data = self.nodes.get(node.inner) orelse return null;
            return if (data.context) |*context| context else null;
        }

        /// Gets a mutable reference to the the context data associated with the node (null if the
        /// node has no context or is not in the tree)
        pub fn getNodeContextMut(self: *Self, node: NodeId) ?*NodeContext {
            const data = self.nodes.get(node.inner) orelse return null;
            return if (data.context) |*context| context else null;
        }

        /// Gets mutable references to the the context data associated with the nodes. All keys must be valid and disjoint, otherwise null is returned.
        pub fn getDisjointNodeContextMut(self: *Self, comptime n: usize, keys: [n]NodeId) ?[n]*NodeContext {
            var result: [n]*NodeContext = undefined;
            for (keys, 0..) |key, i| {
                for (keys[0..i]) |previous| {
                    if (previous == key) return null;
                }
                const data = self.nodes.get(key.inner) orelse return null;
                result[i] = if (data.context) |*context| context else return null;
            }
            return result;
        }

        /// Adds a `child` node under the supplied `parent`
        pub fn addChild(self: *Self, parent_node: NodeId, child_node: NodeId) Allocator.Error!void {
            _ = self.nodeData(child_node);
            try self.nodeData(parent_node).children.append(self.gpa, child_node);
            self.nodeData(child_node).parent = parent_node;
            self.markDirty(parent_node);
        }

        /// Inserts a `child` node at the given `child_index` under the supplied `parent`, shifting all children after it to the right.
        pub fn insertChildAtIndex(self: *Self, parent_node: NodeId, child_index: usize, child_node: NodeId) (TaffyError || Allocator.Error)!void {
            const parent_data = self.nodeData(parent_node);

            const child_count = parent_data.children.items.len;
            if (child_index > child_count) {
                return error.ChildIndexOutOfBounds;
            }

            _ = self.nodeData(child_node);
            try parent_data.children.insert(self.gpa, child_index, child_node);
            self.nodeData(child_node).parent = parent_node;
            self.markDirty(parent_node);
        }

        /// Directly sets the `children` of the supplied `parent`
        pub fn setChildren(self: *Self, parent_node: NodeId, child_ids: []const NodeId) Allocator.Error!void {
            // Make sure the new list fits before changing anything
            try self.nodeData(parent_node).children.ensureTotalCapacity(self.gpa, child_ids.len);

            // Remove node as parent from all its current children.
            for (self.nodeData(parent_node).children.items) |child| {
                self.nodeData(child).parent = null;
            }

            // Build up relation node <-> child
            for (child_ids) |child| {
                // Remove child from previous parent
                if (self.nodeData(child).parent) |previous_parent| {
                    _ = self.removeChild(previous_parent, child);
                }
                self.nodeData(child).parent = parent_node;
            }

            const parent_children = &self.nodeData(parent_node).children;
            parent_children.clearRetainingCapacity();
            parent_children.appendSliceAssumeCapacity(child_ids);

            self.markDirty(parent_node);
        }

        /// Removes the `child` of the parent `node`
        ///
        /// The child is not removed from the tree entirely, it is simply no longer attached to its previous parent.
        /// Panics if `child_node` is not a child of `parent_node` (as upstream).
        pub fn removeChild(self: *Self, parent_node: NodeId, child_node: NodeId) NodeId {
            const index = std.mem.indexOfScalar(NodeId, self.nodeData(parent_node).children.items, child_node) orelse
                std.debug.panic("{f} is not a child of {f}", .{ child_node, parent_node });
            return self.removeChildAtIndex(parent_node, index) catch unreachable;
        }

        /// Removes the child at the given `index` from the `parent`
        ///
        /// The child is not removed from the tree entirely, it is simply no longer attached to its previous parent.
        pub fn removeChildAtIndex(self: *Self, parent_node: NodeId, child_index: usize) TaffyError!NodeId {
            const parent_data = self.nodeData(parent_node);
            const child_count = parent_data.children.items.len;
            if (child_index >= child_count) {
                return error.ChildIndexOutOfBounds;
            }

            const child = parent_data.children.orderedRemove(child_index);
            self.nodeData(child).parent = null;

            self.markDirty(parent_node);

            return child;
        }

        /// Removes the children with indices in `[start, end)` from the `parent`
        ///
        /// Children are not removed from the tree entirely, they are simply no longer attached to their previous parent.
        ///
        /// Panics if the range is invalid (as upstream).
        pub fn removeChildrenRange(self: *Self, parent_node: NodeId, start: usize, end: usize) void {
            const parent_children = &self.nodeData(parent_node).children;
            if (start > end or end > parent_children.items.len) {
                std.debug.panic("invalid child range {d}..{d} for {d} children", .{ start, end, parent_children.items.len });
            }
            for (parent_children.items[start..end]) |child| {
                self.nodeData(child).parent = null;
            }
            parent_children.replaceRangeAssumeCapacity(start, end - start, &.{});

            self.markDirty(parent_node);
        }

        /// Replaces the child at the given `child_index` from the `parent` node with the new `child` node
        ///
        /// The child is not removed from the tree entirely, it is simply no longer attached to its previous parent.
        pub fn replaceChildAtIndex(self: *Self, parent_node: NodeId, child_index: usize, new_child: NodeId) TaffyError!NodeId {
            const parent_data = self.nodeData(parent_node);

            const child_count = parent_data.children.items.len;
            if (child_index >= child_count) {
                return error.ChildIndexOutOfBounds;
            }

            self.nodeData(new_child).parent = parent_node;
            const old_child = parent_data.children.items[child_index];
            parent_data.children.items[child_index] = new_child;
            self.nodeData(old_child).parent = null;

            self.markDirty(parent_node);

            return old_child;
        }

        /// Returns the child node of the parent `node` at the provided `child_index`
        pub fn childAtIndex(self: *const Self, parent_node: NodeId, child_index: usize) TaffyError!NodeId {
            const parent_data = self.nodeData(parent_node);
            const child_count = parent_data.children.items.len;
            if (child_index >= child_count) {
                return error.ChildIndexOutOfBounds;
            }

            return parent_data.children.items[child_index];
        }

        /// Returns the total number of nodes in the tree
        pub fn totalNodeCount(self: *const Self) usize {
            return self.nodes.count();
        }

        /// Whether `node` is in this tree (false for ids of removed nodes and ids from other trees).
        /// Never panics, so it can validate ids before calling the methods that panic on them.
        pub fn containsNode(self: *const Self, node: NodeId) bool {
            return self.nodes.contains(node.inner);
        }

        /// Returns the `NodeId` of the parent node of the specified node (if it exists)
        ///
        /// - Return null if the specified node has no parent
        /// - Panics if the specified node does not exist
        pub fn parent(self: *const Self, child_id: NodeId) ?NodeId {
            return self.nodeData(child_id).parent;
        }

        /// Returns the list of children that belong to the parent node. The slice is borrowed from
        /// the tree and is invalidated by any change to the parent's children.
        pub fn children(self: *const Self, parent_node: NodeId) []const NodeId {
            return self.nodeData(parent_node).children.items;
        }

        /// Returns the out-of-flow (absolute/fixed) boxes whose containing block is `node`, as
        /// recorded by the last layout. These boxes are laid out by `node` rather than by their
        /// parent, and their `Layout.location` is relative to `node`.
        pub fn hoistedChildren(self: *const Self, node: NodeId) []const NodeId {
            return self.nodeData(node).hoisted_children.items;
        }

        /// Sets the `Style` of the provided `node`
        pub fn setStyle(self: *Self, node: NodeId, new_style: Style) void {
            self.nodeData(node).style = new_style;
            self.markDirty(node);
        }

        /// Gets the `Style` of the provided `node`
        pub fn style(self: *const Self, node: NodeId) *const Style {
            return &self.nodeData(node).style;
        }

        /// Return this node layout relative to its parent
        pub fn layout(self: *const Self, node: NodeId) *const Layout {
            if (self.config.use_rounding) {
                return &self.nodeData(node).final_layout;
            } else {
                return &self.nodeData(node).unrounded_layout;
            }
        }

        /// Returns this node layout with unrounded values relative to its parent.
        pub fn unroundedLayout(self: *const Self, node: NodeId) *const Layout {
            return &self.nodeData(node).unrounded_layout;
        }

        /// Get the "detailed layout info" for a node.
        ///
        /// Currently this is only implemented for CSS Grid containers where it contains
        /// the computed size of each grid track and the computed placement of each grid item
        pub fn detailedLayoutInfo(self: *const Self, node_id: NodeId) *const DetailedLayoutInfo {
            return &self.nodeData(node_id).detailed_layout_info;
        }

        /// Marks the layout of this node and its ancestors as outdated
        pub fn markDirty(self: *Self, node: NodeId) void {
            var current = node;
            while (true) {
                const data = self.nodeData(current);
                switch (data.cache.clear()) {
                    // Node was already marked as dirty.
                    // No need to visit ancestors
                    // as they should be marked as dirty already.
                    .already_empty => return,
                    .cleared => current = data.parent orelse return,
                }
            }
        }

        /// Indicates whether the layout of this node needs to be recomputed
        pub fn dirty(self: *const Self, node: NodeId) bool {
            return self.nodeData(node).cache.isEmpty();
        }

        /// Updates the stored layout of the provided `node` and its children
        ///
        /// `measurer` computes the layout of leaf nodes (nodes without children). It is a value or
        /// pointer with the method
        ///
        ///     measure(self, inputs: LayoutInput, node_id: NodeId, node_context: ?*NodeContext, style: *const Style) LayoutOutput
        ///
        /// which is called for each leaf node that needs (re)measuring. `node_context` is the node's
        /// context, if it has one. Pass a pointer if `measure` needs to mutate the measurer's state.
        /// A typical implementation calls `computeLeafLayout(inputs, style, NoCalc{}, content_measurer)`
        /// with a content measurer derived from the node context. The returned output is owned by the
        /// tree. Measuring cannot fail.
        pub fn computeLayoutWithMeasure(
            self: *Self,
            node_id: NodeId,
            available_space: Size(AvailableSpace),
            measurer: anytype,
        ) LayoutError!void {
            const use_rounding = self.config.use_rounding;
            var taffy_view: View(@TypeOf(measurer)) = .{ .taffy = self, .measurer = measurer };
            // Keep a modest amount of scratch memory for the next layout pass
            defer self.scratch_allocator.trim(scratch_retain_limit);
            // Laying a node out as the root positions it as a root and may resize it. If it has a
            // parent, the parent's cached layout no longer describes it, so the parent must lay it
            // out again the next time the parent is laid out.
            defer if (self.nodeData(node_id).parent) |parent_id| self.markDirty(parent_id);
            try compute_mod.computeRootLayout(&taffy_view, node_id, available_space);
            if (use_rounding) {
                compute_mod.roundLayout(&taffy_view, node_id);
            }
        }

        /// Updates the stored layout of the provided `node` and its children
        pub fn computeLayout(self: *Self, node: NodeId, available_space: Size(AvailableSpace)) LayoutError!void {
            return self.computeLayoutWithMeasure(node, available_space, LeafMeasurer(NodeContext){});
        }

        /// Prints a debug representation of the tree's layout
        pub fn printTree(self: *const Self, root: NodeId) void {
            print.printTree(self, root);
        }

        /// Returns a view of the tree implementing the layout interfaces, with every leaf measured
        /// as zero-sized content (upstream test helper `as_layout_tree`)
        pub fn asLayoutTree(self: *Self) View(LeafMeasurer(NodeContext)) {
            return .{ .taffy = self, .measurer = .{} };
        }

        /// View over the tree that holds the tree itself along with the measurer, and implements
        /// the layout interfaces (`LayoutPartialTree`, `LayoutContainingBlock`, `CacheTree`,
        /// `LayoutBlockContainer`, `LayoutFlexboxContainer`, `LayoutGridContainer`, `RoundTree`).
        /// This allows the measurer to be stored outside of the `TaffyTree` struct.
        pub fn View(comptime Measurer: type) type {
            return struct {
                const ViewSelf = @This();

                /// A reference to the TaffyTree
                taffy: *Self,
                /// The measurer for leaf nodes
                measurer: Measurer,

                /// Unified implementation that both `computeChildLayout` and
                /// `computeBlockChildLayout` delegate to.
                fn computeChildLayoutImpl(self: *ViewSelf, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput {
                    // If RunMode is perform_hidden_layout then this indicates that an ancestor node is `Display.none`
                    // and thus that we should lay out this node using hidden layout regardless of it's own display style.
                    if (inputs.run_mode == .perform_hidden_layout) {
                        // `roundLayout` reaches out-of-flow boxes only through their containing block's
                        // hoisted child list, and a box inside a hidden subtree is in no such list. Write the
                        // final layout here so that it does not keep the layout from an earlier visible pass.
                        const hidden_node = self.taffy.nodeData(node_id);
                        hidden_node.final_layout = Layout.withOrder(0);
                        hidden_node.rounded_pass = 0;
                        return compute_mod.computeHiddenLayout(self, node_id);
                    }

                    // We run the following wrapped in "computeCachedLayout", which will check the cache for an entry matching the node and inputs and:
                    //   - Return that entry if exists
                    //   - Else call `Uncached.compute` (below) to compute the result
                    //
                    // If there was no cache match and a new result needs to be computed then that result will be added to the cache
                    return compute_mod.computeCachedLayout(self, node_id, inputs, Uncached{ .block_ctx = block_ctx });
                }

                const Uncached = struct {
                    block_ctx: ?*BlockContext,

                    pub fn compute(uncached: @This(), tree: *ViewSelf, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
                        const node = tree.taffy.nodeData(node_id);
                        const display_mode = node.style.display;
                        const has_children = tree.childCount(node_id) > 0;

                        // Dispatch to a layout algorithm based on the node's display style and whether the node has children or not.
                        var output: LayoutOutput = if (display_mode == .none)
                            try compute_mod.computeHiddenLayout(tree, node_id)
                        else if (has_children) switch (display_mode) {
                            .block => try compute_mod.computeBlockLayout(tree, node_id, inputs, uncached.block_ctx),
                            .flow_root => try compute_mod.computeBlockLayout(tree, node_id, inputs, null),
                            .flex => try compute_mod.computeFlexboxLayout(tree, node_id, inputs),
                            .grid => try compute_mod.computeGridLayout(tree, node_id, inputs),
                            .none => unreachable,
                        } else blk: {
                            const node_context: ?*NodeContext = if (node.context) |*context| context else null;
                            break :blk tree.measurer.measure(inputs, node_id, node_context, &node.style);
                        };

                        // Lay out any out-of-flow candidates for which this node is the containing block.
                        // The rest stay stored on the node for its parent to pick up. This runs inside the
                        // cache-miss function so that the stored list belongs to the cached output.
                        // Only full layout passes run it: measure passes must not write hoisted box layouts
                        // (which would not be rewritten if the final layout pass is a cache hit).
                        if (inputs.run_mode == .perform_layout) {
                            try compute_mod.computeOofLayout(tree, node_id, &output);
                        }

                        return output;
                    }
                };

                // TraversePartialTree / TraverseTree

                pub fn childIds(self: *const ViewSelf, parent_node_id: NodeId) ChildIter {
                    return self.taffy.childIds(parent_node_id);
                }

                pub fn childCount(self: *const ViewSelf, parent_node_id: NodeId) usize {
                    return self.taffy.childCount(parent_node_id);
                }

                pub fn getChildId(self: *const ViewSelf, parent_node_id: NodeId, child_index: usize) NodeId {
                    return self.taffy.getChildId(parent_node_id, child_index);
                }

                // LayoutPartialTree

                pub fn allocator(self: *const ViewSelf) Allocator {
                    return self.taffy.gpa;
                }

                pub fn scratch(self: *const ViewSelf) *Scratch {
                    return &self.taffy.scratch_allocator;
                }

                pub fn oofCandidates(self: *const ViewSelf, node_id: NodeId) []const OofCandidate {
                    return self.taffy.nodeData(node_id).oof_candidates;
                }

                pub fn setOofCandidates(self: *ViewSelf, node_id: NodeId, candidates: []const OofCandidate) LayoutError!void {
                    const gpa = self.taffy.gpa;
                    const node = self.taffy.nodeData(node_id);
                    if (node.oof_candidates.len != candidates.len) {
                        // Replace the buffer before copying, so that a failed allocation leaves an
                        // empty (and so harmless) list behind
                        gpa.free(node.oof_candidates);
                        node.oof_candidates = &.{};
                        if (candidates.len == 0) return;
                        node.oof_candidates = try gpa.alloc(OofCandidate, candidates.len);
                    }
                    @memcpy(node.oof_candidates, candidates);
                }

                pub fn getCoreContainerStyle(self: *const ViewSelf, node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(node_id).style;
                }

                pub fn setUnroundedLayout(self: *ViewSelf, node_id: NodeId, l: *const Layout) void {
                    // Relaying out a parent rewrites the layouts of all of its children, mostly with
                    // the values they already have. Only a real change needs rounding again.
                    const node = self.taffy.nodeData(node_id);
                    if (std.mem.eql(u8, std.mem.asBytes(&node.unrounded_layout), std.mem.asBytes(l))) return;
                    node.unrounded_layout = l.*;
                    self.taffy.stampLayoutChange(node_id);
                }

                pub fn resolveCalcValue(self: *const ViewSelf, val: CalcHandle, basis: f32) f32 {
                    _ = self;
                    _ = val;
                    _ = basis;
                    return 0.0;
                }

                pub fn computeChildLayout(self: *ViewSelf, node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
                    return self.computeChildLayoutImpl(node_id, inputs, null);
                }

                // LayoutContainingBlock

                pub fn getOofItemStyle(self: *const ViewSelf, node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(node_id).style;
                }

                pub fn clearHoistedChildren(self: *ViewSelf, node_id: NodeId) void {
                    // Called for every container on every layout; most have no hoisted children
                    const node = self.taffy.nodeData(node_id);
                    if (node.hoisted_children.items.len == 0) return;
                    node.hoisted_children.clearRetainingCapacity();
                    self.taffy.stampLayoutChange(node_id);
                }

                pub fn addHoistedChildren(self: *ViewSelf, node_id: NodeId, hoisted: []const NodeId) LayoutError!void {
                    if (hoisted.len == 0) return;
                    try self.taffy.nodeData(node_id).hoisted_children.appendSlice(self.taffy.gpa, hoisted);
                    self.taffy.stampLayoutChange(node_id);
                }

                pub fn getDetailedLayoutInfo(self: *const ViewSelf, node_id: NodeId) *const DetailedLayoutInfo {
                    return &self.taffy.nodeData(node_id).detailed_layout_info;
                }

                // CacheTree

                pub fn cacheGet(self: *ViewSelf, node_id: NodeId, input: *const LayoutInput) ?LayoutOutput {
                    return self.taffy.cacheGet(node_id, input);
                }

                pub fn cacheStore(self: *ViewSelf, node_id: NodeId, input: *const LayoutInput, layout_output: LayoutOutput) void {
                    self.taffy.cacheStore(node_id, input, layout_output);
                }

                pub fn cacheClear(self: *ViewSelf, node_id: NodeId) void {
                    self.taffy.cacheClear(node_id);
                }

                // LayoutBlockContainer

                pub fn getBlockContainerStyle(self: *const ViewSelf, node_id: NodeId) *const Style {
                    return self.getCoreContainerStyle(node_id);
                }

                pub fn getBlockChildStyle(self: *const ViewSelf, child_node_id: NodeId) *const Style {
                    return self.getCoreContainerStyle(child_node_id);
                }

                pub fn computeBlockChildLayout(self: *ViewSelf, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput {
                    return self.computeChildLayoutImpl(node_id, inputs, block_ctx);
                }

                // LayoutFlexboxContainer

                pub fn getFlexboxContainerStyle(self: *const ViewSelf, node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(node_id).style;
                }

                pub fn getFlexboxChildStyle(self: *const ViewSelf, child_node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(child_node_id).style;
                }

                // LayoutGridContainer

                pub fn getGridContainerStyle(self: *const ViewSelf, node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(node_id).style;
                }

                pub fn getGridChildStyle(self: *const ViewSelf, child_node_id: NodeId) *const Style {
                    return &self.taffy.nodeData(child_node_id).style;
                }

                /// The node's detailed grid info, which the grid algorithm refills on every full
                /// layout. It is allocated the first time the node is laid out as a grid and then
                /// kept, so that later layouts reuse its memory.
                pub fn detailedGridInfo(self: *ViewSelf, node_id: NodeId) LayoutError!?*DetailedGridInfo {
                    const data = self.taffy.nodeData(node_id);
                    switch (data.detailed_layout_info) {
                        .grid => |info| return info,
                        .none => {
                            const info = try self.taffy.gpa.create(DetailedGridInfo);
                            info.* = .{};
                            data.detailed_layout_info = .{ .grid = info };
                            return info;
                        },
                    }
                }

                // RoundTree

                pub fn getUnroundedLayout(self: *const ViewSelf, node: NodeId) Layout {
                    return self.taffy.nodeData(node).unrounded_layout;
                }

                pub fn setFinalLayout(self: *ViewSelf, node_id: NodeId, l: *const Layout) void {
                    const node = self.taffy.nodeData(node_id);
                    node.final_layout = l.*;
                    node.rounded_pass = 0;
                }

                /// Whether the final layouts of the node and of everything below it are what
                /// rounding against the passed parent offset would produce again: nothing in
                /// the subtree changed since it was last rounded, against the same offset.
                pub fn isRoundingCurrent(self: *const ViewSelf, node_id: NodeId, parent_x: f32, parent_y: f32) bool {
                    const node = self.taffy.nodeData(node_id);
                    return node.layout_stamp <= node.rounded_pass and
                        node.rounded_origin[0] == @as(u32, @bitCast(parent_x)) and
                        node.rounded_origin[1] == @as(u32, @bitCast(parent_y));
                }

                /// Record that the node's final layout was rounded against the passed parent
                /// offset. Called after `setFinalLayout`.
                pub fn markRounded(self: *ViewSelf, node_id: NodeId, parent_x: f32, parent_y: f32) void {
                    const node = self.taffy.nodeData(node_id);
                    node.rounded_pass = self.taffy.layout_pass;
                    node.rounded_origin = .{ @bitCast(parent_x), @bitCast(parent_y) };
                }

                /// Called when a rounding pass ends. Later layout changes get a newer stamp.
                pub fn finishRounding(self: *ViewSelf) void {
                    self.taffy.layout_pass += 1;
                }

                pub fn isOutOfFlow(self: *const ViewSelf, node_id: NodeId) bool {
                    const node = self.taffy.nodeData(node_id);
                    return node.style.position.isOutOfFlow() and node.style.display != .none;
                }

                pub fn hoistedChildCount(self: *const ViewSelf, node_id: NodeId) usize {
                    return self.taffy.nodeData(node_id).hoisted_children.items.len;
                }

                pub fn getHoistedChildId(self: *const ViewSelf, node_id: NodeId, index: usize) NodeId {
                    return self.taffy.nodeData(node_id).hoisted_children.items[index];
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Dimension = style_mod.Dimension;
const LengthPercentage = style_mod.LengthPercentage;
const LengthPercentageAuto = style_mod.LengthPercentageAuto;
const Rect = geometry.Rect;
const traits = @import("traits.zig");

fn sizeMeasureFunction(inputs: LayoutInput, node_context: ?*Size(f32), node_style: *const Style) LayoutOutput {
    const Content = struct {
        context: ?*Size(f32),
        pub fn measure(self: @This(), known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
            _ = available_space;
            return known_dimensions.unwrapOr(if (self.context) |c| c.* else Size(f32).zero);
        }
    };
    return compute_mod.computeLeafLayout(inputs, node_style, style_mod.NoCalc{}, Content{ .context = node_context });
}

/// Upstream `size_measure_function`, as a measurer
const SizeMeasurer = struct {
    calls: usize = 0,
    pub fn measure(self: *SizeMeasurer, inputs: LayoutInput, node_id: NodeId, node_context: ?*Size(f32), node_style: *const Style) LayoutOutput {
        _ = node_id;
        self.calls += 1;
        return sizeMeasureFunction(inputs, node_context, node_style);
    }
};

test "interfaces are implemented" {
    const Tree = TaffyTree(void);
    traits.assertImplements(Tree, &.{ .traverse_tree, .cache_tree, .print_tree });
    traits.assertImplements(Tree.View(LeafMeasurer(void)), &.{
        .layout_partial_tree,      .layout_containing_block, .cache_tree,             .round_tree,
        .layout_flexbox_container, .layout_grid_container,   .layout_block_container,
    });
}

test "new should allocate default capacity" {
    const default_capacity: usize = 16; // This is the capacity defined in `init`
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    try testing.expect(taffy.nodes.capacity() >= default_capacity);
}

test "test with capacity" {
    const capacity: usize = 8;
    var taffy = try TaffyTree(void).withCapacity(testing.allocator, capacity);
    defer taffy.deinit();

    try testing.expect(taffy.nodes.capacity() >= capacity);
}

test "test new leaf" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const node = try taffy.newLeaf(.{});

    // node should be in the taffy tree and have no children
    try testing.expect(taffy.childCount(node) == 0);
}

test "new leaf with context" {
    var taffy = try TaffyTree(Size(f32)).init(testing.allocator);
    defer taffy.deinit();

    const node = try taffy.newLeafWithContext(.{}, Size(f32).zero);

    // node should be in the taffy tree and have no children
    try testing.expect(taffy.childCount(node) == 0);
    try testing.expectEqual(Size(f32).zero, taffy.getNodeContext(node).?.*);
}

// Test that newWithChildren works as expected
test "test new with children" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    // node should have two children
    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
    try testing.expectEqual(child0, taffy.children(node)[0]);
    try testing.expectEqual(child1, taffy.children(node)[1]);
}

test "remove node should remove" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const node = try taffy.newLeaf(.{});

    _ = taffy.remove(node);
    try testing.expectEqual(@as(usize, 0), taffy.totalNodeCount());
}

test "remove node should detach hierarchy" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    // Build a linear tree layout: <0> <- <1> <- <2>
    const node2 = try taffy.newLeaf(.{});
    const node1 = try taffy.newWithChildren(.{}, &.{node2});
    const node0 = try taffy.newWithChildren(.{}, &.{node1});

    // Both node0 and node1 should have 1 child nodes
    try testing.expectEqualSlices(NodeId, &.{node1}, taffy.children(node0));
    try testing.expectEqualSlices(NodeId, &.{node2}, taffy.children(node1));

    // Disconnect the tree: <0> <2>
    _ = taffy.remove(node1);

    // Both remaining nodes should have no child nodes
    try testing.expectEqual(@as(usize, 0), taffy.children(node0).len);
    try testing.expectEqual(@as(usize, 0), taffy.children(node2).len);
    try testing.expectEqual(@as(?NodeId, null), taffy.parent(node2));
}

test "remove last node" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const parent_node = try taffy.newLeaf(.{});
    const child = try taffy.newLeaf(.{});
    try taffy.addChild(parent_node, child);

    _ = taffy.remove(child);
    _ = taffy.remove(parent_node);
}

// Related to: https://github.com/DioxusLabs/taffy/issues/998
test "remove node marks parent dirty" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    // The root's height comes entirely from its child's 1px bottom border
    var child_style: Style = .{};
    child_style.border = .{ .left = .fromLength(0.0), .right = .fromLength(0.0), .top = .fromLength(0.0), .bottom = .fromLength(1.0) };
    const child = try taffy.newLeaf(child_style);
    const root = try taffy.newWithChildren(.{}, &.{child});

    try taffy.computeLayout(root, Size(AvailableSpace).min_content);
    try testing.expectEqual(@as(f32, 1.0), taffy.layout(root).size.height);

    _ = taffy.remove(child);
    try testing.expect(taffy.dirty(root));

    // The root no longer has any children, so its height should shrink back to zero
    try taffy.computeLayout(root, Size(AvailableSpace).min_content);
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(root).size.height);
}

test "set measure" {
    var taffy = try TaffyTree(Size(f32)).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeafWithContext(.{}, .{ .width = 200.0, .height = 200.0 });
    var measurer: SizeMeasurer = .{};
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(f32, 200.0), taffy.layout(node).size.width);

    taffy.setNodeContext(node, Size(f32){ .width = 100.0, .height = 100.0 });
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.width);
    try testing.expectEqual(@as(usize, 2), measurer.calls);

    // An identical relayout is served from the cache
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(usize, 2), measurer.calls);
}

test "set measure of previously unmeasured node" {
    var taffy = try TaffyTree(Size(f32)).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{});
    var measurer: SizeMeasurer = .{};
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(node).size.width);

    taffy.setNodeContext(node, Size(f32){ .width = 100.0, .height = 100.0 });
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.width);
}

// Test that adding `addChild()` works
test "add child" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{});
    try testing.expectEqual(@as(usize, 0), taffy.childCount(node));

    const child0 = try taffy.newLeaf(.{});
    try taffy.addChild(node, child0);
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));

    const child1 = try taffy.newLeaf(.{});
    try taffy.addChild(node, child1);
    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
}

test "insert child at index" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const child2 = try taffy.newLeaf(.{});

    const node = try taffy.newLeaf(.{});
    try testing.expectEqual(@as(usize, 0), taffy.childCount(node));

    try taffy.insertChildAtIndex(node, 0, child0);
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));
    try testing.expectEqual(child0, taffy.children(node)[0]);

    try taffy.insertChildAtIndex(node, 0, child1);
    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
    try testing.expectEqual(child1, taffy.children(node)[0]);
    try testing.expectEqual(child0, taffy.children(node)[1]);

    try taffy.insertChildAtIndex(node, 1, child2);
    try testing.expectEqual(@as(usize, 3), taffy.childCount(node));
    try testing.expectEqual(child1, taffy.children(node)[0]);
    try testing.expectEqual(child2, taffy.children(node)[1]);
    try testing.expectEqual(child0, taffy.children(node)[2]);

    try testing.expectError(error.ChildIndexOutOfBounds, taffy.insertChildAtIndex(node, 4, child2));
}

test "set children" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
    try testing.expectEqual(child0, taffy.children(node)[0]);
    try testing.expectEqual(child1, taffy.children(node)[1]);

    const child2 = try taffy.newLeaf(.{});
    const child3 = try taffy.newLeaf(.{});
    try taffy.setChildren(node, &.{ child2, child3 });

    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
    try testing.expectEqual(child2, taffy.children(node)[0]);
    try testing.expectEqual(child3, taffy.children(node)[1]);
    try testing.expectEqual(@as(?NodeId, null), taffy.parent(child0));
}

// Test that removing a child works
test "remove child" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));

    _ = taffy.removeChild(node, child0);
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));
    try testing.expectEqual(child1, taffy.children(node)[0]);

    _ = taffy.removeChild(node, child1);
    try testing.expectEqual(@as(usize, 0), taffy.childCount(node));
}

test "remove child at index" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));

    _ = try taffy.removeChildAtIndex(node, 0);
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));
    try testing.expectEqual(child1, taffy.children(node)[0]);

    _ = try taffy.removeChildAtIndex(node, 0);
    try testing.expectEqual(@as(usize, 0), taffy.childCount(node));
    try testing.expectError(error.ChildIndexOutOfBounds, taffy.removeChildAtIndex(node, 0));
}

test "remove children range" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const child2 = try taffy.newLeaf(.{});
    const child3 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1, child2, child3 });

    try testing.expectEqual(@as(usize, 4), taffy.childCount(node));

    // upstream `1..=2`
    taffy.removeChildrenRange(node, 1, 3);
    try testing.expectEqual(@as(usize, 2), taffy.childCount(node));
    try testing.expectEqualSlices(NodeId, &.{ child0, child3 }, taffy.children(node));
    for ([_]NodeId{ child0, child3 }) |child| {
        try testing.expectEqual(@as(?NodeId, node), taffy.parent(child));
    }
    for ([_]NodeId{ child1, child2 }) |child| {
        try testing.expectEqual(@as(?NodeId, null), taffy.parent(child));
    }
}

// Related to: https://github.com/DioxusLabs/taffy/issues/510
test "remove child updates parents" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const parent_node = try taffy.newLeaf(.{});
    const child = try taffy.newLeaf(.{});

    try taffy.addChild(parent_node, child);

    _ = taffy.remove(parent_node);

    // Once the parent is removed this shouldn't panic.
    try taffy.setChildren(child, &.{});
}

test "replace child at index" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});

    const node = try taffy.newWithChildren(.{}, &.{child0});
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));
    try testing.expectEqual(child0, taffy.children(node)[0]);

    try testing.expectEqual(child0, try taffy.replaceChildAtIndex(node, 0, child1));
    try testing.expectEqual(@as(usize, 1), taffy.childCount(node));
    try testing.expectEqual(child1, taffy.children(node)[0]);
    try testing.expectEqual(@as(?NodeId, null), taffy.parent(child0));
    try testing.expectError(error.ChildIndexOutOfBounds, taffy.replaceChildAtIndex(node, 1, child0));
}

test "test child at index" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const child2 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1, child2 });

    try testing.expectEqual(child0, try taffy.childAtIndex(node, 0));
    try testing.expectEqual(child1, try taffy.childAtIndex(node, 1));
    try testing.expectEqual(child2, try taffy.childAtIndex(node, 2));
    try testing.expectError(error.ChildIndexOutOfBounds, taffy.childAtIndex(node, 3));
}

test "test child count" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try testing.expect(taffy.childCount(node) == 2);
    try testing.expect(taffy.childCount(child0) == 0);
    try testing.expect(taffy.childCount(child1) == 0);
}

test "test children" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try testing.expectEqualSlices(NodeId, &.{ child0, child1 }, taffy.children(node));
    try testing.expectEqual(@as(usize, 0), taffy.children(child0).len);

    var iter = taffy.childIds(node);
    try testing.expectEqual(@as(?NodeId, child0), iter.next());
    try testing.expectEqual(@as(?NodeId, child1), iter.next());
    try testing.expectEqual(@as(?NodeId, null), iter.next());
    try testing.expectEqual(child1, taffy.getChildId(node, 1));
}

test "test set style" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const node = try taffy.newLeaf(.{});
    try testing.expectEqual(Display.flex, taffy.style(node).display);

    taffy.setStyle(node, .{ .display = .none });
    try testing.expectEqual(Display.none, taffy.style(node).display);
}

test "test style" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const node_style: Style = .{ .display = .none, .flex_direction = .row_reverse };

    const node = try taffy.newLeaf(node_style);

    const res = taffy.style(node);
    try testing.expectEqual(Display.none, res.display);
    try testing.expectEqual(style_mod.FlexDirection.row_reverse, res.flex_direction);
}

test "test layout" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{});

    try testing.expect(taffy.layout(node).eql(.{}));
}

test "mark dirty on leaves" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{ .size = Size(Dimension).fromLengths(10.0, 10.0) });
    try testing.expect(taffy.dirty(node));

    try taffy.computeLayout(node, Size(AvailableSpace).max_content);
    try testing.expect(!taffy.dirty(node));

    taffy.markDirty(node);
    try testing.expect(taffy.dirty(node));

    // Changing the style marks the node dirty
    try taffy.computeLayout(node, Size(AvailableSpace).max_content);
    taffy.setStyle(node, .{ .size = Size(Dimension).fromLengths(20.0, 10.0) });
    try testing.expect(taffy.dirty(node));
    try taffy.computeLayout(node, Size(AvailableSpace).max_content);
    try testing.expectEqual(@as(f32, 20.0), taffy.layout(node).size.width);

    // Marking a child dirty marks its (cached) ancestors dirty
    const parent_node = try taffy.newLeaf(.{});
    try taffy.addChild(parent_node, node);
    taffy.cacheStore(parent_node, &LayoutInput.hidden, LayoutOutput.hidden); // ignored: hidden inputs are never cached
    try testing.expect(taffy.dirty(parent_node));
    var input = LayoutInput.hidden;
    input.run_mode = .compute_size;
    taffy.cacheStore(parent_node, &input, LayoutOutput.fromOuterSize(Size(f32).zero));
    try testing.expect(!taffy.dirty(parent_node));
    // Laying the child out as a root invalidates its parent, which positioned it differently
    try taffy.computeLayout(node, Size(AvailableSpace).max_content);
    try testing.expect(taffy.dirty(parent_node));
    taffy.cacheStore(parent_node, &input, LayoutOutput.fromOuterSize(Size(f32).zero));
    try testing.expect(!taffy.dirty(parent_node));
    taffy.markDirty(node);
    try testing.expect(taffy.dirty(node));
    try testing.expect(taffy.dirty(parent_node));
}

test "test mark dirty" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{});
    const child1 = try taffy.newLeaf(.{});
    const node = try taffy.newWithChildren(.{}, &.{ child0, child1 });

    try taffy.computeLayout(node, Size(AvailableSpace).max_content);

    try testing.expect(!taffy.dirty(child0));
    try testing.expect(!taffy.dirty(child1));
    try testing.expect(!taffy.dirty(node));

    taffy.markDirty(node);
    try testing.expect(!taffy.dirty(child0));
    try testing.expect(!taffy.dirty(child1));
    try testing.expect(taffy.dirty(node));

    try taffy.computeLayout(node, Size(AvailableSpace).max_content);
    taffy.markDirty(child0);
    try testing.expect(taffy.dirty(child0));
    try testing.expect(!taffy.dirty(child1));
    try testing.expect(taffy.dirty(node));
}

test "compute layout should produce valid result" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeaf(.{
        .size = .{ .width = Dimension.fromLength(10), .height = Dimension.fromLength(10) },
    });
    try taffy.computeLayout(node, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 100.0 } });
    try testing.expectEqual(Size(f32){ .width = 10.0, .height = 10.0 }, taffy.layout(node).size);
}

test "make sure layout location is top left" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const node = try taffy.newLeaf(.{
        .size = .{ .width = Dimension.fromPercent(1.0), .height = Dimension.fromPercent(1.0) },
    });

    const root = try taffy.newWithChildren(.{
        .size = .{ .width = Dimension.fromLength(100.0), .height = Dimension.fromLength(100.0) },
        .padding = .{ .left = .fromLength(10.0), .right = .fromLength(20.0), .top = .fromLength(30.0), .bottom = .fromLength(40.0) },
    }, &.{node});

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);

    // If Layout.location represents top-left coord, 'node' location
    // must be (due applied 'root' padding): {x: 10, y: 30}.
    //
    // It's important, since result will be different for each other
    // coordinate space:
    // - bottom-left:  {x: 10, y: 40}
    // - top-right:    {x: 20, y: 30}
    // - bottom-right: {x: 20, y: 40}
    const l = taffy.layout(node);
    try testing.expectEqual(@as(f32, 10.0), l.location.x);
    try testing.expectEqual(@as(f32, 30.0), l.location.y);
}

test "set children reparents" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{});
    const old_parent = try taffy.newWithChildren(.{}, &.{child});

    const new_parent = try taffy.newLeaf(.{});
    try taffy.setChildren(new_parent, &.{child});

    try testing.expectEqual(@as(usize, 0), taffy.children(old_parent).len);
    try testing.expectEqual(@as(?NodeId, new_parent), taffy.parent(child));
}

test "remove and clear drop node contexts" {
    var taffy = try TaffyTree(u32).init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeafWithContext(.{}, 7);
    _ = taffy.remove(node);
    try testing.expectEqual(@as(?*const u32, null), taffy.getNodeContext(node));

    for (0..8) |i| _ = try taffy.newLeafWithContext(.{}, @intCast(i));
    try testing.expectEqual(@as(usize, 8), taffy.totalNodeCount());
    taffy.clear();
    try testing.expectEqual(@as(usize, 0), taffy.totalNodeCount());
}

test "stale node ids are detected" {
    var taffy = try TaffyTree(u32).init(testing.allocator);
    defer taffy.deinit();
    const a = try taffy.newLeafWithContext(.{}, 1);
    _ = taffy.remove(a);
    // The slot is reused by the next node, with a different id
    const b = try taffy.newLeafWithContext(.{}, 2);
    try testing.expect(a != b);
    try testing.expectEqual(@as(u32, @truncate(a.inner)), @as(u32, @truncate(b.inner)));
    try testing.expect(taffy.getNodeContextMut(a) == null);
    try testing.expectEqual(@as(u32, 2), taffy.getNodeContextMut(b).?.*);
}

test "node context accessors" {
    var taffy = try TaffyTree(u32).init(testing.allocator);
    defer taffy.deinit();
    const a = try taffy.newLeafWithContext(.{}, 1);
    const b = try taffy.newLeafWithContext(.{}, 2);
    const c = try taffy.newLeaf(.{});
    try testing.expect(taffy.getNodeContext(c) == null);
    const both = taffy.getDisjointNodeContextMut(2, .{ a, b }).?;
    both[0].* += 10;
    both[1].* += 20;
    try testing.expectEqual(@as(u32, 11), taffy.getNodeContext(a).?.*);
    try testing.expectEqual(@as(u32, 22), taffy.getNodeContext(b).?.*);
    try testing.expect(taffy.getDisjointNodeContextMut(2, .{ a, a }) == null);
    try testing.expect(taffy.getDisjointNodeContextMut(2, .{ a, c }) == null);
    taffy.setNodeContext(a, null);
    try testing.expect(taffy.getNodeContext(a) == null);
}

test "hidden subtrees, rounding and debug output" {
    var taffy = try TaffyTree(Size(f32)).init(testing.allocator);
    defer taffy.deinit();

    const leaf0 = try taffy.newLeafWithContext(.{}, .{ .width = 10.4, .height = 3.0 });
    const leaf1 = try taffy.newLeaf(.{ .position = .absolute });
    const root = try taffy.newWithChildren(.{ .display = .none }, &.{ leaf0, leaf1 });
    const lone = try taffy.newLeafWithContext(.{ .padding = Rect(style_mod.LengthPercentage).fromLength(0.25) }, .{ .width = 10.25, .height = 3.0 });

    var measurer: SizeMeasurer = .{};
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(@as(usize, 0), measurer.calls);
    try testing.expectEqual(Size(f32).zero, taffy.layout(leaf0).size);
    try testing.expect(taffy.layout(leaf1).eql(Layout.withOrder(0)));

    try taffy.computeLayoutWithMeasure(lone, Size(AvailableSpace).max_content, &measurer);
    try testing.expectEqual(Size(f32){ .width = 11.0, .height = 4.0 }, taffy.layout(lone).size);
    try testing.expectEqual(Size(f32){ .width = 10.75, .height = 3.5 }, taffy.unroundedLayout(lone).size);
    taffy.disableRounding();
    try testing.expectEqual(Size(f32){ .width = 10.75, .height = 3.5 }, taffy.layout(lone).size);
    taffy.enableRounding();

    try testing.expectEqualStrings("NONE", taffy.getDebugLabel(root));
    try testing.expectEqualStrings("LEAF", taffy.getDebugLabel(lone));
    taffy.setStyle(root, .{ .flex_direction = .column });
    try testing.expectEqualStrings("FLEX COL", taffy.getDebugLabel(root));
    try testing.expect(taffy.detailedLayoutInfo(root).* == .none);
    try testing.expectEqual(@as(usize, 0), taffy.hoistedChildren(root).len);

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try print.writeTree(&w, &taffy, root);
    const expected_prefix = "TREE\n└──  FLEX COL [x: 0    y: 0    w: 0    h: 0    overflow: l:0 r:0 t:0 b:0, border: l:0 r:0 t:0 b:0, padding: l:0 r:0 t:0 b:0] (NodeId(";
    try testing.expect(std.mem.startsWith(u8, w.buffered(), expected_prefix));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\n    ├──  LEAF [x: 0 ") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\n    └──  LEAF [x: 0 ") != null);
}

test "the layout view implements every interface method" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{ .size = Size(Dimension).fromLengths(3.0, 4.0) });
    const root = try taffy.newWithChildren(.{ .display = .block }, &.{child});

    var view = taffy.asLayoutTree();
    try testing.expectEqual(@as(usize, 1), view.childCount(root));
    try testing.expectEqual(child, view.getChildId(root, 0));
    var iter = view.childIds(root);
    try testing.expectEqual(@as(?NodeId, child), iter.next());
    try testing.expect(view.getBlockContainerStyle(root).display == .block);
    try testing.expect(view.getBlockChildStyle(child) == taffy.style(child));
    try testing.expect(view.getFlexboxContainerStyle(root) == taffy.style(root));
    try testing.expect(view.getFlexboxChildStyle(child) == taffy.style(child));
    try testing.expect(view.getGridContainerStyle(root) == taffy.style(root));
    try testing.expect(view.getGridChildStyle(child) == taffy.style(child));
    try testing.expect(view.getOofItemStyle(child) == taffy.style(child));
    try testing.expect(view.getDetailedLayoutInfo(root).* == .none);
    // Detailed grid info storage is created on first use, then reused, and freed with the node
    const info = (try view.detailedGridInfo(root)).?;
    try testing.expect(view.getDetailedLayoutInfo(root).* == .grid);
    info.items = try testing.allocator.alloc(@import("../compute/grid.zig").DetailedGridItemsInfo, 2);
    try testing.expect((try view.detailedGridInfo(root)).? == info);
    try testing.expectEqual(@as(usize, 2), taffy.detailedLayoutInfo(root).grid.items.len);
    try testing.expectEqual(@as(f32, 0.0), traits.calc(&view, 1, 1.0));
    try testing.expect(!view.isOutOfFlow(child));

    // Lay out the leaf child directly through the block-child entry point, without a block context
    const output = try view.computeBlockChildLayout(child, .{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = Size(?f32).none,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = Size(?f32).none,
        .available_space = Size(AvailableSpace).max_content,
        .vertical_margins_are_collapsible = geometry.Line(bool).false,
    }, null);
    try testing.expectEqual(Size(f32){ .width = 3.0, .height = 4.0 }, output.size);
    try testing.expect(!taffy.dirty(child));
    try testing.expectEqual(@as(f32, 4.0), try traits.measureChildSize(&view, child, Size(?f32).none, Size(?f32).none, Size(AvailableSpace).max_content, .inherent_size, .vertical, geometry.Line(bool).false));

    try view.addHoistedChildren(root, &.{child});
    try testing.expectEqual(@as(usize, 1), view.hoistedChildCount(root));
    try testing.expectEqual(child, view.getHoistedChildId(root, 0));
    view.clearHoistedChildren(root);
    try testing.expectEqual(@as(usize, 0), taffy.hoistedChildren(root).len);

    view.setFinalLayout(child, &Layout.withOrder(5));
    try testing.expectEqual(@as(u32, 5), taffy.layout(child).order);
    try testing.expectEqual(@as(u32, 0), view.getUnroundedLayout(child).order);
    try testing.expectEqualStrings("BLOCK", taffy.getDebugLabel(root));

    // Compile (but do not run) the stderr printing entry point
    var print_it = false;
    _ = &print_it;
    if (print_it) taffy.printTree(root);
}

/// A tree with fractional sizes and offsets (so that rounding depends on cumulative positions),
/// nested flex and block containers, an absolutely positioned box and a hidden node
const RoundingFixture = struct {
    taffy: TaffyTree(void),
    nodes: [10]NodeId,

    const root = 0;
    const row = 1;
    const column = 2;
    const leaf_a = 3;
    const leaf_b = 4;
    const leaf_c = 5;
    const abs = 6;
    const hidden = 7;
    const block = 8;
    const leaf_d = 9;

    fn leafStyle(width: f32, height: f32) Style {
        return .{ .size = .{ .width = .fromLength(width), .height = .fromLength(height) } };
    }

    fn init() !RoundingFixture {
        var taffy = try TaffyTree(void).init(testing.allocator);
        errdefer taffy.deinit();
        var nodes: [10]NodeId = undefined;
        nodes[leaf_a] = try taffy.newLeaf(leafStyle(10.3, 7.4));
        nodes[leaf_b] = try taffy.newLeaf(leafStyle(20.6, 5.5));
        nodes[leaf_c] = try taffy.newLeaf(leafStyle(3.7, 9.2));
        nodes[leaf_d] = try taffy.newLeaf(leafStyle(8.4, 2.6));
        var abs_style = leafStyle(4.5, 4.5);
        abs_style.position = .absolute;
        abs_style.inset = .{ .left = .fromLength(1.3), .top = .fromLength(2.7), .right = .auto, .bottom = .auto };
        nodes[abs] = try taffy.newLeaf(abs_style);
        var hidden_style = leafStyle(5.0, 5.0);
        hidden_style.display = .none;
        nodes[hidden] = try taffy.newLeaf(hidden_style);
        nodes[block] = try taffy.newWithChildren(.{
            .display = .block,
            .padding = Rect(LengthPercentage).fromLength(0.6),
        }, &.{ nodes[leaf_d], nodes[abs] });
        nodes[column] = try taffy.newWithChildren(.{
            .display = .flex,
            .flex_direction = .column,
            .position = .relative,
            .margin = Rect(LengthPercentageAuto).fromLength(1.4),
        }, &.{ nodes[leaf_c], nodes[block], nodes[hidden] });
        nodes[row] = try taffy.newWithChildren(.{
            .display = .flex,
            .gap = .{ .width = .fromLength(0.7), .height = .zero },
        }, &.{ nodes[leaf_a], nodes[column], nodes[leaf_b] });
        nodes[root] = try taffy.newWithChildren(.{
            .display = .block,
            .padding = Rect(LengthPercentage).fromLength(2.3),
        }, &.{nodes[row]});
        return .{ .taffy = taffy, .nodes = nodes };
    }

    fn deinit(self: *RoundingFixture) void {
        self.taffy.deinit();
    }

    const Step = union(enum) {
        /// Resize a leaf
        resize: struct { node: usize, width: f32, height: f32 },
        /// Change the padding of the root, which moves everything below it
        root_padding: f32,
        /// Show or hide a node
        display: struct { node: usize, value: style_mod.Display },
        /// Remove a node from its parent
        remove: struct { parent: usize, child: usize },
        /// Append a node to a parent
        append: struct { parent: usize, child: usize },
        /// Mark a node dirty without changing anything
        dirty: usize,
        /// Lay out a subtree as if it were the root
        layout_subtree: usize,
        /// Lay out the tree with rounding turned off
        layout_unrounded,
        /// Lay out the tree with a different available width
        layout_width: f32,
    };

    const available: Size(AvailableSpace) = .{ .width = .{ .definite = 97.3 }, .height = .max_content };

    fn apply(self: *RoundingFixture, step: Step) !void {
        const taffy = &self.taffy;
        switch (step) {
            .resize => |r| {
                var s = taffy.style(self.nodes[r.node]).*;
                s.size = .{ .width = .fromLength(r.width), .height = .fromLength(r.height) };
                taffy.setStyle(self.nodes[r.node], s);
            },
            .root_padding => |padding| {
                var s = taffy.style(self.nodes[root]).*;
                s.padding = Rect(LengthPercentage).fromLength(padding);
                taffy.setStyle(self.nodes[root], s);
            },
            .display => |d| {
                var s = taffy.style(self.nodes[d.node]).*;
                s.display = d.value;
                taffy.setStyle(self.nodes[d.node], s);
            },
            .remove => |r| _ = taffy.removeChild(self.nodes[r.parent], self.nodes[r.child]),
            .append => |a| try taffy.addChild(self.nodes[a.parent], self.nodes[a.child]),
            .dirty => |node| taffy.markDirty(self.nodes[node]),
            .layout_subtree => |node| try taffy.computeLayout(self.nodes[node], available),
            .layout_unrounded => {
                taffy.disableRounding();
                try taffy.computeLayout(self.nodes[root], available);
                taffy.enableRounding();
            },
            .layout_width => |width| try taffy.computeLayout(self.nodes[root], .{ .width = .{ .definite = width }, .height = .max_content }),
        }
    }
};

/// Apply `steps` to a tree, laying it out after every step, and check each time that the final
/// layouts it holds equal those produced by rounding the whole tree again without skipping
fn expectIncrementalRoundingMatches(steps: []const RoundingFixture.Step) !void {
    var fixture = try RoundingFixture.init();
    defer fixture.deinit();
    const taffy = &fixture.taffy;
    const root_node = fixture.nodes[RoundingFixture.root];

    try taffy.computeLayout(root_node, RoundingFixture.available);
    for (steps, 0..) |step, step_index| {
        try fixture.apply(step);
        try taffy.computeLayout(root_node, RoundingFixture.available);

        var incremental: [fixture.nodes.len]Layout = undefined;
        for (&incremental, fixture.nodes) |*l, node| l.* = taffy.layout(node).*;

        // Forget what was rounded, so that the next rounding pass visits every node
        for (fixture.nodes) |node| taffy.nodeData(node).rounded_pass = 0;
        var view = taffy.asLayoutTree();
        compute_mod.roundLayout(&view, root_node);

        for (incremental, fixture.nodes, 0..) |got, node, index| {
            // A detached node is not reached by rounding and keeps whatever layout it had
            if (index != RoundingFixture.root and taffy.parent(node) == null) continue;
            const want = taffy.layout(node).*;
            if (!got.eql(want)) {
                std.debug.print("step {d}, node {d}: got {any}\nwant {any}\n", .{ step_index, index, got, want });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "rounding after a relayout matches rounding the whole tree" {
    const F = RoundingFixture;
    const scenarios = [_][]const F.Step{
        &.{.{ .dirty = F.leaf_d }},
        &.{.{ .resize = .{ .node = F.leaf_a, .width = 11.8, .height = 7.4 } }},
        &.{.{ .resize = .{ .node = F.leaf_d, .width = 8.4, .height = 6.1 } }},
        &.{ .{ .resize = .{ .node = F.leaf_c, .width = 3.7, .height = 0.6 } }, .{ .resize = .{ .node = F.leaf_c, .width = 3.7, .height = 9.2 } } },
        &.{.{ .root_padding = 3.1 }},
        &.{ .{ .root_padding = 0.5 }, .{ .resize = .{ .node = F.leaf_b, .width = 1.2, .height = 30.9 } } },
        &.{.{ .display = .{ .node = F.column, .value = .none } }},
        &.{ .{ .display = .{ .node = F.column, .value = .none } }, .{ .display = .{ .node = F.column, .value = .flex } } },
        &.{.{ .display = .{ .node = F.hidden, .value = .block } }},
        &.{.{ .remove = .{ .parent = F.row, .child = F.leaf_a } }},
        &.{ .{ .remove = .{ .parent = F.row, .child = F.leaf_a } }, .{ .append = .{ .parent = F.block, .child = F.leaf_a } } },
        &.{ .{ .remove = .{ .parent = F.block, .child = F.abs } }, .{ .append = .{ .parent = F.row, .child = F.abs } } },
        &.{.{ .layout_subtree = F.column }},
        &.{ .{ .layout_subtree = F.block }, .{ .resize = .{ .node = F.leaf_d, .width = 2.2, .height = 2.6 } }, .{ .layout_subtree = F.row } },
        &.{ .layout_unrounded, .{ .resize = .{ .node = F.leaf_d, .width = 9.9, .height = 2.6 } }, .layout_unrounded },
        &.{ .{ .resize = .{ .node = F.leaf_a, .width = 0.4, .height = 7.4 } }, .layout_unrounded },
        &.{ .{ .layout_width = 51.9 }, .{ .dirty = F.leaf_b } },
        &.{ .{ .layout_width = 13.1 }, .{ .layout_width = 200.6 } },
    };
    for (scenarios, 0..) |steps, index| {
        expectIncrementalRoundingMatches(steps) catch |err| {
            std.debug.print("scenario {d}\n", .{index});
            return err;
        };
    }
}

test "a hidden node keeps its order when its parent is laid out again" {
    var fixture = try RoundingFixture.init();
    defer fixture.deinit();
    const F = RoundingFixture;
    const taffy = &fixture.taffy;
    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    // The hidden node is the third child of the column
    try testing.expectEqual(@as(u32, 2), taffy.layout(fixture.nodes[F.hidden]).order);
    taffy.markDirty(fixture.nodes[F.leaf_c]);
    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    try testing.expectEqual(@as(u32, 2), taffy.layout(fixture.nodes[F.hidden]).order);
}

test "laying out a subtree on its own does not leave it misplaced in the full tree" {
    var fixture = try RoundingFixture.init();
    defer fixture.deinit();
    var fresh = try RoundingFixture.init();
    defer fresh.deinit();
    const F = RoundingFixture;
    const taffy = &fixture.taffy;

    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    try taffy.computeLayout(fixture.nodes[F.column], .{ .width = .{ .definite = 31.7 }, .height = .max_content });
    try testing.expect(taffy.dirty(fixture.nodes[F.row]));
    try testing.expect(taffy.dirty(fixture.nodes[F.root]));
    try taffy.computeLayout(fixture.nodes[F.root], F.available);

    try fresh.taffy.computeLayout(fresh.nodes[F.root], F.available);
    for (fixture.nodes, fresh.nodes) |a, b| {
        try testing.expect(taffy.layout(a).eql(fresh.taffy.layout(b).*));
    }
}

test "rounding skips unchanged subtrees" {
    var fixture = try RoundingFixture.init();
    defer fixture.deinit();
    const F = RoundingFixture;
    const taffy = &fixture.taffy;
    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    const first_pass = taffy.nodeData(fixture.nodes[F.leaf_a]).rounded_pass;
    try testing.expect(first_pass != 0);

    // Changing one leaf's height re-rounds the leaf and its ancestors, but not its neighbours
    var s = taffy.style(fixture.nodes[F.leaf_d]).*;
    s.size.height = .fromLength(2.6);
    taffy.setStyle(fixture.nodes[F.leaf_d], s);
    taffy.markDirty(fixture.nodes[F.leaf_d]);
    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    try testing.expectEqual(first_pass, taffy.nodeData(fixture.nodes[F.leaf_a]).rounded_pass);
    try testing.expectEqual(first_pass, taffy.nodeData(fixture.nodes[F.leaf_d]).rounded_pass);

    s.size.height = .fromLength(14.9);
    taffy.setStyle(fixture.nodes[F.leaf_d], s);
    try taffy.computeLayout(fixture.nodes[F.root], F.available);
    try testing.expect(taffy.nodeData(fixture.nodes[F.leaf_d]).rounded_pass > first_pass);
    try testing.expect(taffy.nodeData(fixture.nodes[F.block]).rounded_pass > first_pass);
    try testing.expectEqual(first_pass, taffy.nodeData(fixture.nodes[F.leaf_c]).rounded_pass);
}
