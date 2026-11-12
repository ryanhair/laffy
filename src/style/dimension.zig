//! Style types for representing lengths / sizes
//!
//! Each type is a tagged union of the kinds of value it allows, so a value can be written as a
//! literal (`.{ .length = 10 }`, `.auto`) and inspected with `switch`. All of them are 8 bytes.
//! Constructor functions (`Dimension.fromLength(10)`, `Dimension.fitContentPx(5)`, ...) are
//! provided as well, since generic code such as `Size(T).fromLength` builds values through them.
const std = @import("std");
const compact_length = @import("compact_length.zig");
const CompactLength = compact_length.CompactLength;
const CalcHandle = compact_length.CalcHandle;

/// A unit of linear measurement: a length, a percentage or a `calc()` value.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const LengthPercentage = union(enum) {
    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    length: f32,
    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    percent: f32,
    /// A `calc()` value. The handle is opaque to laffy and is passed back to the tree's
    /// `resolveCalcValue` method.
    calc: CalcHandle,

    /// Zero length
    pub const zero: LengthPercentage = .{ .length = 0.0 };

    pub fn fromLength(value: f32) LengthPercentage {
        return .{ .length = value };
    }

    pub fn fromPercent(value: f32) LengthPercentage {
        return .{ .percent = value };
    }

    pub fn fromCalc(handle: CalcHandle) LengthPercentage {
        return .{ .calc = handle };
    }

    pub fn eql(self: LengthPercentage, other: LengthPercentage) bool {
        return std.meta.eql(self, other);
    }
};

/// A unit of linear measurement: a length, a percentage, a `calc()` value or `auto`.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const LengthPercentageAuto = union(enum) {
    /// An absolute length in some abstract units
    length: f32,
    /// A percentage length relative to the size of the containing block, in the range [0.0, 1.0]
    percent: f32,
    /// A `calc()` value
    calc: CalcHandle,
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes.
    auto,

    /// Zero length
    pub const zero: LengthPercentageAuto = .{ .length = 0.0 };

    pub fn fromLengthPercentage(input: LengthPercentage) LengthPercentageAuto {
        return CompactLength.from(input).into(LengthPercentageAuto);
    }

    pub fn fromLength(value: f32) LengthPercentageAuto {
        return .{ .length = value };
    }

    pub fn fromPercent(value: f32) LengthPercentageAuto {
        return .{ .percent = value };
    }

    pub fn fromCalc(handle: CalcHandle) LengthPercentageAuto {
        return .{ .calc = handle };
    }

    /// Returns:
    ///   - The value for a length
    ///   - The resolved value for a percentage or `calc()`, against `context`
    ///   - `null` for `auto`
    pub fn resolveToOption(self: LengthPercentageAuto, context: f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .length => |value| value,
            .percent => |fraction| context * fraction,
            .calc => |handle| calc_resolver.resolveCalcValue(handle, context),
            .auto => null,
        };
    }

    pub fn isAuto(self: LengthPercentageAuto) bool {
        return self == .auto;
    }

    pub fn eql(self: LengthPercentageAuto, other: LengthPercentageAuto) bool {
        return std.meta.eql(self, other);
    }
};

/// A unit of linear measurement: a length, a percentage, a `calc()` value, `auto` or one of the
/// sizing keywords.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const Dimension = union(enum) {
    /// An absolute length in some abstract units
    length: f32,
    /// A percentage length relative to the size of the containing block, in the range [0.0, 1.0]
    percent: f32,
    /// A `calc()` value
    calc: CalcHandle,
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes.
    auto,
    /// The smallest size that can fit the item's contents with ALL soft line-wrapping
    /// opportunities taken
    min_content,
    /// The smallest size that can fit the item's contents with NO soft line-wrapping
    /// opportunities taken
    max_content,
    /// `fit-content(<length>)`: the stretch-fit size clamped between the min-content and
    /// max-content sizes, and by the limit
    fit_content_px: f32,
    /// `fit-content(<percentage>)`
    fit_content_percent: f32,
    /// `fit-content(calc(...))`
    fit_content_calc: CalcHandle,
    /// The `fit-content` keyword: the stretch-fit size clamped between the min-content and
    /// max-content sizes
    fit_content,
    /// The `stretch` keyword: the size that fills the available space
    stretch,
    /// The `content` keyword of `flex-basis`: size by the item's content
    content,

    /// Zero length
    pub const zero: Dimension = .{ .length = 0.0 };

    pub fn fromLengthPercentage(input: LengthPercentage) Dimension {
        return CompactLength.from(input).into(Dimension);
    }

    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) Dimension {
        return CompactLength.from(input).into(Dimension);
    }

    pub fn fromLength(value: f32) Dimension {
        return .{ .length = value };
    }

    pub fn fromPercent(value: f32) Dimension {
        return .{ .percent = value };
    }

    pub fn fromCalc(handle: CalcHandle) Dimension {
        return .{ .calc = handle };
    }

    pub fn fitContentPx(limit: f32) Dimension {
        return .{ .fit_content_px = limit };
    }

    pub fn fitContentPercent(limit: f32) Dimension {
        return .{ .fit_content_percent = limit };
    }

    pub fn fitContentCalc(handle: CalcHandle) Dimension {
        return .{ .fit_content_calc = handle };
    }

    /// `fit-content(...)` with the passed limit
    pub fn fitContent(limit: LengthPercentage) Dimension {
        return CompactLength.fitContent(limit).into(Dimension);
    }

    /// The value of a length, or `null` for every other kind
    pub fn intoOption(self: Dimension) ?f32 {
        return switch (self) {
            .length => |value| value,
            else => null,
        };
    }

    pub fn isAuto(self: Dimension) bool {
        return self == .auto;
    }

    /// Whether the value is one of the sizing keywords: `min-content`, `max-content`,
    /// `fit-content`, `fit-content(...)` or `stretch`
    pub fn isSizingKeyword(self: Dimension) bool {
        return switch (self) {
            .min_content, .max_content, .fit_content, .stretch => true,
            .fit_content_px, .fit_content_percent, .fit_content_calc => true,
            .length, .percent, .calc, .auto, .content => false,
        };
    }

    pub fn isStretch(self: Dimension) bool {
        return self == .stretch;
    }

    pub fn isContent(self: Dimension) bool {
        return self == .content;
    }

    pub fn isFitContentCalc(self: Dimension) bool {
        return self == .fit_content_calc;
    }

    /// Whether the resolved value depends on a percentage basis
    pub fn usesPercentage(self: Dimension) bool {
        return switch (self) {
            .percent, .calc, .fit_content_percent, .fit_content_calc => true,
            else => false,
        };
    }

    pub fn eql(self: Dimension, other: Dimension) bool {
        return std.meta.eql(self, other);
    }
};

