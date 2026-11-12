//! Low-level access to the layout algorithms themselves. For a higher-level API, see `TaffyTree`.
//!
//! ### Layout functions
//!
//! The layout functions all take a `tree: anytype` parameter (a pointer to a type implementing
//! `LayoutPartialTree`, see `src/tree/traits.zig`), which represents a single container node and
//! it's direct children.
//!
//! | Function                 | Purpose                                                                                                                                                                                            |
//! | ---                      | ---                                                                                                                                                                                                |
//! | `computeFlexboxLayout`   | Layout a Flexbox container and it's direct children                                                                                                                                                |
//! | `computeGridLayout`      | Layout a CSS Grid container and it's direct children                                                                                                                                               |
//! | `computeBlockLayout`     | Layout a Block container and it's direct children                                                                                                                                                  |
//! | `computeLeafLayout`      | Applies common properties like padding/border/aspect-ratio to a node before deferring to a passed measure function to determine it's size. Can be applied to nodes like text or image nodes.      |
//! | `computeRootLayout`      | Layout the root node of a tree (regardless of it's layout mode). This function is typically called once to begin a layout run.                                                                     |
//! | `computeHiddenLayout`    | Mark a node as hidden during layout (like `Display.none`)                                                                                                                                          |
//! | `computeCachedLayout`    | Attempts to find a cached layout for the specified node and layout inputs. Uses the provided function to compute the layout (and then stores the result in the cache) if no cached layout is found. |
//!
//! ### Other functions
//!
//! | Function     | Requires    | Purpose                                                              |
//! | ---          | ---         | ---                                                                  |
//! | `roundLayout`| `RoundTree` | Round a tree of float-valued layouts to integer pixels               |
//! | `printTree`  | `PrintTree` | Print a debug representation of a node tree and it's computed layout |
const std = @import("std");
const geometry = @import("geometry.zig");
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style = @import("style.zig");
const AvailableSpace = style.AvailableSpace;
const ContainingBlockClaims = style.ContainingBlockClaims;
const Overflow = style.Overflow;
const Position = style.Position;
const layout = @import("tree/layout.zig");
const AxisStaticAlign = layout.AxisStaticAlign;
const AxisStaticEdge = layout.AxisStaticEdge;
const AxisStaticPosition = layout.AxisStaticPosition;
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidate = layout.OofCandidate;
const ScrollableOverflow = layout.ScrollableOverflow;
const NodeId = @import("tree/node.zig").NodeId;
const traits = @import("tree/traits.zig");
const math = @import("util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const maybeSub = math.maybeSub;
const resolve = @import("util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("util/sys.zig");
const Scratch = @import("util/scratch.zig");

pub const common = struct {
    pub const alignment = @import("compute/common/alignment.zig");
    pub const scrollable_overflow = @import("compute/common/scrollable_overflow.zig");
    pub const sizing_keyword = @import("compute/common/sizing_keyword.zig");
};
pub const block = @import("compute/block.zig");
pub const flexbox = @import("compute/flexbox.zig");
pub const float = @import("compute/float.zig");
pub const grid = @import("compute/grid.zig");
pub const leaf = @import("compute/leaf.zig");
pub const oof = @import("compute/oof.zig");

pub const computeBlockAlignContentOffset = block.computeBlockAlignContentOffset;
pub const computeBlockLayout = block.computeBlockLayout;
pub const BlockContext = block.BlockContext;
pub const BlockFormattingContext = block.BlockFormattingContext;
pub const FloatMark = block.FloatMark;
pub const BfcSlot = float.BfcSlot;
pub const ContentSlot = float.ContentSlot;
pub const FloatContext = float.FloatContext;
pub const FloatIntrinsicWidthCalculator = float.FloatIntrinsicWidthCalculator;
pub const computeFlexboxLayout = flexbox.computeFlexboxLayout;
pub const computeGridLayout = grid.computeGridLayout;
pub const computeLeafLayout = leaf.computeLeafLayout;
pub const computeOofLayout = oof.computeOofLayout;
pub const computeOofLayoutForArea = oof.computeOofLayoutForArea;
pub const resolveStaticOffset = oof.resolveStaticOffset;
pub const OofLayoutResult = oof.OofLayoutResult;

/// A module for unified re-exports of detailed layout info structs, used by low level API
pub const detailed_info = struct {
    pub const DetailedGridInfo = grid.DetailedGridInfo;
    pub const DetailedGridItemsInfo = grid.DetailedGridItemsInfo;
    pub const DetailedGridTracksInfo = grid.DetailedGridTracksInfo;
    pub const GridLineNames = grid.GridLineNames;
    pub const GridLineNamesIter = grid.GridLineNamesIter;
};

/// Compute layout for the root node in the tree
///
/// The root's containing block is the initial containing block (ICB), which has the dimensions of the
/// viewport (`available_space`) and is anchored at the canvas origin. The root's `position` and `inset`
/// styles are resolved against it:
///
/// - A `position: absolute`/`fixed` root is laid out by the out-of-flow positioning routine used for
///   every other out-of-flow box (insets, shrink-to-fit sizing, auto margins, ...), with its static
///   position at the ICB origin. This requires a definite `available_space` in both axes: otherwise there
///   is no ICB to resolve against and the root is laid out as if it were in flow.
/// - A `position: relative` root is laid out in flow and then offset by its insets.
///
/// `tree` implements `LayoutContainingBlock` and `CacheTree`.
pub fn computeRootLayout(tree: anytype, root: NodeId, available_space: Size(AvailableSpace)) LayoutError!void {
    traits.assertImplements(@TypeOf(tree), &.{ .layout_containing_block, .cache_tree });
    const frame = Scratch.Frame.begin(tree);
    defer frame.end();
    const scratch = frame.allocator();
    const root_style = tree.getCoreContainerStyle(root);
    const position = root_style.position;
    const direction = root_style.direction;

    const icb_size = available_space.intoOptions();
    const oof_root_area: ?Size(f32) = if (position.isOutOfFlow() and icb_size.width != null and icb_size.height != null)
        .{ .width = icb_size.width.?, .height = icb_size.height.? }
    else
        null;

    // When the root's layout is served from the cache its layout algorithm does not run, so the
    // hoisted children it recorded on a previous run (including those added by the root
    // positioning pass below) are still in place and must not be re-added.
    var root_is_cached = false;

    var root_layout: Layout = undefined;
    if (oof_root_area) |area_size| {
        // The static position of the root places its margin box at the origin of the ICB
        const start: f32, const end: f32 = if (direction.isRtl()) .{ area_size.width, area_size.width } else .{ 0.0, 0.0 };
        const candidate: OofCandidate = .{
            .node = root,
            .order = 0,
            .position = position,
            .static_position = .{
                .x = .{
                    .area = .{ .start = start, .end = end },
                    .@"align" = AxisStaticAlign.fromKeyword(if (direction.isRtl()) .end else .start),
                },
                .y = AxisStaticPosition.fromEdge(0.0, .start),
            },
        };
        const box = try oof.layoutOofBox(
            tree,
            candidate,
            area_size,
            Point(f32).zero,
            direction,
            // The initial containing block is not a scroll container
            .{ .x = .visible, .y = .visible },
            null,
            RootCacheCheck{ .root = root, .root_is_cached = &root_is_cached },
        );
        root_layout = box.layout;
    } else {
        root_layout = try computeInFlowRootLayout(tree, root, available_space, &root_is_cached);
    }
    // The out-of-flow boxes that no node in the tree claimed
    const candidates = tree.oofCandidates(root);

    // Final positioning pass for out-of-flow boxes with no nearer containing block: the initial
    // containing block is the containing block for `position: fixed` boxes and for
    // `position: absolute` boxes with no positioned ancestor.
    if (candidates.len != 0) {
        const overflow = tree.getCoreContainerStyle(root).overflow;

        // The initial containing block has the dimensions of the viewport (the available space) and is
        // anchored at the canvas origin. In an axis where the available space is indefinite, fall back
        // to the root's padding box.
        const area_inset = root_layout.border.add(.{
            .left = 0.0,
            .right = root_layout.scrollbar_size.width,
            .top = 0.0,
            .bottom = root_layout.scrollbar_size.height,
        });
        const root_padding_box_size = root_layout.size.sub(.{ .width = area_inset.horizontalAxisSum(), .height = area_inset.verticalAxisSum() });
        const area_width: f32, const area_x: f32 = if (icb_size.width) |width|
            .{ @max(width - root_layout.scrollbar_size.width, 0.0), -root_layout.location.x }
        else
            .{ root_padding_box_size.width, area_inset.left };
        const area_height: f32, const area_y: f32 = if (icb_size.height) |height|
            .{ @max(height - root_layout.scrollbar_size.height, 0.0), -root_layout.location.y }
        else
            .{ root_padding_box_size.height, area_inset.top };
        const area_size: Size(f32) = .{ .width = area_width, .height = area_height };
        const area_offset: Point(f32) = .{ .x = area_x, .y = area_y };

        var hoisted: std.ArrayList(NodeId) = .empty;
        var unclaimed: std.ArrayList(OofCandidate) = .empty;
        _ = try oof.performOofLayout(
            tree,
            scratch,
            root,
            candidates,
            area_size,
            area_offset,
            direction,
            // The root is the initial containing block and claims all remaining candidates
            ContainingBlockClaims.all,
            overflow,
            .{ .x = direction.isRtl(), .y = false },
            &hoisted,
            &unclaimed,
        );
        // the root positioning pass must claim all remaining candidates
        std.debug.assert(unclaimed.items.len == 0);
        if (!root_is_cached) {
            try tree.addHoistedChildren(root, hoisted.items);
        }
    }
}

/// The `before_layout` callback of the root positioning pass: records whether the root's final
/// layout will be served from the cache
const RootCacheCheck = struct {
    root: NodeId,
    root_is_cached: *bool,

    pub fn call(self: RootCacheCheck, tree: anytype, inputs: *const LayoutInput) LayoutError!void {
        self.root_is_cached.* = tree.cacheGet(self.root, inputs) != null;
    }
};

/// Lay out an in-flow (or `position: relative`) root node against the available space, store its layout
/// and return it.
fn computeInFlowRootLayout(
    tree: anytype,
    root: NodeId,
    available_space: Size(AvailableSpace),
    root_is_cached: *bool,
) LayoutError!Layout {
    var known_dimensions = Size(?f32).none;

    // The available space passed to the root excludes the root's margins
    const root_available_space = blk: {
        const root_style = tree.getCoreContainerStyle(root);
        const margin = resolveOrZero(root_style.margin, available_space.width.intoOption(), tree);
        break :blk maybeMax(maybeSub(available_space, margin.sumAxes()), Size(f32).zero);
    };

    {
        const parent_size = available_space.intoOptions();
        const root_style = tree.getCoreContainerStyle(root);

        if (root_style.isBlock()) {
            // Pull these out earlier to avoid borrowing issues
            const aspect_ratio = root_style.aspect_ratio;
            const padding = resolveOrZero(root_style.padding, parent_size.width, tree);
            const border = resolveOrZero(root_style.border, parent_size.width, tree);
            const padding_border_size = padding.add(border).sumAxes();
            const box_sizing_adjustment = if (root_style.box_sizing == .content_box) padding_border_size else Size(f32).zero;

            const min_size = maybeAdd(maybeResolve(root_style.min_size, parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
            const max_size = maybeAdd(maybeResolve(root_style.max_size, parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
            const clamped_style_size = maybeClamp(
                maybeAdd(maybeResolve(root_style.size, parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
                min_size,
                max_size,
            );

            // If both min and max in a given axis are set and max <= min then this determines the size in that axis
            const min_max_definite_size: Size(?f32) = .{
                .width = minMaxDefinite(min_size.width, max_size.width),
                .height = minMaxDefinite(min_size.height, max_size.height),
            };

            // Block nodes automatically stretch fit their width to fit available space if available space is definite
            const available_space_based_size: Size(?f32) = .{ .width = root_available_space.width.intoOption(), .height = null };

            const styled_based_known_dimensions = maybeMax(
                known_dimensions.@"or"(min_max_definite_size).@"or"(clamped_style_size).@"or"(available_space_based_size),
                padding_border_size,
            );

            known_dimensions = styled_based_known_dimensions;
        }
    }

    const inputs: LayoutInput = .{
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = available_space.intoOptions(),
        .available_space = root_available_space,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .run_mode = .perform_layout,
        .vertical_margins_are_collapsible = Line(bool).false,
    };
    root_is_cached.* = tree.cacheGet(root, &inputs) != null;

    // Recursively compute node layout
    const output = try tree.computeChildLayout(root, inputs);
    const root_style = tree.getCoreContainerStyle(root);
    const padding = resolveOrZero(root_style.padding, available_space.width.intoOption(), tree);
    const border = resolveOrZero(root_style.border, available_space.width.intoOption(), tree);
    const margin = resolveOrZero(root_style.margin, available_space.width.intoOption(), tree);
    const scrollbar_size: Size(f32) = .{
        .width = if (root_style.overflow.y == .scroll) root_style.scrollbar_width else 0.0,
        .height = if (root_style.overflow.x == .scroll) root_style.scrollbar_width else 0.0,
    };
    const is_rtl = root_style.direction.isRtl();

    // The root's margin box is placed at the origin of the initial containing block
    var location: Point(f32) = .{
        .x = if (is_rtl and available_space.width.intoOption() != null)
            available_space.width.intoOption().? - output.size.width - margin.right
        else
            margin.left,
        .y = margin.top,
    };

    // A relatively positioned root is offset by its insets (resolved against the initial containing block)
    if (root_style.position == .relative) {
        const icb_size = available_space.intoOptions();
        const inset = root_style.inset;
        const left = maybeResolve(inset.left, icb_size.width, tree);
        const right = maybeResolve(inset.right, icb_size.width, tree);
        const top = maybeResolve(inset.top, icb_size.height, tree);
        const bottom = maybeResolve(inset.bottom, icb_size.height, tree);
        location.x += if (is_rtl)
            (if (right) |r| -r else (left orelse 0.0))
        else
            (left orelse (if (right) |r| -r else 0.0));
        location.y += top orelse (if (bottom) |b| -b else 0.0);
    }

    const root_layout: Layout = .{
        .order = 0,
        .location = location,
        .size = output.size,
        .scrollable_overflow_rect = output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .padding = padding,
        .border = border,
        // TODO: support auto margins for root node?
        .margin = margin,
    };
    tree.setUnroundedLayout(root, &root_layout);

    return root_layout;
}

/// `Some(min)` if both `min` and `max` are set and `max <= min`
fn minMaxDefinite(min: ?f32, max: ?f32) ?f32 {
    if (min) |min_v| {
        if (max) |max_v| {
            if (max_v <= min_v) return min_v;
        }
    }
    return null;
}

/// Attempts to find a cached layout for the specified node and layout inputs.
///
/// Uses `compute_uncached` to compute the layout (and then stores the result in the cache) if no
/// cached layout is found. `compute_uncached` is any value (or pointer) with a method
/// `compute(self, tree: @TypeOf(tree), node_id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput`.
///
/// `tree` implements `CacheTree` and `LayoutPartialTree`.
pub fn computeCachedLayout(
    tree: anytype,
    node: NodeId,
    inputs: LayoutInput,
    compute_uncached: anytype,
) LayoutError!LayoutOutput {
    // First we check if we have a cached result for the given input
    if (tree.cacheGet(node, &inputs)) |cached_size_and_baselines| {
        return cached_size_and_baselines;
    }

    // The node's out-of-flow candidates always belong to its most recent final layout. Layout
    // algorithms store a new list; clear the old one here for the nodes they do not run for.
    if (inputs.run_mode == .perform_layout) try tree.setOofCandidates(node, &.{});

    const computed_size_and_baselines = try compute_uncached.compute(tree, node, inputs);

    // Cache result
    tree.cacheStore(node, &inputs, computed_size_and_baselines);

    return computed_size_and_baselines;
}

/// Rounds the calculated layout to exact pixel values
///
/// In order to ensure that no gaps in the layout are introduced we:
///   - Always round based on the cumulative x/y coordinates (relative to the viewport) rather than
///     parent-relative coordinates
///   - Compute width/height by first rounding the top/bottom/left/right and then computing the difference
///     rather than rounding the width/height directly
///
/// See <https://github.com/facebook/yoga/commit/aa5b296ac78f7a22e1aeaf4891243c6bb76488e2> for more context
///
/// In order to prevent innacuracies caused by rounding already-rounded values, we read from `unrounded_layout`
/// and write to `final_layout`.
///
/// `tree` implements `RoundTree`.
pub fn roundLayout(tree: anytype, node_id: NodeId) void {
    traits.assertImplements(@TypeOf(tree), &.{.round_tree});
    roundLayoutInner(tree, node_id, 0.0, 0.0);
    if (comptime @hasDecl(traits.TreeType(@TypeOf(tree)), "finishRounding")) tree.finishRounding();
}

/// Recursive function to apply rounding to all descendents
fn roundLayoutInner(tree: anytype, node_id: NodeId, parent_cumulative_x: f32, parent_cumulative_y: f32) void {
    // A tree that tracks changes can tell that a whole subtree would round to what it already holds
    const tracks_changes = comptime @hasDecl(traits.TreeType(@TypeOf(tree)), "isRoundingCurrent");
    if (tracks_changes and tree.isRoundingCurrent(node_id, parent_cumulative_x, parent_cumulative_y)) return;

    const round = sys.round;
    const unrounded_layout = tree.getUnroundedLayout(node_id);
    var rounded = unrounded_layout;

    const parent_x = parent_cumulative_x;
    const parent_y = parent_cumulative_y;
    const cumulative_x = parent_cumulative_x + unrounded_layout.location.x;
    const cumulative_y = parent_cumulative_y + unrounded_layout.location.y;

    rounded.location.x = round(cumulative_x) - round(parent_x);
    rounded.location.y = round(cumulative_y) - round(parent_y);
    rounded.size.width = round(cumulative_x + unrounded_layout.size.width) - round(cumulative_x);
    rounded.size.height = round(cumulative_y + unrounded_layout.size.height) - round(cumulative_y);
    rounded.scrollbar_size.width = round(unrounded_layout.scrollbar_size.width);
    rounded.scrollbar_size.height = round(unrounded_layout.scrollbar_size.height);
    rounded.border.left = round(cumulative_x + unrounded_layout.border.left) - round(cumulative_x);
    rounded.border.right = round(cumulative_x + unrounded_layout.size.width) -
        round(cumulative_x + unrounded_layout.size.width - unrounded_layout.border.right);
    rounded.border.top = round(cumulative_y + unrounded_layout.border.top) - round(cumulative_y);
    rounded.border.bottom = round(cumulative_y + unrounded_layout.size.height) -
        round(cumulative_y + unrounded_layout.size.height - unrounded_layout.border.bottom);
    rounded.padding.left = round(cumulative_x + unrounded_layout.padding.left) - round(cumulative_x);
    rounded.padding.right = round(cumulative_x + unrounded_layout.size.width) -
        round(cumulative_x + unrounded_layout.size.width - unrounded_layout.padding.right);
    rounded.padding.top = round(cumulative_y + unrounded_layout.padding.top) - round(cumulative_y);
    rounded.padding.bottom = round(cumulative_y + unrounded_layout.size.height) -
        round(cumulative_y + unrounded_layout.size.height - unrounded_layout.padding.bottom);

    roundScrollableOverflowRect(&rounded, unrounded_layout.scrollable_overflow_rect, cumulative_x, cumulative_y);

    tree.setFinalLayout(node_id, &rounded);
    if (tracks_changes) tree.markRounded(node_id, parent_cumulative_x, parent_cumulative_y);

    // Recurse into in-flow children. Out-of-flow (absolute/fixed) children are skipped here:
    // they are instead visited via their containing block's hoisted child list below, which
    // ensures each node is visited exactly once and that its cumulative offset is accumulated
    // relative to its containing block (which its `location` is relative to).
    const child_count = tree.childCount(node_id);
    for (0..child_count) |index| {
        const child = tree.getChildId(node_id, index);
        if (!tree.isOutOfFlow(child)) {
            roundLayoutInner(tree, child, cumulative_x, cumulative_y);
        }
    }

    // Recurse into out-of-flow boxes for which this node is the containing block
    const hoisted_count = tree.hoistedChildCount(node_id);
    for (0..hoisted_count) |index| {
        const child = tree.getHoistedChildId(node_id, index);
        roundLayoutInner(tree, child, cumulative_x, cumulative_y);
    }
}

/// Round the scrollable overflow rect.
fn roundScrollableOverflowRect(
    rounded: *Layout,
    unrounded_overflow: ScrollableOverflow,
    cumulative_x: f32,
    cumulative_y: f32,
) void {
    const unrounded_rect = unrounded_overflow.rect();
    rounded.scrollable_overflow_rect = ScrollableOverflow.new(
        .{
            .left = roundEdge(cumulative_x, unrounded_rect.left),
            .right = roundEdge(cumulative_x, unrounded_rect.right),
            .top = roundEdge(cumulative_y, unrounded_rect.top),
            .bottom = roundEdge(cumulative_y, unrounded_rect.bottom),
        },
        unrounded_overflow.isReversed(),
    );
}

fn roundEdge(offset: f32, edge: f32) f32 {
    const rounded = sys.round(offset + edge) - sys.round(offset);
    if (rounded == 0.0) {
        // Keep left/top -0.0; ScrollableOverflow.new only re-packs right/bottom signs from reversed.
        return sys.copysign(rounded, edge);
    } else {
        return rounded;
    }
}

/// Creates a layout for this node and its children, recursively.
/// Each hidden node has zero size and is placed at the origin
///
/// `tree` implements `LayoutPartialTree` and `CacheTree`.
pub fn computeHiddenLayout(tree: anytype, node: NodeId) LayoutError!LayoutOutput {
    // Clear cache and set zeroed-out layout for the node
    tree.cacheClear(node);
    try tree.setOofCandidates(node, &.{});
    tree.setUnroundedLayout(node, &Layout.withOrder(0));

    // Perform hidden layout on all children
    for (0..tree.childCount(node)) |index| {
        const child_id = tree.getChildId(node, index);
        _ = try tree.computeChildLayout(child_id, LayoutInput.hidden);
    }

    return LayoutOutput.hidden;
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Cache = @import("tree/cache.zig").Cache;
const Style = style.Style;
const Dimension = style.Dimension;
const LengthPercentage = style.LengthPercentage;
const LengthPercentageAuto = style.LengthPercentageAuto;
const TaffyTree = @import("tree/taffy_tree.zig").TaffyTree;

/// A minimal custom tree implementing the documented interfaces, used to check the interface
/// contract, the recursion between `computeCachedLayout` and `computeChildLayout`, and the error
/// set plumbing for a tree other than `TaffyTree`.
///
/// Its container layout is deliberately trivial: a node with children stacks them vertically at
/// the top-left of its content box, sized by their own (leaf or container) layout, and reports
/// absolutely positioned children as out-of-flow candidates.
const StackTree = struct {
    const Node = struct {
        style: Style = .{},
        children: std.ArrayList(NodeId) = .empty,
        hoisted: std.ArrayList(NodeId) = .empty,
        oof_candidates: std.ArrayList(OofCandidate) = .empty,
        cache: Cache = .{},
        unrounded: Layout = .{},
        final: Layout = .{},
        /// Content size reported by the leaf measure function
        content: Size(f32) = Size(f32).zero,
    };

    gpa: std.mem.Allocator,
    scratch_allocator: Scratch,
    nodes: std.ArrayList(Node) = .empty,
    uncached_computations: usize = 0,

    fn deinit(self: *StackTree) void {
        for (self.nodes.items) |*n| {
            n.children.deinit(self.gpa);
            n.hoisted.deinit(self.gpa);
            n.oof_candidates.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
        self.scratch_allocator.deinit();
    }

    fn init(gpa: std.mem.Allocator) StackTree {
        return .{ .gpa = gpa, .scratch_allocator = .init(gpa) };
    }

    fn add(self: *StackTree, node_style: Style, content: Size(f32), children: []const NodeId) !NodeId {
        var n: Node = .{ .style = node_style, .content = content };
        try n.children.appendSlice(self.gpa, children);
        try self.nodes.append(self.gpa, n);
        return NodeId.fromUsize(self.nodes.items.len - 1);
    }

    fn node(self: *StackTree, id: NodeId) *Node {
        return &self.nodes.items[id.toUsize()];
    }

    // TraversePartialTree
    const ChildIter = struct {
        ids: []const NodeId,
        index: usize = 0,
        pub fn next(self: *ChildIter) ?NodeId {
            if (self.index >= self.ids.len) return null;
            defer self.index += 1;
            return self.ids[self.index];
        }
    };
    pub fn childIds(self: *StackTree, parent: NodeId) ChildIter {
        return .{ .ids = self.node(parent).children.items };
    }
    pub fn childCount(self: *StackTree, parent: NodeId) usize {
        return self.node(parent).children.items.len;
    }
    pub fn getChildId(self: *StackTree, parent: NodeId, index: usize) NodeId {
        return self.node(parent).children.items[index];
    }

    // LayoutPartialTree
    pub fn allocator(self: *StackTree) std.mem.Allocator {
        return self.gpa;
    }
    pub fn scratch(self: *StackTree) *Scratch {
        return &self.scratch_allocator;
    }
    pub fn oofCandidates(self: *StackTree, id: NodeId) []const OofCandidate {
        return self.node(id).oof_candidates.items;
    }
    pub fn setOofCandidates(self: *StackTree, id: NodeId, candidates: []const OofCandidate) LayoutError!void {
        const list = &self.node(id).oof_candidates;
        list.clearRetainingCapacity();
        try list.appendSlice(self.gpa, candidates);
    }
    pub fn getCoreContainerStyle(self: *StackTree, id: NodeId) *const Style {
        return &self.node(id).style;
    }
    pub const resolveCalcValue = traits.LayoutPartialTreeDefaults.resolveCalcValue;
    pub fn setUnroundedLayout(self: *StackTree, id: NodeId, l: *const Layout) void {
        self.node(id).unrounded = l.*;
    }
    pub fn computeChildLayout(self: *StackTree, id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
        if (inputs.run_mode == .perform_hidden_layout) return computeHiddenLayout(self, id);
        return computeCachedLayout(self, id, inputs, Uncached{});
    }

    // LayoutContainingBlock
    pub fn getOofItemStyle(self: *StackTree, id: NodeId) *const Style {
        return &self.node(id).style;
    }
    pub fn clearHoistedChildren(self: *StackTree, id: NodeId) void {
        self.node(id).hoisted.clearRetainingCapacity();
    }
    pub fn addHoistedChildren(self: *StackTree, id: NodeId, hoisted: []const NodeId) LayoutError!void {
        try self.node(id).hoisted.appendSlice(self.gpa, hoisted);
    }
    pub const getDetailedLayoutInfo = traits.LayoutContainingBlockDefaults.getDetailedLayoutInfo;

    // LayoutBlockContainer (only the provided method, to instantiate the default)
    pub const computeBlockChildLayout = traits.LayoutBlockContainerDefaults.computeBlockChildLayout;

    // CacheTree
    pub fn cacheGet(self: *StackTree, id: NodeId, input: *const LayoutInput) ?LayoutOutput {
        return self.node(id).cache.get(input);
    }
    pub fn cacheStore(self: *StackTree, id: NodeId, input: *const LayoutInput, output: LayoutOutput) void {
        self.node(id).cache.store(input, output);
    }
    pub fn cacheClear(self: *StackTree, id: NodeId) void {
        _ = self.node(id).cache.clear();
    }

    // RoundTree
    pub fn getUnroundedLayout(self: *StackTree, id: NodeId) Layout {
        return self.node(id).unrounded;
    }
    pub fn setFinalLayout(self: *StackTree, id: NodeId, l: *const Layout) void {
        self.node(id).final = l.*;
    }
    pub fn isOutOfFlow(self: *StackTree, id: NodeId) bool {
        const s = &self.node(id).style;
        return s.position.isOutOfFlow() and s.display != .none;
    }
    pub fn hoistedChildCount(self: *StackTree, id: NodeId) usize {
        return self.node(id).hoisted.items.len;
    }
    pub fn getHoistedChildId(self: *StackTree, id: NodeId, index: usize) NodeId {
        return self.node(id).hoisted.items[index];
    }

    // PrintTree
    pub fn getDebugLabel(self: *StackTree, id: NodeId) []const u8 {
        return if (self.childCount(id) == 0) "LEAF" else "STACK";
    }
    pub fn getFinalLayout(self: *StackTree, id: NodeId) Layout {
        return self.node(id).final;
    }

    const Measure = struct {
        content: Size(f32),
        pub fn measure(self: Measure, known: Size(?f32), available: Size(AvailableSpace)) Size(f32) {
            _ = available;
            return known.unwrapOr(self.content);
        }
    };

    const Uncached = struct {
        pub fn compute(_: Uncached, tree: *StackTree, id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
            tree.uncached_computations += 1;
            const n = tree.node(id);
            if (n.style.display == .none) return computeHiddenLayout(tree, id);
            var output = if (n.children.items.len == 0)
                computeLeafLayout(inputs, &n.style, tree, Measure{ .content = n.content })
            else
                try computeStackLayout(tree, id, inputs);
            if (inputs.run_mode == .perform_layout) try computeOofLayout(tree, id, &output);
            return output;
        }
    };

    /// The trivial container algorithm: stack in-flow children vertically
    fn computeStackLayout(tree: *StackTree, id: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
        const frame = Scratch.Frame.begin(tree);
        defer frame.end();
        const gpa = frame.allocator();
        const container_style = tree.getCoreContainerStyle(id);
        const padding = resolveOrZero(container_style.padding, inputs.parent_size.width, tree);
        const border = resolveOrZero(container_style.border, inputs.parent_size.width, tree);
        const inset = padding.add(border);

        var candidates: std.ArrayList(OofCandidate) = .empty;
        var y: f32 = inset.top;
        var width: f32 = 0.0;
        var iter = tree.childIds(id);
        var order: u32 = 0;
        while (iter.next()) |child| : (order += 1) {
            const child_style = tree.node(child).style;
            if (child_style.position.isOutOfFlow()) {
                try candidates.append(gpa, .{
                    .node = child,
                    .order = order,
                    .position = child_style.position,
                    .static_position = .{
                        .x = AxisStaticPosition.fromEdge(inset.left, .start),
                        .y = AxisStaticPosition.fromEdge(y, .start),
                    },
                });
                continue;
            }
            const size = try traits.measureChildSizeBoth(tree, child, Size(?f32).none, Size(?f32).none, Size(AvailableSpace).max_content, .inherent_size, Line(bool).false);
            if (inputs.run_mode == .perform_layout) {
                _ = try traits.performChildLayout(tree, child, .{ .width = size.width, .height = size.height }, Size(?f32).none, Size(AvailableSpace).max_content, .inherent_size, Line(bool).false);
                const location: Point(f32) = .{ .x = inset.left, .y = y };
                try layout.appendOofCandidates(&candidates, gpa, tree.oofCandidates(child), location);
                tree.setUnroundedLayout(child, &.{ .order = order, .location = location, .size = size });
            }
            y += size.height;
            width = @max(width, size.width);
        }
        const content_size: Size(f32) = .{ .width = width + inset.horizontalAxisSum(), .height = y + inset.bottom };
        const size = inputs.known_dimensions.unwrapOr(content_size);
        var output = LayoutOutput.fromOuterSize(size);
        if (inputs.run_mode == .perform_layout) {
            try tree.setOofCandidates(id, candidates.items);
            output.oof_positioning_area = .{
                .size = .{ .width = size.width - border.horizontalAxisSum(), .height = size.height - border.verticalAxisSum() },
                .offset = .{ .x = border.left, .y = border.top },
            };
        }
        return output;
    }
};

test "custom tree: multi-level layout through computeCachedLayout recursion" {
    var tree: StackTree = .init(testing.allocator);
    defer tree.deinit();

    var padded: Style = .{};
    padded.padding = Rect(LengthPercentage).fromLength(10.0);
    const leaf_a = try tree.add(.{}, .{ .width = 30.0, .height = 10.0 }, &.{});
    const leaf_b = try tree.add(.{}, .{ .width = 20.5, .height = 15.25 }, &.{});
    const inner = try tree.add(padded, Size(f32).zero, &.{ leaf_a, leaf_b });
    const leaf_c = try tree.add(.{}, .{ .width = 5.0, .height = 5.0 }, &.{});
    const root = try tree.add(.{}, Size(f32).zero, &.{ inner, leaf_c });

    try computeRootLayout(&tree, root, Size(AvailableSpace).max_content);
    roundLayout(&tree, root);

    try testing.expectEqual(Size(f32){ .width = 50.0, .height = 45.25 }, tree.node(inner).unrounded.size);
    try testing.expectEqual(Point(f32){ .x = 10.0, .y = 20.0 }, tree.node(leaf_b).unrounded.location);
    try testing.expectEqual(Size(f32){ .width = 50.0, .height = 50.25 }, tree.node(root).unrounded.size);
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 45.25 }, tree.node(leaf_c).unrounded.location);
    // Rounding is based on cumulative coordinates
    try testing.expectEqual(Size(f32){ .width = 21.0, .height = 15.0 }, tree.node(leaf_b).final.size);
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 45.0 }, tree.node(leaf_c).final.location);
    try testing.expectEqual(Size(f32){ .width = 5.0, .height = 5.0 }, tree.node(leaf_c).final.size);

    // A second identical pass is served entirely from the root's cache
    const before = tree.uncached_computations;
    try computeRootLayout(&tree, root, Size(AvailableSpace).max_content);
    try testing.expectEqual(before, tree.uncached_computations);

    // Hidden layout clears everything below a display: none node
    tree.node(root).style.display = .none;
    tree.cacheClear(root);
    try computeRootLayout(&tree, root, Size(AvailableSpace).max_content);
    try testing.expectEqual(Size(f32).zero, tree.node(leaf_b).unrounded.size);
    try testing.expect(tree.node(leaf_b).cache.isEmpty());

    // The block-container default forwards to computeChildLayout
    tree.node(root).style.display = .flex;
    tree.cacheClear(root);
    _ = try tree.computeBlockChildLayout(leaf_c, LayoutInput.hidden, null);
}

test "custom tree: out-of-flow candidates bubble to their containing block" {
    var tree: StackTree = .init(testing.allocator);
    defer tree.deinit();

    var abs_style: Style = .{};
    abs_style.position = .absolute;
    abs_style.inset = .{ .left = .fromLength(5.0), .right = .auto, .top = .auto, .bottom = .fromLength(3.0) };
    abs_style.size = Size(Dimension).fromLengths(7.0, 4.0);
    var fixed_style: Style = .{};
    fixed_style.position = .fixed;
    var relative: Style = .{};
    relative.position = .relative;
    relative.border = Rect(LengthPercentage).fromLength(1.0);

    const abs = try tree.add(abs_style, Size(f32).zero, &.{});
    const fixed = try tree.add(fixed_style, .{ .width = 2.0, .height = 3.0 }, &.{});
    const filler = try tree.add(.{}, .{ .width = 40.0, .height = 20.0 }, &.{});
    const static_container = try tree.add(.{}, Size(f32).zero, &.{ filler, abs, fixed });
    const positioned = try tree.add(relative, Size(f32).zero, &.{static_container});
    const root = try tree.add(.{}, Size(f32).zero, &.{positioned});

    try computeRootLayout(&tree, root, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 80.0 } });
    roundLayout(&tree, root);

    // The absolute box is claimed by the relatively positioned node (its border box is 42x22)
    try testing.expectEqualSlices(NodeId, &.{abs}, tree.node(positioned).hoisted.items);
    try testing.expectEqual(Point(f32){ .x = 6.0, .y = 14.0 }, tree.node(abs).unrounded.location);
    try testing.expectEqual(Size(f32){ .width = 7.0, .height = 4.0 }, tree.node(abs).unrounded.size);
    // The fixed box bubbles to the root (the initial containing block), at its static position
    try testing.expectEqualSlices(NodeId, &.{fixed}, tree.node(root).hoisted.items);
    try testing.expectEqual(Point(f32){ .x = 1.0, .y = 21.0 }, tree.node(fixed).unrounded.location);
    try testing.expectEqual(Size(f32){ .width = 2.0, .height = 3.0 }, tree.node(fixed).unrounded.size);
    // Out-of-flow boxes are rounded through their containing block
    try testing.expectEqual(Point(f32){ .x = 6.0, .y = 14.0 }, tree.node(abs).final.location);

    // A cached relayout keeps the hoisted lists intact
    try computeRootLayout(&tree, root, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 80.0 } });
    try testing.expectEqualSlices(NodeId, &.{fixed}, tree.node(root).hoisted.items);
}

test "custom tree: absolutely positioned and relatively positioned roots" {
    var tree: StackTree = .init(testing.allocator);
    defer tree.deinit();

    var abs_root: Style = .{};
    abs_root.position = .absolute;
    abs_root.inset = .{ .left = .fromLength(10.0), .right = .fromLength(10.0), .top = .fromLength(5.0), .bottom = .auto };
    abs_root.margin = .{ .left = .fromLength(2.0), .right = .fromLength(0.0), .top = .fromLength(0.0), .bottom = .fromLength(0.0) };
    const root = try tree.add(abs_root, .{ .width = 3.0, .height = 4.0 }, &.{});
    try computeRootLayout(&tree, root, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 50.0 } });
    // Stretch-fit width: 100 - 10 - 10 - 2
    try testing.expectEqual(Size(f32){ .width = 78.0, .height = 4.0 }, tree.node(root).unrounded.size);
    try testing.expectEqual(Point(f32){ .x = 12.0, .y = 5.0 }, tree.node(root).unrounded.location);

    var rel_root: Style = .{};
    rel_root.position = .relative;
    rel_root.direction = .rtl;
    rel_root.inset = .{ .left = .fromLength(1.0), .right = .fromLength(3.0), .top = .auto, .bottom = .fromLength(4.0) };
    rel_root.margin = Rect(LengthPercentageAuto).fromLength(2.0);
    const root2 = try tree.add(rel_root, .{ .width = 10.0, .height = 10.0 }, &.{});
    try computeRootLayout(&tree, root2, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 50.0 } });
    try testing.expectEqual(Point(f32){ .x = 100.0 - 10.0 - 2.0 - 3.0, .y = 2.0 - 4.0 }, tree.node(root2).unrounded.location);

    var block_root: Style = .{};
    block_root.display = .block;
    block_root.margin = Rect(LengthPercentageAuto).fromLength(5.0);
    block_root.min_size = .{ .width = .auto, .height = .fromLength(30.0) };
    block_root.max_size = .{ .width = .auto, .height = .fromLength(20.0) };
    const root3 = try tree.add(block_root, .{ .width = 10.0, .height = 10.0 }, &.{});
    try computeRootLayout(&tree, root3, .{ .width = .{ .definite = 100.0 }, .height = .{ .definite = 50.0 } });
    // Block roots stretch to the available width (minus margins); min > max fixes the height
    try testing.expectEqual(Size(f32){ .width = 90.0, .height = 30.0 }, tree.node(root3).unrounded.size);
}

