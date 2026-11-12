//! Alignment of tracks and final positioning of items
const std = @import("std");
const geometry = @import("../../geometry.zig");
const InBothAbsAxis = geometry.InBothAbsAxis;
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../../style.zig");
const AlignContent = style_mod.AlignContent;
const AlignItems = style_mod.AlignItems;
const AlignSelf = style_mod.AlignSelf;
const AvailableSpace = style_mod.AvailableSpace;
const Direction = style_mod.Direction;
const Position = style_mod.Position;
const layout = @import("../../tree/layout.zig");
const Layout = layout.Layout;
const LayoutError = layout.LayoutError;
const OofCandidate = layout.OofCandidate;
const Scratch = @import("../../util/scratch.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const traits = @import("../../tree/traits.zig");
const math = @import("../../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const maybeSub = math.maybeSub;
const resolve = @import("../../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../../util/sys.zig");
const common_alignment = @import("../common/alignment.zig");
const applyAlignmentFallback = common_alignment.applyAlignmentFallback;
const childFirstBaseline = common_alignment.childFirstBaseline;
const computeAlignmentOffset = common_alignment.computeAlignmentOffset;
const resolveSelfAlignmentSafety = common_alignment.resolveSelfAlignmentSafety;
const scrollable_overflow = @import("../common/scrollable_overflow.zig");
const computeScrollableOverflowContribution = scrollable_overflow.computeScrollableOverflowContribution;
const ScrollableOverflowContainer = scrollable_overflow.ScrollableOverflowContainer;
const sizing_keyword = @import("../common/sizing_keyword.zig");
const resolveSizingKeyword = sizing_keyword.resolveSizingKeyword;
const SizingKeywordResolution = sizing_keyword.SizingKeywordResolution;
const GridTrack = @import("types.zig").GridTrack;

/// Align the grid tracks within the grid according to the align-content (rows) or
/// justify-content (columns) property. This only does anything if the size of the
/// grid is not equal to the size of the grid container in the axis being aligned.
pub fn alignTracks(
    grid_container_content_box_size: f32,
    padding: Line(f32),
    border: Line(f32),
    tracks: []GridTrack,
    track_alignment_style: AlignContent,
    axis_is_reversed: bool,
) void {
    var used_size: f32 = -0.0;
    for (tracks) |*track| used_size += track.base_size;
    const free_space = grid_container_content_box_size - used_size;
    const origin = padding.start + border.start;

    // Count the number of non-collapsed tracks (not counting gutters)
    var num_tracks: usize = 0;
    var index: usize = 1;
    while (index < tracks.len) : (index += 2) {
        if (!tracks[index].is_collapsed) num_tracks += 1;
    }

    // Grid layout treats gaps as full tracks rather than applying them at alignment so we
    // simply pass zero here. Grid layout is never reversed.
    const gap: f32 = 0.0;
    const layout_is_reversed = false;
    const fallback_alignment = applyAlignmentFallback(free_space, num_tracks, track_alignment_style);
    const track_alignment = if (axis_is_reversed) fallback_alignment.reversed() else fallback_alignment;

    // If every track is collapsed then no track receives the alignment offset below, but the
    // grid's lines should still be aligned within the container (e.g. at the inline-start edge
    // for RTL), so apply the offset to the origin instead.
    const empty_grid_offset: f32 = if (num_tracks == 0)
        computeAlignmentOffset(free_space, num_tracks, gap, track_alignment, layout_is_reversed, true)
    else
        0.0;

    // Compute offsets. Tracks are stored in logical order; when the axis is reversed (RTL)
    // physical offsets are assigned right-to-left by iterating the tracks in reverse.
    var total_offset = origin + empty_grid_offset;
    var seen_non_collapsed_track = false;
    for (0..tracks.len) |i| {
        const track = if (axis_is_reversed) &tracks[tracks.len - 1 - i] else &tracks[i];
        // Odd tracks are gutters (but slices are zero-indexed, so odd tracks have even indices)
        const is_gutter = i % 2 == 0;
        const is_non_collapsed_track = !is_gutter and !track.is_collapsed;

        // Alignment offsets should be applied only to non-collapsed tracks.
        const is_first = is_non_collapsed_track and !seen_non_collapsed_track;

        const offset: f32 = if (is_non_collapsed_track)
            computeAlignmentOffset(free_space, num_tracks, gap, track_alignment, layout_is_reversed, is_first)
        else
            0.0;

        track.offset = total_offset + offset;
        total_offset = total_offset + offset + track.base_size;
        if (is_non_collapsed_track) {
            seen_non_collapsed_track = true;
        }
    }
}

/// The result of `alignAndPositionItem`
pub const PositionedItem = struct {
    /// The item's contribution to the container's scrollable overflow
    overflow_contribution: Rect(f32),
    /// The item's y position, excluding any relative offset
    y_position: f32,
    /// The item's height
    height: f32,
    /// The item's first baseline
    baseline: ?f32,
};

/// Align and size a grid item into it's final position
pub fn alignAndPositionItem(
    tree: anytype,
    node: NodeId,
    order: u32,
    grid_area: Rect(f32),
    // Percentage basis for the item's styles. Grid passes the grid area size; grid lanes (css-grid-3) items
    // have the container's content box as their containing block in the stacking axis.
    containing_block_size: Size(f32),
    container_alignment_styles: InBothAbsAxis(AlignItems),
    baseline_shim: f32,
    direction: Direction,
    padding_box_inset: Rect(f32),
    overflow_container: *const ScrollableOverflowContainer,
    bubbled_candidates: *std.ArrayList(OofCandidate),
) LayoutError!PositionedItem {
    const grid_area_size: Size(f32) = .{ .width = grid_area.right - grid_area.left, .height = grid_area.bottom - grid_area.top };

    const style = tree.getGridChildStyle(node);

    const overflow = style.getOverflow();
    const contain = style.getContain();
    const scrollbar_width = style.getScrollbarWidth();
    const aspect_ratio = style.getAspectRatio();
    const is_replaced = style.isReplaced();
    // Fall back to the container's justify-items/align-items if unset (`null`), and then resolve
    // writing-mode-relative self-start/self-end keywords against the item's own direction.
    // The horizontal axis is the inline axis (laffy only supports horizontal-tb); the vertical
    // (block) axis resolves them to plain start/end.
    const item_direction = style.getDirection();
    const justify_self = (style.getJustifySelf() orelse container_alignment_styles.horizontal).resolveSelfRelative(item_direction, direction, true);
    const align_self = (style.getAlignSelf() orelse container_alignment_styles.vertical).resolveSelfRelative(item_direction, direction, false);

    const position = style.getPosition();
    const inset = style.getInset();
    const inset_horizontal: Line(?f32) = .{
        .start = inset.left.resolveToOption(containing_block_size.width, tree),
        .end = inset.right.resolveToOption(containing_block_size.width, tree),
    };
    const inset_vertical: Line(?f32) = .{
        .start = inset.top.resolveToOption(containing_block_size.height, tree),
        .end = inset.bottom.resolveToOption(containing_block_size.height, tree),
    };
    const padding = resolveOrZero(style.getPadding(), @as(?f32, containing_block_size.width), tree);
    const border = resolveOrZero(style.getBorder(), @as(?f32, containing_block_size.width), tree);
    const padding_border_size = padding.add(border).sumAxes();

    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) padding_border_size else Size(f32).zero;

    const containing_block_options: Size(?f32) = .{ .width = containing_block_size.width, .height = containing_block_size.height };
    const size_style = style.getSize();
    const inherent_size = maybeAdd(maybeResolve(size_style, containing_block_options, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
    const min_size = maybeMax(
        maybeAdd(maybeResolve(style.getMinSize(), containing_block_options, tree), box_sizing_adjustment)
            .@"or"(.{ .width = padding_border_size.width, .height = padding_border_size.height }),
        padding_border_size,
    ).maybeApplyAspectRatio(aspect_ratio);
    const max_size = maybeAdd(maybeResolve(style.getMaxSize(), containing_block_options, tree).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);

    // Resolve `normal` alignment (the default if alignment is set on neither the parent or the node itself)
    // Note: if the child has a preferred aspect ratio but neither width or height are set, then the width is stretched
    // and the then height is calculated from the width according the aspect ratio
    // Replaced elements are not stretched: they are sized as for `start`.
    // See: https://www.w3.org/TR/css-grid-1/#grid-item-sizing
    const alignment_styles: InBothAbsAxis(AlignSelf) = .{
        .horizontal = switch (justify_self.keyword) {
            .normal => if (inherent_size.width != null or size_style.width.isSizingKeyword() or is_replaced)
                AlignSelf.start
            else
                AlignSelf.stretch,
            else => justify_self,
        },
        .vertical = switch (align_self.keyword) {
            .normal => if (inherent_size.height != null or
                size_style.height.isSizingKeyword() or
                aspect_ratio != null or
                is_replaced)
                AlignSelf.start
            else
                AlignSelf.stretch,
            else => align_self,
        },
    };

    // Note: This is not a bug. It is part of the CSS spec that both horizontal and vertical margins
    // resolve against the WIDTH of the grid area.
    const margin_style = style.getMargin();
    const margin: Rect(?f32) = .{
        .left = margin_style.left.resolveToOption(containing_block_size.width, tree),
        .right = margin_style.right.resolveToOption(containing_block_size.width, tree),
        .top = margin_style.top.resolveToOption(containing_block_size.width, tree),
        .bottom = margin_style.bottom.resolveToOption(containing_block_size.width, tree),
    };

    const grid_area_minus_item_margins_size: Size(f32) = .{
        .width = @max(maybeSub(maybeSub(grid_area_size.width, margin.left), margin.right), 0.0),
        .height = @max(maybeSub(maybeSub(grid_area_size.height, margin.top), margin.bottom) - baseline_shim, 0.0),
    };

    // A size that is a sizing keyword (min-content, max-content, fit-content,
    // fit-content(...), stretch) either resolves to an exact size or is resolved
    // by measuring the item under the corresponding available space constraint
    // (upstream's `Option<Option<_>>` is flattened: only `Some(Some(_))` is ever matched)
    const keyword_width: ?SizingKeywordResolution = if (inherent_size.width == null)
        resolveSizingKeyword(size_style.width, grid_area_minus_item_margins_size.width, containing_block_size.width, tree)
    else
        null;
    const keyword_height: ?SizingKeywordResolution = if (inherent_size.height == null)
        resolveSizingKeyword(size_style.height, grid_area_minus_item_margins_size.height, containing_block_size.height, tree)
    else
        null;

    // If both axes need to be measured then resolve them with a single measure call
    const keyword_measured_size: Size(?f32) = blk: {
        const kw = keyword_width orelse break :blk Size(?f32).none;
        const kh = keyword_height orelse break :blk Size(?f32).none;
        if (kw == .measure and kh == .measure and !position.isOutOfFlow()) {
            const measured = try traits.measureChildSizeBoth(
                tree,
                node,
                Size(?f32).none,
                containing_block_options,
                .{ .width = kw.measure, .height = kh.measure },
                .inherent_size,
                Line(bool).false,
            );
            break :blk .{ .width = measured.width, .height = measured.height };
        }
        break :blk Size(?f32).none;
    };

    // If node is absolutely positioned and width is not set explicitly, then deduce it
    // from left, right and container_content_box if both are set.
    const width_a: ?f32 = inherent_size.width orelse blk: {
        // Apply width derived from both the left and right properties of an absolutely
        // positioned element being set
        if (position.isOutOfFlow()) {
            if (inset_horizontal.start) |left| {
                if (inset_horizontal.end) |right| {
                    break :blk @max(grid_area_minus_item_margins_size.width - left - right, 0.0);
                }
            }
        }

        if (keyword_width) |resolution| {
            break :blk switch (resolution) {
                .exact => |width| width,
                .measure => |available_width| keyword_measured_size.width orelse try traits.measureChildSize(
                    tree,
                    node,
                    Size(?f32).none,
                    containing_block_options,
                    .{ .width = available_width, .height = .{ .definite = grid_area_minus_item_margins_size.height } },
                    .inherent_size,
                    .horizontal,
                    Line(bool).false,
                ),
            };
        }

        // Apply width based on stretch alignment if:
        //  - Alignment style is "stretch"
        //  - The node is not absolutely positioned
        //  - The node does not have auto margins in this axis.
        if (margin.left != null and
            margin.right != null and
            alignment_styles.horizontal == AlignSelf.stretch and
            !position.isOutOfFlow())
        {
            break :blk grid_area_minus_item_margins_size.width;
        }

        break :blk null;
    };

    // Reapply aspect ratio after stretch and absolute position width adjustments
    const size_a = (Size(?f32){ .width = width_a, .height = inherent_size.height }).maybeApplyAspectRatio(aspect_ratio);
    const width_b = size_a.width;

    const height_b: ?f32 = size_a.height orelse blk: {
        if (position.isOutOfFlow()) {
            if (inset_vertical.start) |top| {
                if (inset_vertical.end) |bottom| {
                    break :blk @max(grid_area_minus_item_margins_size.height - top - bottom, 0.0);
                }
            }
        }

        if (keyword_height) |resolution| {
            break :blk switch (resolution) {
                .exact => |height| height,
                .measure => |available_height| keyword_measured_size.height orelse try traits.measureChildSize(
                    tree,
                    node,
                    .{ .width = width_b, .height = null },
                    containing_block_options,
                    .{
                        .width = if (width_b) |w| .{ .definite = w } else .{ .definite = grid_area_minus_item_margins_size.width },
                        .height = available_height,
                    },
                    .inherent_size,
                    .vertical,
                    Line(bool).false,
                ),
            };
        }

        // Apply height based on stretch alignment if:
        //  - Alignment style is "stretch"
        //  - The node is not absolutely positioned
        //  - The node does not have auto margins in this axis.
        if (margin.top != null and
            margin.bottom != null and
            alignment_styles.vertical == AlignSelf.stretch and
            !position.isOutOfFlow())
        {
            break :blk grid_area_minus_item_margins_size.height;
        }

        break :blk null;
    };
    // Reapply aspect ratio after stretch and absolute position height adjustments
    const size_b = (Size(?f32){ .width = width_b, .height = height_b }).maybeApplyAspectRatio(aspect_ratio);

    // Clamp size by min and max width/height
    const clamped = maybeClamp(size_b, min_size, max_size);

    // Layout node
    const size: Size(?f32) = if (position.isOutOfFlow() and (clamped.width == null or clamped.height == null)) blk: {
        const measured = try traits.measureChildSizeBoth(
            tree,
            node,
            clamped,
            containing_block_options,
            .{ .width = .{ .definite = grid_area_minus_item_margins_size.width }, .height = .{ .definite = grid_area_minus_item_margins_size.height } },
            .inherent_size,
            Line(bool).false,
        );
        break :blk .{ .width = measured.width, .height = measured.height };
    } else clamped;

    var layout_output = try traits.performChildLayout(
        tree,
        node,
        size,
        containing_block_options,
        .{ .width = .{ .definite = grid_area_minus_item_margins_size.width }, .height = .{ .definite = grid_area_minus_item_margins_size.height } },
        .inherent_size,
        Line(bool).false,
    );

    // Resolve final size
    const final_size = maybeClamp(size.unwrapOr(layout_output.size), min_size, max_size);
    const width = final_size.width;
    const height = final_size.height;

    const x_aligned = alignItemWithinArea(
        .{ .start = grid_area.left, .end = grid_area.right },
        alignment_styles.horizontal,
        width,
        position,
        inset_horizontal,
        margin.horizontalComponents(),
        0.0,
        direction,
    );
    const y_aligned = alignItemWithinArea(
        .{ .start = grid_area.top, .end = grid_area.bottom },
        alignment_styles.vertical,
        height,
        position,
        inset_vertical,
        margin.verticalComponents(),
        baseline_shim,
        .ltr,
    );
    const x_margin = x_aligned.margin;
    const y_without_relative_offset = y_aligned.position;
    const y_margin = y_aligned.margin;
    // A relative offset moves the item, but does not affect the container's baseline (which is computed from the
    // returned y position, without the offset)
    const x = x_aligned.position + relativeOffset(position, inset_horizontal, direction);
    const y = y_without_relative_offset + relativeOffset(position, inset_vertical, .ltr);

    const scrollbar_size: Size(f32) = .{
        .width = if (overflow.y == .scroll) scrollbar_width else 0.0,
        .height = if (overflow.x == .scroll) scrollbar_width else 0.0,
    };

    const resolved_margin: Rect(f32) = .{ .left = x_margin.start, .right = x_margin.end, .top = y_margin.start, .bottom = y_margin.end };

    // Bubble out-of-flow candidates from the item's subtree, translating anchors from
    // item-relative to container-relative coordinates
    try layout.appendOofCandidates(bubbled_candidates, Scratch.allocatorOf(tree), tree.oofCandidates(node), .{ .x = x, .y = y });

    tree.setUnroundedLayout(node, &.{
        .order = order,
        .location = .{ .x = x, .y = y },
        .size = .{ .width = width, .height = height },
        .scrollable_overflow_rect = layout_output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .padding = padding,
        .border = border,
        .margin = resolved_margin,
    });

    const contribution_location: Point(f32) = .{ .x = x - padding_box_inset.left, .y = y - padding_box_inset.top };
    const contribution = computeScrollableOverflowContribution(
        contribution_location,
        .{ .width = width, .height = height },
        layout_output.scrollable_overflow_rect.rect(),
        border,
        overflow,
        contain,
        overflow_container,
        resolved_margin,
    );

    const baseline = childFirstBaseline(layout_output.baselines.first, height, overflow.y);
    return .{ .overflow_contribution = contribution, .y_position = y_without_relative_offset, .height = height, .baseline = baseline };
}

/// The result of `alignItemWithinArea`
pub const AlignedItem = struct {
    /// The item's position in the axis
    position: f32,
    /// The item's resolved margins in the axis
    margin: Line(f32),
};

/// Align and size a grid item along a single axis
pub fn alignItemWithinArea(
    grid_area: Line(f32),
    alignment_style: AlignSelf,
    resolved_size: f32,
    position: Position,
    inset: Line(?f32),
    margin: Line(?f32),
    baseline_shim: f32,
    direction: Direction,
) AlignedItem {
    // Calculate grid area dimension in the axis
    const non_auto_margin: Line(f32) = .{ .start = (margin.start orelse 0.0) + baseline_shim, .end = margin.end orelse 0.0 };
    const grid_area_size = @max(grid_area.end - grid_area.start, 0.0);
    const free_space = @max(grid_area_size - resolved_size - non_auto_margin.sum(), 0.0);

    // Expand auto margins to fill available space
    const auto_margin_count: u8 = @as(u8, @intFromBool(margin.start == null)) + @as(u8, @intFromBool(margin.end == null));
    const auto_margin_size: f32 = if (auto_margin_count > 0) free_space / @as(f32, @floatFromInt(auto_margin_count)) else 0.0;
    const resolved_margin: Line(f32) = .{
        .start = (margin.start orelse auto_margin_size) + baseline_shim,
        .end = margin.end orelse auto_margin_size,
    };

    const overflows = resolved_size + non_auto_margin.sum() > grid_area_size;
    const alignment_keyword = resolveSelfAlignmentSafety(alignment_style, overflows);

    // Compute offset in the axis
    const alignment_based_offset: f32 = switch (alignment_keyword) {
        // TODO: Add support for baseline alignment. For now we treat it as "start".
        .start, .flex_start, .baseline, .stretch => if (direction.isRtl())
            grid_area_size - resolved_size - resolved_margin.end
        else
            resolved_margin.start,
        .end, .flex_end => if (direction.isRtl())
            resolved_margin.start
        else
            grid_area_size - resolved_size - resolved_margin.end,
        .center => (grid_area_size - resolved_size + resolved_margin.start - resolved_margin.end) / 2.0,
        // Normal is resolved, and SelfStart/SelfEnd are resolved to Start/End against
        // the item's own direction, in `alignAndPositionItem`.
        .normal, .self_start, .self_end => unreachable,
    };

    const offset_within_area: f32 = if (position.isOutOfFlow()) blk: {
        if (inset.start) |start| {
            if (inset.end) |end| {
                break :blk if (direction.isRtl())
                    grid_area_size - end - resolved_size - non_auto_margin.end
                else
                    start + non_auto_margin.start;
            }
            break :blk start + non_auto_margin.start;
        }
        if (inset.end) |end| {
            break :blk grid_area_size - end - resolved_size - non_auto_margin.end;
        }
        break :blk alignment_based_offset;
    } else alignment_based_offset;

    return .{ .position = grid_area.start + offset_within_area, .margin = resolved_margin };
}

/// The offset applied to an item in a single axis by its `inset` if it is `position: relative`
fn relativeOffset(position: Position, inset: Line(?f32), direction: Direction) f32 {
    if (position != .relative) {
        return 0.0;
    }
    const relative_inset: ?f32 = if (direction.isRtl())
        (if (inset.end) |pos| -pos else inset.start)
    else
        (inset.start orelse (if (inset.end) |pos| -pos else null));
    return relative_inset orelse 0.0;
}