const testing = std.testing;

// Checked in every build, so that a change that grows one of these types cannot go unnoticed
comptime {
    std.debug.assert(@sizeOf(LengthPercentage) == 8);
    std.debug.assert(@sizeOf(LengthPercentageAuto) == 8);
    std.debug.assert(@sizeOf(Dimension) == 8);
}

test "constructors build the matching kind" {
    try testing.expectEqual(LengthPercentage{ .length = 3.0 }, LengthPercentage.fromLength(3.0));
    try testing.expectEqual(LengthPercentage{ .percent = 0.25 }, LengthPercentage.fromPercent(0.25));
    try testing.expectEqual(LengthPercentage{ .calc = 4 }, LengthPercentage.fromCalc(4));
    try testing.expect(LengthPercentage.zero.eql(.{ .length = 0.0 }));
    try testing.expectEqual(Dimension{ .fit_content_px = 30.0 }, Dimension.fitContentPx(30.0));
    try testing.expectEqual(Dimension{ .fit_content_percent = 0.75 }, Dimension.fitContentPercent(0.75));
    try testing.expectEqual(Dimension{ .fit_content_calc = 4 }, Dimension.fitContentCalc(4));
    try testing.expectEqual(Dimension{ .fit_content_px = 10.0 }, Dimension.fitContent(.{ .length = 10.0 }));
    try testing.expectEqual(Dimension{ .fit_content_calc = 4 }, Dimension.fitContent(.{ .calc = 4 }));
}

test "widening conversions keep the value" {
    try testing.expectEqual(LengthPercentageAuto{ .percent = 0.5 }, LengthPercentageAuto.fromLengthPercentage(.{ .percent = 0.5 }));
    try testing.expectEqual(Dimension{ .calc = 2 }, Dimension.fromLengthPercentage(.{ .calc = 2 }));
    try testing.expectEqual(@as(Dimension, .auto), Dimension.fromLengthPercentageAuto(.auto));
}

test "Dimension predicates" {
    const d: Dimension = .stretch;
    try testing.expect(d.isStretch() and d.isSizingKeyword() and !d.isAuto());
    try testing.expect((Dimension{ .fit_content_calc = 1 }).isFitContentCalc());
    try testing.expect((Dimension{ .fit_content_calc = 1 }).usesPercentage());
    try testing.expect(!(Dimension{ .length = 1.0 }).usesPercentage());
    try testing.expect(@as(Dimension, .content).isContent());
    try testing.expect(!@as(Dimension, .auto).isSizingKeyword());
    try testing.expect(!(Dimension{ .length = 1.0 }).eql(.{ .length = 2.0 }));
}

test "LengthPercentageAuto resolveToOption" {
    const NoCalc = compact_length.NoCalc;
    try testing.expectEqual(@as(?f32, 5.0), LengthPercentageAuto.fromLength(5.0).resolveToOption(100.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, 50.0), LengthPercentageAuto.fromPercent(0.5).resolveToOption(100.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, null), @as(LengthPercentageAuto, .auto).resolveToOption(100.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, 42.42), LengthPercentageAuto.fromCalc(1).resolveToOption(100.0, compact_length.ConstCalc{ .value = 42.42 }));
    try testing.expectEqual(@as(?f32, 7.0), Dimension.fromLength(7.0).intoOption());
    try testing.expectEqual(@as(?f32, null), Dimension.fromPercent(0.5).intoOption());
}