test "rounding keeps signed zero overflow edges" {
    var tree: StackTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.add(.{}, Size(f32).zero, &.{});
    tree.node(root).unrounded = .{
        .location = .{ .x = 0.4, .y = 0.6 },
        .size = .{ .width = 10.2, .height = 10.2 },
        .scrollable_overflow_rect = ScrollableOverflow.new(.{ .left = -0.2, .right = 10.7, .top = -0.0, .bottom = 3.3 }, .{ .x = true, .y = false }),
        .border = Rect(f32).new(1.4, 1.4, 0.0, 0.0),
    };
    roundLayout(&tree, root);
    const final = tree.node(root).final;
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 1.0 }, final.location);
    try testing.expectEqual(Size(f32){ .width = 11.0, .height = 10.0 }, final.size);
    try testing.expectEqual(@as(f32, 2.0), final.border.left);
    try testing.expectEqual(@as(f32, 2.0), final.border.right);
    try testing.expect(std.math.signbit(final.scrollable_overflow_rect.left()));
    try testing.expectEqual(@as(f32, 0.0), final.scrollable_overflow_rect.left());
    try testing.expectEqual(Point(bool){ .x = true, .y = false }, final.scrollable_overflow_rect.isReversed());
}

test "hidden layout should hide recursively" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    var node_style: Style = .{};
    node_style.display = .flex;
    node_style.size = Size(Dimension).fromLengths(50.0, 50.0);

    const grandchild_00 = try taffy.newLeaf(node_style);
    const grandchild_01 = try taffy.newLeaf(node_style);
    const child_00 = try taffy.newWithChildren(node_style, &.{ grandchild_00, grandchild_01 });

    const grandchild_02 = try taffy.newLeaf(node_style);
    const child_01 = try taffy.newWithChildren(node_style, &.{grandchild_02});

    var root_style = node_style;
    root_style.display = .none;
    const root = try taffy.newWithChildren(root_style, &.{ child_00, child_01 });

    var view = taffy.asLayoutTree();
    _ = try computeHiddenLayout(&view, root);

    // Whatever size and display-mode the nodes had previously,
    // all layouts should resolve to ZERO due to the root's DISPLAY::NONE
    for ([_]NodeId{ root, child_00, child_01, grandchild_00, grandchild_01, grandchild_02 }) |n| {
        const l = taffy.layout(n);
        try testing.expectEqual(Size(f32).zero, l.size);
        try testing.expectEqual(Point(f32).zero, l.location);
    }
}

