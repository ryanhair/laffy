//! Computes size using styles and measure functions
const std = @import("std");
const geometry = @import("../geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style_mod = @import("../style.zig");
const AvailableSpace = style_mod.AvailableSpace;
const layout = @import("../tree/layout.zig");
const Baselines = layout.Baselines;
const CollapsibleMarginSet = layout.CollapsibleMarginSet;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const OofCandidates = layout.OofCandidates;
const ScrollableOverflow = layout.ScrollableOverflow;
const math = @import("../util/math.zig");
const maybeAdd = math.maybeAdd;
const maybeClamp = math.maybeClamp;
const maybeMax = math.maybeMax;
const resolve = @import("../util/resolve.zig");
const maybeResolve = resolve.maybeResolve;
const resolveOrZero = resolve.resolveOrZero;
const sys = @import("../util/sys.zig");
const finalizeScrollableOverflow = @import("common/scrollable_overflow.zig").finalizeScrollableOverflow;

/// Compute the size of a leaf node (node with no children)
///
/// A definite `inputs.available_space` is treated as the space available to the node's border box:
/// the caller is expected to have already subtracted the node's margins from it.
///
/// - `style` implements the `CoreStyle` interface (see `src/style.zig`), e.g. `*const Style`.
/// - `calc` is the `calc()` resolver: any value with a `resolveCalcValue(ptr: *const anyopaque, basis: f32) f32`
///   method (`NoCalc{}` when `calc()` is not supported, or the tree).
/// - `measure_function` is called at most once, as
///   `measure_function.measure(known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32)`.
///   It may be a value or a pointer (use a pointer if `measure` needs to mutate state). It returns the
///   size of the node's content box and cannot fail.
pub fn computeLeafLayout(
    inputs: LayoutInput,
    style: anytype,
    calc: anytype,
    measure_function: anytype,
) LayoutOutput {
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const available_space = inputs.available_space;
    const sizing_mode = inputs.sizing_mode;
    const run_mode = inputs.run_mode;

    // Note: both horizontal and vertical percentage padding/borders are resolved against the container's inline size (i.e. width).
    // This is not a bug, but is how CSS is specified (see: https://developer.mozilla.org/en-US/docs/Web/CSS/padding#values)
    const padding = resolveOrZero(style.getPadding(), parent_size.width, calc);
    const border = resolveOrZero(style.getBorder(), parent_size.width, calc);
    const padding_border = padding.add(border);
    const pb_sum = padding_border.sumAxes();
    const box_sizing_adjustment = if (style.getBoxSizing() == .content_box) pb_sum else Size(f32).zero;

    // Resolve node's preferred/min/max sizes (width/heights) against the available space (percentages resolve to pixel values)
    // For content_size mode, we pretend that the node has no size styles as these should be ignored.
    var node_size: Size(?f32) = undefined;
    var node_min_size: Size(?f32) = undefined;
    var node_max_size: Size(?f32) = undefined;
    var aspect_ratio: ?f32 = undefined;
    switch (sizing_mode) {
        .content_size => {
            node_size = known_dimensions;
            node_min_size = Size(?f32).none;
            node_max_size = Size(?f32).none;
            aspect_ratio = null;
        },
        .inherent_size => {
            aspect_ratio = style.getAspectRatio();
            const style_size = maybeAdd(maybeResolve(style.getSize(), parent_size, calc).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
            const style_min_size = maybeAdd(maybeResolve(style.getMinSize(), parent_size, calc).maybeApplyAspectRatio(aspect_ratio), box_sizing_adjustment);
            const style_max_size = maybeAdd(maybeResolve(style.getMaxSize(), parent_size, calc), box_sizing_adjustment);

            node_size = known_dimensions.@"or"(style_size);
            node_min_size = style_min_size;
            node_max_size = style_max_size;
        },
    }

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow.scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const overflow = style.getOverflow();
    const scrollbar_gutter: Point(f32) = .{
        .x = if (overflow.y == .scroll) style.getScrollbarWidth() else 0.0,
        .y = if (overflow.x == .scroll) style.getScrollbarWidth() else 0.0,
    };
    // TODO: make side configurable based on the `direction` property
    var content_box_inset = padding_border;
    content_box_inset.right += scrollbar_gutter.x;
    content_box_inset.bottom += scrollbar_gutter.y;

    const has_styles_preventing_being_collapsed_through = !style.isBlock() or
        overflow.x.isScrollContainer() or
        overflow.y.isScrollContainer() or
        style.getPosition().isOutOfFlow() or
        style.getContain().establishesIndependentFormattingContext() or
        padding.top > 0.0 or
        padding.bottom > 0.0 or
        border.top > 0.0 or
        border.bottom > 0.0 or
        (if (node_size.height) |h| h > 0.0 else false) or
        (if (node_min_size.height) |h| h > 0.0 else false);

    // Return early if both width and height are known
    if (run_mode == .compute_size and has_styles_preventing_being_collapsed_through) {
        if (node_size.width) |width| {
            if (node_size.height) |height| {
                const size = maybeMax(
                    maybeClamp(Size(f32){ .width = width, .height = height }, node_min_size, node_max_size),
                    someSize(padding_border.sumAxes()),
                );
                return .{
                    .size = size,
                    .scrollable_overflow_rect = ScrollableOverflow.zero,
                    .baselines = Baselines.none,
                    .top_margin = CollapsibleMarginSet.zero,
                    .bottom_margin = CollapsibleMarginSet.zero,
                    .margins_can_collapse_through = false,
                    .oof_candidates = OofCandidates.none,
                    .oof_positioning_area = null,
                };
            }
        }
    }

    // Compute available space
    const measure_available_space: Size(AvailableSpace) = .{
        .width = blk: {
            const space = (if (known_dimensions.width) |w| AvailableSpace.fromF32(w) else available_space.width)
                .maybeSet(known_dimensions.width)
                .maybeSet(node_size.width);
            break :blk switch (space) {
                .definite => |size| .{ .definite = maybeClamp(size, node_min_size.width, node_max_size.width) - content_box_inset.horizontalAxisSum() },
                else => space,
            };
        },
        .height = blk: {
            const space = (if (known_dimensions.height) |h| AvailableSpace.fromF32(h) else available_space.height)
                .maybeSet(known_dimensions.height)
                .maybeSet(node_size.height);
            break :blk switch (space) {
                .definite => |size| .{ .definite = maybeClamp(size, node_min_size.height, node_max_size.height) - content_box_inset.verticalAxisSum() },
                else => space,
            };
        },
    };

    // Measure node
    const measured_size: Size(f32) = measure_function.measure(
        switch (run_mode) {
            .compute_size => known_dimensions,
            .perform_layout => Size(?f32).none,
            .perform_hidden_layout => @panic("computeLeafLayout called with RunMode.perform_hidden_layout"),
        },
        measure_available_space,
    );
    const clamped_size = maybeClamp(
        known_dimensions.@"or"(node_size).unwrapOr(measured_size.add(content_box_inset.sumAxes())),
        node_min_size,
        node_max_size,
    );
    const unpadded_size: Size(f32) = .{
        .width = clamped_size.width,
        .height = @max(clamped_size.height, if (aspect_ratio) |ratio| clamped_size.width / ratio else 0.0),
    };
    const size = maybeMax(unpadded_size, someSize(padding_border.sumAxes()));

    // A scroll container's own padding at the end of the content is part of its scrollable
    // overflow region, so it is included in the overflow rect. Boxes that are not scroll
    // containers do not extend their overflow region by their own padding.
    const scrollable_overflow_rect = blk: {
        const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
        const is_rtl = style.getDirection().isRtl();
        const start_padding = if (is_rtl) padding.right else padding.left;
        const end_padding = if (is_rtl) padding.left else padding.right;
        const client_width = @max(size.width - border.horizontalAxisSum() - scrollbar_gutter.x, 0.0);
        const content_end = start_padding + measured_size.width + (if (is_scroll_container) end_padding else 0.0);
        const rect: Rect(f32) = .{
            .left = if (is_rtl) @min(client_width - content_end, 0.0) else 0.0,
            .right = if (is_rtl) client_width else content_end,
            .top = 0.0,
            .bottom = padding.top + measured_size.height + (if (is_scroll_container) padding.bottom else 0.0),
        };
        break :blk finalizeScrollableOverflow(
            rect,
            size.sub(border.sumAxes()).sub(.{ .width = scrollbar_gutter.x, .height = scrollbar_gutter.y }),
            .{ .x = is_rtl, .y = false },
            is_scroll_container,
        );
    };

    return .{
        .size = size,
        .scrollable_overflow_rect = scrollable_overflow_rect,
        .baselines = Baselines.none,
        .top_margin = CollapsibleMarginSet.zero,
        .bottom_margin = CollapsibleMarginSet.zero,
        .margins_can_collapse_through = !has_styles_preventing_being_collapsed_through and
            size.height == 0.0 and
            measured_size.height == 0.0,
        .oof_candidates = OofCandidates.none,
        .oof_positioning_area = null,
    };
}

/// `size.map(Some)`
inline fn someSize(size: Size(f32)) Size(?f32) {
    return .{ .width = size.width, .height = size.height };
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Style = style_mod.Style;
const Dimension = style_mod.Dimension;
const LengthPercentage = style_mod.LengthPercentage;
const Line = geometry.Line;

/// A measure function returning a fixed content size, recording its arguments
const FixedMeasure = struct {
    size: Size(f32),
    calls: usize = 0,
    last_known: Size(?f32) = Size(?f32).none,
    last_available: Size(AvailableSpace) = Size(AvailableSpace).max_content,

    pub fn measure(self: *FixedMeasure, known: Size(?f32), available: Size(AvailableSpace)) Size(f32) {
        self.calls += 1;
        self.last_known = known;
        self.last_available = available;
        return self.size;
    }
};

fn leafInputs(run_mode: layout.RunMode, sizing_mode: layout.SizingMode) LayoutInput {
    return .{
        .run_mode = run_mode,
        .sizing_mode = sizing_mode,
        .axis = .both,
        .known_dimensions = Size(?f32).none,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 200.0, .height = 100.0 },
        .available_space = .{ .width = .{ .definite = 200.0 }, .height = .{ .definite = 100.0 } },
        .vertical_margins_are_collapsible = Line(bool).false,
    };
}

test "leaf with measure function, padding and border" {
    var style: Style = .{};
    style.padding = Rect(LengthPercentage).length(5.0);
    style.border = .{ .left = .length(1.0), .right = .length(1.0), .top = .length(2.0), .bottom = .length(2.0) };
    var m: FixedMeasure = .{ .size = .{ .width = 30.0, .height = 20.0 } };
    const out = computeLeafLayout(leafInputs(.perform_layout, .inherent_size), &style, style_mod.NoCalc{}, &m);
    try testing.expectEqual(Size(f32){ .width = 42.0, .height = 34.0 }, out.size);
    try testing.expectEqual(@as(usize, 1), m.calls);
    try testing.expectEqual(Size(?f32).none, m.last_known);
    try testing.expect(m.last_available.width.eql(.{ .definite = 188.0 }));
    try testing.expect(!out.margins_can_collapse_through);
    // overflow rect: content box offset by padding, not extended by end padding
    try testing.expectEqual(Rect(f32){ .left = 0.0, .right = 35.0, .top = 0.0, .bottom = 25.0 }, out.scrollable_overflow_rect.rect());
}

test "leaf with definite size, percentages, min/max and aspect ratio" {
    var style: Style = .{};
    style.size = .{ .width = Dimension.percent(0.5), .height = Dimension.auto };
    style.aspect_ratio = 2.0;
    style.max_size.width = .length(80.0);
    var m: FixedMeasure = .{ .size = .{ .width = 1.0, .height = 1.0 } };
    const out = computeLeafLayout(leafInputs(.perform_layout, .inherent_size), &style, style_mod.NoCalc{}, &m);
    // width 100 from 50% of 200, clamped to 80; height from the aspect ratio of the unclamped size (50)
    try testing.expectEqual(Size(f32){ .width = 80.0, .height = 50.0 }, out.size);
    try testing.expect(m.last_available.width.eql(.{ .definite = 80.0 }));
}

test "leaf early return for compute_size with both dimensions known" {
    var style: Style = .{};
    style.size = Size(Dimension).fromLengths(10.0, 20.0);
    style.padding = Rect(LengthPercentage).length(15.0);
    var m: FixedMeasure = .{ .size = .{ .width = 1.0, .height = 1.0 } };
    const out = computeLeafLayout(leafInputs(.compute_size, .inherent_size), &style, style_mod.NoCalc{}, &m);
    try testing.expectEqual(@as(usize, 0), m.calls);
    try testing.expectEqual(Size(f32){ .width = 30.0, .height = 30.0 }, out.size);
}

test "leaf content_size mode ignores size styles" {
    var style: Style = .{};
    style.size = Size(Dimension).fromLengths(10.0, 20.0);
    var m: FixedMeasure = .{ .size = .{ .width = 7.0, .height = 9.0 } };
    var in = leafInputs(.compute_size, .content_size);
    in.known_dimensions.width = 3.0;
    const out = computeLeafLayout(in, &style, style_mod.NoCalc{}, &m);
    try testing.expectEqual(Size(f32){ .width = 3.0, .height = 9.0 }, out.size);
    try testing.expectEqual(Size(?f32){ .width = 3.0, .height = null }, m.last_known);
    try testing.expect(m.last_available.width.eql(.{ .definite = 3.0 }));
}

test "empty block leaf can be collapsed through" {
    var style: Style = .{};
    style.display = .block;
    var m: FixedMeasure = .{ .size = Size(f32).zero };
    const out = computeLeafLayout(leafInputs(.perform_layout, .inherent_size), &style, style_mod.NoCalc{}, &m);
    try testing.expect(out.margins_can_collapse_through);
}

test "scroll container leaf reserves a scrollbar gutter and includes end padding in its overflow" {
    var style: Style = .{};
    style.overflow = .{ .x = .visible, .y = .scroll };
    style.scrollbar_width = 10.0;
    style.padding = Rect(LengthPercentage).length(4.0);
    style.direction = .rtl;
    var m: FixedMeasure = .{ .size = .{ .width = 20.0, .height = 20.0 } };
    const out = computeLeafLayout(leafInputs(.perform_layout, .inherent_size), &style, style_mod.NoCalc{}, &m);
    try testing.expectEqual(Size(f32){ .width = 38.0, .height = 28.0 }, out.size);
    try testing.expect(m.last_available.width.eql(.{ .definite = 182.0 }));
    // client width 28, content end 4 + 20 + 4
    try testing.expectEqual(Rect(f32){ .left = 0.0, .right = 28.0, .top = 0.0, .bottom = 28.0 }, out.scrollable_overflow_rect.rect());
    try testing.expectEqual(Point(bool){ .x = true, .y = false }, out.scrollable_overflow_rect.isReversed());
}
