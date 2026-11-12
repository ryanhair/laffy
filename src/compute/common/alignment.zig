//! Generic CSS alignment code that is shared between both the Flexbox and CSS Grid algorithms.
const std = @import("std");
const style = @import("../../style.zig");
const AlignContent = style.AlignContent;
const AlignContentKeyword = style.AlignContentKeyword;
const AlignItems = style.AlignItems;
const AlignItemsKeyword = style.AlignItemsKeyword;
const Overflow = style.Overflow;

/// The first baseline of a child box (measured from the top of its border box, like `Baselines`) as used
/// for baseline alignment and for determining its container's baseline, given the baseline it reported, its
/// border-box height, and its vertical `overflow`.
///
/// Scroll containers' baselines are determined from their content as if scrolled to the initial position, but are
/// additionally clamped to their border box. A scroll container with no baseline synthesizes one from its border-box
/// bottom edge. See <https://github.com/w3c/csswg-drafts/issues/7660>
pub fn childFirstBaseline(first_baseline: ?f32, height: f32, overflow_y: Overflow) ?f32 {
    if (overflow_y.isScrollContainer()) {
        return @max(@min(first_baseline orelse height, height), 0.0);
    } else {
        return first_baseline;
    }
}

/// Resolve the `safe`/`unsafe` overflow-position fallback for a self-level alignment value
/// (used by `align-self` / `justify-self`-style sites and by absolutely-positioned items in
/// flex/grid). If the alignment subject overflows its alignment container and the requested
/// alignment is `safe`, fall back to logical `start` per CSS Box Alignment
/// <https://www.w3.org/TR/css-align-3/#overflow-values>. Otherwise drop the safety modifier
/// and return the bare keyword.
pub fn resolveSelfAlignmentSafety(alignment: AlignItems, overflows: bool) AlignItemsKeyword {
    if (alignment.safety == .safe and overflows) {
        return .start;
    } else {
        return alignment.keyword;
    }
}

/// Resolve any spec-defined fallbacks for the given `AlignContent` value, returning the
/// bare position keyword the alignment math should use.
///
/// In addition to the spec at <https://www.w3.org/TR/css-align-3/> this implementation follows
/// the resolution of <https://github.com/w3c/csswg-drafts/issues/10154>.
///
/// `normal` behaves differently in each layout mode, so callers must resolve
/// `AlignContentKeyword.normal` to the keyword it behaves as before calling this function
/// (if it is not resolved then it is treated as `stretch`).
pub fn applyAlignmentFallback(free_space: f32, num_items: usize, alignment_mode: AlignContent) AlignContentKeyword {
    // normal must be resolved before computing content alignment
    std.debug.assert(alignment_mode.keyword != .normal);
    var keyword: AlignContentKeyword = switch (alignment_mode.keyword) {
        .normal => .stretch,
        else => |keyword| keyword,
    };
    var is_safe = alignment_mode.safety == .safe;

    // 1. If there is only a single item being aligned or the items overflow the container, the
    //    distributed alignment keywords (`stretch`, `space-*`) fall back to a positional keyword.
    //    The `space-*` fallbacks gain implicit `safe` semantics so step 2 can flip them to `start`
    //    on overflow, whereas `stretch` falls back to plain `flex-start`.
    //    https://www.w3.org/TR/css-align-3/#distribution-values
    if (num_items <= 1 or free_space <= 0.0) {
        switch (keyword) {
            .stretch => keyword = .flex_start,
            .space_between => {
                keyword = .flex_start;
                is_safe = true;
            },
            .space_around, .space_evenly => {
                keyword = .center;
                is_safe = true;
            },
            else => {},
        }
    }

    // 2. Safe alignment falls back to `start` whenever the alignment subject would overflow the
    //    alignment container.
    if (free_space <= 0.0 and is_safe) {
        keyword = .start;
    }

    return keyword;
}

