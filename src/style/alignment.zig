//! Style types for controlling alignment.
//!
//! The public alignment types (`AlignItems`, `AlignContent`, and their aliases) are
//! structs with two orthogonal fields: a *position* keyword
//! (`AlignItemsKeyword` / `AlignContentKeyword`) and an *overflow-position*
//! modifier (`AlignmentSafety`). The CSS spellings — `start`, `end`,
//! `flex_start`, `flex_end`, `center`, `stretch`, `space_between`, …, `safe_start`,
//! `safe_end`, `safe_flex_start`, `safe_flex_end`, `safe_center` — are exposed as
//! declarations on the structs.
//!
//! The structs are `packed struct(u16)` so that they can be compared with `==`.
//! Upstream's `keyword()` accessor is not ported because it would clash with the `keyword`
//! field: read the field directly.
const std = @import("std");
const Direction = @import("../style.zig").Direction;

/// The position-keyword half of `AlignItems` (and its aliases `AlignSelf`,
/// `JustifyItems`, `JustifySelf`).
pub const AlignItemsKeyword = enum(u8) {
    /// The layout mode's default alignment: usually `stretch`, but `start` in some cases.
    normal,
    /// Items are packed toward the start of the axis.
    start,
    /// Items are packed toward the end of the axis.
    end,
    /// Items are packed towards the flex-relative start of the axis.
    ///
    /// For flex containers with flex_direction row_reverse or column_reverse this is
    /// equivalent to end. In all other cases it is equivalent to start.
    flex_start,
    /// Items are packed towards the flex-relative end of the axis.
    ///
    /// For flex containers with flex_direction row_reverse or column_reverse this is
    /// equivalent to start. In all other cases it is equivalent to end.
    flex_end,
    /// Items are packed toward the start of the axis as determined by the item's own
    /// writing mode/direction (rather than the container's).
    ///
    /// Equivalent to start when the item's `direction` matches the container's, and
    /// to end when they differ (in the inline axis).
    self_start,
    /// Items are packed toward the end of the axis as determined by the item's own
    /// writing mode/direction (rather than the container's).
    ///
    /// Equivalent to end when the item's `direction` matches the container's, and
    /// to start when they differ (in the inline axis).
    self_end,
    /// Items are packed along the center of the cross axis.
    center,
    /// Items are aligned such as their baselines align.
    baseline,
    /// Stretch to fill the container.
    stretch,

    /// The default value
    pub const default: AlignItemsKeyword = .normal;
};

/// The position-keyword half of `AlignContent` (and its alias `JustifyContent`).
pub const AlignContentKeyword = enum(u8) {
    /// The layout mode's default alignment: `stretch` for flex and grid containers, `start`
    /// for block containers.
    normal,
    /// Items are packed toward the start of the axis.
    start,
    /// Items are packed toward the end of the axis.
    end,
    /// Items are packed towards the flex-relative start of the axis.
    flex_start,
    /// Items are packed towards the flex-relative end of the axis.
    flex_end,
    /// Items are centered around the middle of the axis.
    center,
    /// Items are stretched to fill the container.
    stretch,
    /// The first and last items are aligned flush with the edges of the container
    /// (no gap). The gap between items is distributed evenly.
    space_between,
    /// The gap between the first and last items is exactly THE SAME as the gap
    /// between items. The gaps are distributed evenly.
    space_evenly,
    /// The gap between the first and last items is exactly HALF the gap between
    /// items. The gaps are distributed evenly in proportion to these ratios.
    space_around,

    /// The default value
    pub const default: AlignContentKeyword = .normal;

    /// Returns the reversed keyword for RTL (right-to-left) contexts: `start`↔`end`,
    /// `flex_start`↔`flex_end`. `stretch` maps to `end` to preserve the layout
    /// algorithms' historical handling. `normal`, `center` and the distribution keywords
    /// (`space_between`, `space_evenly`, `space_around`) are unaffected because their
    /// visual placement is direction-symmetric.
    pub fn reversed(self: AlignContentKeyword) AlignContentKeyword {
        return switch (self) {
            .start => .end,
            .end => .start,
            .flex_start => .flex_end,
            .flex_end => .flex_start,
            .stretch => .end,
            .normal, .center, .space_between, .space_evenly, .space_around => self,
        };
    }
};

