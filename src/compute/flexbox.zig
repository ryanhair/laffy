//! Computes the [flexbox](https://css-tricks.com/snippets/css/a-guide-to-flexbox/) layout algorithm on `TaffyTree` according to the [spec](https://www.w3.org/TR/css-flexbox-1/)
//!
//! `tree` arguments implement `LayoutFlexboxContainer` (see `src/tree/traits.zig`).
const std = @import("std");
const geometry = @import("../geometry.zig");
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../style.zig");
const AlignContent = style_mod.AlignContent;
const AlignContentKeyword = style_mod.AlignContentKeyword;
const AlignItems = style_mod.AlignItems;
const AlignItemsKeyword = style_mod.AlignItemsKeyword;
const AlignSelf = style_mod.AlignSelf;
const AvailableSpace = style_mod.AvailableSpace;
const Contain = style_mod.Contain;
const Dimension = style_mod.Dimension;
const Direction = style_mod.Direction;
const FlexDirection = style_mod.FlexDirection;
const JustifyContent = style_mod.JustifyContent;
const Overflow = style_mod.Overflow;
const layout = @import("../tree/layout.zig");
const AxisStaticAlign = layout.AxisStaticAlign;
const AxisStaticEdge = layout.AxisStaticEdge;
const AxisStaticPosition = layout.AxisStaticPosition;
const Baselines = layout.Baselines;
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidate = layout.OofCandidate;
const OofCandidates = layout.OofCandidates;
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
const alignment = @import("common/alignment.zig");
const applyAlignmentFallback = alignment.applyAlignmentFallback;
const childFirstBaseline = alignment.childFirstBaseline;
const computeAlignmentOffset = alignment.computeAlignmentOffset;
const resolveSelfAlignmentSafety = alignment.resolveSelfAlignmentSafety;
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const computeScrollableOverflowContribution = scrollable_overflow.computeScrollableOverflowContribution;
const finalizeScrollableOverflow = scrollable_overflow.finalizeScrollableOverflow;
const ScrollableOverflowContainer = scrollable_overflow.ScrollableOverflowContainer;
const sizing_keyword = @import("common/sizing_keyword.zig");
const resolveSizingKeyword = sizing_keyword.resolveSizingKeyword;

/// The intermediate results of a flexbox calculation for a single item
const FlexItem = struct {
    /// The identifier for the associated node
    node: NodeId,

    /// The order of the node relative to it's siblings
    order: u32,

    /// The base size of this item
    size: Size(?f32),
    /// The raw size style of this item. Used to detect and resolve sizing
    /// keywords (`min-content`, `max-content`, `fit-content`, `fit-content(...)`, and `stretch`)
    size_style: Size(Dimension),
    /// The minimum allowable size of this item
    min_size: Size(?f32),
    /// The maximum allowable size of this item
    max_size: Size(?f32),
    /// The aspect ratio of this item
    aspect_ratio: ?f32,
    /// The cross-alignment of this item
    align_self: AlignSelf,

    /// The overflow style of the item
    overflow: Point(Overflow),
    /// The contain style of the item
    contain: Contain,
    /// The width of the scrollbars (if it has any)
    scrollbar_width: f32,
    /// The flex shrink style of the item
    flex_shrink: f32,
    /// The flex grow style of the item
    flex_grow: f32,
    /// Whether the item's used flex basis is definite (rather than derived from the item's content)
    flex_basis_is_definite: bool,

    /// The minimum size of the item. This differs from min_size above because it also
    /// takes into account content based automatic minimum sizes
    resolved_minimum_main_size: f32,

    /// The `position: relative` offset of this item, resolved to (width, height) in the
    /// container's coordinate space (zero for non-relative items)
    relative_inset: Size(f32),
    /// The margin of this item
    margin: Rect(f32),
    /// Whether each margin is an auto margin or not
    margin_is_auto: Rect(bool),
    /// The padding of this item
    padding: Rect(f32),
    /// The border of this item
    border: Rect(f32),

    /// The default size of this item
    flex_basis: f32,
    /// The default size of this item, minus padding and border
    inner_flex_basis: f32,
    /// The amount by which this item has deviated from its target size
    violation: f32,
    /// Is the size of this item locked
    frozen: bool,

    /// Either the max- or min- content flex fraction
    /// See https://www.w3.org/TR/css-flexbox-1/#intrinsic-main-sizes
    content_flex_fraction: f32,

    /// The proposed inner size of this item
    hypothetical_inner_size: Size(f32),
    /// The proposed outer size of this item
    hypothetical_outer_size: Size(f32),
    /// The size that this item wants to be
    target_size: Size(f32),
    /// The size that this item wants to be, plus any padding and border
    outer_target_size: Size(f32),

    /// The position of the bottom edge of this item
    baseline: f32,

    /// A temporary value for the main offset
    ///
    /// Offset is the relative position from the item's natural flow position based on
    /// relative position values, alignment, and justification. Does not include margin/padding/border.
    offset_main: f32,
    /// A temporary value for the cross offset
    ///
    /// Offset is the relative position from the item's natural flow position based on
    /// relative position values, alignment, and justification. Does not include margin/padding/border.
    offset_cross: f32,

    /// Out-of-flow candidates bubbled out of this item's subtree. Anchors are relative to the
    /// container's border box (translated when the item's final layout is computed).
    /// Allocated with the tree's allocator and owned by the item.
    oof_candidates: OofCandidates,

    /// The size that the item's size styles exclude: padding + border for `box-sizing: content-box`, otherwise zero
    fn boxSizingAdjustment(self: *const FlexItem, style: anytype) Size(f32) {
        if (style.getBoxSizing() == .content_box) {
            return self.padding.add(self.border).sumAxes();
        } else {
            return Size(f32).zero;
        }
    }

    /// Returns true if the item is a <https://www.w3.org/TR/css-overflow-3/#scroll-container>
    fn isScrollContainer(self: *const FlexItem) bool {
        return self.overflow.x.isScrollContainer() or self.overflow.y.isScrollContainer();
    }

    /// Whether the used cross size of the item is the cross size of its flex line: it has a cross size of
    /// `stretch`, or of `auto` with `align-self: stretch`, and neither of its cross-axis margins is `auto`.
    inline fn isStretched(self: *const FlexItem, dir: FlexDirection) bool {
        const cross_size = self.size_style.cross(dir);
        return !self.margin_is_auto.crossStart(dir) and
            !self.margin_is_auto.crossEnd(dir) and
            (cross_size.isStretch() or (self.align_self == AlignSelf.stretch and cross_size.isAuto()));
    }

    /// Returns true if the item participates in baseline alignment: it has `align-self: baseline`
    /// and neither of its cross-axis margins are `auto`.
    /// See <https://www.w3.org/TR/css-flexbox-1/#baseline-participation>
    fn participatesInBaselineAlignment(self: *const FlexItem, dir: FlexDirection) bool {
        return self.align_self == AlignSelf.baseline and
            !self.margin_is_auto.crossStart(dir) and
            !self.margin_is_auto.crossEnd(dir);
    }
};

/// A line of `FlexItem` used for intermediate computation
const FlexLine = struct {
    /// The slice of items to iterate over during computation of this line
    items: []FlexItem,
    /// The dimensions of the cross-axis
    cross_size: f32,
    /// The relative offset of the cross-axis
    offset_cross: f32,

    fn new(items: []FlexItem) FlexLine {
        return .{ .items = items, .cross_size = 0.0, .offset_cross = 0.0 };
    }
};

/// Values that can be cached during the flexbox algorithm
const AlgoConstants = struct {
    /// The direction of the current segment being laid out
    dir: FlexDirection,
    /// The layout direction of the current segment being laid out
    layout_direction: Direction,
    /// Is this segment a row
    is_row: bool,
    /// Is this segment a column
    is_column: bool,
    /// Is wrapping enabled (in either direction)
    is_wrap: bool,
    /// Is the wrap direction inverted
    is_wrap_reverse: bool,
    /// Are items balanced across lines (`flex-wrap: balance`)?
    is_balance: bool,
    /// The requested minimum number of lines (`flex-line-count`). Non-null for every
    /// multi-line container, `null` for `no_wrap`.
    line_count: ?u16,

    /// The item's min_size style
    min_size: Size(?f32),
    /// The item's max_size style
    max_size: Size(?f32),
    /// The border of this section
    border: Rect(f32),
    /// The space between the content box and the border box.
    /// This consists of padding + border + scrollbar_gutter.
    content_box_inset: Rect(f32),
    /// The border and scrollbar gutters surrounding the padding box.
    padding_box_inset: Rect(f32),
    /// The resolved padding used for scrollable overflow contributions.
    padding: Rect(f32),
    /// The size reserved for scrollbar gutters in each axis
    scrollbar_gutter: Point(f32),
    /// Whether the node being laid out is a scroll container
    is_scroll_container: bool,
    /// The gap of this section
    gap: Size(f32),
    /// The align_items property of this node
    align_items: AlignItems,
    /// The align_content property of this node
    align_content: AlignContent,
    /// The justify_content property of this node
    justify_content: JustifyContent,

    /// The border-box size of the node being laid out (if known)
    node_outer_size: Size(?f32),
    /// The content-box size of the node being laid out (if known)
    node_inner_size: Size(?f32),
    /// Whether the known main size of the node (if any) is definite. This is `false` when a parent
    /// imposes a main size on this node that is derived from the node's own content, in which case
    /// it is indefinite for the purposes of resolving percentage sizes of items and collecting items
    /// into flex lines. See <https://www.w3.org/TR/css-flexbox-1/#definite-sizes>.
    known_main_size_is_definite: bool,
    /// Whether the node has a known main size which is definite (as of the start of layout,
    /// before the main size is determined from the node's contents)
    has_definite_main_size: bool,
    /// Whether the node has a known cross size which is definite
    has_definite_cross_size: bool,
    /// Whether the cross-axis space that non-stretched items are fit-content sized into is
    /// definite (either the node's cross size is definite, or the cross-axis available space is).
    /// A size resolved by fit-content sizing against definite available space is itself definite
    /// (see <https://www.w3.org/TR/css-sizing-3/#definite>).
    cross_axis_available_space_is_definite: bool,

    /// The size of the virtual container containing the flex items.
    container_size: Size(f32),
    /// The size of the internal container
    inner_container_size: Size(f32),

    /// When a multi-line container requests a minimum number of lines (`flex-line-count`),
    /// definite cross-axis available space for measuring items is divided between the requested
    /// number of lines (after subtracting the cross-axis gaps between them).
    /// See <https://github.com/w3c/csswg-drafts/issues/13414>
    inline fn dividedCrossSpace(self: *const AlgoConstants, cross_available_space: f32) f32 {
        if (self.line_count) |line_count_int| {
            if (line_count_int > 1) {
                const line_count: f32 = @floatFromInt(line_count_int);
                return (cross_available_space - (line_count - 1.0) * self.gap.cross(self.dir)) / line_count;
            }
        }
        return cross_available_space;
    }

    /// Map main/cross reversal to physical axes, including RTL inline progression.
    fn scrollOriginReversed(self: *const AlgoConstants) Point(bool) {
        const main = self.dir.isReverse();
        const cross = self.is_wrap_reverse;
        const x: bool, const y: bool = if (self.is_column) .{ cross, main } else .{ main, cross };
        return .{ .x = x != self.layout_direction.isRtl(), .y = y };
    }
};

