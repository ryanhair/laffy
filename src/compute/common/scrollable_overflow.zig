//! Generic CSS scrollable overflow code that is shared between all CSS algorithms.
const std = @import("std");
const geometry = @import("../../geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style = @import("../../style.zig");
const Contain = style.Contain;
const Overflow = style.Overflow;
const ScrollableOverflow = @import("../../tree/layout.zig").ScrollableOverflow;
const sys = @import("../../util/sys.zig");

/// Container geometry shared by its children's scrollable overflow contributions.
pub const ScrollableOverflowContainer = struct {
    /// Whether the parent clips unreachable overflow and includes end padding.
    parent_is_scroll_container: bool,
    /// The extent of the parent's padding-box frame, excluding scrollbar gutters.
    parent_size: Size(f32),
    /// The scroll origin in each physical axis.
    reversed: Point(bool),
    /// The parent's resolved padding.
    padding: Rect(f32),
};

/// Determine the rectangle that a given node contributes to its parent's scrollable overflow
/// rectangle.
///
/// `location`, child overflow, and the result use physical axes in the parent's padding-box frame.
/// Child overflow is relative to its inner border edge, so the child's border is added first.
/// `parent_size` is the extent of the parent frame (excluding scrollbar gutters). The node's own
/// `scrollable_overflow_rect` propagates to the parent only where the node's overflow allows it
/// to escape: a scroll container (`hidden`/`scroll` in either axis) clips both axes and
/// contributes only its border box, while for non-scroll-containers `clip` clips just its own
/// axis and `visible` propagates.
///
/// Boxes positioned wholly in the unreachable scrollable overflow region (entirely before the
/// scroll origin in either axis) must be clipped by a scroll container and are excluded from its
/// scrollable overflow region (<https://www.w3.org/TR/css-overflow-3/#scrollable>). This
/// exclusion only applies when the parent is a scroll container: boxes with `overflow: visible`
/// have no unreachable region of their own, so all of their content contributes.
///
/// A box whose containment contains its scrollable overflow (layout or paint containment)
/// contributes only its border box, regardless of its overflow style.
///
/// End padding extends the in-flow child's margin edge, not its propagated overflow.
/// Union with the border/overflow contribution prevents negative margins from shrinking it.
pub inline fn computeScrollableOverflowContribution(
    location: Point(f32),
    size: Size(f32),
    child_scrollable_overflow_rect: Rect(f32),
    border: Rect(f32),
    overflow: Point(Overflow),
    contain: Contain,
    container: *const ScrollableOverflowContainer,
    margin: Rect(f32),
) Rect(f32) {
    const parent_is_scroll_container = container.parent_is_scroll_container;
    const parent_size = container.parent_size;
    const reversed = container.reversed;
    const padding = container.padding;
    const scrollable_overflow_rect: Rect(f32) = .{
        .left = child_scrollable_overflow_rect.left + border.left,
        .right = child_scrollable_overflow_rect.right + border.left,
        .top = child_scrollable_overflow_rect.top + border.top,
        .bottom = child_scrollable_overflow_rect.bottom + border.top,
    };
    const is_scroll_container = overflow.x.isScrollContainer() or overflow.y.isScrollContainer();
    const overflow_is_contained = contain.containsScrollableOverflow();
    const propagates: Point(bool) = .{
        .x = !is_scroll_container and !overflow_is_contained and overflow.x == .visible,
        .y = !is_scroll_container and !overflow_is_contained and overflow.y == .visible,
    };
    const end_extent: Size(f32) = .{
        .width = if (propagates.x) sys.f32Max(size.width, scrollable_overflow_rect.right) else size.width,
        .height = if (propagates.y) sys.f32Max(size.height, scrollable_overflow_rect.bottom) else size.height,
    };
    if (end_extent.width <= 0.0 or end_extent.height <= 0.0) {
        return Rect(f32).zero;
    }
    const start_extent: Point(f32) = .{
        .x = if (propagates.x) sys.f32Min(0.0, scrollable_overflow_rect.left) else 0.0,
        .y = if (propagates.y) sys.f32Min(0.0, scrollable_overflow_rect.top) else 0.0,
    };
    const contribution: Rect(f32) = .{
        .left = location.x + start_extent.x,
        .right = location.x + end_extent.width,
        .top = location.y + start_extent.y,
        .bottom = location.y + end_extent.height,
    };
    const is_wholly_unreachable =
        (if (reversed.x) contribution.left >= parent_size.width else contribution.right <= 0.0) or
        (if (reversed.y) contribution.top >= parent_size.height else contribution.bottom <= 0.0);
    if (parent_is_scroll_container and is_wholly_unreachable) {
        return Rect(f32).zero;
    } else {
        if (parent_is_scroll_container) {
            var padded = contribution;
            if (reversed.x) {
                padded.left = sys.f32Min(padded.left, location.x - sys.f32Max(0.0, padding.left + margin.left));
            } else {
                padded.right = sys.f32Max(padded.right, location.x + size.width + sys.f32Max(0.0, padding.right + margin.right));
            }
            if (reversed.y) {
                padded.top = sys.f32Min(padded.top, location.y - sys.f32Max(0.0, padding.top + margin.top));
            } else {
                padded.bottom = sys.f32Max(padded.bottom, location.y + size.height + sys.f32Max(0.0, padding.bottom + margin.bottom));
            }
            return padded;
        } else {
            return contribution;
        }
    }
}

/// Pack an algorithm's physical accumulator and clip unreachable
/// overflow only for scroll containers. All geometry is unpacked until this output boundary.
pub fn finalizeScrollableOverflow(
    rect: Rect(f32),
    size: Size(f32),
    reversed: Point(bool),
    is_scroll_container: bool,
) ScrollableOverflow {
    var result = rect;
    const clamped_size: Size(f32) = .{ .width = sys.f32Max(size.width, 0.0), .height = sys.f32Max(size.height, 0.0) };
    const final_reversed: Point(bool) = if (is_scroll_container) blk: {
        if (reversed.x) {
            result.right = sys.f32Min(result.right, clamped_size.width);
        } else {
            result.left = 0.0;
        }
        if (reversed.y) {
            result.bottom = sys.f32Min(result.bottom, clamped_size.height);
        } else {
            result.top = 0.0;
        }
        break :blk reversed;
    } else .{ .x = false, .y = false };
    return ScrollableOverflow.new(result, final_reversed);
}

const testing = std.testing;

test "computeScrollableOverflowContribution" {
    const visible: Point(Overflow) = .{ .x = .visible, .y = .visible };
    const container: ScrollableOverflowContainer = .{
        .parent_is_scroll_container = false,
        .parent_size = .{ .width = 100.0, .height = 100.0 },
        .reversed = .{ .x = false, .y = false },
        .padding = Rect(f32).zero,
    };
    // A visible child propagates its own overflow (offset by its border)
    const r = computeScrollableOverflowContribution(
        .{ .x = 10.0, .y = 20.0 },
        .{ .width = 30.0, .height = 40.0 },
        .{ .left = -5.0, .right = 50.0, .top = 0.0, .bottom = 10.0 },
        Rect(f32).new(1, 1, 2, 2),
        visible,
        Contain.none,
        &container,
        Rect(f32).zero,
    );
    try testing.expectEqual(Rect(f32){ .left = 6.0, .right = 61.0, .top = 20.0, .bottom = 60.0 }, r);
    // A scroll container child contributes only its border box
    const s = computeScrollableOverflowContribution(
        .{ .x = 10.0, .y = 20.0 },
        .{ .width = 30.0, .height = 40.0 },
        .{ .left = -5.0, .right = 50.0, .top = 0.0, .bottom = 10.0 },
        Rect(f32).zero,
        .{ .x = .hidden, .y = .visible },
        Contain.none,
        &container,
        Rect(f32).zero,
    );
    try testing.expectEqual(Rect(f32){ .left = 10.0, .right = 40.0, .top = 20.0, .bottom = 60.0 }, s);
    // Empty boxes contribute nothing
    const e = computeScrollableOverflowContribution(.{ .x = 10.0, .y = 20.0 }, .{ .width = 0.0, .height = 40.0 }, Rect(f32).zero, Rect(f32).zero, visible, Contain.none, &container, Rect(f32).zero);
    try testing.expectEqual(Rect(f32).zero, e);
    // In a scroll container, wholly unreachable boxes are excluded and end padding is included
    var scroll = container;
    scroll.parent_is_scroll_container = true;
    scroll.padding = Rect(f32).new(0, 7, 0, 3);
    const u = computeScrollableOverflowContribution(.{ .x = -50.0, .y = 0.0 }, .{ .width = 30.0, .height = 40.0 }, Rect(f32).zero, Rect(f32).zero, visible, Contain.none, &scroll, Rect(f32).zero);
    try testing.expectEqual(Rect(f32).zero, u);
    const p = computeScrollableOverflowContribution(.{ .x = 0.0, .y = 0.0 }, .{ .width = 30.0, .height = 40.0 }, Rect(f32).zero, Rect(f32).zero, visible, Contain.none, &scroll, Rect(f32).new(0, 1, 0, 1));
    try testing.expectEqual(Rect(f32){ .left = 0.0, .right = 38.0, .top = 0.0, .bottom = 44.0 }, p);
}

test "finalizeScrollableOverflow" {
    const rect: Rect(f32) = .{ .left = -10.0, .right = 150.0, .top = -5.0, .bottom = 80.0 };
    const plain = finalizeScrollableOverflow(rect, .{ .width = 100.0, .height = 100.0 }, .{ .x = true, .y = false }, false);
    try testing.expectEqual(rect, plain.rect());
    try testing.expectEqual(Point(bool){ .x = false, .y = false }, plain.isReversed());
    const scroll = finalizeScrollableOverflow(rect, .{ .width = 100.0, .height = 100.0 }, .{ .x = true, .y = false }, true);
    try testing.expectEqual(Rect(f32){ .left = -10.0, .right = 100.0, .top = 0.0, .bottom = 80.0 }, scroll.rect());
    try testing.expectEqual(Point(bool){ .x = true, .y = false }, scroll.isReversed());
}