/// The overflow-position modifier per [CSS Box Alignment §4.3][css-align-overflow].
///
/// `safe` falls back to start-edge alignment when the alignment subject would
/// overflow the alignment container, so the start of the content stays visible.
/// `unsafe` keeps the requested alignment even when that causes overflow at the
/// start edge. `default` (no overflow-position keyword specified) behaves as
/// `unsafe`, except for absolutely positioned boxes whose alignment is instead
/// adjusted to minimize overflow per [CSS Box Alignment §4.4.1.2][css-align-abspos].
///
/// CSS only defines `safe` / `unsafe` against the position values `start`, `end`,
/// `flex-start`, `flex-end`, `center`. The struct shape does not enforce that
/// constraint at the type level — the parser rejects invalid combinations, and
/// the compute pass treats `safe` paired with a non-position keyword (`stretch`,
/// `baseline`, `space-*`) the same as `unsafe`.
///
/// [css-align-overflow]: https://www.w3.org/TR/css-align-3/#overflow-values
/// [css-align-abspos]: https://www.w3.org/TR/css-align-3/#auto-safety-position
pub const AlignmentSafety = enum(u8) {
    /// No overflow-position keyword specified. Behaves as `unsafe`, except for absolutely
    /// positioned boxes, whose alignment is adjusted to minimize overflow of their
    /// containing block.
    default,
    /// Keeps the requested alignment even when the subject overflows the alignment
    /// container at the start edge.
    unsafe,
    /// Falls back to the start edge when the subject would overflow, to avoid data
    /// loss.
    safe,
};

/// Used to control how child nodes are aligned.
/// For Flexbox it controls alignment in the cross axis.
/// For Grid it controls alignment in the block axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/align-items)
pub const AlignItems = packed struct(u16) {
    /// Position keyword.
    keyword: AlignItemsKeyword = .normal,
    /// Overflow-position modifier (`safe` / `unsafe`).
    safety: AlignmentSafety = .default,

    /// The default value (`normal`)
    pub const default: AlignItems = normal;

    /// The layout mode's default alignment. See `AlignItemsKeyword.normal`.
    pub const normal: AlignItems = .{ .keyword = .normal, .safety = .default };
    /// Items are packed toward the start of the axis.
    pub const start: AlignItems = .{ .keyword = .start, .safety = .default };
    /// Items are packed toward the end of the axis.
    pub const end: AlignItems = .{ .keyword = .end, .safety = .default };
    /// Items are packed towards the flex-relative start of the axis.
    pub const flex_start: AlignItems = .{ .keyword = .flex_start, .safety = .default };
    /// Items are packed towards the flex-relative end of the axis.
    pub const flex_end: AlignItems = .{ .keyword = .flex_end, .safety = .default };
    /// Items are packed toward the start of the axis as determined by the item's own direction.
    pub const self_start: AlignItems = .{ .keyword = .self_start, .safety = .default };
    /// Items are packed toward the end of the axis as determined by the item's own direction.
    pub const self_end: AlignItems = .{ .keyword = .self_end, .safety = .default };
    /// Items are packed along the center of the cross axis.
    pub const center: AlignItems = .{ .keyword = .center, .safety = .default };
    /// Items are aligned such as their baselines align.
    pub const baseline: AlignItems = .{ .keyword = .baseline, .safety = .default };
    /// Stretch to fill the container.
    pub const stretch: AlignItems = .{ .keyword = .stretch, .safety = .default };
    /// Like `start`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_start: AlignItems = .{ .keyword = .start, .safety = .safe };
    /// Like `end`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_end: AlignItems = .{ .keyword = .end, .safety = .safe };
    /// Like `flex_start`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_flex_start: AlignItems = .{ .keyword = .flex_start, .safety = .safe };
    /// Like `flex_end`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_flex_end: AlignItems = .{ .keyword = .flex_end, .safety = .safe };
    /// Like `center`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_center: AlignItems = .{ .keyword = .center, .safety = .safe };
    /// Like `self_start`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_self_start: AlignItems = .{ .keyword = .self_start, .safety = .safe };
    /// Like `self_end`, but falls back to `start` when the alignment subject overflows the
    /// alignment container, to avoid data loss.
    pub const safe_self_end: AlignItems = .{ .keyword = .self_end, .safety = .safe };

    /// Returns `true` iff this carries the `safe` overflow-position modifier.
    pub inline fn isSafe(self: AlignItems) bool {
        return self.safety == .safe;
    }

    /// Returns this alignment with the given overflow-position modifier.
    pub inline fn withSafety(self: AlignItems, safety: AlignmentSafety) AlignItems {
        return .{ .keyword = self.keyword, .safety = safety };
    }

    /// Returns true if the keyword is `stretch` or `normal` (ignoring any overflow-position
    /// modifier).
    pub inline fn isStretchOrNormal(self: AlignItems) bool {
        return self.keyword == .stretch or self.keyword == .normal;
    }

    /// Resolve the writing-mode-relative `self_start`/`self_end` keywords to `start`/`end`
    /// based on the item's own `direction` per CSS Box Alignment §5.2
    /// <https://www.w3.org/TR/css-align-3/#self-alignment>. All other keywords are
    /// returned unchanged.
    ///
    /// The `start`/`end` keywords used by the compute paths are relative to the
    /// *container's* writing mode/direction, so in the inline axis `self_start` resolves
    /// to `start` when the item's direction matches the container's and to `end` when it
    /// differs. laffy only supports the `horizontal-tb` writing mode, so in the block
    /// axis `self_start`/`self_end` always resolve to `start`/`end` respectively.
    pub fn resolveSelfRelative(
        self: AlignItems,
        item_direction: Direction,
        container_direction: Direction,
        axis_is_inline: bool,
    ) AlignItems {
        const flip = axis_is_inline and item_direction != container_direction;
        const keyword: AlignItemsKeyword = switch (self.keyword) {
            .self_start => if (flip) .end else .start,
            .self_end => if (flip) .start else .end,
            else => |other| other,
        };
        return .{ .keyword = keyword, .safety = self.safety };
    }
};