test "custom tree: computeOofLayoutForArea positions claimed candidates without touching hoisted lists" {
    var tree: StackTree = .init(testing.allocator);
    defer tree.deinit();

    var abs_style: Style = .{};
    abs_style.position = .absolute;
    abs_style.inset = .{ .left = .auto, .right = .fromLength(4.0), .top = .fromLength(2.0), .bottom = .auto };
    const abs = try tree.add(abs_style, .{ .width = 6.0, .height = 3.0 }, &.{});
    const owner = try tree.add(.{}, Size(f32).zero, &.{abs});

    const candidates = [_]OofCandidate{
        .{
            .node = abs,
            .order = 0,
            .position = .absolute,
            .static_position = .{ .x = AxisStaticPosition.fromEdge(0.0, .start), .y = AxisStaticPosition.fromEdge(0.0, .start) },
        },
        .{
            .node = abs,
            .order = 1,
            .position = .fixed,
            .static_position = .{ .x = AxisStaticPosition.fromEdge(0.0, .start), .y = AxisStaticPosition.fromEdge(0.0, .start) },
        },
    };
    var result = try computeOofLayoutForArea(
        &tree,
        owner,
        &candidates,
        .{ .size = .{ .width = 50.0, .height = 40.0 }, .offset = .{ .x = 1.0, .y = 1.0 } },
        .ltr,
        .{ .absolute = true, .fixed = false },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqualSlices(NodeId, &.{abs}, result.hoisted.items);
    try testing.expectEqual(@as(usize, 1), result.unclaimed.items.len);
    try testing.expectEqual(Position.fixed, result.unclaimed.items[0].position);
    try testing.expectEqual(@as(usize, 0), tree.node(owner).hoisted.items.len);
    try testing.expectEqual(Point(f32){ .x = 1.0 + 50.0 - 4.0 - 6.0, .y = 3.0 }, tree.node(abs).unrounded.location);
    try testing.expectEqual(Rect(f32){ .left = 0.0, .right = 46.0, .top = 0.0, .bottom = 5.0 }, result.scrollable_overflow_rect);
    try testing.expectEqual(Point(f32){ .x = 2.0, .y = 3.0 }, resolveStaticOffset(
        .{ .x = AxisStaticPosition.fromEdge(2.0, .start), .y = AxisStaticPosition.fromEdge(3.0, .start) },
        .{ .width = 1.0, .height = 1.0 },
        Rect(f32).zero,
    ));

    // Compile (but do not run) the stderr printing entry point for this tree type
    var print_it = false;
    _ = &print_it;
    if (print_it) @import("util/print.zig").printTree(&tree, owner);
}
