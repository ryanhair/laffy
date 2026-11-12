//! Shared positioning pass for out-of-flow (`position: absolute` / `position: fixed`) boxes.
//!
//! Layout algorithms do not lay out their out-of-flow children directly (unless they are the
//! child's containing block). Instead they emit `OofCandidate` records, stored per node on the
//! tree (`tree.setOofCandidates`), which bubble up the tree until they reach the box's
//! containing block, which lays the box out using the routine in this module.
//!
//! `tree` arguments implement `LayoutContainingBlock` (see `src/tree/traits.zig`).
const std = @import("std");
const geometry = @import("../geometry.zig");
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style = @import("../style.zig");
const AlignSelf = style.AlignSelf;
const AlignmentSafety = style.AlignmentSafety;
const AvailableSpace = style.AvailableSpace;
const BoxSizing = style.BoxSizing;
const Contain = style.Contain;
const ContainingBlockClaims = style.ContainingBlockClaims;
const Direction = style.Direction;
const LengthPercentageAuto = style.LengthPercentageAuto;
const Overflow = style.Overflow;
const layout = @import("../tree/layout.zig");
const AxisStaticEdge = layout.AxisStaticEdge;
const AxisStaticPosition = layout.AxisStaticPosition;
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidate = layout.OofCandidate;
const Scratch = @import("../util/scratch.zig");
const OofPositioningArea = layout.OofPositioningArea;
const NodeId = @import("../tree/node.zig").NodeId;
const traits = @import("../tree/traits.zig");
const math = @import("../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const resolve = @import("../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../util/sys.zig");
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const computeScrollableOverflowContribution = scrollable_overflow.computeScrollableOverflowContribution;
const finalizeScrollableOverflow = scrollable_overflow.finalizeScrollableOverflow;
const ScrollableOverflowContainer = scrollable_overflow.ScrollableOverflowContainer;
const resolveAbsoluteSizingKeywords = @import("common/sizing_keyword.zig").resolveAbsoluteSizingKeywords;

/// Resolve the final static offset of an out-of-flow box from its static position, given the
/// box's final size and resolved margins.
///
/// In each axis the box's margin box is aligned within the static-position area according to the
/// recorded alignment keyword. When the alignment is `safe` and the margin box overflows the
/// area, the fallback keyword is used instead (the `safe` overflow-position keyword from CSS
/// Box Alignment). The returned offset locates the box's border box and is relative to whatever
/// the static-position areas are relative to (the containing block's border box once a candidate
/// has bubbled to its containing block).
pub fn resolveStaticOffset(
    static_position: Point(AxisStaticPosition),
    final_size: Size(f32),
    resolved_margin: Rect(f32),
) Point(f32) {
    return .{
        .x = resolveStaticOffsetAxis(
            static_position.x,
            final_size.width,
            .{ .start = resolved_margin.left, .end = resolved_margin.right },
        ),
        .y = resolveStaticOffsetAxis(
            static_position.y,
            final_size.height,
            .{ .start = resolved_margin.top, .end = resolved_margin.bottom },
        ),
    };
}

/// Single-axis version of `resolveStaticOffset`
fn resolveStaticOffsetAxis(sp: AxisStaticPosition, size: f32, margin: Line(f32)) f32 {
    const margin_box_size = size + margin.start + margin.end;
    const overflows = sp.@"align".safety == .safe and margin_box_size > sp.area.end - sp.area.start;
    const keyword = if (overflows) sp.@"align".fallback else sp.@"align".keyword;
    return alignInLine(sp.area, margin_box_size, keyword) + margin.start;
}

/// Position a box of `size` within `container` so that it is aligned to the given physical edge
fn alignInLine(container: Line(f32), size: f32, edge: AxisStaticEdge) f32 {
    return switch (edge) {
        .start => container.start,
        .end => container.end - size,
        .center => (container.start + container.end - size) / 2.0,
    };
}

/// The self-alignment of an out-of-flow box in one axis, resolved relative to the writing mode
/// of its containing block (`start` is the logical start edge of the containing block).
const OofAlignment = enum {
    /// `normal` (or `auto`): stretch-fit sizing for non-replaced, non-table boxes; start alignment
    normal,
    /// `stretch`: stretch-fit sizing; start alignment
    stretch,
    /// Aligned to the logical start edge
    start,
    /// Centered
    center,
    /// Aligned to the logical end edge
    end,

    /// Convert an `align-self`/`justify-self` value for an out-of-flow box into a logical
    /// alignment relative to the containing block's writing mode.
    ///
    /// `alignment` must already have had `self-start`/`self-end` resolved against the containing
    /// block's direction (see `AlignSelf.resolveSelfRelative`).
    fn fromResolved(alignment: AlignSelf) OofAlignment {
        // self-start/self-end must be resolved before computing out-of-flow alignment
        std.debug.assert(alignment.keyword != .self_start and alignment.keyword != .self_end);
        return switch (alignment.keyword) {
            .normal => .normal,
            .stretch => .stretch,
            .center => .center,
            .end, .flex_end, .self_end => .end,
            // The fallback alignment of `baseline` is `start`
            .start, .flex_start, .self_start, .baseline => .start,
        };
    }

    /// The physical edge of the containing block the box's margin box is aligned to once its
    /// size has been determined. `normal` and `stretch` behave as `start`.
    fn physicalEdge(self: OofAlignment, reversed: bool) AxisStaticEdge {
        return switch (self) {
            .center => .center,
            .end => if (reversed) .start else .end,
            .normal, .stretch, .start => if (reversed) .end else .start,
        };
    }
};

/// The inputs to the absolute positioning layout model
/// (<https://www.w3.org/TR/css-position-3/#abspos-layout>) in a single axis. All coordinates
/// are physical (left-to-right / top-to-bottom) and relative to the start of the containing
/// block's inset-resolution area.
const OofAxis = struct {
    /// The size of the containing block in this axis
    cb_size: f32,
    /// The box's resolved inset properties (`null` = `auto`)
    inset: Line(?f32),
    /// The box's resolved margins (`null` = `auto`)
    margin: Line(?f32),
    /// The box's static position (relative to the containing block's inset-resolution area)
    static_position: AxisStaticPosition,
    /// The box's self-alignment in this axis
    alignment: OofAlignment,
    /// The overflow-position modifier of the box's self-alignment in this axis
    safety: AlignmentSafety,
    /// Whether this is the inline axis of the containing block
    is_inline: bool,
    /// Whether the logical start edge of the containing block is the physical end edge of this
    /// axis (the inline axis of an RTL containing block)
    reversed: bool,
    /// Whether the containing block is a scroll container which scrolls in this axis
    is_scroll_axis: bool,

    /// The physical edge corresponding to the logical start edge of the containing block
    fn startEdge(self: *const OofAxis) AxisStaticEdge {
        return if (self.reversed) .end else .start;
    }

    /// The physical edge corresponding to the logical end edge of the containing block
    fn endEdge(self: *const OofAxis) AxisStaticEdge {
        return if (self.reversed) .start else .end;
    }

    /// The inset-modified containing block (IMCB) in this axis
    /// <https://www.w3.org/TR/css-position-3/#resolving-insets>
    fn insetModifiedContainingBlock(self: *const OofAxis) Line(f32) {
        var imcb: Line(f32) = undefined;
        var weaker_edge: AxisStaticEdge = undefined;
        if (self.inset.start) |start| {
            if (self.inset.end) |end| {
                imcb = .{ .start = start, .end = self.cb_size - end };
                weaker_edge = self.endEdge();
            } else {
                // A lone auto inset resolves to zero, and is the weaker inset
                imcb = .{ .start = start, .end = self.cb_size };
                weaker_edge = .end;
            }
        } else if (self.inset.end) |end| {
            imcb = .{ .start = 0.0, .end = self.cb_size - end };
            weaker_edge = .start;
        } else {
            // Both insets are auto: resolve them from the static position rectangle and the
            // alignment within it
            const sp = self.static_position;
            imcb = switch (sp.@"align".keyword) {
                .start => .{ .start = sp.area.start, .end = self.cb_size },
                .end => .{ .start = 0.0, .end = sp.area.end },
                .center => blk: {
                    // Center the IMCB on the static position rectangle's center, bounded by
                    // the nearer edge of the containing block
                    const center = (sp.area.start + sp.area.end) / 2.0;
                    const start_distance = center;
                    const end_distance = self.cb_size - center;
                    if (@abs(start_distance) <= @abs(end_distance)) {
                        break :blk .{ .start = 0.0, .end = 2.0 * start_distance };
                    } else {
                        break :blk .{ .start = self.cb_size - 2.0 * end_distance, .end = self.cb_size };
                    }
                },
            };
            weaker_edge = self.endEdge();
        }

        // Overconstrained insets: the weaker inset is reduced to bring the IMCB size up to zero
        // <https://www.w3.org/TR/css-position-3/#resolving-insets>
        if (imcb.end < imcb.start) {
            switch (weaker_edge) {
                .start => imcb.start = imcb.end,
                else => imcb.end = imcb.start,
            }
        }
        return imcb;
    }

    /// The size of the IMCB in this axis: the space available to the box's margin box
    fn insetModifiedContainingBlockSize(self: *const OofAxis) f32 {
        const imcb = self.insetModifiedContainingBlock();
        return imcb.end - imcb.start;
    }

    /// The stretch-fit size of the box's border box: the IMCB minus the non-auto margins (auto
    /// margins are treated as zero) <https://www.w3.org/TR/css-position-3/#abspos-auto-size>
    fn stretchFitSize(self: *const OofAxis) f32 {
        const non_auto_margin_sum = (self.margin.start orelse 0.0) + (self.margin.end orelse 0.0);
        return @max(self.insetModifiedContainingBlockSize() - non_auto_margin_sum, 0.0);
    }

    /// Whether an `auto` size in this axis is the stretch-fit size (rather than fit-content)
    /// <https://www.w3.org/TR/css-position-3/#abspos-auto-size>
    fn isStretchSized(self: *const OofAxis, is_replaced: bool, is_table: bool) bool {
        const no_auto_inset = self.inset.start != null and self.inset.end != null;
        return no_auto_inset and switch (self.alignment) {
            .stretch => true,
            .normal => !is_replaced and !is_table,
            else => false,
        };
    }

    /// Resolve the box's auto margins given its final size
    /// <https://www.w3.org/TR/css-position-3/#abspos-margins>
    fn resolveMargins(self: *const OofAxis, size: f32) Line(f32) {
        const both_insets = self.inset.start != null and self.inset.end != null;
        const imcb = self.insetModifiedContainingBlock();
        const free_space = imcb.end - imcb.start - size;
        if (self.margin.start != null and self.margin.end != null) {
            return .{ .start = self.margin.start.?, .end = self.margin.end.? };
        }
        // If either inset is auto then auto margins resolve to zero
        if (!both_insets) {
            return .{ .start = self.margin.start orelse 0.0, .end = self.margin.end orelse 0.0 };
        }
        if (self.margin.start) |start| {
            return .{ .start = start, .end = free_space - start };
        }
        if (self.margin.end) |end| {
            return .{ .start = free_space - end, .end = end };
        }
        // In the inline axis, negative free space is absorbed entirely by the end margin
        if (free_space < 0.0 and self.is_inline) {
            if (self.reversed) {
                return .{ .start = free_space, .end = 0.0 };
            } else {
                return .{ .start = 0.0, .end = free_space };
            }
        } else {
            return .{ .start = free_space / 2.0, .end = free_space / 2.0 };
        }
    }

    /// Compute the physical start of the box's border box given its final size and margins
    /// <https://www.w3.org/TR/css-position-3/#abspos-alignment>
    fn position(self: *const OofAxis, size: f32, margin: Line(f32)) f32 {
        const imcb = self.insetModifiedContainingBlock();
        const has_start = self.inset.start != null;
        const has_end = self.inset.end != null;
        if (!has_start and !has_end) {
            // Both insets are auto: static alignment, with safe overflow relative to the IMCB
            const sp = self.static_position;
            const margin_box_size = size + margin.start + margin.end;
            const offset = if (sp.@"align".safety == .safe and margin_box_size > imcb.end - imcb.start)
                alignInLine(imcb, margin_box_size, self.startEdge())
            else
                alignInLine(sp.area, margin_box_size, sp.@"align".keyword);
            return offset + margin.start;
        }
        // One auto inset: the margin box is aligned to the edge of the stronger inset
        if (has_start and !has_end) return imcb.start + margin.start;
        if (!has_start and has_end) return imcb.end - size - margin.end;

        // Auto margins have already absorbed all of the free space
        if (self.margin.start == null or self.margin.end == null) {
            return imcb.start + margin.start;
        }

        const margin_box_size = size + margin.start + margin.end;
        const imcb_size = imcb.end - imcb.start;
        const edge = self.alignment.physicalEdge(self.reversed);
        const margin_box_start = switch (self.safety) {
            .unsafe => alignInLine(imcb, margin_box_size, edge),
            .safe => blk: {
                const safe_edge = if (margin_box_size > imcb_size) self.startEdge() else edge;
                break :blk alignInLine(imcb, margin_box_size, safe_edge);
            },
            // Default overflow alignment for absolutely positioned boxes:
            // <https://www.w3.org/TR/css-align-3/#auto-safety-position>
            .default => blk: {
                if (margin_box_size <= imcb_size or self.alignment == .normal) {
                    // 1. Fits within the IMCB: align as specified
                    break :blk alignInLine(imcb, margin_box_size, edge);
                } else {
                    // The overflow limit rect is the bounding rect of the IMCB and the
                    // containing block, extended to infinity in the scrollable direction
                    // of a scroll container
                    var limit: Line(f32) = .{ .start = @min(imcb.start, 0.0), .end = @max(imcb.end, self.cb_size) };
                    if (self.is_scroll_axis) {
                        if (self.reversed) {
                            limit.start = -std.math.inf(f32);
                        } else {
                            limit.end = std.math.inf(f32);
                        }
                    }
                    if (margin_box_size <= limit.end - limit.start) {
                        // 2. Fits within the overflow limit rect: cover the IMCB and align
                        // as specified as far as possible without overflowing the limit
                        const start = alignInLine(imcb, margin_box_size, edge);
                        break :blk @max(@min(start, limit.end - margin_box_size), limit.start);
                    } else {
                        // 3. Start-align within the overflow limit rect
                        break :blk alignInLine(limit, margin_box_size, self.startEdge());
                    }
                }
            },
        };
        return margin_box_start + margin.start;
    }
};

/// Run the out-of-flow positioning pass for `node_id` after its layout algorithm has produced
/// `output`: lay out the node's stored out-of-flow candidates (`tree.oofCandidates`) for which
/// the node is the containing block, record them as the node's hoisted children, and replace the
/// stored list with the unclaimed remainder (which bubble further up the tree).
/// The scrollable overflow contributed by the claimed boxes is merged into
/// `output.scrollable_overflow_rect`.
///
/// This should be called once per `RunMode.perform_layout` container layout, after the layout
/// algorithm (block/flexbox/grid) has run, and *inside* any layout caching wrapper (such as
/// `computeCachedLayout`) so that cache hits do not re-run the pass. It is a no-op when
/// `output.oof_positioning_area` is `null` (leaf and size-only outputs).
///
/// Which candidates the node claims is determined by the node's style via
/// `isContainingBlock()`. `position: fixed` boxes unclaimed by every ancestor are claimed by the
/// final root positioning pass in `computeRootLayout`.
pub fn computeOofLayout(tree: anytype, node_id: NodeId, output: *LayoutOutput) LayoutError!void {
    const area = output.oof_positioning_area orelse return;
    const candidates = tree.oofCandidates(node_id);
    if (candidates.len == 0) {
        tree.clearHoistedChildren(node_id);
        return;
    }
    const frame = Scratch.Frame.begin(tree);
    defer frame.end();

    const container_style = tree.getCoreContainerStyle(node_id);
    const direction = container_style.getDirection();
    const claims = container_style.isContainingBlock();

    const reversed = output.scrollable_overflow_rect.isReversed();
    const result = try computeOofLayoutForAreaWithOrigin(
        tree,
        frame.allocator(),
        node_id,
        candidates,
        area,
        direction,
        claims,
        reversed,
    );
    // Always record the hoisted child list (even when empty) so that lists recorded by previous
    // layout runs do not persist
    tree.clearHoistedChildren(node_id);
    try tree.addHoistedChildren(node_id, result.hoisted.items);
    try tree.setOofCandidates(node_id, result.unclaimed.items);
    {
        const final_reversed = output.scrollable_overflow_rect.isReversed();
        const overflow = tree.getCoreContainerStyle(node_id).getOverflow();
        output.scrollable_overflow_rect = finalizeScrollableOverflow(
            output.scrollable_overflow_rect.rect().@"union"(result.scrollable_overflow_rect),
            area.size,
            final_reversed,
            overflow.x.isScrollContainer() or overflow.y.isScrollContainer(),
        );
    }
}

/// The result of laying out out-of-flow candidates against an explicit positioning area.
///
/// When returned by `computeOofLayoutForArea`, both lists are allocated with the tree's
/// allocator and owned by the caller (see `deinit`).
pub const OofLayoutResult = struct {
    /// Candidates claimed and laid out by this pass, in document order.
    hoisted: std.ArrayList(NodeId),
    /// Candidates not claimed by this pass, which must continue bubbling.
    unclaimed: std.ArrayList(OofCandidate),
    /// Scrollable overflow contributed by the claimed candidates, relative to the positioning
    /// area's inner top-left edge, in physical coordinates (RTL is not mirrored).
    scrollable_overflow_rect: Rect(f32),

    /// Free both lists
    pub fn deinit(self: *OofLayoutResult, gpa: std.mem.Allocator) void {
        self.hoisted.deinit(gpa);
        self.unclaimed.deinit(gpa);
    }
};

/// Lay out out-of-flow candidates against an explicit positioning area.
///
/// Unlike `computeOofLayout`, this function does not update the geometry owner's hoisted
/// children or merge overflow into a `LayoutOutput`. This is useful when the CSS containing
/// block does not have its own layout node and another node owns the resulting geometry.
///
/// `geometry_owner` supplies the layout tree operations, detailed layout information, and
/// scroll-container state used by the positioning pass. `direction` and `claims` describe the
/// actual CSS containing block.
pub fn computeOofLayoutForArea(
    tree: anytype,
    geometry_owner: NodeId,
    candidates: []const OofCandidate,
    area: OofPositioningArea,
    direction: Direction,
    claims: ContainingBlockClaims,
) LayoutError!OofLayoutResult {
    return computeOofLayoutForAreaWithOrigin(
        tree,
        tree.allocator(),
        geometry_owner,
        candidates,
        area,
        direction,
        claims,
        .{ .x = direction.isRtl(), .y = false },
    );
}

/// Run the positioning pass using the containing block's algorithm-specific physical origins.
///
/// The lists of the result are allocated with `gpa`.
fn computeOofLayoutForAreaWithOrigin(
    tree: anytype,
    gpa: std.mem.Allocator,
    geometry_owner: NodeId,
    candidates: []const OofCandidate,
    area: OofPositioningArea,
    direction: Direction,
    claims: ContainingBlockClaims,
    reversed: Point(bool),
) LayoutError!OofLayoutResult {
    const overflow = tree.getCoreContainerStyle(geometry_owner).getOverflow();

    var hoisted: std.ArrayList(NodeId) = .empty;
    errdefer hoisted.deinit(gpa);
    var unclaimed: std.ArrayList(OofCandidate) = .empty;
    errdefer unclaimed.deinit(gpa);
    const raw_scrollable_overflow_rect = try performOofLayout(
        tree,
        gpa,
        geometry_owner,
        candidates,
        area.size,
        area.offset,
        direction,
        claims,
        overflow,
        reversed,
        &hoisted,
        &unclaimed,
    );

    const scrollable_overflow_rect = finalizeScrollableOverflow(
        raw_scrollable_overflow_rect,
        area.size,
        reversed,
        overflow.x.isScrollContainer() or overflow.y.isScrollContainer(),
    ).rect();
    return .{ .hoisted = hoisted, .unclaimed = unclaimed, .scrollable_overflow_rect = scrollable_overflow_rect };
}

/// The result of laying out a single out-of-flow box with `layoutOofBox`.
pub const OofBoxLayout = struct {
    /// The box's final layout (its `location` is relative to the containing block's border box)
    layout: Layout,
    /// The box's `overflow` style
    overflow: Point(Overflow),
    /// The box's `contain` style
    contain: Contain,
};

/// A `before_layout` callback for `layoutOofBox` that does nothing
pub const NoBeforeLayout = struct {
    pub fn call(_: NoBeforeLayout, tree: anytype, inputs: *const LayoutInput) LayoutError!void {
        _ = tree;
        _ = inputs;
    }
};

/// Size and position a single out-of-flow box against its containing block, and store its layout.
///
/// - `area_size`/`area_offset` describe the inset-resolution area of the containing block
///   (border box minus borders and scrollbar gutters), relative to the containing block's border box.
/// - `container_overflow` is the `overflow` style of the containing block, which determines
///   whether overflowing boxes may be aligned into its scrollable overflow area.
/// - `grid_owner` is the node whose detailed layout info is consulted for grid placement: if it is
///   a grid container, the box is positioned relative to the grid area determined by its
///   grid-placement properties rather than the passed area.
/// - `before_layout` is called as `before_layout.call(tree, &inputs) LayoutError!void` with the
///   inputs of the final layout pass just before it runs, which allows the caller to inspect the
///   layout cache for the box (`NoBeforeLayout{}` does nothing).
pub fn layoutOofBox(
    tree: anytype,
    candidate: OofCandidate,
    passed_area_size: Size(f32),
    passed_area_offset: Point(f32),
    direction: Direction,
    container_overflow: Point(Overflow),
    grid_owner: ?NodeId,
    before_layout: anytype,
) LayoutError!OofBoxLayout {
    const child_style = tree.getOofItemStyle(candidate.node);

    // If the current node is a grid container then the box is positioned relative to the
    // grid area determined by its grid-placement properties (which falls back to the passed
    // area for `auto` placement)
    var area_size = passed_area_size;
    var area_offset = passed_area_offset;
    if (grid_owner) |owner| {
        switch (tree.getDetailedLayoutInfo(owner).*) {
            .grid => |grid_info| {
                const area_rect: Rect(f32) = .{
                    .left = area_offset.x,
                    .right = area_offset.x + area_size.width,
                    .top = area_offset.y,
                    .bottom = area_offset.y + area_size.height,
                };
                const grid_area = grid_info.resolveAbsoluteGridArea(
                    child_style.getGridRow(),
                    child_style.getGridColumn(),
                    direction,
                    area_rect,
                );
                area_size = .{ .width = grid_area.right - grid_area.left, .height = grid_area.bottom - grid_area.top };
                area_offset = .{ .x = grid_area.left, .y = grid_area.top };
            },
            .none => {},
        }
    }
    const area_width = area_size.width;
    const area_height = area_size.height;
    const area_size_options: Size(?f32) = .{ .width = area_width, .height = area_height };

    const aspect_ratio = child_style.getAspectRatio();
    const margin_style = child_style.getMargin();
    const margin: Rect(?f32) = .{
        .left = margin_style.left.resolveToOption(area_width, tree),
        .right = margin_style.right.resolveToOption(area_width, tree),
        .top = margin_style.top.resolveToOption(area_width, tree),
        .bottom = margin_style.bottom.resolveToOption(area_width, tree),
    };
    const padding = resolveOrZero(child_style.getPadding(), @as(?f32, area_width), tree);
    const border = resolveOrZero(child_style.getBorder(), @as(?f32, area_width), tree);
    const padding_border_sum = padding.add(border).sumAxes();
    const box_sizing_adjustment = if (child_style.getBoxSizing() == .content_box) padding_border_sum else Size(f32).zero;

    // Resolve inset
    const inset_style = child_style.getInset();
    const left = maybeResolve(inset_style.left, area_width, tree);
    const right = maybeResolve(inset_style.right, area_width, tree);
    const top = maybeResolve(inset_style.top, area_height, tree);
    const bottom = maybeResolve(inset_style.bottom, area_height, tree);

    // Compute known dimensions from min/max/inherent size styles
    const size_style = child_style.getSize();
    const style_size = maybeAdd(maybeResolve(size_style, area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    var min_size = maybeMax(
        maybeAdd(maybeResolve(child_style.getMinSize(), area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment)
            .@"or"(.{ .width = padding_border_sum.width, .height = padding_border_sum.height }),
        padding_border_sum,
    );
    const max_size = maybeAdd(maybeResolve(child_style.getMaxSize(), area_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    var known_dimensions = maybeClamp(style_size, min_size, max_size);

    const is_replaced = child_style.isReplaced();
    const is_table = child_style.isTable();
    const item_direction = child_style.getDirection();
    // laffy only supports the `horizontal-tb` writing mode, so only the inline axis can be reversed.
    // `auto` (`null`) behaves as `normal` for absolutely positioned boxes: it does not defer to the
    // `*-items` properties of the containing block.
    const justify_self = (child_style.getJustifySelf() orelse AlignSelf.normal).resolveSelfRelative(item_direction, direction, true);
    const align_self = (child_style.getAlignSelf() orelse AlignSelf.normal).resolveSelfRelative(item_direction, direction, false);
    const overflow = child_style.getOverflow();
    const scrollbar_width = child_style.getScrollbarWidth();
    const contain = child_style.getContain();

    // Static positions are relative to the containing block's border box: make them relative to
    // the inset-resolution area
    const static_position: Point(AxisStaticPosition) = .{
        .x = .{
            .area = .{
                .start = candidate.static_position.x.area.start - area_offset.x,
                .end = candidate.static_position.x.area.end - area_offset.x,
            },
            .@"align" = candidate.static_position.x.@"align",
        },
        .y = .{
            .area = .{
                .start = candidate.static_position.y.area.start - area_offset.y,
                .end = candidate.static_position.y.area.end - area_offset.y,
            },
            .@"align" = candidate.static_position.y.@"align",
        },
    };

    const horizontal: OofAxis = .{
        .cb_size = area_width,
        .inset = .{ .start = left, .end = right },
        .margin = .{ .start = margin.left, .end = margin.right },
        .static_position = static_position.x,
        .alignment = OofAlignment.fromResolved(justify_self),
        .safety = justify_self.safety,
        .is_inline = true,
        .reversed = direction.isRtl(),
        .is_scroll_axis = container_overflow.x.isScrollContainer(),
    };
    const vertical: OofAxis = .{
        .cb_size = area_height,
        .inset = .{ .start = top, .end = bottom },
        .margin = .{ .start = margin.top, .end = margin.bottom },
        .static_position = static_position.y,
        .alignment = OofAlignment.fromResolved(align_self),
        .safety = align_self.safety,
        .is_inline = false,
        .reversed = false,
        .is_scroll_axis = container_overflow.y.isScrollContainer(),
    };
    const stretch_fit_size: Size(f32) = .{ .width = horizontal.stretchFitSize(), .height = vertical.stretchFitSize() };
    // The space available to the box's border box is its stretch-fit size (the IMCB minus its
    // non-auto margins). The available space for a table never exceeds that of the containing
    // block (minus the margins) <https://www.w3.org/TR/css-tables-3/#abspos>
    var available_size = stretch_fit_size;
    if (is_table) {
        const non_auto_margin: Rect(f32) = .{
            .left = margin.left orelse 0.0,
            .right = margin.right orelse 0.0,
            .top = margin.top orelse 0.0,
            .bottom = margin.bottom orelse 0.0,
        };
        available_size = available_size.min(.{
            .width = @max(area_width - non_auto_margin.horizontalAxisSum(), 0.0),
            .height = @max(area_height - non_auto_margin.verticalAxisSum(), 0.0),
        });
    }
    const clamped_available_size = maybeClamp(available_size, min_size, max_size);
    const available_space: Size(AvailableSpace) = .{
        .width = .{ .definite = clamped_available_size.width },
        .height = .{ .definite = clamped_available_size.height },
    };

    // Resolve any sizing keywords (min-content, max-content, fit-content, fit-content(...),
    // stretch) in the size styles. An explicitly sized axis takes precedence over the
    // automatic size below.
    if (size_style.width.isSizingKeyword() or size_style.height.isSizingKeyword()) {
        try resolveAbsoluteSizingKeywords(
            tree,
            candidate.node,
            &known_dimensions,
            size_style,
            area_size,
            .{ .left = left, .right = right, .top = top, .bottom = bottom },
            margin,
            .content_size,
        );
        known_dimensions = maybeClamp(known_dimensions.maybeApplyAspectRatio(aspect_ratio), min_size, max_size);
    }

    // Resolve automatic sizes <https://www.w3.org/TR/css-position-3/#abspos-auto-size>
    //
    // An auto size is the stretch-fit size (the IMCB minus margins) if the self-alignment in
    // that axis is `stretch` (or `normal` for a non-replaced, non-table box) and neither inset is
    // auto. Otherwise it is the fit-content size, which is measured below. Stretch-fit sizes are
    // resolved first so that a size in the other axis can be transferred through the aspect ratio.
    // The block axis is the ratio-dependent axis, so a stretched inline size is transferred
    // through the aspect ratio rather than also stretching the block size. An explicit
    // `stretch` in both axes stretches both and ignores the aspect ratio.
    const stretch_width = known_dimensions.width == null and horizontal.isStretchSized(is_replaced, is_table);
    const stretch_height = known_dimensions.height == null and vertical.isStretchSized(is_replaced, is_table);
    const both_explicit_stretch = horizontal.alignment == .stretch and vertical.alignment == .stretch;
    const stretch_aspect_ratio: ?f32 = if (stretch_width and stretch_height and both_explicit_stretch) null else aspect_ratio;
    if (stretch_width) {
        if (is_table) {
            // A table cannot be stretched smaller than its content: stretch-fit is a minimum
            min_size.width = @max(min_size.width orelse 0.0, stretch_fit_size.width);
        } else {
            known_dimensions.width = stretch_fit_size.width;
            known_dimensions = maybeClamp(known_dimensions.maybeApplyAspectRatio(stretch_aspect_ratio), min_size, max_size);
        }
    }
    if (known_dimensions.height == null and stretch_height) {
        if (is_table) {
            min_size.height = @max(min_size.height orelse 0.0, stretch_fit_size.height);
        } else {
            known_dimensions.height = stretch_fit_size.height;
            known_dimensions = maybeClamp(known_dimensions.maybeApplyAspectRatio(stretch_aspect_ratio), min_size, max_size);
        }
    }

    const unclamped_final_size: Size(f32) = blk: {
        if (known_dimensions.width) |width| {
            if (known_dimensions.height) |height| break :blk .{ .width = width, .height = height };
        }
        const measured_size = try traits.measureChildSizeBoth(
            tree,
            candidate.node,
            known_dimensions,
            area_size_options,
            available_space,
            .content_size,
            Line(bool).false,
        );
        break :blk known_dimensions.unwrapOr(measured_size);
    };
    const final_size = maybeClamp(unclamped_final_size, min_size, max_size);

    const layout_input: LayoutInput = .{
        .known_dimensions = .{ .width = final_size.width, .height = final_size.height },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = area_size_options,
        .available_space = available_space,
        .sizing_mode = .content_size,
        .axis = .both,
        .run_mode = .perform_layout,
        .vertical_margins_are_collapsible = Line(bool).false,
    };
    try before_layout.call(tree, &layout_input);
    const layout_output = try tree.computeChildLayout(candidate.node, layout_input);

    // Resolve auto margins <https://www.w3.org/TR/css-position-3/#abspos-margins>
    const horizontal_margin = horizontal.resolveMargins(final_size.width);
    const vertical_margin = vertical.resolveMargins(final_size.height);
    const resolved_margin: Rect(f32) = .{
        .left = horizontal_margin.start,
        .right = horizontal_margin.end,
        .top = vertical_margin.start,
        .bottom = vertical_margin.end,
    };

    // Align the margin box within the IMCB <https://www.w3.org/TR/css-position-3/#abspos-alignment>
    const location: Point(f32) = .{
        .x = horizontal.position(final_size.width, horizontal_margin) + area_offset.x,
        .y = vertical.position(final_size.height, vertical_margin) + area_offset.y,
    };

    // Note: axis intentionally switched here as scrollbars take up space in the opposite axis
    // to the axis in which scrolling is enabled.
    const scrollbar_size: Size(f32) = .{
        .width = if (overflow.y == .scroll) scrollbar_width else 0.0,
        .height = if (overflow.x == .scroll) scrollbar_width else 0.0,
    };

    const box_layout: Layout = .{
        .order = candidate.order,
        .size = final_size,
        .scrollable_overflow_rect = layout_output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .location = location,
        .padding = padding,
        .border = border,
        .margin = resolved_margin,
    };
    tree.setUnroundedLayout(candidate.node, &box_layout);

    return .{
        .layout = box_layout,
        .overflow = overflow,
        .contain = contain,
    };
}

/// Perform final layout on the out-of-flow candidates for which the current node is the
/// containing block, and collect the remainder into `unclaimed` for further bubbling.
///
/// - `node_id` is the current node. If its detailed layout info (as returned by
///   `getDetailedLayoutInfo`) indicates that it is a grid container, each claimed box is
///   positioned relative to the grid area determined by its grid-placement properties rather
///   than the passed inset-resolution area.
/// - `candidates` is the merged, document-ordered list of candidates held by the current node
///   (direct out-of-flow children plus candidates bubbled from in-flow children). Anchors must be
///   relative to the current node's border box.
/// - `area_size`/`area_offset` describe the inset-resolution area of the current node
///   (border box minus borders and scrollbar gutters).
/// - `claims` describes which out-of-flow positions the current node acts as a containing block
///   for (see `isContainingBlock()`). The final root positioning pass claims all.
/// - `container_overflow` is the `overflow` style of the containing block.
///
/// Laying out a claimed box may surface further candidates from within its subtree (e.g. a
/// `position: fixed` descendant of a `position: absolute` box). These are re-swept: claimed ones
/// are appended to the work list, unclaimed ones are added to `unclaimed`.
///
/// The ids of claimed boxes are appended to `hoisted` in order. Both lists, and the work list,
/// are allocated with `gpa`. Returns the scrollable overflow contribution of the claimed boxes.
pub fn performOofLayout(
    tree: anytype,
    gpa: std.mem.Allocator,
    node_id: NodeId,
    candidates: []const OofCandidate,
    area_size: Size(f32),
    area_offset: Point(f32),
    direction: Direction,
    claims: ContainingBlockClaims,
    container_overflow: Point(Overflow),
    reversed: Point(bool),
    hoisted: *std.ArrayList(NodeId),
    unclaimed: *std.ArrayList(OofCandidate),
) LayoutError!Rect(f32) {
    var absolute_overflow_rect = Rect(f32).zero;
    if (direction.isRtl()) {
        var rtl_rect = Rect(f32).zero;
        rtl_rect.right = @max(area_size.width, 0.0);
        absolute_overflow_rect = absolute_overflow_rect.@"union"(rtl_rect);
    }

    if (candidates.len == 0) {
        return absolute_overflow_rect;
    }

    const is_scroll_container = container_overflow.x.isScrollContainer() or container_overflow.y.isScrollContainer();
    const overflow_container: ScrollableOverflowContainer = .{
        .parent_is_scroll_container = is_scroll_container,
        .parent_size = area_size,
        .reversed = reversed,
        .padding = Rect(f32).zero,
    };

    // Split the candidate list into an initial work list of claimed candidates and the unclaimed
    // remainder. Further claimed candidates surfaced while laying out a claimed box are appended
    // to the work list (Blink-style re-sweep).
    var worklist: std.ArrayList(OofCandidate) = .empty;
    defer worklist.deinit(gpa);
    for (candidates) |candidate| {
        if (claims.forPosition(candidate.position)) {
            try worklist.append(gpa, candidate);
        } else {
            try unclaimed.append(gpa, candidate);
        }
    }

    var index: usize = 0;
    while (index < worklist.items.len) {
        const candidate = worklist.items[index];
        index += 1;
        try hoisted.append(gpa, candidate.node);

        const box = try layoutOofBox(
            tree,
            candidate,
            area_size,
            area_offset,
            direction,
            container_overflow,
            node_id,
            NoBeforeLayout{},
        );
        const location = box.layout.location;
        const final_size = box.layout.size;

        // Re-sweep any candidates surfaced from within the box's subtree, translating their
        // anchors so they are relative to this node's border box
        // (the surfaced candidates are those now stored for the box's node, with anchors relative
        // to the box's own border box)
        for (tree.oofCandidates(candidate.node)) |stored| {
            var surfaced_candidate = stored;
            surfaced_candidate.static_position.x.area.start += location.x;
            surfaced_candidate.static_position.x.area.end += location.x;
            surfaced_candidate.static_position.y.area.start += location.y;
            surfaced_candidate.static_position.y.area.end += location.y;
            if (claims.forPosition(surfaced_candidate.position)) {
                try worklist.append(gpa, surfaced_candidate);
            } else {
                try unclaimed.append(gpa, surfaced_candidate);
            }
        }

        {
            const relative_location: Point(f32) = .{ .x = location.x - area_offset.x, .y = location.y - area_offset.y };
            absolute_overflow_rect = absolute_overflow_rect.@"union"(computeScrollableOverflowContribution(
                relative_location,
                final_size,
                box.layout.scrollable_overflow_rect.rect(),
                box.layout.border,
                box.overflow,
                box.contain,
                &overflow_container,
                Rect(f32).zero,
            ));
        }
    }

    return absolute_overflow_rect;
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const AxisStaticAlign = layout.AxisStaticAlign;

fn makeSp(area: Line(f32), keyword: AxisStaticEdge, safety: AlignmentSafety, fallback: AxisStaticEdge) AxisStaticPosition {
    return .{ .area = area, .@"align" = AxisStaticAlign{ .keyword = keyword, .safety = safety, .fallback = fallback } };
}

fn resolveX(sp_x: AxisStaticPosition, width: f32, margin: Rect(f32)) f32 {
    const pos: Point(AxisStaticPosition) = .{ .x = sp_x, .y = AxisStaticPosition.fromEdge(0.0, .start) };
    return resolveStaticOffset(pos, .{ .width = width, .height = 10.0 }, margin).x;
}

const test_area: Line(f32) = .{ .start = 10.0, .end = 110.0 };
const no_margin: Rect(f32) = .{ .left = 0.0, .right = 0.0, .top = 0.0, .bottom = 0.0 };
const test_margin: Rect(f32) = .{ .left = 5.0, .right = 15.0, .top = 0.0, .bottom = 0.0 };

test "start alignment" {
    const sp_x = makeSp(test_area, .start, .unsafe, .start);
    try testing.expectEqual(@as(f32, 10.0), resolveX(sp_x, 20.0, no_margin));
    try testing.expectEqual(@as(f32, 15.0), resolveX(sp_x, 20.0, test_margin));
}

test "end alignment" {
    const sp_x = makeSp(test_area, .end, .unsafe, .end);
    try testing.expectEqual(@as(f32, 90.0), resolveX(sp_x, 20.0, no_margin));
    try testing.expectEqual(@as(f32, 75.0), resolveX(sp_x, 20.0, test_margin));
}

test "center alignment" {
    const sp_x = makeSp(test_area, .center, .unsafe, .center);
    try testing.expectEqual(@as(f32, 50.0), resolveX(sp_x, 20.0, no_margin));
    // Center offsets by half the margin difference
    try testing.expectEqual(@as(f32, 45.0), resolveX(sp_x, 20.0, test_margin));
}

test "safe alignment falls back only on overflow" {
    const sp_x = makeSp(test_area, .end, .safe, .start);
    // Fits: aligned to the end
    try testing.expectEqual(@as(f32, 90.0), resolveX(sp_x, 20.0, no_margin));
    // Margin box exactly fills the area: no fallback
    try testing.expectEqual(@as(f32, 10.0), resolveX(sp_x, 100.0, no_margin));
    // Margin box overflows the area: falls back to start
    try testing.expectEqual(@as(f32, 10.0), resolveX(sp_x, 120.0, no_margin));
    try testing.expectEqual(@as(f32, 15.0), resolveX(sp_x, 90.0, test_margin));
}

test "unsafe alignment never falls back" {
    const sp_x = makeSp(test_area, .end, .unsafe, .start);
    try testing.expectEqual(@as(f32, -10.0), resolveX(sp_x, 120.0, no_margin));
}

test "degenerate area" {
    // A zero-extent area (static positions emitted by block layout) behaves as an anchor point
    const anchor = AxisStaticPosition.fromEdge(40.0, .start);
    try testing.expectEqual(@as(f32, 40.0), resolveX(anchor, 20.0, no_margin));
    const anchor_end = AxisStaticPosition.fromEdge(40.0, .end);
    try testing.expectEqual(@as(f32, 20.0), resolveX(anchor_end, 20.0, no_margin));
}

fn testAxis() OofAxis {
    return .{
        .cb_size = 100.0,
        .inset = .{ .start = null, .end = null },
        .margin = .{ .start = 0.0, .end = 0.0 },
        .static_position = AxisStaticPosition.fromEdge(10.0, .start),
        .alignment = .normal,
        .safety = .default,
        .is_inline = true,
        .reversed = false,
        .is_scroll_axis = false,
    };
}

test "OofAxis inset-modified containing block" {
    var axis = testAxis();
    try testing.expectEqual(Line(f32){ .start = 10.0, .end = 100.0 }, axis.insetModifiedContainingBlock());
    axis.inset = .{ .start = 20.0, .end = 30.0 };
    try testing.expectEqual(Line(f32){ .start = 20.0, .end = 70.0 }, axis.insetModifiedContainingBlock());
    try testing.expectEqual(@as(f32, 50.0), axis.stretchFitSize());
    try testing.expect(axis.isStretchSized(false, false));
    try testing.expect(!axis.isStretchSized(true, false));
    // Overconstrained: the end inset is weaker (LTR)
    axis.inset = .{ .start = 80.0, .end = 50.0 };
    try testing.expectEqual(Line(f32){ .start = 80.0, .end = 80.0 }, axis.insetModifiedContainingBlock());
    axis.reversed = true;
    try testing.expectEqual(Line(f32){ .start = 50.0, .end = 50.0 }, axis.insetModifiedContainingBlock());
    // Centered static position
    axis = testAxis();
    axis.static_position = AxisStaticPosition.fromEdge(30.0, .center);
    try testing.expectEqual(Line(f32){ .start = 0.0, .end = 60.0 }, axis.insetModifiedContainingBlock());
    axis.static_position = AxisStaticPosition.fromEdge(70.0, .center);
    try testing.expectEqual(Line(f32){ .start = 40.0, .end = 100.0 }, axis.insetModifiedContainingBlock());
}

test "OofAxis margins and position" {
    var axis = testAxis();
    axis.inset = .{ .start = 10.0, .end = 10.0 };
    axis.margin = .{ .start = null, .end = null };
    try testing.expectEqual(Line(f32){ .start = 20.0, .end = 20.0 }, axis.resolveMargins(40.0));
    try testing.expectEqual(Line(f32){ .start = 0.0, .end = -20.0 }, axis.resolveMargins(100.0));
    axis.is_inline = false;
    try testing.expectEqual(Line(f32){ .start = -10.0, .end = -10.0 }, axis.resolveMargins(100.0));
    axis.margin = .{ .start = 5.0, .end = null };
    try testing.expectEqual(Line(f32){ .start = 5.0, .end = 35.0 }, axis.resolveMargins(40.0));
    try testing.expectEqual(@as(f32, 15.0), axis.position(40.0, .{ .start = 5.0, .end = 35.0 }));

    axis = testAxis();
    axis.inset = .{ .start = 10.0, .end = 10.0 };
    axis.alignment = .end;
    try testing.expectEqual(@as(f32, 50.0), axis.position(40.0, .{ .start = 0.0, .end = 0.0 }));
    // Default safety: overflowing boxes stay within the containing block
    try testing.expectEqual(@as(f32, 0.0), axis.position(100.0, .{ .start = 0.0, .end = 0.0 }));
    axis.safety = .unsafe;
    try testing.expectEqual(@as(f32, -10.0), axis.position(100.0, .{ .start = 0.0, .end = 0.0 }));
    axis.safety = .safe;
    try testing.expectEqual(@as(f32, 10.0), axis.position(100.0, .{ .start = 0.0, .end = 0.0 }));
    // One auto inset
    axis.inset = .{ .start = null, .end = 10.0 };
    try testing.expectEqual(@as(f32, 50.0), axis.position(40.0, .{ .start = 0.0, .end = 0.0 }));
}