/// Used to control how child nodes are aligned.
/// Does not apply to Flexbox, and will be ignored if specified on a flex container.
/// For Grid it controls alignment in the inline axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/justify-items)
pub const JustifyItems = AlignItems;
/// Controls alignment of an individual node.
///
/// Overrides the parent Node's `AlignItems` property.
/// For Flexbox it controls alignment in the cross axis.
/// For Grid it controls alignment in the block axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/align-self)
pub const AlignSelf = AlignItems;
/// Controls alignment of an individual node.
///
/// Overrides the parent Node's `JustifyItems` property.
/// Does not apply to Flexbox, and will be ignored if specified on a flex child.
/// For Grid it controls alignment in the inline axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/justify-self)
pub const JustifySelf = AlignItems;

/// Sets the distribution of space between and around content items.
/// For Flexbox it controls alignment in the cross axis.
/// For Grid it controls alignment in the block axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/align-content)
pub const AlignContent = packed struct(u16) {
    /// Position keyword.
    keyword: AlignContentKeyword = .normal,
    /// Overflow-position modifier (`safe` / `unsafe`).
    safety: AlignmentSafety = .default,

    /// The default value (`normal`)
    pub const default: AlignContent = normal;

    /// The layout mode's default alignment. See `AlignContentKeyword.normal`.
    pub const normal: AlignContent = .{ .keyword = .normal, .safety = .default };
    /// Items are packed toward the start of the axis.
    pub const start: AlignContent = .{ .keyword = .start, .safety = .default };
    /// Items are packed toward the end of the axis.
    pub const end: AlignContent = .{ .keyword = .end, .safety = .default };
    /// Items are packed towards the flex-relative start of the axis.
    pub const flex_start: AlignContent = .{ .keyword = .flex_start, .safety = .default };
    /// Items are packed towards the flex-relative end of the axis.
    pub const flex_end: AlignContent = .{ .keyword = .flex_end, .safety = .default };
    /// Items are centered around the middle of the axis.
    pub const center: AlignContent = .{ .keyword = .center, .safety = .default };
    /// Items are stretched to fill the container.
    pub const stretch: AlignContent = .{ .keyword = .stretch, .safety = .default };
    /// The first and last items are aligned flush with the edges of the container.
    pub const space_between: AlignContent = .{ .keyword = .space_between, .safety = .default };
    /// The gap between the first and last items equals the gap between items.
    pub const space_evenly: AlignContent = .{ .keyword = .space_evenly, .safety = .default };
    /// The gap between the first and last items is half the gap between items.
    pub const space_around: AlignContent = .{ .keyword = .space_around, .safety = .default };
    /// Like `start`, but falls back to `start` when the content overflows the alignment
    /// container, to avoid data loss.
    pub const safe_start: AlignContent = .{ .keyword = .start, .safety = .safe };
    /// Like `end`, but falls back to `start` when the content overflows the alignment
    /// container, to avoid data loss.
    pub const safe_end: AlignContent = .{ .keyword = .end, .safety = .safe };
    /// Like `flex_start`, but falls back to `start` when the content overflows the alignment
    /// container, to avoid data loss.
    pub const safe_flex_start: AlignContent = .{ .keyword = .flex_start, .safety = .safe };
    /// Like `flex_end`, but falls back to `start` when the content overflows the alignment
    /// container, to avoid data loss.
    pub const safe_flex_end: AlignContent = .{ .keyword = .flex_end, .safety = .safe };
    /// Like `center`, but falls back to `start` when the content overflows the alignment
    /// container, to avoid data loss.
    pub const safe_center: AlignContent = .{ .keyword = .center, .safety = .safe };

    /// Returns `true` iff this carries the `safe` overflow-position modifier.
    pub inline fn isSafe(self: AlignContent) bool {
        return self.safety == .safe;
    }

    /// Returns this alignment with the given overflow-position modifier.
    pub inline fn withSafety(self: AlignContent, safety: AlignmentSafety) AlignContent {
        return .{ .keyword = self.keyword, .safety = safety };
    }
};