/// Generic alignment function that is used:
///   - For both align-content and justify-content alignment
///   - For both the Flexbox and CSS Grid algorithms
///
/// CSS Grid does not apply gaps as part of alignment, so the gap parameter should
/// always be set to zero for CSS Grid.
pub fn computeAlignmentOffset(
    free_space: f32,
    num_items: usize,
    gap: f32,
    alignment_mode: AlignContentKeyword,
    layout_is_flex_reversed: bool,
    is_first: bool,
) f32 {
    if (is_first) {
        return switch (alignment_mode) {
            .start => 0.0,
            .flex_start => if (layout_is_flex_reversed) free_space else 0.0,
            .end => free_space,
            .flex_end => if (layout_is_flex_reversed) 0.0 else free_space,
            .center => free_space / 2.0,
            .normal, .stretch => 0.0,
            .space_between => 0.0,
            .space_around => if (free_space >= 0.0)
                (free_space / @as(f32, @floatFromInt(num_items))) / 2.0
            else
                free_space / 2.0,
            .space_evenly => if (free_space >= 0.0)
                free_space / @as(f32, @floatFromInt(num_items + 1))
            else
                free_space / 2.0,
        };
    } else {
        const clamped_free_space = @max(free_space, 0.0);
        return gap + switch (alignment_mode) {
            .start, .flex_start, .end, .flex_end, .center, .normal, .stretch => 0.0,
            .space_between => clamped_free_space / @as(f32, @floatFromInt(num_items - 1)),
            .space_around => clamped_free_space / @as(f32, @floatFromInt(num_items)),
            .space_evenly => clamped_free_space / @as(f32, @floatFromInt(num_items + 1)),
        };
    }
}

const testing = std.testing;

test "childFirstBaseline" {
    try testing.expectEqual(@as(?f32, 5.0), childFirstBaseline(5.0, 3.0, .visible));
    try testing.expectEqual(@as(?f32, null), childFirstBaseline(null, 3.0, .clip));
    try testing.expectEqual(@as(?f32, 3.0), childFirstBaseline(5.0, 3.0, .hidden));
    try testing.expectEqual(@as(?f32, 3.0), childFirstBaseline(null, 3.0, .scroll));
    try testing.expectEqual(@as(?f32, 0.0), childFirstBaseline(-2.0, 3.0, .scroll));
}

test "resolveSelfAlignmentSafety" {
    try testing.expectEqual(AlignItemsKeyword.start, resolveSelfAlignmentSafety(AlignItems.safe_end, true));
    try testing.expectEqual(AlignItemsKeyword.end, resolveSelfAlignmentSafety(AlignItems.safe_end, false));
    try testing.expectEqual(AlignItemsKeyword.end, resolveSelfAlignmentSafety(AlignItems.end, true));
}

test "applyAlignmentFallback" {
    try testing.expectEqual(AlignContentKeyword.flex_start, applyAlignmentFallback(10.0, 1, AlignContent.stretch));
    try testing.expectEqual(AlignContentKeyword.stretch, applyAlignmentFallback(10.0, 2, AlignContent.stretch));
    try testing.expectEqual(AlignContentKeyword.start, applyAlignmentFallback(-1.0, 3, AlignContent.space_between));
    try testing.expectEqual(AlignContentKeyword.center, applyAlignmentFallback(10.0, 1, AlignContent.space_around));
    try testing.expectEqual(AlignContentKeyword.start, applyAlignmentFallback(-1.0, 3, AlignContent.space_evenly));
    try testing.expectEqual(AlignContentKeyword.start, applyAlignmentFallback(0.0, 3, AlignContent.safe_end));
    try testing.expectEqual(AlignContentKeyword.end, applyAlignmentFallback(0.0, 3, AlignContent.end));
    try testing.expectEqual(AlignContentKeyword.flex_start, applyAlignmentFallback(-5.0, 3, AlignContent.stretch));
}

test "computeAlignmentOffset" {
    try testing.expectEqual(@as(f32, 10.0), computeAlignmentOffset(10.0, 2, 1.0, .flex_start, true, true));
    try testing.expectEqual(@as(f32, 0.0), computeAlignmentOffset(10.0, 2, 1.0, .flex_end, true, true));
    try testing.expectEqual(@as(f32, 5.0), computeAlignmentOffset(10.0, 2, 1.0, .center, false, true));
    try testing.expectEqual(@as(f32, 2.5), computeAlignmentOffset(10.0, 2, 1.0, .space_around, false, true));
    try testing.expectEqual(@as(f32, 3.0), computeAlignmentOffset(9.0, 2, 1.0, .space_evenly, false, true));
    try testing.expectEqual(@as(f32, -2.0), computeAlignmentOffset(-4.0, 2, 1.0, .space_evenly, false, true));
    try testing.expectEqual(@as(f32, 11.0), computeAlignmentOffset(10.0, 2, 1.0, .space_between, false, false));
    try testing.expectEqual(@as(f32, 6.0), computeAlignmentOffset(10.0, 2, 1.0, .space_around, false, false));
    try testing.expectEqual(@as(f32, 1.0), computeAlignmentOffset(-10.0, 2, 1.0, .space_between, false, false));
    try testing.expectEqual(@as(f32, 1.0), computeAlignmentOffset(10.0, 2, 1.0, .end, false, false));
}