/// Computes the layout of a box according to the flexbox algorithm
pub fn computeFlexboxLayout(tree: anytype, node: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
    traits.assertImplements(@TypeOf(tree), &.{.layout_flexbox_container});
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const run_mode = inputs.run_mode;
    const style = tree.getFlexboxContainerStyle(node);

    // Pull these out earlier to avoid borrowing issues
    const contain = style.getContain();
    const aspect_ratio = style.getAspectRatio();
    const padding = resolveOrZero(style.getPadding(), parent_size.width, tree);
    const border = resolveOrZero(style.getBorder(), parent_size.width, tree);
    const padding_border_sum = padding.sumAxes().add(border.sumAxes());
    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_sum else Size(f32).zero;

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

    // The size of the container should be floored by the padding and border
    const styled_based_known_dimensions = known_dimensions.@"or"(maybeMax(min_max_definite_size.@"or"(clamped_style_size), padding_border_sum));

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

    // Normalize the definiteness flags: they only apply to dimensions which were passed in as known
    // by the parent. Dimensions resolved from the node's own style are always definite.
    const known_dimensions_are_definite: Size(bool) = .{
        .width = inputs.known_dimensions_are_definite.width or known_dimensions.width == null,
        .height = inputs.known_dimensions_are_definite.height or known_dimensions.height == null,
    };

    var preliminary_inputs = inputs;
    preliminary_inputs.known_dimensions = styled_based_known_dimensions;
    preliminary_inputs.known_dimensions_are_definite = known_dimensions_are_definite;
    var output = try computePreliminary(tree, node, preliminary_inputs);

    // Layout containment suppresses the box's baseline for baseline-alignment purposes
    if (contain.suppressesBaseline()) {
        output.baselines = Baselines.none;
    }

    return output;
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

/// Free the flex items (and any out-of-flow candidates they still own)
fn freeFlexItems(gpa: std.mem.Allocator, flex_items: []FlexItem) void {
    for (flex_items) |*item| item.oof_candidates.deinit(gpa);
    gpa.free(flex_items);
}

/// Compute a preliminary size for an item
fn computePreliminary(tree: anytype, node: NodeId, inputs: LayoutInput) LayoutError!LayoutOutput {
    const gpa = tree.allocator();
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const run_mode = inputs.run_mode;

    // Define some general constants we will need for the remainder of the algorithm.
    var constants = computeConstants(
        tree,
        tree.getFlexboxContainerStyle(node),
        known_dimensions,
        inputs.known_dimensions_are_definite,
        parent_size,
        inputs.available_space,
    );

    // A container with no children has no flex items or lines, so its size follows directly
    // from its own style and the available space.
    if (tree.childCount(node) == 0) {
        return computeEmptyContainerLayout(tree, inputs, constants);
    }

    // 9. Flex Layout Algorithm

    // 9.1. Initial Setup

    // 1. Generate anonymous flex items as described in §4 Flex Items.
    const flex_items = try generateAnonymousFlexItems(tree, node, &constants);
    defer freeFlexItems(gpa, flex_items);

    // 9.2. Line Length Determination

    // 2. Determine the available main and cross space for the flex items
    const available_space = determineAvailableSpace(known_dimensions, inputs.available_space, &constants);

    // 3. Determine the flex base size and hypothetical main size of each item.
    try determineFlexBaseSize(tree, &constants, available_space, flex_items);

    // 4. Determine the main size of the flex container
    // This has already been done as part of computeConstants. The inner size is exposed as constants.node_inner_size.

    // 9.3. Main Size Determination

    // 5. Collect flex items into flex lines.
    var flex_lines_list = if (constants.is_balance)
        try collectBalancedFlexLines(gpa, &constants, available_space, flex_items)
    else
        try collectFlexLines(gpa, &constants, available_space, flex_items);
    defer flex_lines_list.deinit(gpa);
    const flex_lines = flex_lines_list.items;

    // If container size is undefined, determine the container's main size
    // and then re-resolve gaps based on newly determined size
    if (constants.node_inner_size.main(constants.dir)) |inner_main_size| {
        const outer_main_size = inner_main_size + constants.content_box_inset.mainAxisSum(constants.dir);
        constants.inner_container_size.setMain(constants.dir, inner_main_size);
        constants.container_size.setMain(constants.dir, outer_main_size);
    } else {
        // Sets constants.container_size and constants.outer_container_size
        try determineContainerMainSize(tree, available_space, flex_lines, &constants);
        constants.node_inner_size.setMain(constants.dir, constants.inner_container_size.main(constants.dir));
        constants.node_outer_size.setMain(constants.dir, constants.container_size.main(constants.dir));

        // Re-resolve percentage gaps
        const style = tree.getFlexboxContainerStyle(node);
        const inner_container_size = constants.inner_container_size.main(constants.dir);
        const new_gap = maybeResolve(style.getGap().main(constants.dir), inner_container_size, tree) orelse 0.0;
        constants.gap.setMain(constants.dir, new_gap);
    }

    // If only the container's main size has been requested then we are done, as nothing below changes it. This
    // avoids measuring the cross size of every item.
    if (run_mode == .compute_size and constants.dir.mainAxisIsRequestedAxis(inputs.axis)) {
        const size = Size(f32).zero.withMain(constants.dir, constants.container_size.main(constants.dir));
        return LayoutOutput.fromOuterSize(size);
    }

    // 6. Resolve the flexible lengths of all the flex items to find their used main size.
    for (flex_lines) |*line| {
        resolveFlexibleLengths(line, &constants);
    }

    // 9.4. Cross Size Determination

    // 7. Determine the hypothetical cross size of each item.
    for (flex_lines) |*line| {
        try determineHypotheticalCrossSize(tree, line, &constants, known_dimensions, available_space);
    }

    // Calculate child baselines. This function is internally smart and only computes child baselines
    // if they are necessary.
    try calculateChildrenBaseLines(tree, known_dimensions, available_space, flex_lines, &constants);

    // 8. Calculate the cross size of each flex line.
    calculateCrossSize(flex_lines, known_dimensions, &constants);

    // 9. Handle 'align-content: stretch'.
    handleAlignContentStretch(flex_lines, known_dimensions, &constants);

    // 10. Collapse visibility:collapse items. If any flex items have visibility: collapse,
    //     note the cross size of the line they’re in as the item’s strut size, and restart
    //     layout from the beginning.
    //
    //     In this second layout round, when collecting items into lines, treat the collapsed
    //     items as having zero main size. For the rest of the algorithm following that step,
    //     ignore the collapsed items entirely (as if they were display:none) except that after
    //     calculating the cross size of the lines, if any line’s cross size is less than the
    //     largest strut size among all the collapsed items in the line, set its cross size to
    //     that strut size.
    //
    //     Skip this step in the second layout round.

    // TODO implement once (if ever) we support visibility:collapse

    // 11. Determine the used cross size of each flex item.
    determineUsedCrossSize(tree, flex_lines, &constants);

    // 9.5. Main-Axis Alignment

    // 12. Distribute any remaining free space.
    distributeRemainingFreeSpace(flex_lines, &constants);

    // 9.6. Cross-Axis Alignment

    // 13. Resolve cross-axis auto margins (also includes 14).
    resolveCrossAxisAutoMargins(flex_lines, &constants);

    // 15. Determine the flex container’s used cross size.
    const total_line_cross_size = determineContainerCrossSize(flex_lines, known_dimensions, &constants);

    // We have the container size.
    // If our caller does not care about performing layout we are done now.
    if (run_mode == .compute_size) {
        return LayoutOutput.fromOuterSize(constants.container_size);
    }

    // 16. Align all flex lines per align-content.
    alignFlexLinesPerAlignContent(flex_lines, &constants, total_line_cross_size);

    // Do a final layout pass and gather the resulting layouts
    const inflow_overflow_rect = try finalLayoutPass(tree, flex_lines, &constants);

    // Collect out-of-flow candidates in document order (direct out-of-flow children interleaved
    // with candidates bubbled from in-flow children's subtrees). These are laid out by the
    // out-of-flow positioning pass (`computeOofLayout`), which runs after this algorithm.
    var candidates: OofCandidates = .none;
    errdefer candidates.deinit(gpa);
    try collectOofCandidates(tree, node, &constants, flex_lines, &candidates);

    const absolute_position_area = constants.container_size.sub(constants.padding_box_inset.sumAxes());
    const absolute_position_offset: Point(f32) = .{ .x = constants.padding_box_inset.left, .y = constants.padding_box_inset.top };

    const len = tree.childCount(node);
    for (0..len) |order| {
        const child = tree.getChildId(node, order);
        if (tree.getFlexboxChildStyle(child).getBoxGenerationMode() == .none) {
            tree.setUnroundedLayout(child, &Layout.withOrder(@intCast(order)));
            var hidden_output = try traits.performChildLayout(
                tree,
                child,
                Size(?f32).none,
                Size(?f32).none,
                Size(AvailableSpace).max_content,
                .content_size,
                Line(bool).false,
            );
            hidden_output.deinit(gpa);
        }
    }

    // 8.5. Flex Container Baselines: calculate the flex container's first baseline
    // See https://www.w3.org/TR/css-flexbox-1/#flex-baselines
    // The baselines are generated from the startmost flex line, where "startmost" refers to the
    // line's visual position: for wrap-reverse containers the cross axis is flipped, so the
    // startmost line is the last line in flex-line order rather than the first.
    const first_vertical_baseline: ?f32 = blk: {
        if (flex_lines.len == 0) break :blk null;
        const line = if (constants.is_wrap_reverse) flex_lines[flex_lines.len - 1] else flex_lines[0];
        if (line.items.len == 0) break :blk null;
        if (constants.is_column) {
            // For column containers the baseline is generated from the startmost item in the line,
            // which for reverse-direction containers is the last item in flex order.
            const item = if (constants.dir.isReverse()) line.items[line.items.len - 1] else line.items[0];
            break :blk item.baseline;
        } else {
            for (line.items) |*item| {
                if (item.participatesInBaselineAlignment(constants.dir)) break :blk item.baseline;
            }
            break :blk line.items[0].baseline;
        }
    };

    var output = LayoutOutput.fromSizesAndBaselines(
        constants.container_size,
        finalizeScrollableOverflow(
            inflow_overflow_rect,
            constants.container_size
                .sub(constants.border.sumAxes())
                .sub(.{ .width = constants.scrollbar_gutter.x, .height = constants.scrollbar_gutter.y }),
            constants.scrollOriginReversed(),
            constants.is_scroll_container,
        ),
        Baselines.fromFirst(first_vertical_baseline),
    );
    output.oof_candidates = candidates;
    output.oof_positioning_area = .{ .size = absolute_position_area, .offset = absolute_position_offset };
    return output;
}

/// Compute the layout of a flex container with no children. Equivalent to running the remainder of
/// `computePreliminary` with zero flex items, without generating items or lines.
fn computeEmptyContainerLayout(tree: anytype, inputs: LayoutInput, constants_in: AlgoConstants) LayoutError!LayoutOutput {
    var constants = constants_in;
    const known_dimensions = inputs.known_dimensions;
    const run_mode = inputs.run_mode;
    const dir = constants.dir;

    const available_space = determineAvailableSpace(known_dimensions, inputs.available_space, &constants);

    if (constants.node_inner_size.main(dir)) |inner_main_size| {
        const outer_main_size = inner_main_size + constants.content_box_inset.mainAxisSum(dir);
        constants.inner_container_size.setMain(dir, inner_main_size);
        constants.container_size.setMain(dir, outer_main_size);
    } else {
        var no_lines: [0]FlexLine = .{};
        try determineContainerMainSize(tree, available_space, &no_lines, &constants);
    }

    if (run_mode == .compute_size and dir.mainAxisIsRequestedAxis(inputs.axis)) {
        const size = Size(f32).zero.withMain(dir, constants.container_size.main(dir));
        return LayoutOutput.fromOuterSize(size);
    }

    _ = determineContainerCrossSize(&.{}, known_dimensions, &constants);

    // With no children there are no out-of-flow candidates, so the positioning area's value is
    // never read. It still has to be non-null: that is what makes `computeOofLayout` clear a
    // stale hoisted-children list from a run in which the container still had descendants.
    var output = LayoutOutput.fromOuterSize(constants.container_size);
    var rect = Rect(f32).zero;
    rect.right = if (constants.layout_direction.isRtl())
        @max(constants.container_size.width - constants.border.horizontalAxisSum() - constants.scrollbar_gutter.x, 0.0)
    else
        0.0;
    output.scrollable_overflow_rect = finalizeScrollableOverflow(
        rect,
        constants.container_size
            .sub(constants.border.sumAxes())
            .sub(.{ .width = constants.scrollbar_gutter.x, .height = constants.scrollbar_gutter.y }),
        constants.scrollOriginReversed(),
        constants.is_scroll_container,
    );
    output.oof_positioning_area = .{ .size = Size(f32).zero, .offset = Point(f32).zero };
    return output;
}

/// Resolve the `normal` alignment keyword, which behaves as `stretch` for flex items.
/// <https://www.w3.org/TR/css-align-3/#align-flex>
inline fn resolveNormalAlignment(alignment_value: AlignItems) AlignItems {
    return switch (alignment_value.keyword) {
        .normal => AlignItems.stretch,
        else => alignment_value,
    };
}

/// Compute constants that can be reused during the flexbox algorithm.
fn computeConstants(
    tree: anytype,
    style: anytype,
    known_dimensions: Size(?f32),
    known_dimensions_are_definite: Size(bool),
    parent_size: Size(?f32),
    available_space: Size(AvailableSpace),
) AlgoConstants {
    const dir = style.getFlexDirection();
    const is_row = dir.isRow();
    const is_column = dir.isColumn();
    const flex_wrap = style.getFlexWrap();
    const is_wrap = flex_wrap.isMultiLine();
    const is_wrap_reverse = flex_wrap.isReverse();
    const is_balance = flex_wrap.isBalance();
    const line_count: ?u16 = if (is_wrap) @max(style.getFlexLineCount(), 1) else null;

    const aspect_ratio = style.getAspectRatio();
    const padding_raw = resolveOrZero(style.getPadding(), parent_size.width, tree);
    const border = resolveOrZero(style.getBorder(), parent_size.width, tree);
    const padding_border_sum = padding_raw.sumAxes().add(border.sumAxes());
    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_sum else Size(f32).zero;

    // `normal` behaves as `stretch` for flex items. This is resolved once here so that
    // items with an `align_self` of `null`, which defer to this value, are also resolved.
    const align_items = resolveNormalAlignment(style.getAlignItems());
    // `normal` behaves as `stretch` for flex containers. In the main axis `stretch` behaves as
    // `flex-start`, so a `normal` justify-content is resolved straight to `flex-start`.
    // <https://www.w3.org/TR/css-align-3/#distribution-flex>
    const align_content_style = style.getAlignContent();
    const align_content = if (align_content_style.keyword == .normal) AlignContent.stretch else align_content_style;
    const justify_content_style = style.getJustifyContent();
    const justify_content = if (justify_content_style.keyword == .normal) JustifyContent.flex_start else justify_content_style;
    const layout_direction = style.getDirection();

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow.scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const overflow = style.getOverflow();
    const scrollbar_gutter: Point(f32) = .{
        .x = if (overflow.y == .scroll) style.getScrollbarWidth() else 0.0,
        .y = if (overflow.x == .scroll) style.getScrollbarWidth() else 0.0,
    };
    const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
    var content_box_inset = padding_raw.add(border);
    content_box_inset.bottom += scrollbar_gutter.y;

    switch (layout_direction) {
        .ltr => content_box_inset.right += scrollbar_gutter.x,
        .rtl => content_box_inset.left += scrollbar_gutter.x,
    }

    const padding_box_inset = border.add(.{
        .left = if (layout_direction.isRtl()) scrollbar_gutter.x else 0.0,
        .right = if (layout_direction.isRtl()) 0.0 else scrollbar_gutter.x,
        .top = 0.0,
        .bottom = scrollbar_gutter.y,
    });
    const padding: Rect(f32) = .{
        .left = content_box_inset.left - border.left - (if (layout_direction.isRtl()) scrollbar_gutter.x else 0.0),
        .right = content_box_inset.right - border.right - (if (layout_direction.isRtl()) 0.0 else scrollbar_gutter.x),
        .top = content_box_inset.top - border.top,
        .bottom = content_box_inset.bottom - border.bottom - scrollbar_gutter.y,
    };

    const node_outer_size = known_dimensions;
    const node_inner_size = maybeSub(node_outer_size, content_box_inset.sumAxes());
    const known_main_size_is_definite = known_dimensions_are_definite.main(dir);
    const has_definite_main_size = known_main_size_is_definite and known_dimensions.main(dir) != null;
    const has_definite_cross_size = known_dimensions_are_definite.cross(dir) and known_dimensions.cross(dir) != null;
    const cross_axis_available_space_is_definite = has_definite_cross_size or available_space.cross(dir) == .definite;
    const gap = resolveOrZero(style.getGap(), node_inner_size.@"or"(Size(?f32).zero), tree);

    return .{
        .dir = dir,
        .layout_direction = layout_direction,
        .is_row = is_row,
        .is_column = is_column,
        .is_wrap = is_wrap,
        .is_wrap_reverse = is_wrap_reverse,
        .is_balance = is_balance,
        .line_count = line_count,
        .min_size = maybeAdd(maybeResolve(style.getMinSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
        .max_size = maybeAdd(maybeResolve(style.getMaxSize(), parent_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
        .border = border,
        .gap = gap,
        .content_box_inset = content_box_inset,
        .padding_box_inset = padding_box_inset,
        .padding = padding,
        .scrollbar_gutter = scrollbar_gutter,
        .is_scroll_container = is_scroll_container,
        .align_items = align_items,
        .align_content = align_content,
        .justify_content = justify_content,
        .node_outer_size = node_outer_size,
        .node_inner_size = node_inner_size,
        .known_main_size_is_definite = known_main_size_is_definite,
        .has_definite_main_size = has_definite_main_size,
        .has_definite_cross_size = has_definite_cross_size,
        .cross_axis_available_space_is_definite = cross_axis_available_space_is_definite,
        .container_size = Size(f32).zero,
        .inner_container_size = Size(f32).zero,
    };
}

/// `a orelse b` for the `Option::or` pattern
inline fn optOr(a: ?f32, b: ?f32) ?f32 {
    return if (a != null) a else b;
}

/// `opt.map(|pos| -pos)`
inline fn optNeg(a: ?f32) ?f32 {
    return if (a) |v| -v else null;
}

/// Resolve a `position: relative` item's inset to a single offset in the container's flex axes,
/// accounting for flex direction and writing direction.
fn resolveRelativeInset(inset: Rect(?f32), constants: *const AlgoConstants) Size(f32) {
    const direction = constants.dir;
    const is_rtl_row = direction.isRow() and constants.layout_direction.isRtl();
    const is_rtl_column = direction.isColumn() and constants.layout_direction.isRtl();
    const main = if (is_rtl_row)
        optOr(inset.mainEnd(direction), optNeg(inset.mainStart(direction))) orelse 0.0
    else
        optOr(inset.mainStart(direction), optNeg(inset.mainEnd(direction))) orelse 0.0;
    const cross = if (is_rtl_column)
        optOr(optNeg(inset.crossEnd(direction)), inset.crossStart(direction)) orelse 0.0
    else
        optOr(inset.crossStart(direction), optNeg(inset.crossEnd(direction))) orelse 0.0;
    var out = Size(f32).zero;
    out.setMain(direction, main);
    out.setCross(direction, cross);
    return out;
}

/// Generate anonymous flex items.
///
/// # [9.1. Initial Setup](https://www.w3.org/TR/css-flexbox-1/#box-manip)
///
/// - [**Generate anonymous flex items**](https://www.w3.org/TR/css-flexbox-1/#algo-anon-box) as described in [§4 Flex Items](https://www.w3.org/TR/css-flexbox-1/#flex-items).
///
/// The returned slice is allocated with the tree's allocator and owned by the caller.
fn generateAnonymousFlexItems(tree: anytype, node: NodeId, constants: *const AlgoConstants) LayoutError![]FlexItem {
    const gpa = tree.allocator();
    // Percentage sizes of items resolve against the container's inner size, but only if that size
    // is definite. A known main size which is derived from the container's own content is treated
    // as indefinite here.
    const percent_resolution_size = if (constants.known_main_size_is_definite)
        constants.node_inner_size
    else
        constants.node_inner_size.withMain(constants.dir, null);

    var flex_items: std.ArrayList(FlexItem) = .empty;
    errdefer flex_items.deinit(gpa);
    var iter = tree.childIds(node);
    var index: usize = 0;
    while (iter.next()) |child| : (index += 1) {
        const child_style = tree.getFlexboxChildStyle(child);
        if (child_style.getPosition().isOutOfFlow()) continue;
        if (child_style.getBoxGenerationMode() == .none) continue;

        const aspect_ratio = child_style.getAspectRatio();
        const padding = resolveOrZero(child_style.getPadding(), constants.node_inner_size.width, tree);
        const border = resolveOrZero(child_style.getBorder(), constants.node_inner_size.width, tree);
        const box_sizing_adjustment = if (child_style.getBoxSizing() == .content_box)
            padding.add(border).sumAxes()
        else
            Size(f32).zero;
        const margin_style = child_style.getMargin();

        const relative_inset = if (child_style.getPosition() == .relative) blk: {
            const inset_style = child_style.getInset();
            const inset: Rect(?f32) = .{
                .left = maybeResolve(inset_style.left, constants.node_inner_size.width, tree),
                .right = maybeResolve(inset_style.right, constants.node_inner_size.width, tree),
                .top = maybeResolve(inset_style.top, constants.node_inner_size.height, tree),
                .bottom = maybeResolve(inset_style.bottom, constants.node_inner_size.height, tree),
            };
            break :blk resolveRelativeInset(inset, constants);
        } else Size(f32).zero;

        if (flex_items.capacity == 0) {
            // Allocate once, for the child count, when the first item is generated (some children may not generate one)
            try flex_items.ensureTotalCapacity(gpa, tree.childCount(node));
        }
        try flex_items.append(gpa, .{
            .node = child,
            .order = @intCast(index),
            .size = maybeAdd(maybeResolve(child_style.getSize(), percent_resolution_size, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment),
            .size_style = child_style.getSize(),
            .min_size = maybeAdd(maybeResolve(child_style.getMinSize(), percent_resolution_size, tree), box_sizing_adjustment),
            .max_size = maybeAdd(maybeResolve(child_style.getMaxSize(), percent_resolution_size, tree), box_sizing_adjustment),
            .aspect_ratio = aspect_ratio,

            .relative_inset = relative_inset,
            .margin = resolveOrZero(margin_style, constants.node_inner_size.width, tree),
            .margin_is_auto = .{
                .left = margin_style.left.isAuto(),
                .right = margin_style.right.isAuto(),
                .top = margin_style.top.isAuto(),
                .bottom = margin_style.bottom.isAuto(),
            },
            .padding = padding,
            .border = border,
            .align_self = resolveNormalAlignment(child_style.getAlignSelf() orelse constants.align_items)
                .resolveSelfRelative(child_style.getDirection(), constants.layout_direction, constants.is_column),
            .overflow = child_style.getOverflow(),
            .contain = child_style.getContain(),
            .scrollbar_width = child_style.getScrollbarWidth(),
            .flex_grow = child_style.getFlexGrow(),
            .flex_shrink = child_style.getFlexShrink(),
            .flex_basis_is_definite = false,
            .flex_basis = 0.0,
            .inner_flex_basis = 0.0,
            .violation = 0.0,
            .frozen = false,

            .resolved_minimum_main_size = 0.0,
            .hypothetical_inner_size = Size(f32).zero,
            .hypothetical_outer_size = Size(f32).zero,
            .target_size = Size(f32).zero,
            .outer_target_size = Size(f32).zero,
            .content_flex_fraction = 0.0,

            .baseline = 0.0,

            .offset_main = 0.0,
            .offset_cross = 0.0,

            .oof_candidates = .none,
        });
    }
    return flex_items.toOwnedSlice(gpa);
}

/// Determine the available main and cross space for the flex items.
///
/// # [9.2. Line Length Determination](https://www.w3.org/TR/css-flexbox-1/#line-sizing)
///
/// - [**Determine the available main and cross space for the flex items**](https://www.w3.org/TR/css-flexbox-1/#algo-available).
///
/// For each dimension, if that dimension of the flex container’s content box is a definite size, use that;
/// if that dimension of the flex container is being sized under a min or max-content constraint, the available space in that dimension is that constraint;
/// otherwise, subtract the flex container’s margin, border, and padding from the space available to the flex container in that dimension and use that value.
/// **This might result in an infinite value**.
///
/// Note: the flex container's margins have already been subtracted from `outer_available_space` by its parent.
inline fn determineAvailableSpace(
    known_dimensions: Size(?f32),
    outer_available_space: Size(AvailableSpace),
    constants: *const AlgoConstants,
) Size(AvailableSpace) {
    // Note: min/max/preferred size styles have already been applied to known_dimensions in the `compute` function above
    const width: AvailableSpace = if (known_dimensions.width) |node_width|
        .{ .definite = @max(node_width - constants.content_box_inset.horizontalAxisSum(), 0.0) }
    else
        maybeMax(maybeSub(outer_available_space.width, constants.content_box_inset.horizontalAxisSum()), @as(f32, 0.0));

    const height: AvailableSpace = if (known_dimensions.height) |node_height|
        .{ .definite = @max(node_height - constants.content_box_inset.verticalAxisSum(), 0.0) }
    else
        maybeMax(maybeSub(outer_available_space.height, constants.content_box_inset.verticalAxisSum()), @as(f32, 0.0));

    return .{ .width = width, .height = height };
}

/// Determine the flex base size and hypothetical main size of each item.
///
/// # [9.2. Line Length Determination](https://www.w3.org/TR/css-flexbox-1/#line-sizing)
///
/// - [**Determine the flex base size and hypothetical main size of each item:**](https://www.w3.org/TR/css-flexbox-1/#algo-main-item)
///
///     - A. If the item has a definite used flex basis, that’s the flex base size.
///
///     - B. If the flex item has ...
///
///         - an intrinsic aspect ratio,
///         - a used flex basis of content, and
///         - a definite cross size,
///
///       then the flex base size is calculated from its inner cross size and the flex item’s intrinsic aspect ratio.
///
///     - C. If the used flex basis is content or depends on its available space, and the flex container is being sized under a min-content
///       or max-content constraint (e.g. when performing automatic table layout \[CSS21\]), size the item under that constraint.
///       The flex base size is the item’s resulting main size.
///
///     - E. Otherwise, size the item into the available space using its used flex basis in place of its main size, treating a value of content as max-content.
///       If a cross size is needed to determine the main size (e.g. when the flex item’s main size is in its block axis) and the flex item’s cross size is auto and not definite,
///       in this calculation use fit-content as the flex item’s cross size. The flex base size is the item’s resulting main size.
///
///   When determining the flex base size, the item’s min and max main sizes are ignored (no clamping occurs).
///   Furthermore, the sizing calculations that floor the content box size at zero when applying box-sizing are also ignored.
///   (For example, an item with a specified size of zero, positive padding, and box-sizing: border-box will have an outer flex base size of zero—and hence a negative inner flex base size.)
fn determineFlexBaseSize(
    tree: anytype,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem,
) LayoutError!void {
    const dir = constants.dir;

    for (flex_items) |*child| {
        const child_style = tree.getFlexboxChildStyle(child.node);

        // Parent size for child sizing
        const cross_axis_parent_size = constants.node_inner_size.cross(dir);
        const child_parent_size = Size(?f32).fromCross(dir, cross_axis_parent_size);

        // Available space for child sizing (excluding the child's margins)
        // Min/max sizes transferred through the aspect ratio are taken into account here
        // https://github.com/w3c/csswg-drafts/issues/10997
        const transferred_min_size = child.min_size.maybeApplyAspectRatio(child.aspect_ratio);
        const transferred_max_size = child.max_size.maybeApplyAspectRatio(child.aspect_ratio);
        const child_min_cross = transferred_min_size.cross(dir);
        const child_max_cross = transferred_max_size.cross(dir);

        // Clamp available space by min- and max- size
        const cross_axis_available_space: AvailableSpace = switch (available_space.cross(dir)) {
            .definite => |val| .{ .definite = maybeClamp(
                @max(constants.dividedCrossSpace(cross_axis_parent_size orelse val) - child.margin.crossAxisSum(dir), 0.0),
                child_min_cross,
                child_max_cross,
            ) },
            .min_content => if (child_min_cross) |min| .{ .definite = min } else .min_content,
            .max_content => if (child_max_cross) |max| .{ .definite = max } else .max_content,
        };

        // Known dimensions for child sizing
        var child_cross_size_is_definite = child.size.cross(dir) != null;
        const child_known_dimensions = blk: {
            var ckd = child.size.withMain(dir, null);
            // Clamp the definite cross size by the cross min/max sizes so that sizes
            // transferred through an intrinsic aspect ratio (e.g. for replaced elements)
            // are based on the used cross size.
            ckd.setCross(dir, maybeClamp(ckd.cross(dir), transferred_min_size.cross(dir), transferred_max_size.cross(dir)));
            if (child.align_self == AlignSelf.stretch and
                !child.margin_is_auto.crossStart(constants.dir) and
                !child.margin_is_auto.crossEnd(constants.dir) and
                ckd.cross(dir) == null)
            {
                ckd.setCross(dir, cross_axis_available_space.intoOption());
                // The cross size of a stretched item is definite if the container has a definite
                // cross size (https://www.w3.org/TR/css-flexbox-1/#definite-sizes)
                child_cross_size_is_definite = !constants.is_wrap and constants.has_definite_cross_size and cross_axis_parent_size != null;
            }
            break :blk ckd;
        };

        const box_sizing_adjustment = child.boxSizingAdjustment(child_style).main(dir);
        // Percentage flex basis values resolve against the container's inner main size, but only
        // if that size is definite. A known main size which is derived from the container's own
        // content is treated as indefinite here.
        const percent_resolution_main_size: ?f32 = if (constants.known_main_size_is_definite) constants.node_inner_size.main(dir) else null;
        const flex_basis_style = child_style.getFlexBasis();
        const flex_basis = maybeAdd(maybeResolve(flex_basis_style, percent_resolution_main_size, tree), box_sizing_adjustment);

        child.flex_basis = flex_basis: {
            // A. If the item has a definite used flex basis, that’s the flex base size.

            // B. If the flex item has an intrinsic aspect ratio,
            //    a used flex basis of content, and a definite cross size,
            //    then the flex base size is calculated from its inner
            //    cross size and the flex item’s intrinsic aspect ratio.

            const main_size = child.size.main(dir);
            const main_stretch_size = maybeMax(maybeSub(percent_resolution_main_size, child.margin.mainAxisSum(dir)), @as(f32, 0.0));

            // A flex basis that is a sizing keyword (min-content, max-content, fit-content,
            // fit-content(...), stretch) is used in place of the main size property: `stretch`
            // resolves to an exact (definite) size while the other keywords determine the
            // available space constraint the item is measured under. A keyword that cannot be
            // resolved in the current context behaves as `content`.
            const keyword_main_available_space: ?AvailableSpace = if (flex_basis_style.isContent())
                // A flex basis of `content` indicates an automatic size based on the item's
                // content: the item is measured (ignoring its main size property) under the
                // default constraint below
                null
            else if (flex_basis_style.isSizingKeyword()) blk: {
                if (resolveSizingKeyword(flex_basis_style, main_stretch_size, percent_resolution_main_size, tree)) |resolution| {
                    switch (resolution) {
                        .exact => |size| {
                            child.flex_basis_is_definite = true;
                            break :flex_basis size;
                        },
                        .measure => |available| break :blk available,
                    }
                }
                break :blk null;
            } else blk: {
                const auto_main_size: ?f32 = if (flex_basis_style.isAuto()) main_size else null;
                if (optOr(flex_basis, auto_main_size)) |definite_flex_basis| {
                    child.flex_basis_is_definite = true;
                    break :flex_basis definite_flex_basis;
                }

                // A main size that is a sizing keyword either resolves to an exact size or
                // determines the available space constraint the item is measured under
                if (flex_basis_style.isAuto()) {
                    if (resolveSizingKeyword(child.size_style.main(dir), main_stretch_size, percent_resolution_main_size, tree)) |resolution| {
                        switch (resolution) {
                            .exact => |size| {
                                child.flex_basis_is_definite = true;
                                break :flex_basis size;
                            },
                            .measure => |available| break :blk available,
                        }
                    }
                    break :blk null;
                } else {
                    break :blk null;
                }
            };

            // C. If the used flex basis is content or depends on its available space,
            //    and the flex container is being sized under a min-content or max-content
            //    constraint (e.g. when performing automatic table layout [CSS21]),
            //    size the item under that constraint. The flex base size is the item’s
            //    resulting main size.

            // This is covered by the implementation of E below, which passes the available_space constraint
            // through to the child size computation. It may need a separate implementation if/when D is implemented.

            // D. Otherwise, if the used flex basis is content or depends on its
            //    available space, the available main size is infinite, and the flex item’s
            //    inline axis is parallel to the main axis, lay the item out using the rules
            //    for a box in an orthogonal flow [CSS3-WRITING-MODES]. The flex base size
            //    is the item’s max-content main size.

            // TODO if/when vertical writing modes are supported

            // If the item has an aspect ratio and a definite cross size then the flex base size
            // is calculated by transferring that cross size through the aspect ratio (case B
            // above), and is therefore definite.
            if (child_cross_size_is_definite) {
                if (child.aspect_ratio) |ratio| {
                    if (child_known_dimensions.cross(dir)) |cross| {
                        child.flex_basis_is_definite = true;
                        break :flex_basis if (dir.isRow()) cross * ratio else cross / ratio;
                    }
                }
            }

            // E. Otherwise, size the item into the available space using its used flex basis
            //    in place of its main size, treating a value of content as max-content.
            //    If a cross size is needed to determine the main size (e.g. when the
            //    flex item’s main size is in its block axis) and the flex item’s cross size
            //    is auto and not definite, in this calculation use fit-content as the
            //    flex item’s cross size. The flex base size is the item’s resulting main size.

            const child_available_space = Size(AvailableSpace).max_content
                .withMain(
                    dir,
                    keyword_main_available_space orelse
                        // Map AvailableSpace.definite to AvailableSpace.max_content
                        (if (available_space.main(dir) == .min_content) AvailableSpace.min_content else AvailableSpace.max_content),
                )
                .withCross(dir, cross_axis_available_space);

            break :flex_basis try traits.measureChildSize(
                tree,
                child.node,
                child_known_dimensions,
                child_parent_size,
                child_available_space,
                .content_size,
                dir.mainAxis(),
                Line(bool).false,
            );
        };

        // Floor flex-basis by the padding_border_sum (floors inner_flex_basis at zero)
        // This seems to be in violation of the spec which explicitly states that the content box should not be floored at zero
        // (like it usually is) when calculating the flex-basis. But including this matches both Chrome and Firefox's behaviour.
        //
        // TODO: resolve spec violation
        // Spec: https://www.w3.org/TR/css-flexbox-1/#intrinsic-item-contributions
        // Spec: https://www.w3.org/TR/css-flexbox-1/#change-2016-max-contribution
        const padding_border_sum = child.padding.mainAxisSum(constants.dir) + child.border.mainAxisSum(constants.dir);
        child.flex_basis = @max(child.flex_basis, padding_border_sum);

        // The hypothetical main size is the item’s flex base size clamped according to its
        // used min and max main sizes (and flooring the content box size at zero).

        child.inner_flex_basis = child.flex_basis - padding_border_sum;

        const padding_border_axes_sums_f32 = child.padding.add(child.border).sumAxes();
        const padding_border_axes_sums: Size(?f32) = .{ .width = padding_border_axes_sums_f32.width, .height = padding_border_axes_sums_f32.height };

        // Note that it is important that the `parent_size` parameter in the main axis is not set for this
        // function call as it used for resolving percentages, and percentage size in an axis should not contribute
        // to a min-content contribution in that same axis. However the `parent_size` and `available_space` *should*
        // be set to their usual values in the cross axis so that wrapping content can wrap correctly.
        //
        // See https://drafts.csswg.org/css-sizing-3/#min-percentage-contribution
        const automatic_min_size: Size(?f32) = .{
            .width = child.overflow.x.maybeIntoAutomaticMinSize(),
            .height = child.overflow.y.maybeIntoAutomaticMinSize(),
        };
        const style_min_main_size = child.min_size.@"or"(automatic_min_size).main(dir);

        child.resolved_minimum_main_size = if (style_min_main_size) |value| value else blk: {
            const min_content_main_size = min_content: {
                const child_available_space = Size(AvailableSpace).min_content.withCross(dir, cross_axis_available_space);

                break :min_content try traits.measureChildSize(
                    tree,
                    child.node,
                    child_known_dimensions,
                    child_parent_size,
                    child_available_space,
                    .content_size,
                    dir.mainAxis(),
                    Line(bool).false,
                );
            };

            // 4.5. Automatic Minimum Size of Flex Items
            // https://www.w3.org/TR/css-flexbox-1/#min-size-auto
            const clamped_min_content_size = maybeMin(maybeMin(min_content_main_size, child.size.main(dir)), transferred_max_size.main(dir));
            break :blk maybeMax(clamped_min_content_size, padding_border_axes_sums.main(dir));
        };

        // Sizes transferred through the aspect ratio clamp the hypothetical main size,
        // but do not participate in resolving flexible lengths or clamping the final size.
        // https://github.com/w3c/csswg-drafts/issues/10997
        const hypothetical_inner_min_main = maybeMax(
            maybeMax(child.resolved_minimum_main_size, transferred_min_size.main(constants.dir)),
            padding_border_axes_sums.main(constants.dir),
        );
        const hypothetical_inner_size = maybeClamp(child.flex_basis, @as(?f32, hypothetical_inner_min_main), transferred_max_size.main(constants.dir));
        const hypothetical_outer_size = hypothetical_inner_size + child.margin.mainAxisSum(constants.dir);

        child.hypothetical_inner_size.setMain(constants.dir, hypothetical_inner_size);
        child.hypothetical_outer_size.setMain(constants.dir, hypothetical_outer_size);
    }
}

/// Collect flex items into flex lines.
///
/// # [9.3. Main Size Determination](https://www.w3.org/TR/css-flexbox-1/#main-sizing)
///
/// - [**Collect flex items into flex lines**](https://www.w3.org/TR/css-flexbox-1/#algo-line-break):
///
///     - If the flex container is single-line, collect all the flex items into a single flex line.
///
///     - Otherwise, starting from the first uncollected item, collect consecutive items one by one until the first time that the next collected item would not fit into the flex container’s inner main size
///       (or until a forced break is encountered, see [§10 Fragmenting Flex Layout](https://www.w3.org/TR/css-flexbox-1/#pagination)).
///       If the very first uncollected item wouldn't fit, collect just it into the line.
///
///       For this step, the size of a flex item is its outer hypothetical main size. (**Note: This can be negative**.)
///
///       Repeat until all flex items have been collected into flex lines.
///
///       **Note that the "collect as many" line will collect zero-sized flex items onto the end of the previous line even if the last non-zero item exactly "filled up" the line**.
fn collectFlexLines(
    gpa: std.mem.Allocator,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem,
) LayoutError!std.ArrayList(FlexLine) {
    var lines: std.ArrayList(FlexLine) = .empty;
    errdefer lines.deinit(gpa);

    // Wrapping into multiple lines requires a definite main size. If the container's known main size
    // is derived from its own content (and is thus indefinite) then all items are collected into a
    // single flex line, matching how the container was sized under a min/max-content constraint.
    if (!constants.is_wrap or !constants.known_main_size_is_definite) {
        try lines.append(gpa, FlexLine.new(flex_items));
        return lines;
    }

    const main_axis_available_space: AvailableSpace = if (constants.max_size.main(constants.dir)) |max_size| blk: {
        var available = available_space.main(constants.dir).intoOption() orelse max_size;
        // If the container's main size is not definite then it is at most the max main size,
        // so the max size (and not the available space) is the limit that items wrap against.
        if (!constants.has_definite_main_size) available = @min(available, max_size);
        break :blk .{ .definite = maybeMax(available, constants.min_size.main(constants.dir)) };
    } else if (!constants.dir.isRow() and
        !constants.has_definite_main_size and
        available_space.main(constants.dir).isDefinite())
        // A column container's automatic main size is content-based, so definite available space
        // handed down by an ancestor does not constrain where its lines wrap. Automatic widths
        // resolve against available space, so rows do wrap against it.
        .max_content
    else
        available_space.main(constants.dir);

    switch (main_axis_available_space) {
        // If we're sizing under a max-content constraint then the flex items will never wrap
        // (at least for now - future extensions to the CSS spec may add provisions for forced wrap points)
        .max_content => {
            try lines.append(gpa, FlexLine.new(flex_items));
        },
        // If flex-wrap is Wrap and we're sizing under a min-content constraint, then we take every possible wrapping opportunity
        // and place each item in it's own line
        .min_content => {
            try lines.ensureTotalCapacity(gpa, flex_items.len);
            for (0..flex_items.len) |i| {
                lines.appendAssumeCapacity(FlexLine.new(flex_items[i .. i + 1]));
            }
        },
        .definite => |main_axis_available_space_value| {
            var items = flex_items;
            const main_axis_gap = constants.gap.main(constants.dir);

            while (items.len > 0) {
                // Find index of the first item in the next line
                // (or the last item if all remaining items are in the current line)
                var line_length: f32 = 0.0;
                var index: usize = items.len;
                for (items, 0..) |*child, idx| {
                    // Gaps only occur between items (not before the first one or after the last one)
                    // So first item in the line does not contribute a gap to the line length
                    const gap_contribution: f32 = if (idx == 0) 0.0 else main_axis_gap;
                    line_length += child.hypothetical_outer_size.main(constants.dir) + gap_contribution;
                    if (line_length > main_axis_available_space_value and idx != 0) {
                        index = idx;
                        break;
                    }
                }

                try lines.append(gpa, FlexLine.new(items[0..index]));
                items = items[index..];
            }
        },
    }
    return lines;
}

/// Collect flex items into balanced flex lines (`flex-wrap: balance`), such that the largest
/// line is as small as possible.
///
/// See <https://drafts.csswg.org/css-flexbox-2/#balance-values>
fn collectBalancedFlexLines(
    gpa: std.mem.Allocator,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem,
) LayoutError!std.ArrayList(FlexLine) {
    var lines: std.ArrayList(FlexLine) = .empty;
    errdefer lines.deinit(gpa);
    if (flex_items.len == 0) {
        return lines;
    }

    // If the container's known main size is derived from its own content (and is thus indefinite)
    // then items are balanced without a size limit, matching how the container was sized under a
    // min/max-content constraint.
    const main_axis_available_space: AvailableSpace = if (constants.known_main_size_is_definite) outer: {
        if (constants.max_size.main(constants.dir)) |max_size| {
            var available = available_space.main(constants.dir).intoOption() orelse max_size;
            // If the container's main size is not definite then it is at most the max main size,
            // so the max size (and not the available space) is the limit that items wrap against.
            if (!constants.has_definite_main_size) available = @min(available, max_size);
            break :outer .{ .definite = maybeMax(available, constants.min_size.main(constants.dir)) };
        } else if (!constants.dir.isRow() and
            !constants.has_definite_main_size and
            available_space.main(constants.dir).isDefinite())
        {
            // A column container's automatic main size is content-based, so definite available space
            // handed down by an ancestor does not constrain where its lines wrap. Automatic widths
            // resolve against available space, so rows do wrap against it.
            break :outer .max_content;
        } else {
            break :outer available_space.main(constants.dir);
        }
    } else .max_content;

    // If we're sizing under a min-content constraint then we take every possible wrapping
    // opportunity and place each item in its own line, the same as greedy wrapping (the
    // min-content main size of a multi-line container is the size of its largest item)
    if (main_axis_available_space == .min_content) {
        try lines.ensureTotalCapacity(gpa, flex_items.len);
        for (0..flex_items.len) |i| {
            lines.appendAssumeCapacity(FlexLine.new(flex_items[i .. i + 1]));
        }
        return lines;
    }

    const line_break_size = main_axis_available_space.intoOption() orelse std.math.inf(f32);
    const min_line_count: usize = constants.line_count orelse 1;
    const item_sizes = try gpa.alloc(f32, flex_items.len);
    defer gpa.free(item_sizes);
    for (flex_items, item_sizes) |*item, *size| size.* = item.hypothetical_outer_size.main(constants.dir);
    const item_counts = try balance.balancedLineItemCounts(
        gpa,
        item_sizes,
        line_break_size,
        constants.gap.main(constants.dir),
        min_line_count,
    );
    defer gpa.free(item_counts);

    try lines.ensureTotalCapacity(gpa, item_counts.len);
    var items = flex_items;
    for (item_counts) |count| {
        lines.appendAssumeCapacity(FlexLine.new(items[0..count]));
        items = items[count..];
    }
    std.debug.assert(items.len == 0);
    return lines;
}

/// Compute whether each of an item's known dimensions should be treated as definite when performing
/// layout on the item. An item's post-flexing main size is only treated as definite if the container
/// has a definite main size or the item's used flex basis is definite.
/// See <https://www.w3.org/TR/css-flexbox-1/#definite-sizes>
inline fn itemKnownDimensionDefiniteness(constants: *const AlgoConstants, item: *const FlexItem) Size(bool) {
    const dir = constants.dir;
    const main_is_definite = constants.has_definite_main_size or item.flex_basis_is_definite;

    // An item's cross size is definite if it is stretched (it stretches to the flex line, whose
    // size is known by the time the item's final layout is performed), or if its cross size style
    // resolved to a definite size. Additionally, a non-stretched item's cross *width* is fit-content
    // sized, and a size resolved by fit-content sizing against definite available space is itself
    // definite (<https://www.w3.org/TR/css-sizing-3/#definite>). The same does not apply to cross
    // heights, which are content-based and therefore indefinite when not stretched.

    const has_cross_auto_margins = item.margin_is_auto.crossStart(dir) or item.margin_is_auto.crossEnd(dir);
    const cross_size = item.size_style.cross(dir);
    const is_stretched = !has_cross_auto_margins and
        (cross_size.isStretch() or (item.align_self == AlignSelf.stretch and cross_size.isAuto()));
    const cross_is_definite = is_stretched or
        item.size.cross(dir) != null or
        (!dir.isRow() and constants.cross_axis_available_space_is_definite);

    return (Size(bool){ .width = true, .height = true }).withMain(dir, main_is_definite).withCross(dir, cross_is_definite);
}

/// The sort key of `value` under `f32::total_cmp` (the total order of IEEE 754)
fn totalCmpKey(value: f32) i32 {
    var bits: i32 = @bitCast(value);
    bits ^= @as(i32, @bitCast(@as(u32, @bitCast(bits >> 31)) >> 1));
    return bits;
}

/// `iter.max_by(|a, b| a.total_cmp(b))`: returns the last maximum element
const TotalCmpMax = struct {
    best: ?f32 = null,

    fn add(self: *TotalCmpMax, value: f32) void {
        if (self.best) |best| {
            if (totalCmpKey(value) >= totalCmpKey(best)) self.best = value;
        } else {
            self.best = value;
        }
    }
};

/// The length of an item for the purposes of determining a container's main size from definite
/// available space
inline fn itemMainLength(child: *const FlexItem, constants: *const AlgoConstants) f32 {
    const padding_border_sum = child.padding.add(child.border).mainAxisSum(constants.dir);
    return @max(maybeMax(child.flex_basis, child.min_size.main(constants.dir)) + child.margin.mainAxisSum(constants.dir), padding_border_sum);
}

/// Determine the container's main size (if not already known)
fn determineContainerMainSize(
    tree: anytype,
    available_space: Size(AvailableSpace),
    lines: []FlexLine,
    constants: *AlgoConstants,
) LayoutError!void {
    const dir = constants.dir;
    const main_content_box_inset = constants.content_box_inset.mainAxisSum(constants.dir);

    const outer_main_size_unclamped: f32 = if (constants.node_outer_size.main(constants.dir)) |size| size else switch (available_space.main(dir)) {
        .definite => |main_axis_available_space| blk: {
            const main_axis_gap = constants.gap.main(constants.dir);
            var longest: TotalCmpMax = .{};
            for (lines) |line| {
                const line_main_axis_gap = sumAxisGaps(main_axis_gap, line.items.len);
                var total_target_size: f32 = -0.0;
                for (line.items) |*child| total_target_size += itemMainLength(child, constants);
                longest.add(total_target_size + line_main_axis_gap);
            }
            const longest_line_length: f32 = longest.best orelse 0.0;
            const size = longest_line_length + main_content_box_inset;

            // A balanced container can produce multiple lines that all fit within the
            // available space (via `flex-line-count`), in which case fit-content sizing
            // uses its max-content size: the longest line when items are balanced across
            // the minimum line count without a size limit.
            if (constants.is_balance) {
                const min_line_count = constants.line_count orelse 1;
                var item_count: usize = 0;
                for (lines) |line| item_count += line.items.len;
                if (item_count == 0) {
                    break :blk size;
                }
                const gpa = tree.allocator();
                const item_lengths = try gpa.alloc(f32, item_count);
                defer gpa.free(item_lengths);
                var fill: usize = 0;
                for (lines) |line| {
                    for (line.items) |*child| {
                        item_lengths[fill] = itemMainLength(child, constants);
                        fill += 1;
                    }
                }
                const item_counts = try balance.balancedLineItemCounts(
                    gpa,
                    item_lengths,
                    std.math.inf(f32),
                    main_axis_gap,
                    @max(min_line_count, 1),
                );
                defer gpa.free(item_counts);
                var widest_line_length: f32 = 0.0;
                var index: usize = 0;
                for (item_counts) |count| {
                    var line_sum: f32 = -0.0;
                    for (item_lengths[index .. index + count]) |length| line_sum += length;
                    const line_length: f32 = line_sum + sumAxisGaps(main_axis_gap, count);
                    widest_line_length = @max(widest_line_length, line_length);
                    index += count;
                }
                const max_content_size = widest_line_length + main_content_box_inset;
                break :blk @max(size, @min(max_content_size, main_axis_available_space));
            }

            if (lines.len > 1) {
                break :blk @max(size, main_axis_available_space);
            } else {
                break :blk size;
            }
        },
        .min_content, .max_content => blk: {
            if (available_space.main(dir) == .min_content and constants.is_wrap) {
                var longest: TotalCmpMax = .{};
                for (lines) |line| {
                    const line_main_axis_gap = sumAxisGaps(constants.gap.main(constants.dir), line.items.len);
                    var total_target_size: f32 = -0.0;
                    for (line.items) |*child| {
                        const padding_border_sum = child.padding.add(child.border).mainAxisSum(constants.dir);
                        total_target_size += @max(
                            maybeMax(child.flex_basis, child.min_size.main(constants.dir)) + child.margin.mainAxisSum(constants.dir),
                            padding_border_sum,
                        );
                    }
                    longest.add(total_target_size + line_main_axis_gap);
                }
                const longest_line_length: f32 = longest.best orelse 0.0;
                break :blk longest_line_length + main_content_box_inset;
            }

            // Define a base main_size variable. This is mutated once for iteration over the outer
            // loop over the flex lines as:
            //   "The flex container’s max-content size is the largest sum of the afore-calculated sizes of all items within a single line."
            var main_size: f32 = 0.0;

            for (lines) |line| {
                for (line.items) |*item| {
                    const style_min = item.min_size.main(constants.dir);
                    const margin_sum = item.margin.mainAxisSum(constants.dir);
                    const style_preferred = item.size.main(constants.dir);
                    const style_max = item.max_size.main(constants.dir);

                    // The spec seems a bit unclear on this point (my initial reading was that the `.maybe_max(style_preferred)` should
                    // not be included here), however for row containers this matches both Chrome and Firefox as of 9th March 2023.
                    // For column containers the flex base size alone is the clamping basis (as the spec says): a column item's
                    // `height` must not inflate the container's max-content size beyond the item's flex-basis.
                    //
                    // Spec: https://www.w3.org/TR/css-flexbox-1/#intrinsic-item-contributions
                    // Spec modification: https://www.w3.org/TR/css-flexbox-1/#change-2016-max-contribution
                    // Issue: https://github.com/w3c/csswg-drafts/issues/1435
                    // Gentest: padding_border_overrides_size_flex_basis_0.html
                    // Gentest: blockflex_min_content_ignores_own_height_as_percentage_basis.html
                    const clamping_basis: ?f32 = if (constants.is_row)
                        maybeMax(@as(?f32, item.flex_basis), style_preferred)
                    else
                        item.flex_basis;
                    const flex_basis_min: ?f32 = if (item.flex_shrink == 0.0) clamping_basis else null;
                    const flex_basis_max: ?f32 = if (item.flex_grow == 0.0) clamping_basis else null;

                    const min_main_size = @max(
                        optOr(maybeMax(style_min, flex_basis_min), flex_basis_min) orelse item.resolved_minimum_main_size,
                        item.resolved_minimum_main_size,
                    );
                    const max_main_size = optOr(maybeMin(style_max, flex_basis_max), flex_basis_max) orelse std.math.inf(f32);

                    const content_contribution: f32 = contribution: {
                        // If the clamping values are such that max <= min, then we can avoid the expensive step of computing the content size
                        // as we know that the clamping values will override it anyway
                        if (style_preferred) |pref| {
                            if (max_main_size <= min_main_size or max_main_size <= pref) {
                                break :contribution @max(@min(pref, max_main_size), min_main_size) + margin_sum;
                            }
                        }
                        if (max_main_size <= min_main_size) {
                            break :contribution min_main_size + margin_sum;
                        }

                        // Else compute the min- or -max content size and apply the full formula for computing the
                        // min- or max- content contribution
                        if (item.isScrollContainer()) {
                            break :contribution item.flex_basis + margin_sum;
                        }

                        // If the item has a definite preferred main size then that is its content
                        // contribution (an inherent-size measure of the item would return it), floored
                        // by the item's main-axis padding+border, so measuring the item can be skipped.
                        // Min/max clamping is applied in the same way as for measured contributions.
                        if (style_preferred) |pref| {
                            const item_pb_main = item.padding.mainAxisSum(constants.dir) + item.border.mainAxisSum(constants.dir);
                            const inner_main_size = @max(pref, item_pb_main);
                            if (constants.is_row) {
                                break :contribution maybeClamp(inner_main_size + margin_sum, style_min, style_max);
                            } else {
                                break :contribution maybeClamp(@max(inner_main_size, item.flex_basis) + margin_sum, style_min, style_max);
                            }
                        }

                        // Parent size for child sizing
                        const cross_axis_parent_size = constants.node_inner_size.cross(dir);

                        // Available space for child sizing (excluding the child's margins)
                        const child_min_cross = item.min_size.cross(dir);
                        const child_max_cross = item.max_size.cross(dir);
                        const unclamped_cross_axis_available_space: AvailableSpace = switch (available_space.cross(dir)) {
                            .definite => |val| .{ .definite = @max(
                                constants.dividedCrossSpace(cross_axis_parent_size orelse val) - item.margin.crossAxisSum(dir),
                                0.0,
                            ) },
                            else => |other| other,
                        };
                        const cross_axis_available_space = maybeClamp(unclamped_cross_axis_available_space, child_min_cross, child_max_cross);

                        const child_available_space = available_space.withCross(dir, cross_axis_available_space);

                        // Known dimensions for child sizing
                        const child_known_dimensions = ckd: {
                            var ckd = item.size.withMain(dir, null);
                            // Clamp the definite cross size by the cross min/max sizes, as
                            // `determineFlexBaseSize` does: an item measured wider than its
                            // max-width wraps onto fewer lines and under-reports its height.
                            const transferred_min_size = item.min_size.maybeApplyAspectRatio(item.aspect_ratio);
                            const transferred_max_size = item.max_size.maybeApplyAspectRatio(item.aspect_ratio);
                            ckd.setCross(dir, maybeClamp(ckd.cross(dir), transferred_min_size.cross(dir), transferred_max_size.cross(dir)));
                            if (item.align_self == AlignSelf.stretch and ckd.cross(dir) == null) {
                                ckd.setCross(dir, cross_axis_available_space.intoOption());
                            }
                            break :ckd ckd;
                        };

                        // Either the min- or max- content size depending on which constraint we are sizing under.
                        // TODO: Optimise by using already computed values where available
                        const measured_main_size = try traits.measureChildSize(
                            tree,
                            item.node,
                            child_known_dimensions,
                            constants.node_inner_size,
                            child_available_space,
                            .content_size,
                            dir.mainAxis(),
                            Line(bool).false,
                        );

                        // A known cross size is transferred through the item's aspect-ratio
                        // and floors the measured content size
                        const transferred_main_size: ?f32 = if (item.aspect_ratio) |ratio|
                            (if (child_known_dimensions.cross(dir)) |cross| (if (constants.is_row) cross * ratio else cross / ratio) else null)
                        else
                            null;

                        const inner_main_size = maybeMax(measured_main_size, transferred_main_size);

                        // This is somewhat bizarre in that it's asymmetrical depending whether the flex container is a column or a row.
                        //
                        // I *think* this might relate to https://drafts.csswg.org/css-flexbox-1/#algo-main-container:
                        //
                        //    "The automatic block size of a block-level flex container is its max-content size."
                        //
                        // Which could suggest that flex-basis defining a vertical size does not shrink because it is in the block axis, and the automatic size
                        // in the block axis is a MAX content size. Whereas a flex-basis defining a horizontal size does shrink because the automatic size in
                        // inline axis is MIN content size (although I don't have a reference for that).
                        //
                        // Ultimately, this was not found by reading the spec, but by trial and error fixing tests to align with Webkit/Firefox output.
                        // (see the `flex_basis_unconstraint_row` and `flex_basis_uncontraint_column` generated tests which demonstrate this)
                        if (constants.is_row) {
                            break :contribution maybeClamp(inner_main_size + margin_sum, style_min, style_max);
                        } else {
                            break :contribution maybeClamp(@max(inner_main_size, item.flex_basis) + margin_sum, style_min, style_max);
                        }
                    };
                    item.content_flex_fraction = fraction: {
                        const diff = content_contribution - margin_sum - item.flex_basis;
                        if (diff > 0.0) {
                            break :fraction diff / @max(1.0, item.flex_grow);
                        } else if (diff < 0.0) {
                            const scaled_shrink_factor = @max(1.0, item.flex_shrink) * item.inner_flex_basis;
                            break :fraction diff / scaled_shrink_factor;
                        } else {
                            // We are assuming that diff is 0.0 here and that we haven't accidentally introduced a NaN
                            break :fraction 0.0;
                        }
                    };
                }

                // TODO Spec says to scale everything by the line's max flex fraction. But neither Chrome nor firefox implement this
                // so we don't either. But if we did want to, we'd need this computation here (and to use it below):
                //
                // Within each line, find the largest max-content flex fraction among all the flex items.

                // Add each item’s flex base size to the product of:
                //   - its flex grow factor (or scaled flex shrink factor,if the chosen max-content flex fraction was negative)
                //   - the chosen max-content flex fraction
                // then clamp that result by the max main size floored by the min main size.
                //
                // The flex container’s max-content size is the largest sum of the afore-calculated sizes of all items within a single line.
                // A wrapping row container is at least as large as its largest item (which matters when another item
                // has a negative margin). This matches Chrome. Firefox does not apply this floor.
                const floor_by_largest_item = constants.is_wrap and constants.is_row;
                var largest_item_size: f32 = 0.0;
                var item_main_size_sum: f32 = -0.0;
                for (line.items) |*item| {
                    const flex_fraction = item.content_flex_fraction;

                    const flex_contribution: f32 = if (item.content_flex_fraction > 0.0)
                        @max(1.0, item.flex_grow) * flex_fraction
                    else if (item.content_flex_fraction < 0.0) inner: {
                        const scaled_shrink_factor = @max(1.0, item.flex_shrink) * item.inner_flex_basis;
                        break :inner if (scaled_shrink_factor == 0.0) 0.0 else scaled_shrink_factor * flex_fraction;
                    } else 0.0;
                    const size = item.flex_basis + flex_contribution + item.margin.mainAxisSum(constants.dir);
                    if (floor_by_largest_item) {
                        largest_item_size = @max(largest_item_size, size);
                    }
                    item_main_size_sum += size;
                }

                const gap_sum = sumAxisGaps(constants.gap.main(constants.dir), line.items.len);
                main_size = @max(main_size, @max(largest_item_size, item_main_size_sum + gap_sum));
            }

            break :blk main_size + main_content_box_inset;
        },
    };

    const outer_main_size = @max(
        maybeClamp(outer_main_size_unclamped, constants.min_size.main(constants.dir), constants.max_size.main(constants.dir)),
        main_content_box_inset - constants.scrollbar_gutter.main(constants.dir),
    );

    const inner_main_size = @max(outer_main_size - main_content_box_inset, 0.0);
    constants.container_size.setMain(constants.dir, outer_main_size);
    constants.inner_container_size.setMain(constants.dir, inner_main_size);
    constants.node_inner_size.setMain(constants.dir, inner_main_size);
}

/// Resolve the flexible lengths of the items within a flex line.
/// Sets the `main` component of each item's `target_size` and `outer_target_size`
///
/// # [9.7. Resolving Flexible Lengths](https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths)
fn resolveFlexibleLengths(line: *FlexLine, constants: *const AlgoConstants) void {
    const dir = constants.dir;
    const total_main_axis_gap = sumAxisGaps(constants.gap.main(dir), line.items.len);

    // 1. Determine the used flex factor. Sum the outer hypothetical main sizes of all
    //    items on the line. If the sum is less than the flex container’s inner main size,
    //    use the flex grow factor for the rest of this algorithm; otherwise, use the
    //    flex shrink factor.

    var total_hypothetical_outer_main_size: f32 = -0.0;
    for (line.items) |*child| total_hypothetical_outer_main_size += child.hypothetical_outer_size.main(dir);
    const used_flex_factor: f32 = total_main_axis_gap + total_hypothetical_outer_main_size;
    const growing = used_flex_factor < (constants.node_inner_size.main(dir) orelse 0.0);
    const shrinking = used_flex_factor > (constants.node_inner_size.main(dir) orelse 0.0);
    const exactly_sized = !growing and !shrinking;

    // 2. Size inflexible items. Freeze, setting its target main size to its hypothetical main size
    //    - Any item that has a flex factor of zero
    //    - If using the flex grow factor: any item that has a flex base size
    //      greater than its hypothetical main size
    //    - If using the flex shrink factor: any item that has a flex base size
    //      smaller than its hypothetical main size

    for (line.items) |*child| {
        const inner_target_size = child.hypothetical_inner_size.main(dir);
        child.target_size.setMain(dir, inner_target_size);

        if (exactly_sized or
            (child.flex_grow == 0.0 and child.flex_shrink == 0.0) or
            (growing and child.flex_basis > child.hypothetical_inner_size.main(dir)) or
            (shrinking and child.flex_basis < child.hypothetical_inner_size.main(dir)))
        {
            child.frozen = true;
            const outer_target_size = inner_target_size + child.margin.mainAxisSum(dir);
            child.outer_target_size.setMain(dir, outer_target_size);
        }
    }

    if (exactly_sized) {
        return;
    }

    // 3. Calculate initial free space. Sum the outer sizes of all items on the line,
    //    and subtract this from the flex container’s inner main size. For frozen items,
    //    use their outer target main size; for other items, use their outer flex base size.

    var items_used_space: f32 = -0.0;
    for (line.items) |*child| {
        items_used_space += if (child.frozen)
            child.outer_target_size.main(dir)
        else
            child.flex_basis + child.margin.mainAxisSum(dir);
    }
    const initial_used_space: f32 = total_main_axis_gap + items_used_space;

    const initial_free_space = maybeSub(constants.node_inner_size.main(dir), initial_used_space) orelse 0.0;

    // 4. Loop

    while (true) {
        // a. Check for flexible items. If all the flex items on the line are frozen,
        //    free space has been distributed; exit this loop.
        //    The space used by the items and the sums of the unfrozen items' flex factors
        //    (both needed for step b) are computed in the same pass.

        var all_frozen = true;
        var items_space: f32 = 0.0;
        var sum_flex_grow: f32 = 0.0;
        var sum_flex_shrink: f32 = 0.0;
        for (line.items) |*child| {
            if (child.frozen) {
                items_space += child.outer_target_size.main(dir);
            } else {
                all_frozen = false;
                items_space += child.flex_basis + child.margin.mainAxisSum(dir);
                sum_flex_grow += child.flex_grow;
                sum_flex_shrink += child.flex_shrink;
            }
        }
        if (all_frozen) {
            break;
        }

        // b. Calculate the remaining free space as for initial free space, above.
        //    If the sum of the unfrozen flex items’ flex factors is less than one,
        //    multiply the initial free space by this sum. If the magnitude of this
        //    value is less than the magnitude of the remaining free space, use this
        //    as the remaining free space.

        const used_space: f32 = total_main_axis_gap + items_space;

        const free_space: f32 = if (growing and sum_flex_grow < 1.0)
            maybeMin(initial_free_space * sum_flex_grow - total_main_axis_gap, maybeSub(constants.node_inner_size.main(dir), used_space))
        else if (shrinking and sum_flex_shrink < 1.0)
            maybeMax(initial_free_space * sum_flex_shrink - total_main_axis_gap, maybeSub(constants.node_inner_size.main(dir), used_space))
        else
            maybeSub(constants.node_inner_size.main(dir), used_space) orelse (used_flex_factor - used_space);

        // c. Distribute free space proportional to the flex factors.
        //    - If the remaining free space is zero
        //        Do Nothing
        //    - If using the flex grow factor
        //        Find the ratio of the item’s flex grow factor to the sum of the
        //        flex grow factors of all unfrozen items on the line. Set the item’s
        //        target main size to its flex base size plus a fraction of the remaining
        //        free space proportional to the ratio.
        //    - If using the flex shrink factor
        //        For every unfrozen item on the line, multiply its flex shrink factor by
        //        its inner flex base size, and note this as its scaled flex shrink factor.
        //        Find the ratio of the item’s scaled flex shrink factor to the sum of the
        //        scaled flex shrink factors of all unfrozen items on the line. Set the item’s
        //        target main size to its flex base size minus a fraction of the absolute value
        //        of the remaining free space proportional to the ratio. Note this may result
        //        in a negative inner main size; it will be corrected in the next step.
        //    - Otherwise
        //        Do Nothing

        if (std.math.isNormal(free_space)) {
            if (growing and sum_flex_grow > 0.0) {
                for (line.items) |*child| {
                    if (child.frozen) continue;
                    child.target_size.setMain(dir, child.flex_basis + free_space * (child.flex_grow / sum_flex_grow));
                }
            } else if (shrinking and sum_flex_shrink > 0.0) {
                var sum_scaled_shrink_factor: f32 = -0.0;
                for (line.items) |*child| {
                    if (child.frozen) continue;
                    sum_scaled_shrink_factor += child.inner_flex_basis * child.flex_shrink;
                }

                if (sum_scaled_shrink_factor > 0.0) {
                    for (line.items) |*child| {
                        if (child.frozen) continue;
                        const scaled_shrink_factor = child.inner_flex_basis * child.flex_shrink;
                        child.target_size.setMain(dir, child.flex_basis + free_space * (scaled_shrink_factor / sum_scaled_shrink_factor));
                    }
                }
            }
        }

        // d. Fix min/max violations. Clamp each non-frozen item’s target main size by its
        //    used min and max main sizes and floor its content-box size at zero. If the
        //    item’s target main size was made smaller by this, it’s a max violation.
        //    If the item’s target main size was made larger by this, it’s a min violation.

        var total_violation: f32 = 0.0;
        for (line.items) |*child| {
            if (child.frozen) continue;
            const resolved_min_main: ?f32 = child.resolved_minimum_main_size;
            const max_main = child.max_size.main(dir);
            const clamped = @max(maybeClamp(child.target_size.main(dir), resolved_min_main, max_main), 0.0);
            child.violation = clamped - child.target_size.main(dir);
            child.target_size.setMain(dir, clamped);
            child.outer_target_size.setMain(dir, child.target_size.main(dir) + child.margin.mainAxisSum(dir));

            total_violation = total_violation + child.violation;
        }

        // e. Freeze over-flexed items. The total violation is the sum of the adjustments
        //    from the previous step ∑(clamped size - unclamped size). If the total violation is:
        //    - Zero
        //        Freeze all items.
        //    - Positive
        //        Freeze all the items with min violations.
        //    - Negative
        //        Freeze all the items with max violations.

        for (line.items) |*child| {
            if (child.frozen) continue;
            if (total_violation > 0.0) {
                child.frozen = child.violation > 0.0;
            } else if (total_violation < 0.0) {
                child.frozen = child.violation < 0.0;
            } else {
                child.frozen = true;
            }
        }

        // f. Return to the start of this loop.
    }
}

/// Determine the hypothetical cross size of each item.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Determine the hypothetical cross size of each item**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-item)
///   by performing layout with the used main size and the available space, treating auto as fit-content.
fn determineHypotheticalCrossSize(
    tree: anytype,
    line: *FlexLine,
    constants: *const AlgoConstants,
    node_size: Size(?f32),
    available_space: Size(AvailableSpace),
) LayoutError!void {
    const gpa = tree.allocator();
    const dir = constants.dir;
    // If the flex container is single-line and has a definite cross size then that is the cross size of the
    // line, whatever the hypothetical cross sizes of the items are
    const line_cross_size_is_known = !constants.is_wrap and node_size.cross(dir) != null;

    for (line.items) |*child| {
        const padding_border_sum = child.padding.add(child.border).crossAxisSum(dir);

        // An item that will be stretched to a line whose cross size is already known is not measured: its
        // hypothetical cross size would be used neither for the line nor for the item
        // (see `calculateCrossSize` and `determineUsedCrossSize`)
        if (line_cross_size_is_known and
            child.isStretched(dir) and
            !child.participatesInBaselineAlignment(dir))
        {
            continue;
        }

        // The available space passed to the child excludes the child's margins
        const child_available_main: AvailableSpace = .{ .definite = @max(constants.container_size.main(dir) - child.margin.mainAxisSum(dir), 0.0) };

        // Sizes transferred through the aspect ratio clamp the hypothetical cross size
        // https://github.com/w3c/csswg-drafts/issues/10997
        const transferred_min_cross = child.min_size.maybeApplyAspectRatio(child.aspect_ratio).cross(dir);
        const transferred_max_cross = child.max_size.maybeApplyAspectRatio(child.aspect_ratio).cross(dir);

        const child_cross = maybeMax(maybeClamp(child.size.cross(dir), transferred_min_cross, transferred_max_cross), padding_border_sum);

        const unclamped_child_available_cross: AvailableSpace = switch (available_space.cross(dir)) {
            .definite => |val| .{ .definite = @max(constants.dividedCrossSpace(val) - child.margin.crossAxisSum(dir), 0.0) },
            else => |other| other,
        };
        const default_child_available_cross = maybeMax(
            maybeClamp(unclamped_child_available_cross, transferred_min_cross, transferred_max_cross),
            padding_border_sum,
        );

        // A cross size that is a sizing keyword (min-content, max-content, fit-content,
        // fit-content(...)) determines the available space constraint the item is measured under.
        // The `stretch` keyword is not resolved here: it stretches to the flex line, which is
        // handled in `determineUsedCrossSize`
        const node_inner_cross: ?f32 = constants.node_inner_size.cross(dir);
        const cross_stretch_size = maybeMax(
            maybeSub(if (node_inner_cross) |val| constants.dividedCrossSpace(val) else null, child.margin.crossAxisSum(dir)),
            @as(f32, 0.0),
        );
        const child_available_cross: AvailableSpace = blk: {
            if (resolveSizingKeyword(child.size_style.cross(dir), cross_stretch_size, node_inner_cross, tree)) |resolution| {
                switch (resolution) {
                    .measure => |available| break :blk available,
                    else => {},
                }
            }
            break :blk default_child_available_cross;
        };

        const child_inner_cross: f32 = if (child_cross) |cross| cross else blk: {
            var output = try tree.computeChildLayout(child.node, .{
                .run_mode = .compute_size,
                .sizing_mode = .content_size,
                .axis = layout.RequestedAxis.fromAbsoluteAxis(dir.crossAxis()),
                .known_dimensions = .{
                    .width = if (constants.is_row) child.target_size.width else child_cross,
                    .height = if (constants.is_row) child_cross else child.target_size.height,
                },
                .known_dimensions_are_definite = itemKnownDimensionDefiniteness(constants, child),
                .parent_size = constants.node_inner_size,
                .available_space = .{
                    .width = if (constants.is_row) child_available_main else child_available_cross,
                    .height = if (constants.is_row) child_available_cross else child_available_main,
                },
                .vertical_margins_are_collapsible = Line(bool).false,
            });
            defer output.deinit(gpa);
            break :blk @max(maybeClamp(output.size.getAbs(dir.crossAxis()), transferred_min_cross, transferred_max_cross), padding_border_sum);
        };
        const child_outer_cross = child_inner_cross + child.margin.crossAxisSum(dir);

        child.hypothetical_inner_size.setCross(dir, child_inner_cross);
        child.hypothetical_outer_size.setCross(dir, child_outer_cross);
    }
}

/// Calculate the base lines of the children.
fn calculateChildrenBaseLines(
    tree: anytype,
    node_size: Size(?f32),
    available_space: Size(AvailableSpace),
    flex_lines: []FlexLine,
    constants: *const AlgoConstants,
) LayoutError!void {
    const gpa = tree.allocator();
    // Only compute baselines for flex rows because we only support baseline alignment in the cross axis
    // where that axis is also the inline axis
    // TODO: this may need revisiting if/when we support vertical writing modes
    if (!constants.is_row) {
        return;
    }

    for (flex_lines) |*line| {
        // If a flex line has one or zero items participating in baseline alignment then baseline alignment is a no-op so we skip
        var line_baseline_child_count: usize = 0;
        for (line.items) |*child| {
            if (child.participatesInBaselineAlignment(constants.dir)) line_baseline_child_count += 1;
        }
        if (line_baseline_child_count <= 1) {
            continue;
        }

        for (line.items) |*child| {
            // Only calculate baselines for children participating in baseline alignment
            if (!child.participatesInBaselineAlignment(constants.dir)) {
                continue;
            }

            const unclamped_available_space: Size(AvailableSpace) = .{
                .width = if (constants.is_row)
                    AvailableSpace.fromF32(constants.container_size.width)
                else
                    available_space.width.maybeSet(node_size.width),
                .height = if (constants.is_row)
                    available_space.height.maybeSet(node_size.height)
                else
                    AvailableSpace.fromF32(constants.container_size.height),
            };
            var measured_size_and_baselines = try tree.computeChildLayout(child.node, .{
                .run_mode = .perform_layout,
                .sizing_mode = .content_size,
                .axis = .both,
                .known_dimensions = .{
                    .width = if (constants.is_row) child.target_size.width else child.hypothetical_inner_size.width,
                    .height = if (constants.is_row) child.hypothetical_inner_size.height else child.target_size.height,
                },
                .known_dimensions_are_definite = itemKnownDimensionDefiniteness(constants, child),
                .parent_size = constants.node_inner_size,
                // The available space passed to the child excludes the child's margins
                .available_space = maybeMax(maybeSub(unclamped_available_space, child.margin.sumAxes()), Size(f32).zero),
                .vertical_margins_are_collapsible = Line(bool).false,
            });
            defer measured_size_and_baselines.deinit(gpa);

            const height = measured_size_and_baselines.size.height;
            const baseline = childFirstBaseline(measured_size_and_baselines.baselines.first, height, child.overflow.y) orelse height;

            child.baseline = baseline + child.margin.top;
        }
    }
}

/// Calculate the cross size of each flex line.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Calculate the cross size of each flex line**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-line).
fn calculateCrossSize(flex_lines: []FlexLine, node_size: Size(?f32), constants: *const AlgoConstants) void {
    const dir = constants.dir;
    // If the flex container is single-line and has a definite cross size,
    // the cross size of the flex line is the flex container’s inner cross size.
    if (!constants.is_wrap and node_size.cross(dir) != null) {
        const cross_axis_padding_border = constants.content_box_inset.crossAxisSum(dir);
        const cross_min_size = constants.min_size.cross(dir);
        const cross_max_size = constants.max_size.cross(dir);
        flex_lines[0].cross_size = maybeMax(
            maybeSub(maybeClamp(node_size.cross(dir), cross_min_size, cross_max_size), cross_axis_padding_border),
            @as(f32, 0.0),
        ) orelse 0.0;
    } else {
        // Otherwise, for each flex line:
        //
        //    1. Collect all the flex items whose inline-axis is parallel to the main-axis, whose
        //       align-self is baseline, and whose cross-axis margins are both non-auto. Find the
        //       largest of the distances between each item’s baseline and its hypothetical outer
        //       cross-start edge, and the largest of the distances between each item’s baseline
        //       and its hypothetical outer cross-end edge, and sum these two values.

        //    2. Among all the items not collected by the previous step, find the largest
        //       outer hypothetical cross size.

        //    3. The used cross-size of the flex line is the largest of the numbers found in the
        //       previous two steps and zero.
        for (flex_lines) |*line| {
            var max_baseline: f32 = 0.0;
            for (line.items) |*child| max_baseline = @max(max_baseline, child.baseline);
            var cross_size: f32 = 0.0;
            for (line.items) |*child| {
                const value = if (child.participatesInBaselineAlignment(dir))
                    max_baseline - child.baseline + child.hypothetical_outer_size.cross(dir)
                else
                    child.hypothetical_outer_size.cross(dir);
                cross_size = @max(cross_size, value);
            }
            line.cross_size = cross_size;
        }

        // If the flex container is single-line, then clamp the line’s cross-size to be within the container’s computed min and max cross sizes.
        // Note that if CSS 2.1’s definition of min/max-width/height applied more generally, this behavior would fall out automatically.
        if (!constants.is_wrap) {
            const cross_axis_padding_border = constants.content_box_inset.crossAxisSum(dir);
            const cross_min_size = constants.min_size.cross(dir);
            const cross_max_size = constants.max_size.cross(dir);
            flex_lines[0].cross_size = maybeClamp(
                flex_lines[0].cross_size,
                maybeSub(cross_min_size, cross_axis_padding_border),
                maybeSub(cross_max_size, cross_axis_padding_border),
            );
        }
    }
}

/// Handle 'align-content: stretch'.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Handle 'align-content: stretch'**](https://www.w3.org/TR/css-flexbox-1/#algo-line-stretch). If the flex container has a definite cross size, align-content is stretch,
///   and the sum of the flex lines' cross sizes is less than the flex container’s inner cross size,
///   increase the cross size of each flex line by equal amounts such that the sum of their cross sizes exactly equals the flex container’s inner cross size.
fn handleAlignContentStretch(flex_lines: []FlexLine, node_size: Size(?f32), constants: *const AlgoConstants) void {
    const dir = constants.dir;
    if (constants.align_content == AlignContent.stretch) {
        const cross_axis_padding_border = constants.content_box_inset.crossAxisSum(dir);
        const cross_min_size = constants.min_size.cross(dir);
        const cross_max_size = constants.max_size.cross(dir);
        const container_min_inner_cross = maybeMax(
            maybeSub(maybeClamp(optOr(node_size.cross(dir), cross_min_size), cross_min_size, cross_max_size), cross_axis_padding_border),
            @as(f32, 0.0),
        ) orelse 0.0;

        const total_cross_axis_gap = sumAxisGaps(constants.gap.cross(dir), flex_lines.len);
        var lines_cross_sum: f32 = -0.0;
        for (flex_lines) |line| lines_cross_sum += line.cross_size;
        const lines_total_cross: f32 = lines_cross_sum + total_cross_axis_gap;

        if (lines_total_cross < container_min_inner_cross) {
            const remaining = container_min_inner_cross - lines_total_cross;
            const addition = remaining / @as(f32, @floatFromInt(flex_lines.len));
            for (flex_lines) |*line| line.cross_size += addition;
        }
    }
}

/// Determine the used cross size of each flex item.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Determine the used cross size of each flex item**](https://www.w3.org/TR/css-flexbox-1/#algo-stretch). If a flex item has align-self: stretch, its computed cross size property is auto,
///   and neither of its cross-axis margins are auto, the used outer cross size is the used cross size of its flex line, clamped according to the item’s used min and max cross sizes.
///   Otherwise, the used cross size is the item’s hypothetical cross size.
///
///   If the flex item has align-self: stretch, redo layout for its contents, treating this used size as its definite cross size so that percentage-sized children can be resolved.
///
///   **Note that this step does not affect the main size of the flex item, even if it has an intrinsic aspect ratio**.
fn determineUsedCrossSize(tree: anytype, flex_lines: []FlexLine, constants: *const AlgoConstants) void {
    const dir = constants.dir;
    for (flex_lines) |*line| {
        const line_cross_size = line.cross_size;

        for (line.items) |*child| {
            const child_style = tree.getFlexboxChildStyle(child.node);
            // A cross size of `stretch` stretches to the flex line like align-self: stretch
            // (but regardless of the alignment style)
            child.target_size.setCross(dir, if (child.isStretched(dir)) blk: {
                // For some reason this particular usage of max_width is an exception to the rule that max_width's transfer
                // using the aspect_ratio (if set). Both Chrome and Firefox agree on this. And reading the spec, it seems like
                // a reasonable interpretation. Although it seems to me that the spec *should* apply aspect_ratio here.
                // Percentage padding and border resolve against the container's inline size
                // (its width) on all four sides, not against its height for the top/bottom sides
                const box_sizing_adjustment = child.boxSizingAdjustment(child_style);

                const max_size_ignoring_aspect_ratio = maybeAdd(maybeResolve(child_style.getMaxSize(), constants.node_inner_size, tree), box_sizing_adjustment);

                break :blk maybeClamp(
                    @max(line_cross_size - child.margin.crossAxisSum(dir), 0.0),
                    child.min_size.cross(dir),
                    max_size_ignoring_aspect_ratio.cross(dir),
                );
            } else child.hypothetical_inner_size.cross(dir));

            child.outer_target_size.setCross(dir, child.target_size.cross(dir) + child.margin.crossAxisSum(dir));
        }
    }
}

/// Distribute any remaining free space.
///
/// # [9.5. Main-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#main-alignment)
///
/// - [**Distribute any remaining free space**](https://www.w3.org/TR/css-flexbox-1/#algo-main-align). For each flex line:
///
///   1. If the remaining free space is positive and at least one main-axis margin on this line is `auto`, distribute the free space equally among these margins.
///      Otherwise, set all `auto` margins to zero.
///
///   2. Align the items along the main-axis per `justify-content`.
fn distributeRemainingFreeSpace(flex_lines: []FlexLine, constants: *const AlgoConstants) void {
    const dir = constants.dir;
    for (flex_lines) |*line| {
        const total_main_axis_gap = sumAxisGaps(constants.gap.main(dir), line.items.len);
        var items_used_space: f32 = -0.0;
        for (line.items) |*child| items_used_space += child.outer_target_size.main(dir);
        const used_space: f32 = total_main_axis_gap + items_used_space;
        var free_space = constants.inner_container_size.main(dir) - used_space;
        var num_auto_margins: usize = 0;

        for (line.items) |*child| {
            if (child.margin_is_auto.mainStart(dir)) {
                num_auto_margins += 1;
            }
            if (child.margin_is_auto.mainEnd(dir)) {
                num_auto_margins += 1;
            }
        }

        if (free_space > 0.0 and num_auto_margins > 0) {
            const margin = free_space / @as(f32, @floatFromInt(num_auto_margins));

            for (line.items) |*child| {
                if (child.margin_is_auto.mainStart(dir)) {
                    if (constants.is_row) {
                        child.margin.left = margin;
                    } else {
                        child.margin.top = margin;
                    }
                }
                if (child.margin_is_auto.mainEnd(dir)) {
                    if (constants.is_row) {
                        child.margin.right = margin;
                    } else {
                        child.margin.bottom = margin;
                    }
                }
            }

            // The auto margins have absorbed all of the free space, leaving none for `justify-content`
            free_space = 0.0;
        }

        const num_items = line.items.len;
        const layout_reverse = dir.isReverse();
        const gap = constants.gap.main(dir);
        const justify_content_mode = applyAlignmentFallback(free_space, num_items, constants.justify_content);

        for (0..num_items) |i| {
            const child = if (layout_reverse) &line.items[num_items - 1 - i] else &line.items[i];
            child.offset_main = computeAlignmentOffset(free_space, num_items, gap, justify_content_mode, layout_reverse, i == 0);
        }
    }
}

/// Resolve cross-axis `auto` margins.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Resolve cross-axis `auto` margins**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-margins).
///   If a flex item has auto cross-axis margins:
///
///   - If its outer cross size (treating those auto margins as zero) is less than the cross size of its flex line,
///     distribute the difference in those sizes equally to the auto margins.
///
///   - Otherwise, if the block-start or inline-start margin (whichever is in the cross axis) is auto, set it to zero.
///     Set the opposite margin so that the outer cross size of the item equals the cross size of its flex line.
fn resolveCrossAxisAutoMargins(flex_lines: []FlexLine, constants: *const AlgoConstants) void {
    const dir = constants.dir;
    for (flex_lines) |*line| {
        const line_cross_size = line.cross_size;
        var max_baseline: f32 = 0.0;
        for (line.items) |*child| max_baseline = @max(max_baseline, child.baseline);
        var max_baseline_to_bottom_distance: f32 = 0.0;
        for (line.items) |*child| {
            if (!child.participatesInBaselineAlignment(dir)) continue;
            max_baseline_to_bottom_distance = @max(max_baseline_to_bottom_distance, child.outer_target_size.cross(dir) - child.baseline);
        }

        for (line.items) |*child| {
            const free_space = line_cross_size - child.outer_target_size.cross(dir);

            if (child.margin_is_auto.crossStart(dir) and child.margin_is_auto.crossEnd(dir)) {
                if (constants.is_row) {
                    child.margin.top = free_space / 2.0;
                    child.margin.bottom = free_space / 2.0;
                } else {
                    child.margin.left = free_space / 2.0;
                    child.margin.right = free_space / 2.0;
                }
            } else if (child.margin_is_auto.crossStart(dir)) {
                if (constants.is_row) {
                    child.margin.top = free_space;
                } else {
                    child.margin.left = free_space;
                }
            } else if (child.margin_is_auto.crossEnd(dir)) {
                if (constants.is_row) {
                    child.margin.bottom = free_space;
                } else {
                    child.margin.right = free_space;
                }
            } else {
                // 14. Align all flex items along the cross-axis.
                child.offset_cross = alignFlexItemsAlongCrossAxis(
                    child,
                    free_space,
                    max_baseline,
                    max_baseline_to_bottom_distance,
                    constants,
                );
            }
        }
    }
}

/// Align all flex items along the cross-axis.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Align all flex items along the cross-axis**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-align) per `align-self`,
///   if neither of the item's cross-axis margins are `auto`.
fn alignFlexItemsAlongCrossAxis(
    child: *const FlexItem,
    free_space: f32,
    max_baseline: f32,
    max_baseline_to_bottom_distance: f32,
    constants: *const AlgoConstants,
) f32 {
    const cross_axis_should_reverse = constants.is_column and constants.layout_direction == .rtl;

    // If align-self uses a "safe" overflow-position keyword and the item would overflow its
    // line cross size, fall back to logical Start to avoid data loss. See CSS Box Alignment 3
    // §4.3 <https://www.w3.org/TR/css-align-3/#overflow-values>. Otherwise, drop the safety
    // field so the switch below operates on a bare keyword.
    const align_keyword: AlignItemsKeyword = if (child.align_self.isSafe() and free_space < 0.0)
        .start
    else
        child.align_self.keyword;

    return switch (align_keyword) {
        .start => if (cross_axis_should_reverse) free_space else 0.0,
        .flex_start => if (constants.is_wrap_reverse != cross_axis_should_reverse) free_space else 0.0,
        .end => if (cross_axis_should_reverse) 0.0 else free_space,
        .flex_end => if (constants.is_wrap_reverse != cross_axis_should_reverse) 0.0 else free_space,
        .center => free_space / 2.0,
        .baseline => blk: {
            if (constants.is_row) {
                if (constants.is_wrap_reverse) {
                    // In a wrap-reverse container the cross axis is flipped, so the baseline-aligned
                    // group of items is aligned to the cross-start edge, which is the bottom of the line.
                    const line_cross_size = free_space + child.outer_target_size.cross(constants.dir);
                    break :blk line_cross_size - max_baseline_to_bottom_distance - child.baseline;
                } else {
                    break :blk max_baseline - child.baseline;
                }
            } else {
                // Until we support vertical writing modes, baseline alignment only makes sense if
                // the constants.direction is row, so we treat it as flex-start alignment in columns.
                const baseline_column_should_reverse = cross_axis_should_reverse and !constants.is_wrap;
                break :blk if (constants.is_wrap_reverse != baseline_column_should_reverse) free_space else 0.0;
            }
        },
        .stretch => if (constants.is_wrap_reverse != cross_axis_should_reverse) free_space else 0.0,
        // Normal is resolved to Stretch, and SelfStart/SelfEnd are resolved to Start/End
        // against the item's own direction when flex items are generated.
        .normal, .self_start, .self_end => unreachable,
    };
}

/// Determine the flex container’s used cross size.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Determine the flex container’s used cross size**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-container):
///
///     - If the cross size property is a definite size, use that, clamped by the used min and max cross sizes of the flex container.
///
///     - Otherwise, use the sum of the flex lines' cross sizes, clamped by the used min and max cross sizes of the flex container.
fn determineContainerCrossSize(
    flex_lines: []const FlexLine,
    node_size: Size(?f32),
    constants: *AlgoConstants,
) f32 {
    const dir = constants.dir;
    const total_cross_axis_gap = sumAxisGaps(constants.gap.cross(dir), flex_lines.len);
    var total_line_cross_size: f32 = -0.0;
    for (flex_lines) |line| total_line_cross_size += line.cross_size;

    const padding_border_sum = constants.content_box_inset.crossAxisSum(dir);
    const cross_scrollbar_gutter = constants.scrollbar_gutter.cross(dir);
    const min_cross_size = constants.min_size.cross(dir);
    const max_cross_size = constants.max_size.cross(dir);
    const outer_container_size = @max(
        maybeClamp(
            node_size.cross(dir) orelse (total_line_cross_size + total_cross_axis_gap + padding_border_sum),
            min_cross_size,
            max_cross_size,
        ),
        padding_border_sum - cross_scrollbar_gutter,
    );
    const inner_container_size = @max(outer_container_size - padding_border_sum, 0.0);

    constants.container_size.setCross(dir, outer_container_size);
    constants.inner_container_size.setCross(dir, inner_container_size);

    return total_line_cross_size;
}

/// Align all flex lines per `align-content`.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Align all flex lines**](https://www.w3.org/TR/css-flexbox-1/#algo-line-align) per `align-content`.
fn alignFlexLinesPerAlignContent(flex_lines: []FlexLine, constants: *const AlgoConstants, total_cross_size: f32) void {
    const num_lines = flex_lines.len;
    const gap = constants.gap.cross(constants.dir);
    const total_cross_axis_gap = sumAxisGaps(gap, num_lines);
    const free_space = constants.inner_container_size.cross(constants.dir) - total_cross_size - total_cross_axis_gap;

    const align_content_mode = applyAlignmentFallback(free_space, num_lines, constants.align_content);

    for (0..num_lines) |i| {
        const line = if (constants.is_wrap_reverse) &flex_lines[num_lines - 1 - i] else &flex_lines[i];
        line.offset_cross = computeAlignmentOffset(free_space, num_lines, gap, align_content_mode, constants.is_wrap_reverse, i == 0);
    }
}

/// Calculates the layout for a flex-item
fn calculateFlexItem(
    tree: anytype,
    item: *FlexItem,
    total_offset_main: *f32,
    total_offset_cross: f32,
    line_offset_cross: f32,
    total_overflow_rect: *Rect(f32),
    overflow_container: *const ScrollableOverflowContainer,
    constants: *const AlgoConstants,
) LayoutError!void {
    const gpa = tree.allocator();
    const container_size = constants.container_size;
    const node_inner_size = constants.node_inner_size;
    const direction = constants.dir;
    const layout_direction = constants.layout_direction;
    const item_known_dimension_definiteness = itemKnownDimensionDefiniteness(constants, item);
    var layout_output = try tree.computeChildLayout(item.node, .{
        .run_mode = .perform_layout,
        .sizing_mode = .content_size,
        .axis = .both,
        .known_dimensions = .{ .width = item.target_size.width, .height = item.target_size.height },
        .known_dimensions_are_definite = item_known_dimension_definiteness,
        .parent_size = node_inner_size,
        // The available space passed to the child excludes the child's margins
        .available_space = .{
            .width = .{ .definite = @max(container_size.width - item.margin.horizontalAxisSum(), 0.0) },
            .height = .{ .definite = @max(container_size.height - item.margin.verticalAxisSum(), 0.0) },
        },
        .vertical_margins_are_collapsible = Line(bool).false,
    });
    defer layout_output.deinit(gpa);
    const size = layout_output.size;
    const scrollable_overflow_rect = layout_output.scrollable_overflow_rect;

    const is_rtl_row = direction.isRow() and layout_direction.isRtl();
    const is_rtl_column = direction.isColumn() and layout_direction.isRtl();
    const main_relative_inset = item.relative_inset.main(direction);
    const cross_relative_inset = item.relative_inset.cross(direction);
    const effective_line_offset_cross: f32 = if (is_rtl_column) 0.0 else line_offset_cross;

    const offset_main = if (is_rtl_row)
        total_offset_main.* - item.offset_main - item.margin.mainEnd(direction) - main_relative_inset - size.width
    else
        total_offset_main.* + item.offset_main + item.margin.mainStart(direction) + main_relative_inset;

    const offset_cross = total_offset_cross +
        item.offset_cross +
        effective_line_offset_cross +
        item.margin.crossStart(direction) +
        cross_relative_inset;

    const inner_baseline = childFirstBaseline(layout_output.baselines.first, size.height, item.overflow.y) orelse size.height;
    if (direction.isRow()) {
        const baseline_offset_cross = total_offset_cross + item.offset_cross + effective_line_offset_cross + item.margin.crossStart(direction);
        item.baseline = baseline_offset_cross + inner_baseline;
    } else {
        const baseline_offset_main = total_offset_main.* + item.offset_main + item.margin.mainStart(direction);
        item.baseline = baseline_offset_main + inner_baseline;
    }

    const location: Point(f32) = if (direction.isRow())
        .{ .x = offset_main, .y = offset_cross }
    else
        .{ .x = offset_cross, .y = offset_main };
    const scrollbar_size: Size(f32) = .{
        .width = if (item.overflow.y == .scroll) item.scrollbar_width else 0.0,
        .height = if (item.overflow.x == .scroll) item.scrollbar_width else 0.0,
    };

    tree.setUnroundedLayout(item.node, &.{
        .order = item.order,
        .size = size,
        .scrollable_overflow_rect = scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .location = location,
        .padding = item.padding,
        .border = item.border,
        .margin = item.margin,
    });

    // Keep out-of-flow candidates from the item's subtree, translating anchors from
    // item-relative to container-relative coordinates
    item.oof_candidates.deinit(gpa);
    item.oof_candidates = layout_output.oof_candidates.take();
    if (!item.oof_candidates.isEmpty()) {
        item.oof_candidates.translate(location);
    }

    if (is_rtl_row) {
        total_offset_main.* -= item.offset_main + item.margin.mainAxisSum(direction) + size.main(direction);
    } else {
        total_offset_main.* += item.offset_main + item.margin.mainAxisSum(direction) + size.main(direction);
    }

    {
        const contribution_location: Point(f32) = .{
            .x = location.x - constants.padding_box_inset.left,
            .y = location.y - constants.padding_box_inset.top,
        };
        const contribution = computeScrollableOverflowContribution(
            contribution_location,
            size,
            scrollable_overflow_rect.rect(),
            item.border,
            item.overflow,
            item.contain,
            overflow_container,
            item.margin,
        );
        total_overflow_rect.* = total_overflow_rect.@"union"(contribution);
    }
}

/// Calculates the layout line
fn calculateLayoutLine(
    tree: anytype,
    line: *FlexLine,
    total_offset_cross: *f32,
    overflow_rect: *Rect(f32),
    overflow_container: *const ScrollableOverflowContainer,
    constants: *const AlgoConstants,
) LayoutError!void {
    const container_size = constants.container_size;
    const padding_border = constants.content_box_inset;
    const direction = constants.dir;
    const layout_direction = constants.layout_direction;
    var total_offset_main = if (layout_direction.isRtl() and direction.isRow())
        container_size.width - padding_border.mainEnd(direction)
    else
        padding_border.mainStart(direction);
    const line_offset_cross = line.offset_cross;

    const is_rtl_column = layout_direction.isRtl() and direction.isColumn();
    if (is_rtl_column) {
        total_offset_cross.* -= line_offset_cross + line.cross_size;
    }

    const item_count = line.items.len;
    for (0..item_count) |i| {
        const item = if (direction.isReverse()) &line.items[item_count - 1 - i] else &line.items[i];
        try calculateFlexItem(
            tree,
            item,
            &total_offset_main,
            total_offset_cross.*,
            line_offset_cross,
            overflow_rect,
            overflow_container,
            constants,
        );
    }

    if (!is_rtl_column) {
        total_offset_cross.* += line_offset_cross + line.cross_size;
    }
}

/// Do a final layout pass and collect the resulting layouts.
fn finalLayoutPass(tree: anytype, flex_lines: []FlexLine, constants: *const AlgoConstants) LayoutError!Rect(f32) {
    const overflow_container: ScrollableOverflowContainer = .{
        .parent_is_scroll_container = constants.is_scroll_container,
        .parent_size = constants.container_size
            .sub(constants.border.sumAxes())
            .sub(.{ .width = constants.scrollbar_gutter.x, .height = constants.scrollbar_gutter.y }),
        .reversed = constants.scrollOriginReversed(),
        .padding = constants.padding,
    };
    var total_offset_cross = if (constants.is_column and constants.layout_direction.isRtl())
        constants.container_size.width - constants.content_box_inset.crossEnd(constants.dir)
    else
        constants.content_box_inset.crossStart(constants.dir);

    var overflow_rect = Rect(f32).zero;

    const line_count = flex_lines.len;
    for (0..line_count) |i| {
        const line = if (constants.is_wrap_reverse) &flex_lines[line_count - 1 - i] else &flex_lines[i];
        try calculateLayoutLine(tree, line, &total_offset_cross, &overflow_rect, &overflow_container, constants);
    }

    if (constants.layout_direction.isRtl()) {
        const client_width = @max(constants.container_size.width - constants.border.horizontalAxisSum() - constants.scrollbar_gutter.x, 0.0);
        var rtl_rect = Rect(f32).zero;
        rtl_rect.right = client_width;
        overflow_rect = overflow_rect.@"union"(rtl_rect);
    }

    if (constants.is_scroll_container) {
        const client_width = @max(constants.container_size.width - constants.border.horizontalAxisSum() - constants.scrollbar_gutter.x, 0.0);
        overflow_rect = overflow_rect.@"union"(.{
            .left = if (constants.layout_direction.isRtl())
                @min(client_width - (constants.content_box_inset.left - constants.border.left - constants.scrollbar_gutter.x), 0.0)
            else
                0.0,
            .right = if (constants.layout_direction.isRtl())
                client_width
            else
                constants.content_box_inset.right - constants.border.right - constants.scrollbar_gutter.x,
            .top = 0.0,
            .bottom = constants.content_box_inset.bottom - constants.border.bottom - constants.scrollbar_gutter.y,
        });
    }
    return overflow_rect;
}

/// Iterates the items of the flex lines (in document order) that hold out-of-flow candidates
/// (upstream `flat_map(..).filter(..).peekable()`)
const ItemsWithCandidates = struct {
    lines: []FlexLine,
    line: usize = 0,
    item: usize = 0,

    /// The next item holding candidates, without consuming it
    fn peek(self: *ItemsWithCandidates) ?*FlexItem {
        while (self.line < self.lines.len) {
            const items = self.lines[self.line].items;
            while (self.item < items.len) : (self.item += 1) {
                if (!items[self.item].oof_candidates.isEmpty()) return &items[self.item];
            }
            self.line += 1;
            self.item = 0;
        }
        return null;
    }

    /// Consume and return the next item holding candidates if its order is `order`
    fn nextIfOrder(self: *ItemsWithCandidates, order: u32) ?*FlexItem {
        const next_item = self.peek() orelse return null;
        if (next_item.order != order) return null;
        self.item += 1;
        return next_item;
    }
};

/// Collect out-of-flow candidates in document order: direct out-of-flow children (computing their
/// static positions per the flexbox alignment rules) interleaved with the candidates bubbled out
/// of each in-flow item's subtree. Final sizing and positioning happens in the shared
/// out-of-flow positioning pass at the containing block.
fn collectOofCandidates(
    tree: anytype,
    node: NodeId,
    constants: *const AlgoConstants,
    flex_lines: []FlexLine,
    candidates: *OofCandidates,
) LayoutError!void {
    const gpa = tree.allocator();
    // Lines are contiguous slices of the items in document order (reversal is applied to
    // positions, not storage), so walking the lines yields items sorted by `order`
    var items: ItemsWithCandidates = .{ .lines = flex_lines };

    const dir = constants.dir;
    const container_size = constants.container_size;
    const content_box_inset = constants.content_box_inset;

    const main_axis_is_horizontal = constants.is_row;
    const cross_axis_is_horizontal = !constants.is_row;
    const main_is_rtl = main_axis_is_horizontal and constants.layout_direction.isRtl();
    const cross_is_rtl = cross_axis_is_horizontal and constants.layout_direction.isRtl();
    const main_axis_flex_start_reversed = dir.isReverse() != main_is_rtl;
    const cross_axis_flex_start_reversed = constants.is_wrap_reverse != cross_is_rtl;

    // The static-position area in each axis is the container's content box
    const main_area: Line(f32) = .{
        .start = content_box_inset.mainStart(dir),
        .end = container_size.main(dir) - content_box_inset.mainEnd(dir),
    };
    const cross_area: Line(f32) = .{
        .start = content_box_inset.crossStart(dir),
        .end = container_size.cross(dir) - content_box_inset.crossEnd(dir),
    };

    for (0..tree.childCount(node)) |order| {
        const child = tree.getChildId(node, order);
        const child_style = tree.getFlexboxChildStyle(child);
        const position = child_style.getPosition();

        if (child_style.getBoxGenerationMode() == .none) {
            continue;
        }
        // In-flow item: merge the candidates bubbled out of its subtree
        if (!position.isOutOfFlow()) {
            if (items.nextIfOrder(@intCast(order))) |item| {
                try candidates.append(gpa, &item.oof_candidates);
            }
            continue;
        }

        const align_self = resolveNormalAlignment(child_style.getAlignSelf() orelse constants.align_items)
            .resolveSelfRelative(child_style.getDirection(), constants.layout_direction, constants.is_column);

        // Main-axis static position (justify-content).
        //
        // Stretch is an invalid value for justify_content in the flexbox algorithm, so we
        // treat it as if it wasn't set (and thus we default to FlexStart behaviour).
        // Normal has already been resolved to FlexStart.
        //
        // The `safe` overflow-position keyword is intentionally NOT applied here, even when
        // the abs-positioned item would overflow the main axis: Chrome does not apply safe
        // fallback to `justify-content` on absolutely-positioned flex items (only the
        // cross-axis `align-self` does so). Matching the layout authority over a strict
        // spec read keeps gentest fixtures green; reconsider if Chromium changes behavior.
        //
        // `start`/`end` are writing-mode relative (they flip for RTL but not for
        // reversed flex-directions), whereas `flex-start`/`flex-end` and the
        // distributed keywords' fallbacks are flex-relative.
        const main_keyword = constants.justify_content.keyword;
        const main_start_position = switch (main_keyword) {
            .start => !main_is_rtl,
            .end => main_is_rtl,
            else => true,
        };
        const main_edge: AxisStaticEdge = switch (main_keyword) {
            .space_between, .normal, .stretch, .flex_start => if (main_axis_flex_start_reversed) .end else .start,
            .flex_end => if (main_axis_flex_start_reversed) .start else .end,
            .start, .end => if (main_start_position) .start else .end,
            .space_evenly, .space_around, .center => .center,
        };

        // Cross-axis static position (align-self).
        //
        // `start`/`end` (and `baseline`, whose static-position fallback is `start`) are
        // writing-mode relative: they flip for RTL but not for `wrap-reverse`.
        // `flex-start`/`flex-end` and the `stretch` fallback are flex-relative.
        const cross: AxisStaticPosition = .{
            .area = cross_area,
            .@"align" = .{
                .keyword = crossEdgeFor(align_self.keyword, cross_is_rtl, cross_axis_flex_start_reversed),
                .safety = align_self.safety,
                .fallback = crossEdgeFor(resolveSelfAlignmentSafety(align_self, true), cross_is_rtl, cross_axis_flex_start_reversed),
            },
        };
        const main: AxisStaticPosition = .{ .area = main_area, .@"align" = AxisStaticAlign.fromKeyword(main_edge) };

        const static_position: Point(AxisStaticPosition) = if (constants.is_row) .{ .x = main, .y = cross } else .{ .x = cross, .y = main };
        try candidates.push(gpa, .{ .node = child, .order = @intCast(order), .position = position, .static_position = static_position });
    }
}

/// The physical edge of the static-position area that an (already resolved) `align-self` keyword
/// aligns an out-of-flow child of a flex container to, in the cross axis
fn crossEdgeFor(keyword: AlignItemsKeyword, cross_is_rtl: bool, cross_axis_flex_start_reversed: bool) AxisStaticEdge {
    const start_position = switch (keyword) {
        .start, .baseline => !cross_is_rtl,
        .end => cross_is_rtl,
        else => true,
    };
    return switch (keyword) {
        // Stretch alignment does not apply to absolutely positioned items
        // See "Example 3" at https://www.w3.org/TR/css-flexbox-1/#abspos-items
        // Note: Stretch should be FlexStart not Start when we support both
        .start, .end, .baseline => if (start_position) .start else .end,
        .stretch, .flex_start => if (cross_axis_flex_start_reversed) .end else .start,
        .flex_end => if (cross_axis_flex_start_reversed) .start else .end,
        .center => .center,
        // Normal is resolved to Stretch, and SelfStart/SelfEnd are resolved to Start/End
        // against the item's own direction where `align_self` is read.
        .normal, .self_start, .self_end => unreachable,
    };
}

/// Computes the total space taken up by gaps in an axis given:
///   - The size of each gap
///   - The number of items (children or flex-lines) between which there are gaps
inline fn sumAxisGaps(gap: f32, num_items: usize) f32 {
    // Gaps only exist between items, so...
    if (num_items <= 1) {
        // ...if there are less than 2 items then there are no gaps
        return 0.0;
    } else {
        // ...otherwise there are (num_items - 1) gaps
        return gap * @as(f32, @floatFromInt(num_items - 1));
    }
}

/// Balanced line breaking for `flex-wrap: balance`.
///
/// Implements the balancing algorithm from the CSS Flexbox Level 2 draft
/// (<https://drafts.csswg.org/css-flexbox-2/#balancing>). Items are divided into exactly
/// `line_count` contiguous sequences (lines), where `line_count` is the number of lines that
/// greedy line breaking would produce (with item sizes floored at zero), raised to the minimum
/// flex line count (`flex-line-count`, clamped to the number of items), such that:
///
/// - every line holds at least one item;
/// - no line's size exceeds the container's inner main size, unless the line holds a single
///   (overflowing) item;
/// - a zero-sized item is assigned to the end of the preceding line rather than the beginning
///   of a line, unless no valid division can glue it there: because extending the preceding
///   line through the item would make it exceed the container's inner main size (which covers
///   a preceding single overflowing item), or because gluing leaves the remaining lines
///   without a valid division of the remaining items;
/// - calling the difference between a line's size and the container's inner main size the
///   line's *error*, the sum of the squared errors of all lines is minimized;
/// - ties are broken by assigning the most items to the first line, then the most items to the
///   second line, and so on.
///
/// Because every division has the same line count, total item size, and total gap size,
/// minimizing the sum of squared errors is equivalent to minimizing the sum of squared *line
/// sizes*, which is what is actually computed: it needs no target size, so an indefinite
/// (infinite) container size needs no special handling — no line overflows, and the
/// minimization equalizes the line sizes. All arithmetic uses `f64`: finite `f32` sizes
/// convert exactly, and the squares and sums involved are far from `f64`'s limits, so
/// equally-balanced divisions compare equal and are resolved by the tie-break rather than by
/// rounding noise.
///
/// The minimization is a dynamic program over (line count, first item of suffix) accelerated
/// with the divide-and-conquer optimization, running in `O(line_count * item_count *
/// log(item_count))` time; the naive `O(line_count * item_count²)` dynamic program is kept as
/// a test oracle.
const balance = struct {
    const Allocator = std.mem.Allocator;

    /// Score assigned to divisions that violate the line size constraint
    const infeasible: f64 = std.math.inf(f64);

    /// Convert an item size in pixels to an `f64`, flooring negative sizes at zero. (An
    /// infinite size is clamped to the largest finite `f32` so that sums stay meaningful.)
    fn toSize(value: f32) f64 {
        const v: f64 = value;
        const max: f64 = std.math.floatMax(f32);
        if (v < 0.0) return 0.0;
        if (v > max) return max;
        return v;
    }

    /// A per-item prefix sum, paired with whether the item's (floored) size is zero
    const Sum = struct { sum: f64, is_zero: bool };

    /// Line sizing shared by the scoring and readback phases
    const LineSizes = struct {
        /// Per item, the prefix sum of the item sizes through it (each item also contributes
        /// one trailing gap, so the size of the line holding items `start..=end` is
        /// `sums[end].sum - sums[start - 1].sum - gap_between_items`), paired with whether the
        /// item's (floored) size is zero
        sums: []const Sum,
        /// The size of the gap between adjacent items on a line
        gap_between_items: f64,
        /// The container's inner main size, which lines may not exceed (unless they hold a
        /// single item)
        limit: f64,

        /// The total number of items
        fn itemCount(self: *const LineSizes) usize {
            return self.sums.len;
        }

        /// Whether the item at `index` has a (floored) size of zero
        fn isZeroItem(self: *const LineSizes, index: usize) bool {
            return self.sums[index].is_zero;
        }

        /// The size of the line holding items `start..=end`
        fn lineSize(self: *const LineSizes, start: usize, end: usize) f64 {
            const start_sum: f64 = if (start == 0) 0.0 else self.sums[start - 1].sum;
            return self.sums[end].sum - start_sum - self.gap_between_items;
        }

        /// The squared size of the line holding items `start..=end`, or `infeasible` for a
        /// line of more than one item exceeding the limit
        fn lineCost(self: *const LineSizes, start: usize, end: usize) f64 {
            const size = self.lineSize(start, end);
            if (end > start and size > self.limit) {
                return infeasible;
            }
            return size * size;
        }

        /// For every suffix of the items, the number of lines that greedy line breaking
        /// produces for it: each line collects consecutive items until the next item no longer
        /// fits, and if even the first item of a line doesn't fit, that line takes just the one
        /// (overflowing) item. (The entry for the empty suffix is zero.)
        ///
        /// This is also the *fewest* lines each suffix can validly be divided into, and a
        /// suffix can validly be divided into any number of lines from that count up to its
        /// item count: dividing at greedy line ends never violates the zero-sized-item rule
        /// (a line that can hold no more of the following items can never glue them), and
        /// from any in-range line count the same holds with line ends capped to leave one
        /// item per remaining line.
        fn suffixGreedyLineCounts(self: *const LineSizes, gpa: Allocator) Allocator.Error![]u32 {
            const item_count = self.itemCount();
            const counts = try gpa.alloc(u32, item_count + 1);
            @memset(counts, 0);
            // The (exclusive) end of the greedy first line of the suffix, which only moves
            // down as the suffix grows leftwards since lines starting earlier are larger
            var line_end = item_count;
            var start = item_count;
            while (start > 0) {
                start -= 1;
                while (line_end > start + 1 and self.lineSize(start, line_end - 1) > self.limit) {
                    line_end -= 1;
                }
                counts[start] = 1 + counts[line_end];
            }
            return counts;
        }

        /// For every `start`, the largest `end` such that the line holding items `start..=end`
        /// does not exceed the limit (or `start` itself if even that one item overflows)
        fn fitEnds(self: *const LineSizes, gpa: Allocator) Allocator.Error![]u32 {
            const item_count = self.itemCount();
            const fit_ends = try gpa.alloc(u32, item_count);
            // Lines starting later are smaller, so the fit end only moves up
            var fit_end: usize = 0;
            for (0..item_count) |start| {
                if (fit_end < start) {
                    fit_end = start;
                }
                while (fit_end + 1 < item_count and self.lineSize(start, fit_end + 1) <= self.limit) {
                    fit_end += 1;
                }
                fit_ends[start] = @intCast(fit_end);
            }
            return fit_ends;
        }
    };

    /// One row of the balancing dynamic program: divisions of item suffixes into exactly
    /// `lines` lines
    const Row = struct {
        /// The line sizing for the items being divided
        sizes: *const LineSizes,
        /// See `LineSizes.fitEnds`
        fit_ends: []const u32,
        /// The previous row: `prev[start]` is the minimum score of any valid division of items
        /// `start..` into exactly `lines - 1` lines (`infeasible` if there is none)
        prev: []const f64,
        /// The line ends that precede a non-zero item, in ascending order and capped to
        /// `max_end`. Line ends preceding a *zero* item are constrained by the
        /// zero-sized-item rule and handled separately: for a first line starting at `start`,
        /// the only end preceding a zero item that can be part of a valid division is
        /// `min(fit_ends[start], max_end)` — the line extended as far as the limit and the
        /// remaining lines' one-item-each budget allow. Ending earlier is forbidden by the
        /// rule (the zero item could be glued: the extended line fits and, per
        /// `LineSizes.suffixGreedyLineCounts`, what remains after even the longest glued
        /// line divides validly into the remaining lines whenever what remains after the
        /// shorter line does, which it must for the division to be feasible at all), and
        /// ending later exceeds the limit on a line of more than one item.
        nonzero_ends: []const u32,
        /// The largest possible end of the first line: the remaining `lines - 1` lines need
        /// one item each
        max_end: usize,
    };

    /// The index of the first element of `ends` for which `end < bound` is false (`ends` must be
    /// sorted; upstream `partition_point(|&end| end < bound)`)
    fn partitionPointLess(ends: []const u32, bound: usize) usize {
        var lo: usize = 0;
        var hi: usize = ends.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (@as(usize, ends[mid]) < bound) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The index of the first element of `ends` for which `end <= bound` is false
    fn partitionPointLessEq(ends: []const u32, bound: usize) usize {
        var lo: usize = 0;
        var hi: usize = ends.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (@as(usize, ends[mid]) <= bound) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Compute `cur[start]` and `opts[start]` for `start` in `start_lo..=start_hi`, where
    /// `cur[start]` is the minimum over valid ends `end` of
    /// `row.sizes.lineCost(start, end) + row.prev[end + 1]` and `opts[start]` is the largest
    /// `end` achieving that minimum. Ends preceding a non-zero item are minimized over
    /// `row.nonzero_ends[col_lo..col_hi]`; the (at most one) end preceding a zero item allowed
    /// by the zero-sized-item rule is merged in afterwards.
    ///
    /// Uses the divide-and-conquer dynamic programming optimization: over the ends preceding
    /// non-zero items, the cost function satisfies the concave quadrangle inequality (it is
    /// the square of a quantity that increases in `end` and decreases in `start`, plus a term
    /// depending on `end` alone, with infeasibility monotone in line length), so the largest
    /// minimizing end is non-decreasing in `start`. Solving the middle `start` therefore
    /// splits the end range in two, and each recursion level scans each candidate end a
    /// bounded number of times. (The ends constrained by the zero-sized-item rule are *not*
    /// monotone this way, which is why they are excluded from the scan and merged in
    /// separately.)
    fn fillRow(
        row: *const Row,
        cur: []f64,
        opts: []u32,
        start_lo: usize,
        start_hi: usize,
        col_lo: usize,
        col_hi: usize,
    ) void {
        if (start_lo > start_hi) {
            return;
        }
        const start = start_lo + (start_hi - start_lo) / 2;

        // Minimize over the in-range ends preceding a non-zero item, starting from `start`
        // (the line must hold at least one item)
        const first_col = col_lo + partitionPointLess(row.nonzero_ends[col_lo..col_hi], start);
        var min_cost = infeasible;
        var min_col: ?usize = null;
        for (first_col..col_hi) |col| {
            const end: usize = row.nonzero_ends[col];
            const line_cost = row.sizes.lineCost(start, end);
            if (line_cost == infeasible) {
                // Every longer line also exceeds the limit
                break;
            }
            const cost = line_cost + row.prev[end + 1];
            // `<=` keeps the *largest* minimizing end, assigning the most items to the
            // earliest lines as the tie-break requires
            if (cost <= min_cost) {
                min_cost = cost;
                min_col = col;
            }
        }

        // Merge the single end preceding a zero item that the zero-sized-item rule allows
        var min_end: ?usize = if (min_col) |col| row.nonzero_ends[col] else null;
        const zero_end = @min(@as(usize, row.fit_ends[start]), row.max_end);
        if (row.sizes.isZeroItem(zero_end + 1)) {
            const cost = row.sizes.lineCost(start, zero_end) + row.prev[zero_end + 1];
            if (cost < min_cost or (cost == min_cost and (if (min_end) |end| end < zero_end else true))) {
                min_cost = cost;
                min_end = zero_end;
            }
        }

        // Infeasible states are excluded from the range by the caller, and every feasible
        // state has a valid transition (see `LineSizes.suffixGreedyLineCounts`)
        std.debug.assert(std.math.isFinite(min_cost));
        cur[start] = min_cost;
        opts[start] = @intCast(min_end orelse start);

        // The zero-rule end is excluded from the narrowing: only the non-zero ends' minima
        // are monotone
        if (start > start_lo) {
            const next_col_hi = if (min_col) |col| col + 1 else col_hi;
            fillRow(row, cur, opts, start_lo, start - 1, col_lo, next_col_hi);
        }
        if (start < start_hi) {
            const next_col_lo = min_col orelse first_col;
            fillRow(row, cur, opts, start + 1, start_hi, next_col_lo, col_hi);
        }
    }

    /// Build the per-item prefix sums for `item_sizes`
    fn buildSums(gpa: Allocator, item_sizes: []const f32, gap_between_items: f64) Allocator.Error![]Sum {
        const sums = try gpa.alloc(Sum, item_sizes.len);
        var sum: f64 = 0.0;
        for (item_sizes, sums) |item_size, *entry| {
            const size = toSize(item_size);
            sum += size + gap_between_items;
            entry.* = .{ .sum = sum, .is_zero = size == 0.0 };
        }
        return sums;
    }

    /// Determine the number of items on each line that balances items across lines, such that
    /// the largest line is as small as possible, with a minimum of `min_line_count` lines
    /// (or one line per item if there are fewer items).
    ///
    /// `item_sizes` must be non-empty. The returned line item counts are all non-zero and sum to
    /// the number of items. The returned slice is allocated with `gpa` and owned by the caller.
    ///
    /// Runs in `O(line_count * item_count * log(item_count))` time using
    /// `O(line_count * item_count)` transient memory.
    fn balancedLineItemCounts(
        gpa: Allocator,
        item_sizes: []const f32,
        line_limit: f32,
        gap_between_items_f32: f32,
        min_line_count: usize,
    ) Allocator.Error![]usize {
        const item_count = item_sizes.len;
        std.debug.assert(item_count > 0);
        const gap_between_items = toSize(gap_between_items_f32);
        const limit: f64 = line_limit;

        const sums = try buildSums(gpa, item_sizes, gap_between_items);
        defer gpa.free(sums);
        const sizes: LineSizes = .{ .sums = sums, .gap_between_items = gap_between_items, .limit = limit };

        // `suffix_greedy[start]` is the number of lines greedy line breaking produces for items
        // `start..`, which is also the *fewest* lines the suffix can validly be divided into
        const suffix_greedy = try sizes.suffixGreedyLineCounts(gpa);
        defer gpa.free(suffix_greedy);
        const line_count = @max(@as(usize, suffix_greedy[0]), std.math.clamp(min_line_count, 1, item_count));

        var item_counts: std.ArrayList(usize) = try .initCapacity(gpa, line_count);
        errdefer item_counts.deinit(gpa);
        if (line_count == item_count) {
            // One item per line is the only division (this covers `flex-line-count` of at least
            // the item count as well as every item overflowing a line of its own)
            item_counts.appendNTimesAssumeCapacity(1, item_count);
            return item_counts.toOwnedSlice(gpa);
        }

        const fit_ends = try sizes.fitEnds(gpa);
        defer gpa.free(fit_ends);
        var nonzero_ends: std.ArrayList(u32) = try .initCapacity(gpa, item_count - 1);
        defer nonzero_ends.deinit(gpa);
        for (0..item_count - 1) |end| {
            if (!sizes.isZeroItem(end + 1)) {
                nonzero_ends.appendAssumeCapacity(@intCast(end));
            }
        }

        // `prev[start]` is the minimum total score of any valid division of items `start..`
        // into exactly `lines - 1` lines (`infeasible` if there is none), and `cur` is the
        // row being computed for `lines` lines: a division into `lines` lines is a first line
        // `start..=end` plus a division of `end + 1..` into `lines - 1` lines.
        // `opts[(lines - 2) * item_count + start]` records the largest `end` achieving
        // `cur[start]`, from which the chosen division is read back.
        var prev = try gpa.alloc(f64, item_count);
        defer gpa.free(prev);
        for (0..item_count) |start| {
            prev[start] = sizes.lineCost(start, item_count - 1);
        }
        var cur = try gpa.alloc(f64, item_count);
        defer gpa.free(cur);
        @memset(cur, infeasible);
        const opts = try gpa.alloc(u32, (line_count - 1) * item_count);
        defer gpa.free(opts);
        @memset(opts, 0);
        for (2..line_count + 1) |lines| {
            // The remaining `lines - 1` lines need one item each, bounding this line's end
            const max_end = item_count - lines;
            // Starts whose suffix doesn't fit in `lines` lines even with greedy breaking are
            // infeasible; they form a prefix (a longer suffix never needs fewer lines), and
            // excluding them keeps every state `fillRow` solves feasible
            var first_start: usize = 0;
            while (first_start < max_end and @as(usize, suffix_greedy[first_start]) > lines) {
                cur[first_start] = infeasible;
                first_start += 1;
            }
            const col_hi = partitionPointLessEq(nonzero_ends.items, max_end);
            const row: Row = .{ .sizes = &sizes, .fit_ends = fit_ends, .prev = prev, .nonzero_ends = nonzero_ends.items, .max_end = max_end };
            const opts_row = opts[(lines - 2) * item_count .. (lines - 1) * item_count];
            fillRow(&row, cur, opts_row, first_start, max_end, 0, col_hi);
            std.mem.swap([]f64, &prev, &cur);
        }

        // Read the division back out front to back
        std.debug.assert(std.math.isFinite(prev[0]));
        var start: usize = 0;
        var lines = line_count;
        while (lines >= 2) : (lines -= 1) {
            const end: usize = opts[(lines - 2) * item_count + start];
            item_counts.appendAssumeCapacity(end - start + 1);
            start = end + 1;
        }
        item_counts.appendAssumeCapacity(item_count - start);
        return item_counts.toOwnedSlice(gpa);
    }

    // -----------------------------------------------------------------------------------------
    // Tests

    /// The number of lines that greedy line breaking produces: each line collects
    /// consecutive items until the next item no longer fits, and if even the first item of
    /// a line doesn't fit, that line takes just the one (overflowing) item
    fn greedyLineCount(sizes: *const LineSizes) usize {
        const item_count = sizes.itemCount();
        var line_count: usize = 1;
        var index: usize = 0;
        while (index < item_count) {
            var next = index;
            while (next < item_count and sizes.lineSize(index, next) <= sizes.limit) {
                next += 1;
            }
            if (next == index) {
                next = index + 1;
            }
            index = next;
            if (index < item_count) {
                line_count += 1;
            }
        }
        return line_count;
    }

    /// The zero-sized-item rule, brute force: a line `start..=end` (of a division of
    /// `start..` into `lines` lines) may only end before a zero-sized item if no division
    /// that extends the line through the item exists — every extension either exceeds the
    /// limit or leaves the remaining items without a valid division into the remaining
    /// lines. (`min_errors` rows below `lines` must already be computed.)
    fn zeroBoundaryValid(sizes: *const LineSizes, min_errors: []const f64, lines: usize, start: usize, end: usize) bool {
        const item_count = sizes.itemCount();
        if (!sizes.isZeroItem(end + 1)) {
            return true;
        }
        var glued_end = end + 1;
        while (glued_end <= item_count - lines) : (glued_end += 1) {
            if (sizes.lineSize(start, glued_end) > sizes.limit) {
                break;
            }
            if (std.math.isFinite(min_errors[(lines - 2) * item_count + glued_end + 1])) {
                return false;
            }
        }
        return true;
    }

    /// The naive `O(line_count * item_count²)` dynamic program from the spec, used as a
    /// test oracle for the divide-and-conquer optimized implementation
    fn naiveLineItemCounts(
        gpa: Allocator,
        item_sizes: []const f32,
        line_limit: f32,
        gap_between_items_f32: f32,
        min_line_count: usize,
    ) ![]usize {
        const item_count = item_sizes.len;
        const gap_between_items = toSize(gap_between_items_f32);
        const limit: f64 = line_limit;

        const sums = try buildSums(gpa, item_sizes, gap_between_items);
        defer gpa.free(sums);
        const sizes: LineSizes = .{ .sums = sums, .gap_between_items = gap_between_items, .limit = limit };

        const line_count = @max(greedyLineCount(&sizes), std.math.clamp(min_line_count, 1, item_count));

        // `min_errors[(lines - 1) * item_count + start]` is the minimum total score of any
        // valid division of items `start..` into exactly `lines` lines
        var min_errors: std.ArrayList(f64) = try .initCapacity(gpa, line_count * item_count);
        defer min_errors.deinit(gpa);
        for (0..item_count) |start| {
            min_errors.appendAssumeCapacity(sizes.lineCost(start, item_count - 1));
        }
        for (2..line_count + 1) |lines| {
            const row = (lines - 1) * item_count;
            for (0..item_count) |start| {
                var min_error = infeasible;
                var end = start;
                while (end + lines <= item_count) : (end += 1) {
                    const line_cost = sizes.lineCost(start, end);
                    if (line_cost == infeasible) {
                        break;
                    }
                    if (zeroBoundaryValid(&sizes, min_errors.items, lines, start, end)) {
                        const err = line_cost + min_errors.items[row - item_count + end + 1];
                        if (err < min_error) {
                            min_error = err;
                        }
                    }
                }
                min_errors.appendAssumeCapacity(min_error);
            }
        }

        // For each line, the *largest* end whose error plus the minimum remaining error
        // adds up to the (feasible) minimum is chosen
        try testing.expect(std.math.isFinite(min_errors.items[(line_count - 1) * item_count]));
        var item_counts: std.ArrayList(usize) = try .initCapacity(gpa, line_count);
        errdefer item_counts.deinit(gpa);
        var start: usize = 0;
        var lines_after = line_count;
        while (lines_after > 0) {
            lines_after -= 1;
            const target = min_errors.items[lines_after * item_count + start];
            var end = item_count - 1 - lines_after;
            while (true) {
                if (sizes.lineCost(start, end) != infeasible and
                    (lines_after == 0 or zeroBoundaryValid(&sizes, min_errors.items, lines_after + 1, start, end)))
                {
                    const remaining_error: f64 = if (lines_after == 0) 0.0 else min_errors.items[(lines_after - 1) * item_count + end + 1];
                    if (sizes.lineCost(start, end) + remaining_error == target) {
                        break;
                    }
                }
                try testing.expect(end > start);
                end -= 1;
            }
            item_counts.appendAssumeCapacity(end - start + 1);
            start = end + 1;
        }
        try testing.expectEqual(item_count, start);
        return item_counts.toOwnedSlice(gpa);
    }

    fn expectCounts(item_sizes: []const f32, line_limit: f32, gap: f32, min_line_count: usize, expected: []const usize) !void {
        const counts = try balancedLineItemCounts(testing.allocator, item_sizes, line_limit, gap, min_line_count);
        defer testing.allocator.free(counts);
        try testing.expectEqualSlices(usize, expected, counts);
    }

    test "zero_sized_item_rule" {
        // The zero item joins the first line even though the gap it brings makes the score
        // worse: [70, 0] / [20] has line sizes 80 / 20 (score 6800), while [70] / [0, 20]
        // would have line sizes 70 / 30 (score 5800)
        try expectCounts(&.{ 70.0, 0.0, 20.0 }, 100.0, 10.0, 1, &.{ 2, 1 });
        // The zero item is not glued to a single overflowing item's line
        try expectCounts(&.{ 150.0, 0.0, 30.0 }, 100.0, 0.0, 1, &.{ 1, 2 });
        // Zero items are glued as far as the requested line count allows
        try expectCounts(&.{ 70.0, 0.0, 0.0 }, 100.0, 0.0, 2, &.{ 2, 1 });
    }

    test "matches_naive_dp" {
        const gpa = testing.allocator;
        // A simple xorshift PRNG so the test is deterministic and dependency-free
        const Rng = struct {
            state: u64 = 0x243F6A8885A308D3,
            fn next(self: *@This(), bound: u32) u32 {
                self.state ^= self.state << 13;
                self.state ^= self.state >> 7;
                self.state ^= self.state << 17;
                return @as(u32, @truncate(self.state >> 32)) % bound;
            }
        };
        var rng: Rng = .{};

        var item_sizes_buf: [64]f32 = undefined;
        for (0..5000) |case| {
            // Mostly small item counts (quantized sizes maximize ties, exercising the
            // tie-break rules), with some larger ones exercising the recursion
            const item_count: usize = if (case % 20 == 0) rng.next(60) + 1 else rng.next(15) + 1;
            const item_sizes = item_sizes_buf[0..item_count];
            for (item_sizes) |*size| {
                size.* = switch (rng.next(8)) {
                    // Frequent zero items exercise the zero-sized-item rule
                    0, 1 => 0.0,
                    2 => -10.0,
                    else => @as(f32, @floatFromInt(rng.next(8))) * 25.0,
                };
            }
            const line_limit: f32 = switch (rng.next(5)) {
                0 => std.math.inf(f32),
                else => @as(f32, @floatFromInt(rng.next(10))) * 30.0,
            };
            const gap_between_items = @as(f32, @floatFromInt(rng.next(4))) * 5.0;
            const min_line_count: usize = rng.next(@as(u32, @intCast(item_count)) + 2);

            const expected = try naiveLineItemCounts(gpa, item_sizes, line_limit, gap_between_items, min_line_count);
            defer gpa.free(expected);
            const actual = try balancedLineItemCounts(gpa, item_sizes, line_limit, gap_between_items, min_line_count);
            defer gpa.free(actual);
            testing.expectEqualSlices(usize, expected, actual) catch |err| {
                std.debug.print("case {d}: item_sizes={any} line_limit={d} gap_between_items={d} min_line_count={d}\n", .{
                    case, item_sizes, line_limit, gap_between_items, min_line_count,
                });
                return err;
            };
        }
    }
};

test {
    _ = balance;
}

// ---------------------------------------------------------------------------------------------
// Tests (laffy additions: leak checks of multi-level layouts under the testing allocator)

const testing = std.testing;
const TaffyTree = @import("../tree/taffy_tree.zig").TaffyTree;
const Style = style_mod.Style;
const LengthPercentage = style_mod.LengthPercentage;
const LengthPercentageAuto = style_mod.LengthPercentageAuto;

/// Build a multi-level flex tree with absolutely positioned children at several depths (some
/// claimed by an intermediate relatively positioned container, some bubbling to the root), a
/// hidden child, baseline-aligned items (whose baseline pass performs layout on subtrees with
/// out-of-flow descendants), wrapping and balanced lines, then lay it out twice.
fn layoutNestedTree(gpa: std.mem.Allocator) !void {
    var taffy = try TaffyTree(void).init(gpa);
    defer taffy.deinit();

    var abs_style: Style = .{};
    abs_style.position = .absolute;
    abs_style.inset = .{ .left = .length(5.0), .right = .auto, .top = .auto, .bottom = .length(3.0) };
    abs_style.size = Size(Dimension).fromLengths(7.0, 4.0);
    var fixed_style: Style = .{};
    fixed_style.position = .fixed;
    fixed_style.size = Size(Dimension).fromLengths(2.0, 3.0);
    var leaf_style: Style = .{};
    leaf_style.size = Size(Dimension).fromLengths(20.0, 10.0);
    var hidden_style: Style = .{};
    hidden_style.display = .none;

    // Innermost: a baseline-aligned row holding absolutely positioned and fixed children
    const deep_abs = try taffy.newLeaf(abs_style);
    const deep_fixed = try taffy.newLeaf(fixed_style);
    const deep_leaf = try taffy.newLeaf(leaf_style);
    var baseline_item_style: Style = .{};
    baseline_item_style.align_self = AlignSelf.baseline;
    baseline_item_style.padding = Rect(LengthPercentage).length(2.0);
    const baseline_a = try taffy.newWithChildren(baseline_item_style, &.{ deep_leaf, deep_abs, deep_fixed });
    const baseline_leaf = try taffy.newLeaf(leaf_style);
    const baseline_b = try taffy.newWithChildren(baseline_item_style, &.{baseline_leaf});
    const hidden_leaf = try taffy.newLeaf(leaf_style);
    const hidden = try taffy.newWithChildren(hidden_style, &.{hidden_leaf});
    const row = try taffy.newWithChildren(.{}, &.{ baseline_a, baseline_b, hidden });

    // A relatively positioned wrapping column that claims absolutely positioned descendants
    var column_style: Style = .{};
    column_style.position = .relative;
    column_style.flex_direction = .column;
    column_style.flex_wrap = .wrap;
    column_style.size = .{ .width = Dimension.auto, .height = Dimension.length(40.0) };
    column_style.gap = Size(LengthPercentage).length(3.0);
    const column_abs = try taffy.newLeaf(abs_style);
    const column_leaf_a = try taffy.newLeaf(leaf_style);
    const column_leaf_b = try taffy.newLeaf(leaf_style);
    const column = try taffy.newWithChildren(column_style, &.{ row, column_leaf_a, column_abs, column_leaf_b });

    // A balanced wrapping row with a percentage-sized and an auto-margined item
    var balanced_style: Style = .{};
    balanced_style.flex_wrap = .balance;
    balanced_style.flex_line_count = 2;
    balanced_style.size = .{ .width = Dimension.length(60.0), .height = Dimension.auto };
    var percent_style: Style = .{};
    percent_style.size = .{ .width = Dimension.percent(0.5), .height = Dimension.length(5.0) };
    var auto_margin_style = leaf_style;
    auto_margin_style.margin = .{ .left = .auto, .right = .length(1.0), .top = .auto, .bottom = .length(0.0) };
    const balanced_children = [_]NodeId{
        try taffy.newLeaf(leaf_style),
        try taffy.newLeaf(percent_style),
        try taffy.newLeaf(auto_margin_style),
        try taffy.newLeaf(abs_style),
        try taffy.newLeaf(leaf_style),
    };
    const balanced = try taffy.newWithChildren(balanced_style, &balanced_children);

    var root_style: Style = .{};
    root_style.flex_direction = .row_reverse;
    root_style.direction = .rtl;
    root_style.padding = Rect(LengthPercentage).length(4.0);
    root_style.overflow = .{ .x = .scroll, .y = .scroll };
    root_style.scrollbar_width = 5.0;
    const root_abs = try taffy.newLeaf(abs_style);
    const root = try taffy.newWithChildren(root_style, &.{ column, root_abs, balanced });

    try taffy.computeLayout(root, .{ .width = .{ .definite = 200.0 }, .height = .{ .definite = 150.0 } });
    // The column is the containing block of its own absolutely positioned descendants; the fixed
    // box and the root's own absolutely positioned children are laid out by the root
    try testing.expectEqualSlices(NodeId, &.{ deep_abs, column_abs }, taffy.hoistedChildren(column));
    try testing.expectEqual(@as(usize, 3), taffy.hoistedChildren(root).len);
    try testing.expectEqual(Size(f32){ .width = 7.0, .height = 4.0 }, taffy.layout(deep_abs).size);
    try testing.expectEqual(Size(f32).zero, taffy.layout(hidden_leaf).size);

    // A relayout after a style change exercises the cache and the hoisted-list bookkeeping
    taffy.setStyle(column_leaf_b, percent_style);
    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try taffy.computeLayout(root, Size(AvailableSpace).min_content);
    try testing.expectEqualSlices(NodeId, &.{ deep_abs, column_abs }, taffy.hoistedChildren(column));
}

test "multi-level flex trees with absolutely positioned children do not leak" {
    try layoutNestedTree(testing.allocator);
}

test "multi-level flex layout frees everything when allocations fail" {
    try testing.checkAllAllocationFailures(testing.allocator, layoutNestedTree, .{});
}

test "flex row distributes free space and positions children" {
    var taffy = try TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    var grow: Style = .{};
    grow.flex_grow = 1.0;
    grow.margin = Rect(LengthPercentageAuto).length(5.0);
    var fixed: Style = .{};
    fixed.size = Size(Dimension).fromLengths(30.0, 20.0);
    const a = try taffy.newLeaf(grow);
    const b = try taffy.newLeaf(fixed);
    var root_style: Style = .{};
    root_style.size = Size(Dimension).fromLengths(100.0, 50.0);
    root_style.align_items = AlignItems.center;
    const root = try taffy.newWithChildren(root_style, &.{ a, b });

    try taffy.computeLayout(root, Size(AvailableSpace).max_content);
    try testing.expectEqual(Size(f32){ .width = 60.0, .height = 0.0 }, taffy.layout(a).size);
    try testing.expectEqual(Point(f32){ .x = 5.0, .y = 25.0 }, taffy.layout(a).location);
    try testing.expectEqual(Point(f32){ .x = 70.0, .y = 15.0 }, taffy.layout(b).location);
}