/// Sets the distribution of space between and around content items.
/// For Flexbox it controls alignment in the main axis.
/// For Grid it controls alignment in the inline axis.
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/justify-content)
pub const JustifyContent = AlignContent;

const testing = std.testing;

test "align types within size budget" {
    try testing.expect(@sizeOf(AlignItems) <= 2);
    try testing.expect(@sizeOf(AlignContent) <= 2);
    try testing.expect(@sizeOf(?AlignItems) <= 4);
}

test "align items is safe" {
    try testing.expect(AlignItems.safe_start.isSafe());
    try testing.expect(AlignItems.safe_end.isSafe());
    try testing.expect(AlignItems.safe_flex_start.isSafe());
    try testing.expect(AlignItems.safe_flex_end.isSafe());
    try testing.expect(AlignItems.safe_center.isSafe());
    try testing.expect(!AlignItems.start.isSafe());
    try testing.expect(!AlignItems.end.isSafe());
    try testing.expect(!AlignItems.flex_start.isSafe());
    try testing.expect(!AlignItems.flex_end.isSafe());
    try testing.expect(!AlignItems.center.isSafe());
    try testing.expect(!AlignItems.baseline.isSafe());
    try testing.expect(!AlignItems.stretch.isSafe());
    try testing.expect(AlignItems.safe_self_start.isSafe());
    try testing.expect(AlignItems.safe_self_end.isSafe());
    try testing.expect(!AlignItems.self_start.isSafe());
    try testing.expect(!AlignItems.self_end.isSafe());
    try testing.expect(!AlignItems.normal.isSafe());
}

test "align items keyword strips safe" {
    try testing.expectEqual(AlignItemsKeyword.start, AlignItems.safe_start.keyword);
    try testing.expectEqual(AlignItemsKeyword.end, AlignItems.safe_end.keyword);
    try testing.expectEqual(AlignItemsKeyword.flex_start, AlignItems.safe_flex_start.keyword);
    try testing.expectEqual(AlignItemsKeyword.flex_end, AlignItems.safe_flex_end.keyword);
    try testing.expectEqual(AlignItemsKeyword.center, AlignItems.safe_center.keyword);
    try testing.expectEqual(AlignItemsKeyword.self_start, AlignItems.safe_self_start.keyword);
    try testing.expectEqual(AlignItemsKeyword.self_end, AlignItems.safe_self_end.keyword);
}

test "align items keyword passthrough" {
    try testing.expectEqual(AlignItemsKeyword.start, AlignItems.start.keyword);
    try testing.expectEqual(AlignItemsKeyword.stretch, AlignItems.stretch.keyword);
    try testing.expectEqual(AlignItemsKeyword.baseline, AlignItems.baseline.keyword);
    try testing.expectEqual(AlignItemsKeyword.flex_start, AlignItems.flex_start.keyword);
    try testing.expectEqual(AlignItemsKeyword.normal, AlignItems.normal.keyword);
}

