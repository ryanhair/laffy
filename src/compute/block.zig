//! Computes the CSS block layout algorithm in the case that the block container being laid out contains only block-level boxes
//!
//! `tree` arguments implement `LayoutBlockContainer` (see `src/tree/traits.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const FloatInsets = geometry.FloatInsets;
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../style.zig");
const AlignContent = style_mod.AlignContent;
const AlignItems = style_mod.AlignItems;
const AlignItemsKeyword = style_mod.AlignItemsKeyword;
const AlignSelf = style_mod.AlignSelf;
const AvailableSpace = style_mod.AvailableSpace;
const Clear = style_mod.Clear;
const Contain = style_mod.Contain;
const Dimension = style_mod.Dimension;
const Direction = style_mod.Direction;
const Float = style_mod.Float;
const FloatDirection = style_mod.FloatDirection;
const LengthPercentageAuto = style_mod.LengthPercentageAuto;
const Overflow = style_mod.Overflow;
const Position = style_mod.Position;
const TextAlign = style_mod.TextAlign;
const layout = @import("../tree/layout.zig");
const AxisStaticPosition = layout.AxisStaticPosition;
const Baselines = layout.Baselines;
const CollapsibleMarginSet = layout.CollapsibleMarginSet;
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidates = layout.OofCandidates;
const RunMode = layout.RunMode;
const ScrollableOverflow = layout.ScrollableOverflow;
const NodeId = @import("../tree/node.zig").NodeId;
const traits = @import("../tree/traits.zig");
const math = @import("../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const maybeMin = math.maybeMin;
const maybeSub = math.maybeSub;
const resolve = @import("../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../util/sys.zig");
const f32Max = sys.f32Max;
const float = @import("float.zig");
const BfcSlot = float.BfcSlot;
const ContentSlot = float.ContentSlot;
const FloatContext = float.FloatContext;
const FloatIntrinsicWidthCalculator = float.FloatIntrinsicWidthCalculator;
const fit_tolerance = float.fit_tolerance;
const alignment = @import("common/alignment.zig");
const applyAlignmentFallback = alignment.applyAlignmentFallback;
const childFirstBaseline = alignment.childFirstBaseline;
const computeAlignmentOffset = alignment.computeAlignmentOffset;
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const computeScrollableOverflowContribution = scrollable_overflow.computeScrollableOverflowContribution;
const finalizeScrollableOverflow = scrollable_overflow.finalizeScrollableOverflow;
const ScrollableOverflowContainer = scrollable_overflow.ScrollableOverflowContainer;
const sizing_keyword = @import("common/sizing_keyword.zig");
const resolveSizingKeyword = sizing_keyword.resolveSizingKeyword;

/// Compute the block-axis offset that `align-content` applies to the in-flow content of a block
/// container, given the free space between the container's content box and its content.
///
/// The entire stack of in-flow content is treated as a single alignment subject, so the
/// distribution keywords (`space-*`, `stretch`) invoke their single-subject fallbacks. This is
/// used both by block layout and by inline formatting contexts (line boxes) which are laid out
/// externally to Taffy.
pub fn computeBlockAlignContentOffset(align_content: AlignContent, free_space: f32) f32 {
    const keyword = applyAlignmentFallback(free_space, 1, align_content);
    return computeAlignmentOffset(free_space, 1, 0.0, keyword, false, true);
}

/// Context for positioning Block and Float boxes within a Block Formatting Context
///
/// laffy note: create with `init(gpa)` and free with `deinit`.
pub const BlockFormattingContext = struct {
    /// The float positioning context that handles positioning floats within this Block Formatting Context
    float_context: FloatContext,

    /// Create a new `BlockFormattingContext` (upstream `BlockFormattingContext::new`)
    pub fn init(gpa: Allocator) BlockFormattingContext {
        return .{ .float_context = FloatContext.init(gpa) };
    }

    /// Free the context's float lists
    pub fn deinit(self: *BlockFormattingContext) void {
        self.float_context.deinit();
    }

    /// Create an initial `BlockContext` for this `BlockFormattingContext`
    pub fn rootBlockContext(self: *BlockFormattingContext) BlockContext {
        return .{
            .bfc = self,
            .y_offset = 0.0,
            .insets = FloatInsets.zero,
            .content_box_insets = FloatInsets.zero,
            .float_content_contribution = -std.math.inf(f32),
            .is_root = true,
            .adjoining_floats = .{ false, false },
            .top_adjoining_floats = null,
        };
    }
};

/// A mark of how many floats a Block Formatting Context held when it was taken.
/// See `BlockContext.floatMark`.
pub const FloatMark = struct {
    /// The number of left floats
    left: usize,
    /// The number of right floats
    right: usize,
};

/// Context for each individual Block within a Block Formatting Context
///
/// Contains a mutable reference to the BlockFormattingContext + block-specific data
pub const BlockContext = struct {
    /// A mutable reference to the root BlockFormatttingContext that this BlockContext belongs to
    bfc: *BlockFormattingContext,
    /// The y-offset of the border-top of the block node, relative to the to the border-top of the
    /// root node of the Block Formatting Context it belongs to.
    y_offset: f32,
    /// The x-inset of the border-box in from each side of the block node, relative to the root node of the Block Formatting Context it belongs to.
    insets: FloatInsets,
    /// The x-insets of the content box
    content_box_insets: FloatInsets,
    /// The height that floats take up in the element (`-inf` if the element's
    /// subtree does not contain any floats)
    float_content_contribution: f32,
    /// Whether the node is the root of the Block Formatting Context is belongs to.
    is_root: bool,
    /// Whether a float has been placed (on each side) whose position adjoins the current
    /// margin-collapse strut of this block (i.e. whose final position can still be moved by
    /// margins that collapse into that strut). Such floats force clearance on cleared elements
    /// whose margins adjoin the same strut.
    adjoining_floats: [2]bool,
    /// The value of `adjoining_floats` frozen at the first point at which in-flow content was
    /// committed within this block (resolving the position of the block's top margin strut).
    /// `null` if no in-flow content has been committed yet.
    top_adjoining_floats: ?[2]bool,

    /// Create a sub-`BlockContext` for a child block node
    pub fn subContext(self: *BlockContext, additional_y_offset: f32, insets_in: FloatInsets) BlockContext {
        const insets = self.insets.add(insets_in);
        return .{
            .bfc = self.bfc,
            .y_offset = self.y_offset + additional_y_offset,
            .insets = insets,
            .content_box_insets = insets,
            .float_content_contribution = -std.math.inf(f32),
            .is_root = false,
            // Floats adjoining the parent's current strut also adjoin this block's top strut
            // (if this block's top margin collapses with its first child's, which is checked separately)
            .adjoining_floats = self.adjoining_floats,
            .top_adjoining_floats = null,
        };
    }

    /// Returns whether this block is the root block of it's Block Formatting Context
    pub fn isBfcRoot(self: *const BlockContext) bool {
        return self.is_root;
    }

    /// Set the width of the overall Block Formatting Context. This is used to resolve positions
    /// that are relative to the right of the context such as right-floated boxes.
    ///
    /// Sub-blocks within a Block Formatting Context should use the `subContext` method to create
    /// a sub-`BlockContext` with `insets` instead.
    pub fn setWidth(self: *BlockContext, available_width: f32) void {
        self.bfc.float_context.setWidth(available_width);
    }

    /// Set the x-axis content-box insets of the `BlockContext`. These are the difference between the border-box
    /// and the content-box of the box (padding + border + scrollbar_gutter).
    pub fn applyContentBoxInset(self: *BlockContext, content_box_x_insets: FloatInsets) void {
        self.content_box_insets = self.insets.add(content_box_x_insets);
    }

    /// Whether the float context contains any floats
    pub inline fn hasFloats(self: *const BlockContext) bool {
        return self.bfc.float_context.hasFloats();
    }

    /// Whether the float context contains any floats that extend to or below min_y
    pub inline fn hasActiveFloats(self: *const BlockContext, min_y: f32) bool {
        return self.bfc.float_context.hasActiveFloats(min_y + self.y_offset);
    }

    /// Position a floated box with the context. `id` identifies the box in `floatsPlacedSince`.
    pub fn placeFloatedBox(
        self: *BlockContext,
        id: u64,
        floated_box: Size(f32),
        min_y: f32,
        direction: FloatDirection,
        clear: Clear,
        adjoins_unresolved_strut: bool,
    ) LayoutError!Point(f32) {
        if (adjoins_unresolved_strut) {
            self.adjoining_floats[@backingInt(direction)] = true;
        }
        var pos = try self.bfc.float_context.placeFloatedBox(
            id,
            floated_box,
            min_y + self.y_offset,
            self.content_box_insets,
            direction,
            clear,
        );
        pos.y -= self.y_offset;
        pos.x -= self.insets.left;

        self.float_content_contribution = @max(self.float_content_contribution, pos.y + floated_box.height);

        return pos;
    }

    /// A mark of the floats placed in the Block Formatting Context so far, for `floatsPlacedSince`
    pub fn floatMark(self: *const BlockContext) FloatMark {
        const float_context = &self.bfc.float_context;
        return .{ .left = float_context.leftFloats().len, .right = float_context.rightFloats().len };
    }

    /// The id and position of each floated box placed since `mark` was taken: left floats in the
    /// order they were placed, then right floats. Positions are relative to this block, as
    /// returned by `placeFloatedBox`.
    pub fn floatsPlacedSince(self: *const BlockContext, mark: FloatMark) FloatsPlacedSince {
        return .{ .block_ctx = self, .left = mark.left, .right = mark.right };
    }

    /// Search a space suitable for laying out non-floated content of the given height into
    pub fn findContentSlot(self: *const BlockContext, min_y: f32, height: f32, clear: Clear, after: ?usize) ContentSlot {
        var slot = self.bfc.float_context.findContentSlot(
            min_y + self.y_offset,
            height,
            self.content_box_insets,
            clear,
            after,
        );
        slot.y -= self.y_offset;
        slot.x -= self.insets.left;
        return slot;
    }

    /// Search for a space suitable for laying out a box that establishes an independent
    /// formatting context (whose border box must not overlap floats)
    pub fn findBfcSlot(
        self: *const BlockContext,
        min_y: f32,
        min_height: f32,
        margins: FloatInsets,
        direction: Direction,
        clear: Clear,
        after: ?usize,
    ) BfcSlot {
        var slot = self.bfc.float_context.findBfcSlot(
            min_y + self.y_offset,
            min_height,
            self.content_box_insets,
            margins,
            direction,
            clear,
            after,
        );
        slot.y -= self.y_offset;
        slot.x -= self.insets.left;
        return slot;
    }

    /// Get the bottom of lowest relevant float for the specific clear property
    pub fn clearedThreshold(self: *const BlockContext, clear: Clear) ?f32 {
        const threshold = self.bfc.float_context.clearedThreshold(clear) orelse return null;
        return threshold - self.y_offset;
    }

    /// Whether a float that is adjoining the current margin-collapse strut has been placed
    /// on the side(s) relevant to the passed clear property
    pub fn hasAdjoiningFloat(self: *const BlockContext, clear: Clear) bool {
        return switch (clear) {
            .left => self.adjoining_floats[0],
            .right => self.adjoining_floats[1],
            .both => self.adjoining_floats[0] or self.adjoining_floats[1],
            .none => false,
        };
    }

    /// Merge adjoining float flags propagated from a child block into this block's flags
    fn mergeAdjoiningFloats(self: *BlockContext, flags: [2]bool) void {
        self.adjoining_floats[0] = self.adjoining_floats[0] or flags[0];
        self.adjoining_floats[1] = self.adjoining_floats[1] or flags[1];
    }

    /// Record that in-flow content has been committed within this block, resolving the position of
    /// the current margin-collapse strut. Floats placed before this point no longer adjoin the
    /// current strut. The flags for the block's top strut are frozen at the first commit.
    fn commitStrut(self: *BlockContext) void {
        if (self.top_adjoining_floats == null) {
            self.top_adjoining_floats = self.adjoining_floats;
        }
        self.adjoining_floats = .{ false, false };
    }

    /// The adjoining float flags for this block's top margin strut: floats placed while the
    /// position of the block's top strut was still unresolved
    fn topAdjoiningFloats(self: *const BlockContext) [2]bool {
        return self.top_adjoining_floats orelse self.adjoining_floats;
    }

    /// Update the height that descendent floats consume with the height that floats consume
    /// within a particular child (`child_contribution` is relative to this block's border-top)
    pub fn addChildFloatedContentHeightContribution(self: *BlockContext, child_contribution: f32) void {
        self.float_content_contribution = @max(self.float_content_contribution, child_contribution);
    }

    /// Returns the height that descendent floats consume
    pub fn floatedContentHeightContribution(self: *const BlockContext) f32 {
        return self.float_content_contribution;
    }
};

/// Iterator returned by `BlockContext.floatsPlacedSince`
pub const FloatsPlacedSince = struct {
    block_ctx: *const BlockContext,
    left: usize,
    right: usize,

    /// A placed float: its id and its position relative to the block
    pub const Item = struct { id: u64, position: Point(f32) };

    pub fn next(self: *FloatsPlacedSince) ?Item {
        const float_context = &self.block_ctx.bfc.float_context;
        const placed: *const float.PlacedFloatedBox, const direction: FloatDirection = blk: {
            if (self.left < float_context.leftFloats().len) {
                self.left += 1;
                break :blk .{ &float_context.leftFloats()[self.left - 1], .left };
            }
            if (self.right < float_context.rightFloats().len) {
                self.right += 1;
                break :blk .{ &float_context.rightFloats()[self.right - 1], .right };
            }
            return null;
        };
        const pos = float_context.placedPosition(placed, direction);
        return .{
            .id = placed.id,
            .position = .{ .x = pos.x - self.block_ctx.insets.left, .y = pos.y - self.block_ctx.y_offset },
        };
    }
};

/// Per-child data that is accumulated and modified over the course of the layout algorithm
const BlockItem = struct {
    /// The identifier for the associated node
    node_id: NodeId,

    /// The "source order" of the item. This is the index of the item within the children iterator,
    /// and controls the order in which the nodes are placed
    order: u32,

    /// Items that are tables don't have stretch sizing applied to them
    is_table: bool,

    /// Compressible replaced items resolve an auto width to their intrinsic size rather than
    /// being stretch-sized <https://www.w3.org/TR/CSS22/visudet.html#block-replaced-width>
    is_compressible_replaced: bool,

    /// For compressible replaced items, the cap on their min-content contribution from a
    /// percentage `width` or `max-width` resolved against zero
    /// <https://drafts.csswg.org/css-sizing-3/#replaced-percentage-min-contribution>
    min_content_width_cap: ?f32,

    /// Whether the child is a non-independent block or inline node
    is_in_same_bfc: bool,

    /// The `float` style of the node
    float: Float,
    /// The `clear` style of the node
    clear: Clear,

    /// The size style of this item. Used to detect and resolve sizing keywords
    /// (`min-content`, `max-content`, `fit-content`, `fit-content(...)`, and `stretch`).
    /// In the height (block) axis only `stretch` requires resolution: the intrinsic sizing
    /// keywords are all equal to the content size, which is what an auto height already
    /// resolves to.
    size_style: Size(Dimension),

    /// The base size of this item
    size: Size(?f32),
    /// The minimum allowable size of this item
    min_size: Size(?f32),
    /// The maximum allowable size of this item
    max_size: Size(?f32),

    /// The overflow style of the item
    overflow: Point(Overflow),
    /// The contain style of the item
    contain: Contain,
    /// The width of the item's scrollbars (if it has scrollbars)
    scrollbar_width: f32,

    /// The position style of the item
    position: Position,
    /// The `direction` style of the item (used to resolve `self-start`/`self-end`)
    direction: Direction,
    /// The `align-self` style of the item (used to derive the static position of out-of-flow items)
    align_self: ?AlignSelf,
    /// The `justify-self` style of the item (used to align in-flow items and to derive the static position of
    /// out-of-flow items)
    justify_self: ?AlignSelf,
    /// The final offset of this item
    inset: Rect(LengthPercentageAuto),
    /// The margin of this item
    margin: Rect(LengthPercentageAuto),
    /// The margin of this item
    padding: Rect(f32),
    /// The margin of this item
    border: Rect(f32),
    /// The sum of padding and border for this item
    padding_border_sum: Size(f32),

    /// The computed border box size of this item
    computed_size: Size(f32),
    /// The computed "static position" of this item. The static position is the position
    /// taking into account padding, border, margins, and scrollbar_gutters but not inset
    static_position: Point(f32),
    /// Whether margins can be collapsed through this item
    can_be_collapsed_through: bool,

    /// Pending layout for in-flow non-floated items. Held back from `setUnroundedLayout` so the
    /// post-loop `align-content` pass in `computeInner` can shift `location.y` before commit.
    final_layout: ?Layout,

    /// Out-of-flow candidates bubbled out of this (in-flow) item's subtree. Anchors are relative
    /// to the item's border box until they are translated at merge time.
    /// Allocated with the tree's allocator and owned by the item.
    oof_candidates: OofCandidates,
};

/// Free the block items (and any out-of-flow candidates they still own)
fn freeBlockItems(gpa: Allocator, items: []BlockItem) void {
    for (items) |*item| item.oof_candidates.deinit(gpa);
    gpa.free(items);
}

/// `Some(min)` if both `min` and `max` are set and `max <= min`
inline fn minMaxDefinite(min: ?f32, max: ?f32) ?f32 {
    if (min) |min_v| {
        if (max) |max_v| {
            if (max_v <= min_v) return min_v;
        }
    }
    return null;
}

/// `value.min(0.0)` (used to map margins for scrollable overflow contributions)
fn minZero(value: f32) f32 {
    return @min(value, 0.0);
}

/// Computes the layout of a node according to the block layout algorithm
///
/// `tree` implements `LayoutBlockContainer`. `block_ctx` is the block context of the parent's
/// block formatting context (`null` to establish a new one).
pub fn computeBlockLayout(tree: anytype, node_id: NodeId, inputs: LayoutInput, block_ctx: ?*BlockContext) LayoutError!LayoutOutput {
    traits.assertImplements(@TypeOf(tree), &.{.layout_block_container});
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const run_mode = inputs.run_mode;
    const style = tree.getBlockContainerStyle(node_id);

    // Pull these out earlier to avoid borrowing issues
    const overflow = style.getOverflow();
    const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
    const contain = style.getContain();
    // css-align-3 §5.1.1: a non-`normal` `align-content` makes a block container establish an
    // independent formatting context. <https://drafts.csswg.org/css-align-3/#distribution-block>
    // Layout and paint containment also establish an independent formatting context.
    // <https://drafts.csswg.org/css-contain-2/#containment-layout>
    const establishes_new_bfc = is_scroll_container or
        style.getAlignContent().keyword != .normal or
        contain.establishesIndependentFormattingContext();
    const aspect_ratio = style.getAspectRatio();
    const padding = resolveOrZero(style.getPadding(), parent_size.width, tree);
    const border = resolveOrZero(style.getBorder(), parent_size.width, tree);
    const padding_border_size = padding.add(border).sumAxes();
    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_size else Size(f32).zero;

    const min_size = maybeAdd(maybeResolve(style.getMinSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const max_size = maybeAdd(maybeResolve(style.getMaxSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const clamped_style_size: Size(?f32) = if (inputs.sizing_mode == .inherent_size)
        maybeClamp(
            maybeAdd(maybeResolve(style.getSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
            min_size,
            max_size,
        )
    else
        Size(?f32).none;

    // If both min and max in a given axis are set and max <= min then this determines the size in that axis
    const min_max_definite_size: Size(?f32) = .{
        .width = minMaxDefinite(min_size.width, max_size.width),
        .height = minMaxDefinite(min_size.height, max_size.height),
    };

    const styled_based_known_dimensions = maybeMax(
        known_dimensions.@"or"(min_max_definite_size).@"or"(clamped_style_size),
        padding_border_size,
    );

    // Short-circuit layout if the container's size is fully determined by the container's size and the run mode
    // is ComputeSize (and thus the container's size is all that we're interested in)
    if (run_mode == .compute_size) {
        if (styled_based_known_dimensions.width) |width| {
            if (styled_based_known_dimensions.height) |height| {
                return LayoutOutput.fromOuterSize(.{ .width = width, .height = height });
            }
        }

        // We can also short-circuit if the width is known and only the width has been requested.
        if (inputs.axis == .horizontal) {
            if (styled_based_known_dimensions.width) |width| {
                return LayoutOutput.fromOuterSize(.{ .width = width, .height = 0.0 });
            }
        }
    }

    // Unwrap the block formatting context if one was passed, or else create a new one
    var inner_inputs = inputs;
    inner_inputs.known_dimensions = styled_based_known_dimensions;
    var output = if (block_ctx != null and !establishes_new_bfc)
        try computeInner(tree, node_id, inner_inputs, block_ctx.?)
    else blk: {
        var root_bfc = BlockFormattingContext.init(tree.allocator());
        defer root_bfc.deinit();
        var root_ctx = root_bfc.rootBlockContext();
        break :blk try computeInner(tree, node_id, inner_inputs, &root_ctx);
    };

    // Layout containment suppresses the box's baseline for baseline-alignment purposes
    if (contain.suppressesBaseline()) {
        output.baselines = Baselines.none;
    }

    return output;
}

/// Computes the layout of a `LayoutBlockContainer` according to the block layout algorithm
fn computeInner(tree: anytype, node_id: NodeId, inputs: LayoutInput, block_ctx: *BlockContext) LayoutError!LayoutOutput {
    const gpa = tree.allocator();
    const known_dimensions_in = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const available_space = inputs.available_space;
    const run_mode = inputs.run_mode;
    const vertical_margins_are_collapsible = inputs.vertical_margins_are_collapsible;

    const style = tree.getBlockContainerStyle(node_id);
    const raw_padding = style.getPadding();
    const raw_border = style.getBorder();
    const raw_margin = style.getMargin();
    const aspect_ratio = style.getAspectRatio();
    const padding = resolveOrZero(raw_padding, parent_size.width, tree);
    const border = resolveOrZero(raw_border, parent_size.width, tree);
    const direction = style.getDirection();

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow.scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const scrollbar_gutter: Rect(f32) = blk: {
        const transposed = style.getOverflow().transpose();
        const offsets: Point(f32) = .{
            .x = if (transposed.x == .scroll) style.getScrollbarWidth() else 0.0,
            .y = if (transposed.y == .scroll) style.getScrollbarWidth() else 0.0,
        };
        break :blk switch (direction) {
            .ltr => .{ .top = 0.0, .left = 0.0, .right = offsets.x, .bottom = offsets.y },
            .rtl => .{ .top = 0.0, .left = offsets.x, .right = 0.0, .bottom = offsets.y },
        };
    };
    const padding_border = padding.add(border);
    const padding_border_size = padding_border.sumAxes();
    const content_box_inset = padding_border.add(scrollbar_gutter);

    // Apply content box inset
    block_ctx.applyContentBoxInset(FloatInsets.new(content_box_inset.left, content_box_inset.right));

    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_size else Size(f32).zero;
    const size = maybeAdd(maybeResolve(style.getSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const min_size = maybeAdd(maybeResolve(style.getMinSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const max_size = maybeAdd(maybeResolve(style.getMaxSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);

    // css-sizing-4: a definite size in one axis transfers through `aspect-ratio`
    // to make the other definite. Deriving it from `known_dimensions` self-gates
    // the transfer — a block parent fills an axis only when it's a real
    // constraint (e.g. the stretched width at final layout) and leaves it None
    // while probing intrinsic sizes, so measure passes stay content-based. Only a
    // newly-filled axis is adopted (and clamped); an incoming known size is left
    // as the parent resolved it (re-clamping would undo padding/border overrides).
    const known_dimensions: Size(?f32) = blk: {
        const derived = maybeClamp(known_dimensions_in.maybeApplyAspectRatio(aspect_ratio), min_size, max_size);
        break :blk .{
            .width = known_dimensions_in.width orelse derived.width,
            .height = known_dimensions_in.height orelse derived.height,
        };
    };
    const percentage_basis_dimensions: Size(?f32) = .{
        .width = known_dimensions.width,
        .height = if (inputs.known_dimensions_are_definite.height) known_dimensions.height else null,
    };
    const container_content_box_size = maybeSub(percentage_basis_dimensions, content_box_inset.sumAxes());

    const overflow = style.getOverflow();
    const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
    const establishes_new_bfc = is_scroll_container or
        style.getAlignContent().keyword != .normal or
        style.getContain().establishesIndependentFormattingContext();

    // Determine margin collapsing behaviour
    //
    // Whether a child's margins could collapse through each of this box's block-axis edges: the
    // box does not establish a new BFC and has neither border nor padding on that side.
    const children_margins_adjoin_own_edges: Line(bool) = .{
        .start = vertical_margins_are_collapsible.start and
            !establishes_new_bfc and
            !style.getPosition().isOutOfFlow() and
            padding.top == 0.0 and
            border.top == 0.0,
        .end = vertical_margins_are_collapsible.end and
            !establishes_new_bfc and
            !style.getPosition().isOutOfFlow() and
            padding.bottom == 0.0 and
            border.bottom == 0.0,
    };
    const own_margins_collapse_with_children: Line(bool) = .{
        .start = children_margins_adjoin_own_edges.start,
        .end = children_margins_adjoin_own_edges.end and size.height == null,
    };
    const has_styles_preventing_being_collapsed_through = !style.isBlock() or
        block_ctx.isBfcRoot() or
        establishes_new_bfc or
        style.getPosition().isOutOfFlow() or
        padding.top > 0.0 or
        padding.bottom > 0.0 or
        border.top > 0.0 or
        border.bottom > 0.0;

    const text_align = style.getTextAlign();
    const align_content = style.getAlignContent();
    const justify_items = style.getJustifyItems();

    // 1. Generate items
    const items = try generateItemList(tree, node_id, container_content_box_size);
    defer freeBlockItems(gpa, items);

    // 2. Compute container width
    const container_outer_width = if (known_dimensions.width) |width| width else blk: {
        const available_width = maybeSub(available_space.width, content_box_inset.horizontalAxisSum());
        const intrinsic_width = try determineContentBasedContainerWidth(tree, items, available_width) +
            content_box_inset.horizontalAxisSum();
        break :blk maybeMax(maybeClamp(intrinsic_width, min_size.width, max_size.width), @as(?f32, padding_border_size.width));
    };

    // Short-circuit if computing size and both dimensions known
    if (run_mode == .compute_size) {
        if (known_dimensions.height) |container_outer_height| {
            return LayoutOutput.fromOuterSize(.{ .width = container_outer_width, .height = container_outer_height });
        }
    }

    // We can also short-circuit if the width is known and only the width has been requested.
    if (run_mode == .compute_size and inputs.axis == .horizontal) {
        return LayoutOutput.fromOuterSize(.{ .width = container_outer_width, .height = 0.0 });
    }

    // Under `SizingMode.content_size` the container's own `height`/`min-height` are ignored,
    // so they cannot serve as the percentage basis for children either
    // (https://drafts.csswg.org/css-flexbox/#min-size-auto: the content size suggestion
    // must not be influenced by the item's specified height).
    const container_percentage_resolution_height: ?f32 = percentage_basis_dimensions.height orelse
        (if (inputs.sizing_mode == .inherent_size) maybeMax(size.height, min_size.height) else null);

    // 3. Perform final item layout and return content height
    //
    // Percentage padding and borders resolve against the *containing block's* width
    // (`parent_size`), not the box's own width. These only differ when the box has a
    // non-stretch width. Fall back to the box's own width when the parent size is
    // unknown (e.g. at the root of the layout tree).
    const percentage_resolution_width = parent_size.width orelse container_outer_width;
    const resolved_padding = resolveOrZero(raw_padding, @as(?f32, percentage_resolution_width), tree);
    const resolved_border = resolveOrZero(raw_border, @as(?f32, percentage_resolution_width), tree);
    const resolved_content_box_inset = resolved_padding.add(resolved_border).add(scrollbar_gutter);
    const final_result = try performFinalLayoutOnInFlowChildren(
        tree,
        run_mode,
        items,
        container_outer_width,
        container_percentage_resolution_height,
        content_box_inset,
        resolved_content_box_inset,
        resolved_border,
        resolved_padding,
        text_align,
        justify_items,
        direction,
        own_margins_collapse_with_children,
        children_margins_adjoin_own_edges,
        is_scroll_container,
        block_ctx,
    );
    var inflow_overflow_rect = final_result.inflow_overflow_rect;
    var intrinsic_outer_height = final_result.content_height;
    const first_child_top_margin_set = final_result.first_child_top_margin_set;
    const last_child_bottom_margin_set = final_result.last_child_bottom_margin_set;
    var first_baseline = final_result.first_baseline;

    // Root BFCs contain floats: the content height extends to the bottom margin edge of any
    // floated descendant, and the container's bottom padding and border sit below that
    if (block_ctx.isBfcRoot() or establishes_new_bfc) {
        intrinsic_outer_height = @max(
            intrinsic_outer_height,
            block_ctx.floatedContentHeightContribution() + resolved_content_box_inset.bottom,
        );
    }

    const container_outer_height = maybeMax(
        known_dimensions.height orelse maybeClamp(intrinsic_outer_height, min_size.height, max_size.height),
        @as(?f32, padding_border_size.height),
    );
    const final_outer_size: Size(f32) = .{ .width = container_outer_width, .height = container_outer_height };

    // CSS2 §8.3.1: the bottom margin of a block with `height: auto` collapses with its last
    // in-flow child's bottom margin only if the box's `min-height` is less than the box's
    // used height. When `min-height` determines the used height, the last child's bottom
    // margin no longer adjoins the box's bottom edge, so it stays inside the box instead of
    // collapsing with the box's own bottom margin. (`max-height` has no such effect.)
    const height_constrained_by_min_height = if (min_size.height) |h| h > 0.0 and h >= container_outer_height else false;
    const own_bottom_margin_collapses_with_children = own_margins_collapse_with_children.end and !height_constrained_by_min_height;

    // Apply `align-content` to in-flow non-floated items if requested. The per-item layouts were
    // held back in `item.final_layout` so that this step can shift `location.y` before tree commit.
    //
    // For block layout the entire stack of in-flow children is treated as a single alignment
    // subject. That means distribution keywords (`space-between`, `space-around`,
    // `space-evenly`, `stretch`) must invoke the single-subject fallback unconditionally —
    // which is what passing `num_items = 1` to `applyAlignmentFallback` does. The whole
    // group then shifts by one offset, with zero inter-item gap.
    if (align_content.keyword != .normal) {
        const container_inner_height = container_outer_height - resolved_content_box_inset.verticalAxisSum();
        const inflow_content_height = intrinsic_outer_height - resolved_content_box_inset.verticalAxisSum();
        const free_space = container_inner_height - inflow_content_height;
        const group_offset = computeBlockAlignContentOffset(align_content, free_space);
        if (first_baseline) |baseline| first_baseline = baseline + group_offset;
        for (items) |*item| {
            if (item.final_layout) |*final_layout| {
                final_layout.location.y += group_offset;
            }
            // The static positions of out-of-flow children move with the in-flow content
            if (item.position.isOutOfFlow()) {
                item.static_position.y += group_offset;
            }
        }
        var any_in_flow = false;
        for (items) |*item| {
            if (item.final_layout != null) any_in_flow = true;
        }
        if (any_in_flow) {
            inflow_overflow_rect = Rect(f32).zero;
            const overflow_container: ScrollableOverflowContainer = .{
                .parent_is_scroll_container = is_scroll_container,
                .parent_size = final_outer_size.sub(resolved_border.sumAxes()).sub(scrollbar_gutter.sumAxes()),
                .reversed = .{ .x = direction.isRtl(), .y = false },
                .padding = resolved_padding,
            };
            for (items) |*item| {
                if (item.final_layout) |*final_layout| {
                    const contribution_location: Point(f32) = .{
                        .x = final_layout.location.x - resolved_border.left - scrollbar_gutter.left,
                        .y = final_layout.location.y - resolved_border.top,
                    };
                    inflow_overflow_rect = inflow_overflow_rect.@"union"(computeScrollableOverflowContribution(
                        contribution_location,
                        final_layout.size,
                        final_layout.scrollable_overflow_rect.rect(),
                        final_layout.border,
                        item.overflow,
                        item.contain,
                        &overflow_container,
                        final_layout.margin.map(f32, minZero),
                    ));
                }
            }
        }
    }

    // Determine whether this node can be collapsed through
    var all_in_flow_children_can_be_collapsed_through = true;
    for (items) |*item| {
        if (item.float.isFloated()) continue;
        if (!(item.position.isOutOfFlow() or item.can_be_collapsed_through)) {
            all_in_flow_children_can_be_collapsed_through = false;
            break;
        }
    }
    // CSS2 §8.3.1: a box's top and bottom margins collapse through it only if its *used* height
    // is zero, so `height`/`min-height`/`max-height` are judged by the height they resolve to
    // (e.g. `height: 1px; max-height: 0` collapses, `min-height: 1%` under an auto-height
    // parent collapses) rather than by their computed values.
    const can_be_collapsed_through = !has_styles_preventing_being_collapsed_through and
        container_outer_height == 0.0 and
        all_in_flow_children_can_be_collapsed_through;

    var output: LayoutOutput = .{
        .size = final_outer_size,
        .scrollable_overflow_rect = ScrollableOverflow.zero,
        .baselines = Baselines.fromFirst(first_baseline),
        .top_margin = if (own_margins_collapse_with_children.start)
            first_child_top_margin_set
        else
            CollapsibleMarginSet.fromMargin(resolveOrZero(raw_margin.top, parent_size.width, tree)),
        .bottom_margin = if (own_bottom_margin_collapses_with_children)
            last_child_bottom_margin_set
        else
            CollapsibleMarginSet.fromMargin(resolveOrZero(raw_margin.bottom, parent_size.width, tree)),
        .margins_can_collapse_through = can_be_collapsed_through,
        .oof_candidates = OofCandidates.none,
        .oof_positioning_area = null,
    };

    // Short-circuit if computing size.
    //
    // Note: it is important that we return the margin-collapsing related outputs here as Parent block containers
    // rely on the `top_margin`/`bottom_margin` of their children to compute their own intrinsic height.
    if (run_mode == .compute_size) {
        return output;
    }

    // Commit deferred child layouts to the tree.
    for (items) |*item| {
        if (item.final_layout) |*final_layout| {
            tree.setUnroundedLayout(item.node_id, final_layout);
        }
    }

    // 4. Collect out-of-flow candidates in document order (direct out-of-flow children plus
    // candidates bubbled from in-flow children's subtrees). These are laid out by the
    // out-of-flow positioning pass (`computeOofLayout`), which runs after this algorithm.
    var candidates: OofCandidates = .none;
    errdefer candidates.deinit(gpa);
    for (items) |*item| {
        if (item.position.isOutOfFlow()) {
            // The static-position rectangle of an out-of-flow child of a block container spans
            // the container's content box in the inline axis, and is a zero-height line at the
            // child's hypothetical position in the block axis. The child's self-alignment
            // properties determine how it is aligned within that rectangle.
            // <https://www.w3.org/TR/css-position-3/#staticpos-rect>
            const inline_area: Line(f32) = .{
                .start = resolved_content_box_inset.left,
                .end = container_outer_width - resolved_content_box_inset.right,
            };
            const block_area: Line(f32) = .{ .start = item.static_position.y, .end = item.static_position.y };
            // A `justify_self` of `null` takes the container's `justify-items`. Block containers have
            // no `align-items`, so an `align_self` of `null` behaves as `normal`.
            const justify_self = (item.justify_self orelse justify_items).resolveSelfRelative(item.direction, direction, true);
            const align_self = (item.align_self orelse AlignItems.normal).resolveSelfRelative(item.direction, direction, false);
            try candidates.push(gpa, .{
                .node = item.node_id,
                .order = item.order,
                .position = item.position,
                .static_position = .{
                    .x = AxisStaticPosition.fromAlignment(justify_self, inline_area, direction.isRtl()),
                    .y = AxisStaticPosition.fromAlignment(align_self, block_area, false),
                },
            });
        } else if (!item.oof_candidates.isEmpty()) {
            // Translate anchors from item-relative to container-relative coordinates
            if (item.final_layout) |*final_layout| {
                item.oof_candidates.translate(final_layout.location);
            }
            try candidates.append(gpa, &item.oof_candidates);
        }
    }

    const absolute_position_inset = resolved_border.add(scrollbar_gutter);
    const absolute_position_area = final_outer_size.sub(absolute_position_inset.sumAxes());
    const absolute_position_offset: Point(f32) = .{ .x = absolute_position_inset.left, .y = absolute_position_inset.top };

    {
        const client_width = @max(
            final_outer_size.width - resolved_border.horizontalAxisSum() - scrollbar_gutter.horizontalAxisSum(),
            0.0,
        );
        if (direction.isRtl()) {
            var rtl_rect = Rect(f32).zero;
            rtl_rect.right = client_width;
            inflow_overflow_rect = inflow_overflow_rect.@"union"(rtl_rect);
        }
        if (is_scroll_container) {
            inflow_overflow_rect = inflow_overflow_rect.@"union"(.{
                .left = if (direction.isRtl()) @min(client_width - resolved_padding.left, 0.0) else 0.0,
                .right = if (direction.isRtl()) client_width else resolved_padding.right,
                .top = 0.0,
                .bottom = resolved_padding.bottom,
            });
        }
        output.scrollable_overflow_rect = finalizeScrollableOverflow(
            inflow_overflow_rect,
            final_outer_size.sub(resolved_border.sumAxes()).sub(scrollbar_gutter.sumAxes()),
            .{ .x = direction.isRtl(), .y = false },
            is_scroll_container,
        );
    }

    // 5. Perform hidden layout on hidden children
    const len = tree.childCount(node_id);
    for (0..len) |order| {
        const child = tree.getChildId(node_id, order);
        const child_style = tree.getBlockChildStyle(child);
        if (child_style.getBoxGenerationMode() == .none) {
            tree.setUnroundedLayout(child, &Layout.withOrder(@intCast(order)));
            var hidden_output = try traits.performChildLayout(
                tree,
                child,
                Size(?f32).none,
                Size(?f32).none,
                Size(AvailableSpace).max_content,
                .inherent_size,
                Line(bool).false,
            );
            hidden_output.deinit(gpa);
        }
    }

    output.oof_candidates = candidates;
    output.oof_positioning_area = .{ .size = absolute_position_area, .offset = absolute_position_offset };
    return output;
}

/// Create a list of `BlockItem` structs where each item in the list represents a child of the current node.
/// The caller owns the returned slice (free it with `freeBlockItems`).
fn generateItemList(tree: anytype, node: NodeId, node_inner_size: Size(?f32)) LayoutError![]BlockItem {
    const gpa = tree.allocator();
    var items: std.ArrayList(BlockItem) = .empty;
    errdefer items.deinit(gpa);
    try items.ensureTotalCapacity(gpa, tree.childCount(node));

    var child_ids = tree.childIds(node);
    var order: u32 = 0;
    while (child_ids.next()) |child_node_id| {
        const child_style = tree.getBlockChildStyle(child_node_id);
        if (child_style.getBoxGenerationMode() == .none) continue;
        defer order += 1;

        const aspect_ratio = child_style.getAspectRatio();
        const padding = resolveOrZero(child_style.getPadding(), node_inner_size.width, tree);
        const border = resolveOrZero(child_style.getBorder(), node_inner_size.width, tree);
        const pb_sum = padding.add(border).sumAxes();
        const box_sizing_adjustment = if (child_style.getBoxSizing() == .content_box) pb_sum else Size(f32).zero;

        const position = child_style.getPosition();
        const overflow = child_style.getOverflow();

        const child_float = child_style.getFloat();
        const is_not_floated = child_float == .none;

        const is_block = child_style.isBlock();
        const is_table = child_style.isTable();
        const is_compressible_replaced = child_style.isCompressibleReplaced();
        const min_content_width_cap: ?f32 = if (is_compressible_replaced) blk: {
            const width = maybeResolve(child_style.getSize().width, @as(?f32, 0.0), tree);
            const max_width = maybeResolve(child_style.getMaxSize().width, @as(?f32, 0.0), tree);
            const capped: ?f32 = if (width) |w| maybeMin(w, max_width) else max_width;
            break :blk maybeAdd(capped, box_sizing_adjustment.width);
        } else null;
        const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
        const contain = child_style.getContain();

        const is_in_same_bfc: bool = is_block and
            !is_table and
            !position.isOutOfFlow() and
            is_not_floated and
            !is_scroll_container and
            !contain.establishesIndependentFormattingContext() and
            child_style.getAlignContent().keyword == .normal;

        items.appendAssumeCapacity(.{
            .node_id = child_node_id,
            .order = order,
            .is_table = is_table,
            .is_compressible_replaced = is_compressible_replaced,
            .min_content_width_cap = min_content_width_cap,
            .is_in_same_bfc = is_in_same_bfc,
            .float = child_float,
            .clear = child_style.getClear(),
            .size_style = child_style.getSize(),
            .size = maybeAdd(maybeResolve(child_style.getSize(), node_inner_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
            .min_size = maybeAdd(maybeResolve(child_style.getMinSize(), node_inner_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
            .max_size = maybeAdd(maybeResolve(child_style.getMaxSize(), node_inner_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
            .overflow = overflow,
            .contain = contain,
            .scrollbar_width = child_style.getScrollbarWidth(),
            .position = position,
            .direction = child_style.getDirection(),
            .align_self = child_style.getAlignSelf(),
            .justify_self = child_style.getJustifySelf(),
            .inset = child_style.getInset(),
            .margin = child_style.getMargin(),
            .padding = padding,
            .border = border,
            .padding_border_sum = pb_sum,

            // Fields to be computed later (for now we initialise with dummy values)
            .computed_size = Size(f32).zero,
            .static_position = Point(f32).zero,
            .can_be_collapsed_through = false,
            .final_layout = null,
            .oof_candidates = .none,
        });
    }
    return items.toOwnedSlice(gpa);
}

/// Resolve the `stretch` sizing keyword for an item's height style. In the block axis the
/// intrinsic sizing keywords (`min-content`, `max-content`, `fit-content`, `fit-content(...)`)
/// are all equal to the content size, which is what an auto height already resolves to, so
/// only `stretch` requires explicit resolution.
///
/// Each of the item's block-axis margins is subtracted from the stretch size unless it is
/// flagged in `margins_treated_as_zero`: when stretching a block-level box, a margin that
/// could collapse through the corresponding edge of the containing block (which has neither
/// border nor padding on that side and does not establish a new BFC) is treated as zero.
/// <https://github.com/w3c/csswg-drafts/issues/11044#issuecomment-2599101601>
/// <https://github.com/w3c/csswg-drafts/issues/13260>
inline fn resolveStretchHeight(
    height_style: Dimension,
    container_inner_height: ?f32,
    item_margin: Rect(f32),
    margins_treated_as_zero: Line(bool),
) ?f32 {
    if (!height_style.isStretch()) {
        return null;
    }
    var height = container_inner_height orelse return null;
    if (!margins_treated_as_zero.start) {
        height -= item_margin.top;
    }
    if (!margins_treated_as_zero.end) {
        height -= item_margin.bottom;
    }
    return height;
}

/// Compute the offset applied to a box by its `inset` if it is `position: relative` (CSS2.2 9.4.3).
///
/// Percentages resolve against the containing block's content box (`parent_size`); a percentage
/// that cannot be resolved behaves as `auto`. If both insets in an axis are non-auto, `top` wins
/// over `bottom`, and `left` wins over `right` in LTR (`right` over `left` in RTL).
inline fn resolveRelativeOffset(item: *const BlockItem, parent_size: Size(?f32), direction: Direction, tree: anytype) Point(f32) {
    if (item.position != .relative) {
        return Point(f32).zero;
    }
    const left = maybeResolve(item.inset.left, parent_size.width, tree);
    const right = maybeResolve(item.inset.right, parent_size.width, tree);
    const top = maybeResolve(item.inset.top, parent_size.height, tree);
    const bottom = maybeResolve(item.inset.bottom, parent_size.height, tree);
    const x: ?f32 = if (direction.isRtl())
        (if (right) |r| -r else left)
    else
        (left orelse (if (right) |r| -r else null));
    const y: ?f32 = top orelse (if (bottom) |b| -b else null);
    return .{ .x = x orelse 0.0, .y = y orelse 0.0 };
}

/// Compute the content-based width in the case that the width of the container is not known
fn determineContentBasedContainerWidth(tree: anytype, items: []const BlockItem, available_width: AvailableSpace) LayoutError!f32 {
    const available_space: Size(AvailableSpace) = .{ .width = available_width, .height = .min_content };

    var max_child_width: f32 = 0.0;
    var float_contribution = FloatIntrinsicWidthCalculator.new(available_width);
    for (items) |*item| {
        if (item.position.isOutOfFlow()) continue;
        const known_dimensions = maybeClamp(item.size, item.min_size, item.max_size);

        const item_x_margin_sum = resolveOrZero(item.margin, available_space.width.intoOption(), tree).horizontalAxisSum();
        const measured_width = if (known_dimensions.width) |width| width else blk: {
            const item_available_width: AvailableSpace = if (resolveSizingKeyword(item.size_style.width, null, null, tree)) |resolution| switch (resolution) {
                .measure => |measure_available_width| measure_available_width,
                .exact => |width| .{ .definite = width },
            } else maybeSub(available_space.width, item_x_margin_sum);
            const width = try traits.measureChildSize(
                tree,
                item.node_id,
                known_dimensions,
                Size(?f32).none,
                .{ .width = item_available_width, .height = available_space.height },
                .inherent_size,
                .horizontal,
                // Must match the value passed when laying the item out (see `Cache`)
                if (item.is_in_same_bfc) Line(bool).true else Line(bool).false,
            );
            // The cap is the item's min-content contribution, so its fit-content contribution is
            // min(max-content, max(cap, available))
            if (item.min_content_width_cap) |cap| {
                switch (item_available_width) {
                    .min_content => break :blk maybeMax(@min(width, cap), item.min_size.width),
                    .definite => |available| break :blk maybeMax(@min(width, @max(cap, available)), item.min_size.width),
                    else => {},
                }
            }
            break :blk width;
        };

        const width = f32Max(measured_width, item.padding_border_sum.width) + item_x_margin_sum;

        if (item.float.floatDirection()) |float_direction| {
            float_contribution.addFloat(width, float_direction, item.clear);
            continue;
        }

        max_child_width = f32Max(max_child_width, width);
    }

    max_child_width = @max(max_child_width, float_contribution.result());

    return max_child_width;
}

/// Resolve the known dimensions an in-flow block-level item is laid out with
fn blockItemKnownDimensions(
    tree: anytype,
    item: *const BlockItem,
    stretch_width: f32,
    container_inner_width: f32,
    container_percentage_resolution_height: ?f32,
    item_non_auto_margin: Rect(f32),
    children_margins_adjoin_own_edges: Line(bool),
    parent_size: Size(?f32),
    is_stretch: bool,
    is_fit_content: bool,
) LayoutError!Size(?f32) {
    // Unless stretched, tables and compressible replaced elements resolve their own width
    // <https://www.w3.org/TR/CSS22/visudet.html#block-replaced-width>
    if ((item.is_table or item.is_compressible_replaced) and !is_stretch) {
        return Size(?f32).none;
    }

    // The automatic width of a block-level box whose `justify-self` is neither `normal` nor `stretch`
    // is equivalent to `fit-content` rather than `stretch`
    const width_style = if (is_fit_content and item.size_style.width.isAuto())
        Dimension.fit_content
    else
        item.size_style.width;

    // Items with a sizing keyword width (min-content, max-content, fit-content,
    // fit-content(...), stretch) resolve their width either directly or by measuring
    // the item under the corresponding available space constraint
    const keyword_width: ?f32 = if (resolveSizingKeyword(width_style, stretch_width, container_inner_width, tree)) |resolution| switch (resolution) {
        .exact => |width| width,
        .measure => |item_available_width| try traits.measureChildSize(
            tree,
            item.node_id,
            Size(?f32).none,
            parent_size,
            .{ .width = item_available_width, .height = .max_content },
            .inherent_size,
            .horizontal,
            // Must match the value passed when laying the item out (see `Cache`)
            if (item.is_in_same_bfc) Line(bool).true else Line(bool).false,
        ),
    } else null;

    const keyword_height = resolveStretchHeight(
        item.size_style.height,
        container_percentage_resolution_height,
        item_non_auto_margin,
        children_margins_adjoin_own_edges,
    );

    const mapped: Size(?f32) = .{
        .width = maybeClamp(item.size.width orelse keyword_width orelse stretch_width, item.min_size.width, item.max_size.width),
        .height = item.size.height orelse keyword_height,
    };
    return maybeClamp(mapped, item.min_size, item.max_size);
}

/// The results of `performFinalLayoutOnInFlowChildren` (upstream returns a tuple)
const FinalLayoutResult = struct {
    inflow_overflow_rect: Rect(f32),
    content_height: f32,
    first_child_top_margin_set: CollapsibleMarginSet,
    last_child_bottom_margin_set: CollapsibleMarginSet,
    first_baseline: ?f32,
};

/// Compute each child's final size and position
fn performFinalLayoutOnInFlowChildren(
    tree: anytype,
    run_mode: RunMode,
    items: []BlockItem,
    container_outer_width: f32,
    container_percentage_resolution_height_in: ?f32,
    content_box_inset: Rect(f32),
    resolved_content_box_inset: Rect(f32),
    resolved_border: Rect(f32),
    resolved_padding: Rect(f32),
    text_align: TextAlign,
    justify_items: AlignItems,
    direction: Direction,
    own_margins_collapse_with_children: Line(bool),
    children_margins_adjoin_own_edges: Line(bool),
    is_scroll_container: bool,
    block_ctx: *BlockContext,
) LayoutError!FinalLayoutResult {
    const gpa = tree.allocator();
    // Resolve container_inner_width for sizing child nodes using initial content_box_inset
    const container_inner_width = @max(container_outer_width - resolved_content_box_inset.horizontalAxisSum(), 0.0);
    const overflow_container: ScrollableOverflowContainer = .{
        .parent_is_scroll_container = is_scroll_container,
        .parent_size = .{ .width = container_inner_width + resolved_padding.horizontalAxisSum(), .height = 0.0 },
        .reversed = .{ .x = direction.isRtl(), .y = false },
        .padding = resolved_padding,
    };
    const container_percentage_resolution_height = maybeSub(container_percentage_resolution_height_in, resolved_content_box_inset.verticalAxisSum());
    const parent_size: Size(?f32) = .{ .width = container_inner_width, .height = container_percentage_resolution_height };
    // Vertical available space in block flow is indefinite, NOT a min-content
    // constraint: MaxContent is taffy's representation of "indefinite".
    // Passing MinContent here made every descendant grid believe it was being
    // sized under a min-content constraint, in which the maximize-tracks step
    // has zero free space — so auto rows containing only scroll-container
    // items (overflow != visible, automatic minimum size = 0) collapsed to
    // zero height. Browsers size such rows to the item's content.
    const available_space: Size(AvailableSpace) = .{ .width = .{ .definite = container_inner_width }, .height = .max_content };

    // TODO: handle nested blocks with different widths
    if (block_ctx.isBfcRoot()) {
        block_ctx.setWidth(container_outer_width);
        block_ctx.applyContentBoxInset(FloatInsets.new(
            resolved_content_box_inset.left,
            resolved_content_box_inset.right,
        ));
    }

    // If this block's top margin does not collapse with its children's then the position of its
    // top margin strut is resolved relative to it, and floats adjoining ancestor struts do not
    // adjoin this block's strut.
    if (!own_margins_collapse_with_children.start) {
        block_ctx.commitStrut();
    }

    var inflow_overflow_rect = Rect(f32).zero;
    var committed_y_offset = resolved_content_box_inset.top;
    var y_offset_for_absolute = resolved_content_box_inset.top;
    var first_child_top_margin_set = CollapsibleMarginSet.zero;
    var active_collapsible_margin_set = CollapsibleMarginSet.zero;
    var is_collapsing_with_first_margin_set = true;
    var first_baseline: ?f32 = null;
    // Whether the active margin set contains the margins of a self-collapsing element with
    // clearance. Such margins collapse with the margins of following siblings but the resulting
    // margin does not collapse with the bottom margin of the parent block.
    var active_margin_set_has_clearance = false;

    var has_active_floats = block_ctx.hasActiveFloats(committed_y_offset);

    for (items) |*item| {
        if (item.position.isOutOfFlow()) {
            const x = switch (direction) {
                .ltr => resolved_content_box_inset.left,
                .rtl => container_outer_width - resolved_content_box_inset.right,
            };
            item.static_position = .{ .x = x, .y = y_offset_for_absolute };
            continue;
        }

        const item_margin: Rect(?f32) = .{
            .left = item.margin.left.resolveToOption(container_inner_width, tree),
            .right = item.margin.right.resolveToOption(container_inner_width, tree),
            .top = item.margin.top.resolveToOption(container_inner_width, tree),
            .bottom = item.margin.bottom.resolveToOption(container_inner_width, tree),
        };
        const item_non_auto_margin: Rect(f32) = .{
            .left = item_margin.left orelse 0.0,
            .right = item_margin.right orelse 0.0,
            .top = item_margin.top orelse 0.0,
            .bottom = item_margin.bottom orelse 0.0,
        };
        const item_non_auto_x_margin_sum = item_non_auto_margin.horizontalAxisSum();

        const scrollbar_size: Size(f32) = .{
            .width = if (item.overflow.y == .scroll) item.scrollbar_width else 0.0,
            .height = if (item.overflow.x == .scroll) item.scrollbar_width else 0.0,
        };

        // Handle floated boxes
        if (item.float.floatDirection()) |float_direction| {
            has_active_floats = true;

            // A float with `width: auto` is shrink-to-fit (fit-content) sized: the available
            // space clamped between its min-content and max-content sizes.
            const available_width = @max(container_inner_width - item_non_auto_x_margin_sum, 0.0);
            var item_known_width: ?f32 = null;
            var item_available_width: AvailableSpace = .{ .definite = available_width };
            if (resolveSizingKeyword(item.size_style.width, available_width, container_inner_width, tree)) |resolution| {
                switch (resolution) {
                    .measure => |available| item_available_width = available,
                    .exact => |width| {
                        item_known_width = width;
                        item_available_width = .{ .definite = width };
                    },
                }
            }
            const item_known_height = resolveStretchHeight(
                item.size_style.height,
                container_percentage_resolution_height,
                item_non_auto_margin,
                // The margins of a float never collapse
                Line(bool).false,
            );
            var item_layout = try traits.performChildLayout(
                tree,
                item.node_id,
                .{ .width = item_known_width, .height = item_known_height },
                parent_size,
                .{ .width = item_available_width, .height = .max_content },
                .inherent_size,
                // A float establishes a new block formatting context: its margins do not
                // collapse with the margins of its children
                Line(bool).false,
            );
            item.oof_candidates.deinit(gpa);
            item.oof_candidates = item_layout.oof_candidates.take();
            const margin_box = item_layout.size.add(item_non_auto_margin.sumAxes());

            // Floats that occur between collapsing margins are positioned as if they had an otherwise
            // empty anonymous block parent taking part in the flow, so the pending collapsible margins
            // contribute to the float's minimum y position (unless those margins collapse with the
            // container's own top margin, in which case they are applied outside the container).
            //
            // In the latter case the position of the float is not fully resolved: margins contributed
            // by later siblings can still collapse into the strut and move the container (and float).
            // Such floats force clearance on cleared elements whose margins adjoin the same strut.
            const adjoins_unresolved_strut = is_collapsing_with_first_margin_set and own_margins_collapse_with_children.start;
            const y_offset_for_float = if (adjoins_unresolved_strut)
                committed_y_offset
            else
                committed_y_offset + active_collapsible_margin_set.resolve();

            var location = try block_ctx.placeFloatedBox(
                item.node_id.toU64(),
                margin_box,
                y_offset_for_float,
                float_direction,
                item.clear,
                adjoins_unresolved_strut,
            );

            // Ensure that content that appears after a float does not get positioned before/above the float
            //
            // FIXME: this isn't quite right, because a second float at the same location
            // shouldn't cause content to push down to it's level
            // committed_y_offset = committed_y_offset.max(location.y);
            // y_offset_for_absolute = y_offset_for_absolute.max(location.y);

            // Convert the margin-box location returned by float placement into a border-box location
            // for the output Layout
            location.y += item_non_auto_margin.top;
            location.x += item_non_auto_margin.left;

            // A relatively positioned float is placed as a float first, then offset by its
            // inset. The offset does not affect the placement of other content (CSS 2.2 9.4.3).
            const inset_offset = resolveRelativeOffset(item, parent_size, direction, tree);
            location.x += inset_offset.x;
            location.y += inset_offset.y;

            // Deferred to the post-loop pass in `computeInner` (like in-flow items) so that
            // `align-content` can shift `location.y` before the layout is committed.
            item.final_layout = .{
                .order = item.order,
                .size = item_layout.size,
                .scrollable_overflow_rect = item_layout.scrollable_overflow_rect,
                .scrollbar_size = scrollbar_size,
                .location = location,
                .padding = item.padding,
                .border = item.border,
                .margin = item_non_auto_margin,
            };

            {
                // TODO: Should the overflow of floated boxes count as "inflow_overflow_rect"
                // or should it be counted separately?
                const contribution_location: Point(f32) = .{
                    .x = location.x - resolved_content_box_inset.left + resolved_padding.left,
                    .y = location.y - resolved_border.top,
                };
                inflow_overflow_rect = inflow_overflow_rect.@"union"(computeScrollableOverflowContribution(
                    contribution_location,
                    item_layout.size,
                    item_layout.scrollable_overflow_rect.rect(),
                    item.border,
                    item.overflow,
                    item.contain,
                    &overflow_container,
                    item_non_auto_margin.map(f32, minZero),
                ));
            }

            continue;
        }

        // Handle non-floated boxes

        // `justify-self` on an in-flow block-level box (css-align-3 §6.1.1). `null` takes the
        // container's `justify-items`, and `normal` lays the box out according to the default
        // block layout rules. `stretch` does too: the default rules already stretch an
        // auto-width box, so it only differs from `normal` for tables and replaced boxes, which
        // would otherwise resolve their own width.
        const justify_self = (item.justify_self orelse justify_items).resolveSelfRelative(item.direction, direction, true);
        const is_stretch = justify_self.keyword == .stretch;
        // The (resolved) `justify-self` if it is neither `normal` nor `stretch`
        const non_stretch_justify_self: ?AlignSelf = switch (justify_self.keyword) {
            .normal, .stretch => null,
            else => justify_self,
        };

        var y_margin_offset: f32 = 0.0;
        var item_avoids_floats = false;
        var item_pushed_below_float = false;

        const Placement = struct { stretch_width: f32, position: Point(f32), width: f32 };
        const placement: Placement = if (item.is_in_same_bfc) blk: {
            const stretch_width = @max(container_inner_width - item_non_auto_x_margin_sum, 0.0);
            const position: Point(f32) = .{ .x = 0.0, .y = 0.0 };
            const width: f32 = 0.0;

            break :blk .{ .stretch_width = stretch_width, .position = position, .width = width };
        } else blk: {
            // Set y_margin_offset (different bfc child)
            if (!is_collapsing_with_first_margin_set or !own_margins_collapse_with_children.start) {
                y_margin_offset = active_collapsible_margin_set.collapseWithMargin(item_non_auto_margin.top).resolve();
            }
            const min_y = committed_y_offset + y_margin_offset;

            // In addition to the running flag, check the float context directly:
            // floats placed by the subtree of a preceding in-flow sibling (in the same
            // BFC) are not reflected in the flag
            if (has_active_floats or block_ctx.hasActiveFloats(min_y)) {
                const x_margins = FloatInsets.new(item_non_auto_margin.left, item_non_auto_margin.right);
                // An auto width resolves to at least the negation of the margin sum
                // (so that the margin box width is non-negative, per CSS2 §10.3.3)
                const min_auto_width = -item_non_auto_x_margin_sum;

                // Find the highest slot (at or below `min_y`) with enough horizontal space
                // for the item's border box, which must not overlap any float
                // The item's height isn't known until it is laid out, so only its styled
                // (minimum) height is checked against floats below its top edge
                const min_height = @max(
                    maybeClamp(item.size.height, item.min_size.height, item.max_size.height) orelse item.min_size.height orelse 0.0,
                    item.padding_border_sum.height,
                );
                var slot_segment: ?usize = null;
                const slot = while (true) {
                    const slot = block_ctx.findBfcSlot(
                        min_y,
                        min_height,
                        x_margins,
                        direction,
                        item.clear,
                        slot_segment,
                    );
                    const segment_id = slot.segment_id orelse break slot;
                    const width = maybeClamp(
                        item.size.width orelse @max(@max(slot.stretch_width, min_auto_width), 0.0),
                        item.min_size.width,
                        item.max_size.width,
                    );
                    if (width <= slot.border_width + fit_tolerance) {
                        break slot;
                    }
                    slot_segment = segment_id;
                };

                // If the item had to move down to avoid floats then it "separates from the
                // float": similarly to clearance, its top margin no longer collapses with
                // the parent's margins.
                if (slot.y > min_y) {
                    item_pushed_below_float = true;
                }

                has_active_floats = slot.segment_id != null;
                item_avoids_floats = true;
                const stretch_width = @max(@max(slot.stretch_width, min_auto_width), 0.0);
                break :blk .{ .stretch_width = stretch_width, .position = .{ .x = slot.x, .y = slot.y }, .width = slot.border_width };
            }

            if (!has_active_floats) {
                const stretch_width = @max(container_inner_width - item_non_auto_x_margin_sum, 0.0);
                break :blk .{
                    .stretch_width = stretch_width,
                    .position = .{ .x = resolved_content_box_inset.left, .y = min_y },
                    .width = container_inner_width,
                };
            }

            unreachable; // One of the above cases will always be hit
        };
        const stretch_width = placement.stretch_width;
        const float_avoiding_position = placement.position;
        const float_avoiding_width = placement.width;

        // The inputs to lay the item out with, given the stretch width available to it
        const inputs: LayoutInput = .{
            .run_mode = run_mode,
            .sizing_mode = .inherent_size,
            .axis = .both,
            .known_dimensions = try blockItemKnownDimensions(
                tree,
                item,
                stretch_width,
                container_inner_width,
                container_percentage_resolution_height,
                item_non_auto_margin,
                children_margins_adjoin_own_edges,
                parent_size,
                is_stretch,
                non_stretch_justify_self != null,
            ),
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = .{ .width = .{ .definite = stretch_width }, .height = available_space.height },
            .vertical_margins_are_collapsible = if (item.is_in_same_bfc) Line(bool).true else Line(bool).false,
        };

        const clear_threshold = block_ctx.clearedThreshold(item.clear);
        const clear_pos = clear_threshold orelse -std.math.inf(f32);

        // The height consumed by floats within a same-BFC child, relative to the child's
        // border-top. Added to the parent's contribution once the child's position is known.
        var child_float_contribution = -std.math.inf(f32);

        var item_layout = if (item.is_in_same_bfc) blk: {
            // Replaced elements may not have a known width (they are sized by their
            // measure function rather than stretch-sized)
            const width = @max(inputs.known_dimensions.width orelse stretch_width, item.padding_border_sum.width);

            // TODO: account for auto margins
            const inset_left = item_non_auto_margin.left + content_box_inset.left;
            const inset_right = container_outer_width - width - inset_left;
            const insets = FloatInsets.new(inset_left, inset_right);

            // Compute child layout. The child's position is estimated from its top margin collapsed with
            // the preceding margins (the child's own collapsed-through margins are not yet known).
            const estimated_y = committed_y_offset +
                active_collapsible_margin_set.collapseWithMargin(item_non_auto_margin.top).resolve();
            var child_block_ctx = block_ctx.subContext(@max(estimated_y, clear_pos), insets);
            const output = try tree.computeBlockChildLayout(item.node_id, inputs, &child_block_ctx);

            // Extract float contribution from child block context
            child_float_contribution = child_block_ctx.floatedContentHeightContribution();
            const child_top_adjoining_floats = child_block_ctx.topAdjoiningFloats();
            // Floats placed while the position of the child's top margin strut was unresolved
            // also adjoin this block's current strut
            block_ctx.mergeAdjoiningFloats(child_top_adjoining_floats);

            break :blk output;
        } else try tree.computeChildLayout(item.node_id, inputs);
        item.oof_candidates.deinit(gpa);
        item.oof_candidates = item_layout.oof_candidates.take();
        const final_size = item_layout.size;

        const top_margin_set = item_layout.top_margin.collapseWithMargin(item_margin.top orelse 0.0);
        const bottom_margin_set = item_layout.bottom_margin.collapseWithMargin(item_margin.bottom orelse 0.0);

        // Expand auto margins to fill available space
        // Note: Vertical auto-margins for relatively positioned block items simply resolve to 0.
        // See: https://www.w3.org/TR/CSS21/visudet.html#abs-non-replaced-width
        const free_x_space = f32Max(0.0, stretch_width - final_size.width);
        const x_axis_auto_margin_size: f32 = blk: {
            const auto_margin_count: u8 = @as(u8, @intFromBool(item_margin.left == null)) + @intFromBool(item_margin.right == null);
            if (auto_margin_count > 0) {
                break :blk free_x_space / @as(f32, @floatFromInt(auto_margin_count));
            } else {
                break :blk 0.0;
            }
        };
        const resolved_margin: Rect(f32) = .{
            .left = item_margin.left orelse x_axis_auto_margin_size,
            .right = item_margin.right orelse x_axis_auto_margin_size,
            .top = item_margin.top orelse 0.0,
            .bottom = item_margin.bottom orelse 0.0,
        };

        // Resolve item inset
        const inset_offset = resolveRelativeOffset(item, parent_size, direction, tree);

        // Set y_margin_offset (same bfc child)
        if (item.is_in_same_bfc and
            (!is_collapsing_with_first_margin_set or !own_margins_collapse_with_children.start))
        {
            y_margin_offset = active_collapsible_margin_set.collapseWithSet(top_margin_set).resolve();
        }

        // Compute clearance (CSS2.2 9.5.2). Clearance is introduced if the hypothetical position of the
        // item's top border edge (the position it would have with normal margin collapsing) is not past
        // the bottom of the relevant floats. When clearance is introduced the item's border edge is
        // placed at `max(float bottom, hypothetical position)`.
        var has_clearance = false;
        if (item.is_in_same_bfc) {
            if (clear_threshold) |threshold| {
                // The hypothetical position always includes the item's collapsed top margin set, even
                // when those margins collapse with the container's own top margin (and are thus applied
                // outside the container): in that case they still move the container (and hence the item)
                // relative to the floats.
                const hypothetical_y = committed_y_offset + active_collapsible_margin_set.collapseWithSet(top_margin_set).resolve();
                // Clearance is forced (regardless of the hypothetical position) if a relevant float is
                // adjoining the margin-collapse strut that the item's top margin would collapse into:
                // if the margins were allowed to collapse they would pull the float down with the item,
                // so clearance is inserted to separate the two, placing the item just below the float.
                const forced_clearance = block_ctx.hasAdjoiningFloat(item.clear);
                if (forced_clearance or hypothetical_y < threshold) {
                    has_clearance = true;
                    // Clearance stops the item's top margin collapsing with preceding margins. If those
                    // preceding margins collapse with the container's own top margin they are applied
                    // outside the container (moving it down), so the item's cleared position within the
                    // container must be reduced by that amount to keep its absolute position correct.
                    const escaped_margin = if (is_collapsing_with_first_margin_set and own_margins_collapse_with_children.start)
                        active_collapsible_margin_set.resolve()
                    else
                        0.0;
                    y_margin_offset = threshold - committed_y_offset - escaped_margin;
                }
            }
        }

        item.computed_size = item_layout.size;
        item.can_be_collapsed_through = item_layout.margins_can_collapse_through and !has_clearance;
        item.static_position = if (item.is_in_same_bfc) blk: {
            const uncleared_y = committed_y_offset + active_collapsible_margin_set.resolve();
            break :blk .{
                .x = switch (direction) {
                    .ltr => resolved_content_box_inset.left,
                    .rtl => container_outer_width - resolved_content_box_inset.right - final_size.width,
                },
                .y = @max(uncleared_y, clear_pos),
            };
        } else .{
            // TODO: handle inset and margins
            .x = switch (direction) {
                .ltr => float_avoiding_position.x,
                .rtl => float_avoiding_position.x + float_avoiding_width - final_size.width,
            },
            .y = float_avoiding_position.y,
        };
        var location: Point(f32) = if (item.is_in_same_bfc) .{
            .x = switch (direction) {
                .ltr => resolved_content_box_inset.left + inset_offset.x + resolved_margin.left,
                .rtl => container_outer_width -
                    resolved_content_box_inset.right -
                    final_size.width -
                    resolved_margin.right +
                    inset_offset.x,
            },
            .y = committed_y_offset + y_margin_offset + inset_offset.y,
        } else blk: {
            // When the item avoids floats, its non-auto margins are already accounted for in the
            // slot's border-box position/width (margins may overlap floats), so only the auto
            // portion of the resolved margin is added here.
            const extra_margin_left: f32, const extra_margin_right: f32 = if (item_avoids_floats)
                .{
                    resolved_margin.left - item_non_auto_margin.left,
                    resolved_margin.right - item_non_auto_margin.right,
                }
            else
                .{ resolved_margin.left, resolved_margin.right };

            // TODO: handle inset and margins
            break :blk .{
                .x = switch (direction) {
                    .ltr => float_avoiding_position.x + extra_margin_left + inset_offset.x,
                    .rtl => float_avoiding_position.x + float_avoiding_width - final_size.width - extra_margin_right +
                        inset_offset.x,
                },
                .y = float_avoiding_position.y + inset_offset.y,
            };
        };

        // Floats within the child are positioned relative to the child's border-top, so the
        // child's (margin-collapsed) position, rather than its relative offset, is added.
        if (item.is_in_same_bfc) {
            block_ctx.addChildFloatedContentHeightContribution(location.y - inset_offset.y + child_float_contribution);
        }

        // Apply alignment. `justify-self` aligns the item's margin box within its alignment
        // container and takes precedence over legacy `text-align`, but auto margins (which have
        // already absorbed the free space) take precedence over `justify-self`.
        const has_auto_x_margin = item_margin.left == null or item_margin.right == null;
        const item_outer_width = item_layout.size.width + resolved_margin.horizontalAxisSum();
        if (non_stretch_justify_self != null and !has_auto_x_margin) {
            const justify_self_value = non_stretch_justify_self.?;
            // The alignment container is the containing block, except that a BFC-establishing
            // box placed next to a float aligns within the space left over by the float (in
            // which case the slot is already inset by the item's margins).
            const container_start: f32, const align_free_x_space: f32 = if (item_avoids_floats)
                .{ float_avoiding_position.x - resolved_margin.left, float_avoiding_width - item_layout.size.width }
            else
                .{ resolved_content_box_inset.left, container_inner_width - item_outer_width };

            const keyword: AlignItemsKeyword = if (justify_self_value.safety == .safe and align_free_x_space < 0.0)
                .start
            else
                justify_self_value.keyword;
            const align_to_end: ?bool = switch (keyword) {
                .center => null,
                .end, .flex_end, .self_end => true,
                else => false,
            };
            const offset: f32 = if (align_to_end) |end|
                (if (end != direction.isRtl()) align_free_x_space else 0.0)
            else
                align_free_x_space / 2.0;
            location.x = container_start + resolved_margin.left + inset_offset.x + offset;
        } else if (non_stretch_justify_self == null and item_outer_width < container_inner_width) {
            const text_free_x_space = container_inner_width - item_outer_width;
            switch (text_align) {
                .auto => {
                    // Do nothing
                },
                .legacy_left => switch (direction) {
                    // Do nothing. Left aligned by default.
                    .ltr => {},
                    .rtl => location.x -= text_free_x_space,
                },
                .legacy_right => switch (direction) {
                    .ltr => location.x += text_free_x_space,
                    // Do nothing. Right aligned by default.
                    .rtl => {},
                },
                .legacy_center => switch (direction) {
                    .ltr => location.x += text_free_x_space / 2.0,
                    .rtl => location.x -= text_free_x_space / 2.0,
                },
            }
        }

        // A block container's first baseline is the first baseline of its first in-flow child
        // that has one. The child's relative offset does not affect it.
        if (first_baseline == null) {
            const child_baseline = childFirstBaseline(item_layout.baselines.first, item_layout.size.height, item.overflow.y);
            if (child_baseline) |baseline| first_baseline = location.y - inset_offset.y + baseline;
        }

        // Used auto margins include float-avoidance offsets, unlike the alignment margins above.
        const used_margin: Rect(f32) = blk: {
            var margin = resolved_margin;
            if (item_avoids_floats) {
                if (item_margin.left == null) {
                    margin.left += float_avoiding_position.x - resolved_content_box_inset.left;
                }
                if (item_margin.right == null) {
                    margin.right += container_outer_width -
                        resolved_content_box_inset.right -
                        float_avoiding_position.x -
                        float_avoiding_width;
                }
            }
            break :blk margin;
        };

        // Defer `setUnroundedLayout` to the post-loop pass in `computeInner` so that
        // `align-content` can shift `location.y` before the layout is committed to the tree.
        item.final_layout = .{
            .order = item.order,
            .size = item_layout.size,
            .scrollable_overflow_rect = item_layout.scrollable_overflow_rect,
            .scrollbar_size = scrollbar_size,
            .location = location,
            .padding = item.padding,
            .border = item.border,
            .margin = used_margin,
        };

        {
            const contribution_location: Point(f32) = .{
                .x = location.x - resolved_content_box_inset.left + resolved_padding.left,
                .y = location.y - resolved_border.top,
            };
            inflow_overflow_rect = inflow_overflow_rect.@"union"(computeScrollableOverflowContribution(
                contribution_location,
                final_size,
                item_layout.scrollable_overflow_rect.rect(),
                item.border,
                item.overflow,
                item.contain,
                &overflow_container,
                used_margin.map(f32, minZero),
            ));
        }

        // Update first_child_top_margin_set
        //
        // The top margin of an item with clearance does not collapse with the container's top margin,
        // so clearance terminates collapsing without contributing the item's own margins.
        if (is_collapsing_with_first_margin_set and item_pushed_below_float) {
            // The item's top margin "separated from the float" and must not
            // propagate to the parent
            is_collapsing_with_first_margin_set = false;
        }
        if (is_collapsing_with_first_margin_set and has_clearance) {
            is_collapsing_with_first_margin_set = false;
        } else if (is_collapsing_with_first_margin_set) {
            if (item.can_be_collapsed_through) {
                first_child_top_margin_set = first_child_top_margin_set
                    .collapseWithSet(top_margin_set)
                    .collapseWithSet(bottom_margin_set);
            } else {
                first_child_top_margin_set = first_child_top_margin_set.collapseWithSet(top_margin_set);
                is_collapsing_with_first_margin_set = false;
            }
        }

        // Update active_collapsible_margin_set
        if (item.can_be_collapsed_through) {
            active_collapsible_margin_set = active_collapsible_margin_set
                .collapseWithSet(top_margin_set)
                .collapseWithSet(bottom_margin_set);
            y_offset_for_absolute = committed_y_offset + item_layout.size.height + y_margin_offset;
        } else {
            committed_y_offset = location.y - inset_offset.y + item_layout.size.height;
            // A self-collapsing item with clearance is not collapsed through (its margins do not collapse
            // with margins of preceding siblings), but its top and bottom margins still collapse with each
            // other and with the margins of following siblings.
            if (has_clearance and item_layout.margins_can_collapse_through) {
                // The element's border edge stays at the cleared position, but its collapsed margin
                // extends below it: the border edge sits `top margin` inside the collapsed margin, so
                // following content is offset by `collapsed margin - top margin` from the border edge.
                committed_y_offset -= top_margin_set.resolve();
                active_collapsible_margin_set = top_margin_set.collapseWithSet(bottom_margin_set);
                active_margin_set_has_clearance = true;
            } else {
                active_collapsible_margin_set = bottom_margin_set;
                active_margin_set_has_clearance = false;
            }
            y_offset_for_absolute = committed_y_offset + active_collapsible_margin_set.resolve();
            // Committing in-flow content resolves the position of the current margin-collapse strut,
            // so floats placed before this point no longer force clearance
            block_ctx.commitStrut();
        }
    }

    // The margins of a self-collapsing element with clearance do not collapse with the bottom
    // margin of the parent block: they extend the parent's content height instead of escaping it
    const last_child_bottom_margin_set = if (active_margin_set_has_clearance) CollapsibleMarginSet.zero else active_collapsible_margin_set;
    const bottom_y_margin_offset = if (active_margin_set_has_clearance)
        active_collapsible_margin_set.resolve()
    else if (own_margins_collapse_with_children.end or
        (is_collapsing_with_first_margin_set and own_margins_collapse_with_children.start))
        0.0
    else
        last_child_bottom_margin_set.resolve();

    committed_y_offset += resolved_content_box_inset.bottom + bottom_y_margin_offset;
    const content_height = f32Max(0.0, committed_y_offset);
    return .{
        .inflow_overflow_rect = inflow_overflow_rect,
        .content_height = content_height,
        .first_child_top_margin_set = first_child_top_margin_set,
        .last_child_bottom_margin_set = last_child_bottom_margin_set,
        .first_baseline = first_baseline,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests (laffy additions: upstream has no unit tests for this module; these check margin
// collapsing, floats and the block context API, and that layouts free everything they allocate)

const testing = std.testing;
const TaffyTree = @import("../tree/taffy_tree.zig").TaffyTree;
const Style = style_mod.Style;
const LengthPercentage = style_mod.LengthPercentage;

/// Build a multi-level block tree with floats (in the root's block formatting context, inside a
/// nested same-BFC block and inside a `flow-root`), cleared boxes, absolutely positioned and fixed
/// children at several depths (some claimed by a relatively positioned `flow-root`, some
/// bubbling to the root), a hidden subtree and an `align-content` container, then lay it out
/// several times.
fn layoutNestedBlockTree(gpa: Allocator) !void {
    var taffy = try TaffyTree(void).init(gpa);
    defer taffy.deinit();

    var abs_style: Style = .{ .display = .block };
    abs_style.position = .absolute;
    abs_style.inset = .{ .left = .length(5.0), .right = .auto, .top = .auto, .bottom = .length(3.0) };
    abs_style.size = Size(Dimension).fromLengths(7.0, 4.0);
    var fixed_style: Style = .{ .display = .block };
    fixed_style.position = .fixed;
    fixed_style.size = Size(Dimension).fromLengths(2.0, 3.0);
    var leaf_style: Style = .{ .display = .block };
    leaf_style.size = .{ .width = Dimension.auto, .height = Dimension.length(10.0) };
    var float_left_style: Style = .{ .display = .block, .float = .left };
    float_left_style.size = Size(Dimension).fromLengths(50.0, 30.0);
    var float_right_style: Style = .{ .display = .block, .float = .right };
    float_right_style.size = Size(Dimension).fromLengths(40.0, 20.0);
    var clear_style = leaf_style;
    clear_style.clear = .both;
    var hidden_style: Style = .{ .display = .none };
    hidden_style.size = Size(Dimension).fromLengths(10.0, 10.0);

    // A nested same-BFC block holding a float (with absolutely positioned and fixed children of
    // its own), a relatively positioned float, an out-of-flow child, a hidden subtree and a
    // cleared box
    const nested_float_abs = try taffy.newLeaf(abs_style);
    const nested_float_fixed = try taffy.newLeaf(fixed_style);
    const nested_float_leaf = try taffy.newLeaf(leaf_style);
    var nested_float_style = float_left_style;
    nested_float_style.size = .{ .width = Dimension.auto, .height = Dimension.auto };
    const nested_float = try taffy.newWithChildren(nested_float_style, &.{ nested_float_leaf, nested_float_abs, nested_float_fixed });
    var relative_float_style = float_right_style;
    relative_float_style.position = .relative;
    relative_float_style.inset = .{ .left = .length(2.0), .right = .auto, .top = .length(3.0), .bottom = .auto };
    const relative_float = try taffy.newLeaf(relative_float_style);
    const para_abs = try taffy.newLeaf(abs_style);
    const hidden_leaf = try taffy.newLeaf(leaf_style);
    const hidden = try taffy.newWithChildren(hidden_style, &.{hidden_leaf});
    const para_text = try taffy.newLeaf(leaf_style);
    const para_cleared = try taffy.newLeaf(clear_style);
    var para_style: Style = .{ .display = .block };
    para_style.margin = .{ .left = .length(0.0), .right = .length(0.0), .top = .length(10.0), .bottom = .length(5.0) };
    const para = try taffy.newWithChildren(para_style, &.{ nested_float, para_text, relative_float, para_abs, hidden, para_cleared });

    // A relatively positioned flow-root that claims its absolutely positioned descendants and
    // contains its own floats
    const flow_float = try taffy.newLeaf(float_left_style);
    const flow_abs = try taffy.newLeaf(abs_style);
    const flow_leaf = try taffy.newLeaf(leaf_style);
    var flow_root_style: Style = .{ .display = .flow_root };
    flow_root_style.position = .relative;
    flow_root_style.padding = Rect(LengthPercentage).length(2.0);
    const flow_root = try taffy.newWithChildren(flow_root_style, &.{ flow_float, flow_leaf, flow_abs });

    // An `align-content: center` container (which establishes a new block formatting context)
    var centered_style: Style = .{ .display = .block };
    centered_style.align_content = AlignContent.center;
    centered_style.size = .{ .width = Dimension.auto, .height = Dimension.length(50.0) };
    centered_style.text_align = .legacy_center;
    var narrow_style = leaf_style;
    narrow_style.size = Size(Dimension).fromLengths(20.0, 10.0);
    const centered_leaf = try taffy.newLeaf(narrow_style);
    const centered_abs = try taffy.newLeaf(abs_style);
    const centered = try taffy.newWithChildren(centered_style, &.{ centered_leaf, centered_abs });

    var root_style: Style = .{ .display = .block };
    root_style.size = .{ .width = Dimension.length(200.0), .height = Dimension.auto };
    root_style.padding = Rect(LengthPercentage).length(4.0);
    root_style.overflow = .{ .x = .visible, .y = .scroll };
    root_style.scrollbar_width = 6.0;
    const float_left = try taffy.newLeaf(float_left_style);
    const float_right = try taffy.newLeaf(float_right_style);
    const root_abs = try taffy.newLeaf(abs_style);
    const root = try taffy.newWithChildren(root_style, &.{ float_left, float_right, root_abs, para, flow_root, centered });

    try taffy.computeLayout(root, .{ .width = .{ .definite = 300.0 }, .height = .{ .definite = 300.0 } });
    // Floats are placed at the root's content edges (the scrollbar gutter is on the right)
    try testing.expectEqual(Point(f32){ .x = 4.0, .y = 4.0 }, taffy.layout(float_left).location);
    try testing.expectEqual(Point(f32){ .x = 150.0, .y = 4.0 }, taffy.layout(float_right).location);
    try testing.expectEqual(Size(f32){ .width = 7.0, .height = 4.0 }, taffy.layout(flow_abs).size);
    try testing.expectEqual(Size(f32){ .width = 20.0, .height = 10.0 }, taffy.layout(centered_leaf).size);
    try testing.expectEqual(Size(f32).zero, taffy.layout(hidden_leaf).size);
    // The flow-root is the containing block of its own absolutely positioned child; the other
    // out-of-flow boxes are laid out by the root
    try testing.expectEqualSlices(NodeId, &.{flow_abs}, taffy.hoistedChildren(flow_root));
    try testing.expectEqualSlices(NodeId, &.{ root_abs, nested_float_abs, nested_float_fixed, para_abs, centered_abs }, taffy.hoistedChildren(root));

    // Relayouts after a style change exercise the cache and the hoisted-list bookkeeping
    taffy.setStyle(para_text, narrow_style);
    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try taffy.computeLayout(root, Size(AvailableSpace).min_content);
    try testing.expectEqualSlices(NodeId, &.{flow_abs}, taffy.hoistedChildren(flow_root));
}

test "multi-level block trees with floats and absolutely positioned children do not leak" {
    try layoutNestedBlockTree(testing.allocator);
}

test "multi-level block layout frees everything when allocations fail" {
    try testing.checkAllAllocationFailures(testing.allocator, layoutNestedBlockTree, .{});
}

test "adjoining sibling margins collapse" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    var a_style: Style = .{ .display = .block };
    a_style.size = .{ .width = Dimension.auto, .height = Dimension.length(10.0) };
    a_style.margin = .{ .left = .length(0.0), .right = .length(0.0), .top = .length(0.0), .bottom = .length(20.0) };
    var b_style = a_style;
    b_style.margin = .{ .left = .length(0.0), .right = .length(0.0), .top = .length(30.0), .bottom = .length(0.0) };
    const a = try taffy.newLeaf(a_style);
    const b = try taffy.newLeaf(b_style);
    var root_style: Style = .{ .display = .block };
    root_style.size = .{ .width = Dimension.length(100.0), .height = Dimension.auto };
    const root = try taffy.newWithChildren(root_style, &.{ a, b });

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 40.0 }, taffy.layout(b).location);
    try testing.expectEqual(Size(f32){ .width = 100.0, .height = 50.0 }, taffy.layout(root).size);
}

test "legacy text-align centers narrow children" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeaf(.{ .display = .block, .size = Size(Dimension).fromLengths(40.0, 10.0) });
    var root_style: Style = .{ .display = .block, .text_align = .legacy_center };
    root_style.size = .{ .width = Dimension.length(100.0), .height = Dimension.auto };
    const root = try taffy.newWithChildren(root_style, &.{child});

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try testing.expectEqual(Point(f32){ .x = 30.0, .y = 0.0 }, taffy.layout(child).location);
}

test "block context places floats relative to sub-blocks" {
    var bfc = BlockFormattingContext.init(testing.allocator);
    defer bfc.deinit();
    var root_ctx = bfc.rootBlockContext();
    try testing.expect(root_ctx.isBfcRoot());
    root_ctx.setWidth(100.0);
    try testing.expect(!root_ctx.hasFloats());

    const mark = root_ctx.floatMark();
    var sub_ctx = root_ctx.subContext(10.0, FloatInsets.new(5.0, 5.0));
    try testing.expect(!sub_ctx.isBfcRoot());
    const left = try sub_ctx.placeFloatedBox(1, .{ .width = 20.0, .height = 10.0 }, 0.0, .left, .none, true);
    try testing.expectEqual(Point(f32){ .x = 0.0, .y = 0.0 }, left);
    const right = try sub_ctx.placeFloatedBox(2, .{ .width = 30.0, .height = 5.0 }, 0.0, .right, .none, false);
    try testing.expectEqual(Point(f32){ .x = 60.0, .y = 0.0 }, right);
    try testing.expect(sub_ctx.hasAdjoiningFloat(.left));
    try testing.expect(!sub_ctx.hasAdjoiningFloat(.right));
    try testing.expectEqual(@as(f32, 10.0), sub_ctx.floatedContentHeightContribution());
    try testing.expectEqual(@as(?f32, 10.0), sub_ctx.clearedThreshold(.left));
    try testing.expect(sub_ctx.hasActiveFloats(9.0));
    try testing.expect(!sub_ctx.hasActiveFloats(10.0));

    // Positions reported by the root context are relative to the root block
    var placed = root_ctx.floatsPlacedSince(mark);
    const first = placed.next().?;
    try testing.expectEqual(@as(u64, 1), first.id);
    try testing.expectEqual(Point(f32){ .x = 5.0, .y = 10.0 }, first.position);
    const second = placed.next().?;
    try testing.expectEqual(@as(u64, 2), second.id);
    try testing.expectEqual(Point(f32){ .x = 65.0, .y = 10.0 }, second.position);
    try testing.expect(placed.next() == null);

    const slot = sub_ctx.findContentSlot(0.0, 1.0, .none, null);
    try testing.expectEqual(@as(f32, 20.0), slot.x);
    try testing.expectEqual(@as(f32, 40.0), slot.width);
    const bfc_slot = sub_ctx.findBfcSlot(0.0, 0.0, FloatInsets.zero, .ltr, .none, null);
    try testing.expectEqual(@as(f32, 20.0), bfc_slot.x);
    try testing.expectEqual(@as(f32, 40.0), bfc_slot.border_width);

    sub_ctx.commitStrut();
    try testing.expectEqual([2]bool{ true, false }, sub_ctx.topAdjoiningFloats());
    try testing.expect(!sub_ctx.hasAdjoiningFloat(.both));
    try testing.expectEqual(@as(f32, 0.0), computeBlockAlignContentOffset(AlignContent.space_between, 10.0));
    try testing.expectEqual(@as(f32, 5.0), computeBlockAlignContentOffset(AlignContent.center, 10.0));
}