test "align items default is normal" {
    try testing.expect(AlignItems.default == AlignItems.normal);
    try testing.expect(AlignItems{} == AlignItems.normal);
    try testing.expectEqual(AlignItemsKeyword.normal, AlignItemsKeyword.default);
    try testing.expectEqual(AlignmentSafety.default, (AlignItems{}).safety);
}

test "resolve self relative inline axis" {
    // Same direction: self-start == start, self-end == end
    try testing.expect(AlignItems.self_start.resolveSelfRelative(.ltr, .ltr, true) == AlignItems.start);
    try testing.expect(AlignItems.self_end.resolveSelfRelative(.ltr, .ltr, true) == AlignItems.end);
    try testing.expect(AlignItems.self_start.resolveSelfRelative(.rtl, .rtl, true) == AlignItems.start);
    try testing.expect(AlignItems.self_end.resolveSelfRelative(.rtl, .rtl, true) == AlignItems.end);
    // Opposite direction: self-start == end, self-end == start
    try testing.expect(AlignItems.self_start.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.end);
    try testing.expect(AlignItems.self_end.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.start);
    try testing.expect(AlignItems.self_start.resolveSelfRelative(.rtl, .ltr, true) == AlignItems.end);
    try testing.expect(AlignItems.self_end.resolveSelfRelative(.rtl, .ltr, true) == AlignItems.start);
    // Safety modifier is preserved
    try testing.expect(AlignItems.safe_self_start.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.safe_end);
    // Other keywords are unchanged
    try testing.expect(AlignItems.start.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.start);
    try testing.expect(AlignItems.flex_end.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.flex_end);
    try testing.expect(AlignItems.normal.resolveSelfRelative(.ltr, .rtl, true) == AlignItems.normal);
}

test "resolve self relative block axis" {
    // In the block axis (horizontal-tb only) direction never flips self-start/self-end
    try testing.expect(AlignItems.self_start.resolveSelfRelative(.ltr, .rtl, false) == AlignItems.start);
    try testing.expect(AlignItems.self_end.resolveSelfRelative(.rtl, .ltr, false) == AlignItems.end);
}

test "align content is safe" {
    try testing.expect(AlignContent.safe_start.isSafe());
    try testing.expect(AlignContent.safe_center.isSafe());
    try testing.expect(!AlignContent.space_between.isSafe());
    try testing.expect(!AlignContent.stretch.isSafe());
    try testing.expect(!AlignContent.normal.isSafe());
}

test "align content keyword strips safe" {
    try testing.expectEqual(AlignContentKeyword.start, AlignContent.safe_start.keyword);
    try testing.expectEqual(AlignContentKeyword.flex_end, AlignContent.safe_flex_end.keyword);
    try testing.expectEqual(AlignContentKeyword.center, AlignContent.safe_center.keyword);
    try testing.expectEqual(AlignContentKeyword.space_between, AlignContent.space_between.keyword);
    try testing.expectEqual(AlignContentKeyword.normal, AlignContent.normal.keyword);
    try testing.expect(JustifyContent.normal == AlignContent.normal);
}

test "align content keyword reversed swaps start end" {
    try testing.expectEqual(AlignContentKeyword.end, AlignContentKeyword.start.reversed());
    try testing.expectEqual(AlignContentKeyword.start, AlignContentKeyword.end.reversed());
    try testing.expectEqual(AlignContentKeyword.flex_end, AlignContentKeyword.flex_start.reversed());
    try testing.expectEqual(AlignContentKeyword.flex_start, AlignContentKeyword.flex_end.reversed());
    // Stretch reverses to End — preserves pre-refactor behaviour.
    try testing.expectEqual(AlignContentKeyword.end, AlignContentKeyword.stretch.reversed());
    try testing.expectEqual(AlignContentKeyword.normal, AlignContentKeyword.normal.reversed());
    try testing.expectEqual(AlignContentKeyword.center, AlignContentKeyword.center.reversed());
    try testing.expectEqual(AlignContentKeyword.space_between, AlignContentKeyword.space_between.reversed());
    try testing.expectEqual(AlignContentKeyword.space_evenly, AlignContentKeyword.space_evenly.reversed());
    try testing.expectEqual(AlignContentKeyword.space_around, AlignContentKeyword.space_around.reversed());
}

test "align content default is normal" {
    try testing.expect(AlignContent.default == AlignContent.normal);
    try testing.expect(JustifyContent.default == JustifyContent.normal);
    try testing.expect(AlignContent{} == AlignContent.normal);
}
