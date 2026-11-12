//! `CompactLength` is the union of every kind of length value that a style can hold. The
//! types in the `dimension` and `grid` modules (`Dimension`, `LengthPercentage`,
//! `MaxTrackSizingFunction`, ...) are tagged unions over the subset of kinds each one allows,
//! and convert to `CompactLength` to share the code that asks questions about a value.
//!
//! Every value is 8 bytes: a tag and a 4-byte payload.
const std = @import("std");

/// An opaque handle to a `calc()` expression. laffy does not interpret it: it is passed back to
/// the tree's `resolveCalcValue` method, which typically uses it as an index into a table of
/// expressions.
pub const CalcHandle = u32;

/// A resolver for `calc()` values that always returns `0.0`.
///
/// Pass this wherever an API takes `calc: anytype` and the caller does not support `calc()`
/// values.
pub const NoCalc = struct {
    pub fn resolveCalcValue(_: NoCalc, _: CalcHandle, _: f32) f32 {
        return 0.0;
    }
};

/// A resolver for `calc()` values that always returns a fixed value. Mostly useful in tests.
pub const ConstCalc = struct {
    value: f32,

    pub fn resolveCalcValue(self: ConstCalc, _: CalcHandle, _: f32) f32 {
        return self.value;
    }
};

/// Any length value
pub const CompactLength = union(enum) {
    /// An absolute length in some abstract units
    length: f32,
    /// A percentage length relative to the size of the containing block, in the range [0.0, 1.0]
    percent: f32,
    /// A `calc()` value
    calc: CalcHandle,
    /// The `auto` keyword
    auto,
    /// A fraction of the leftover space in a grid container (`fr`)
    fr: f32,
    /// The `min-content` keyword
    min_content,
    /// The `max-content` keyword
    max_content,
    /// `fit-content(<length>)`
    fit_content_px: f32,
    /// `fit-content(<percentage>)`
    fit_content_percent: f32,
    /// `fit-content(calc(...))`
    fit_content_calc: CalcHandle,
    /// The `fit-content` keyword
    fit_content,
    /// The `stretch` keyword
    stretch,
    /// The `content` keyword of `flex-basis`
    content,

    /// Zero length
    pub const zero: CompactLength = .{ .length = 0.0 };

    /// Widen a value of one of the narrower length unions
    pub fn from(value: anytype) CompactLength {
        return switch (value) {
            inline else => |payload, tag| @unionInit(CompactLength, @tagName(tag), payload),
        };
    }

    /// Narrow to one of the length unions. The value must be of a kind that `T` allows.
    pub fn into(self: CompactLength, comptime T: type) T {
        switch (self) {
            inline else => |payload, tag| {
                if (comptime @hasField(T, @tagName(tag))) {
                    return @unionInit(T, @tagName(tag), payload);
                } else {
                    unreachable; // the value is of a kind that `T` cannot hold
                }
            },
        }
    }

    /// `fit-content(...)` with the passed limit
    pub fn fitContent(limit: anytype) CompactLength {
        return switch (from(limit)) {
            .length => |value| .{ .fit_content_px = value },
            .percent => |value| .{ .fit_content_percent = value },
            .calc => |handle| .{ .fit_content_calc = handle },
            else => unreachable,
        };
    }

    /// Whether the two values are of the same kind and hold the same number
    pub fn eql(self: CompactLength, other: CompactLength) bool {
        return std.meta.eql(self, other);
    }

    /// Whether the value is `calc()` or `fit-content(calc())`
    pub fn hasCalc(self: CompactLength) bool {
        return self == .calc or self == .fit_content_calc;
    }

    /// Whether the value is a length of exactly zero
    pub fn isZero(self: CompactLength) bool {
        return switch (self) {
            .length => |value| value == 0.0,
            else => false,
        };
    }

    pub fn isLengthOrPercentage(self: CompactLength) bool {
        return self == .length or self == .percent;
    }

    pub fn isLengthPercentageOrCalc(self: CompactLength) bool {
        return self == .length or self == .percent or self == .calc;
    }

    /// Whether the value is `fit-content(...)` with an argument
    pub fn isFitContent(self: CompactLength) bool {
        return self == .fit_content_px or self == .fit_content_percent or self == .fit_content_calc;
    }

    /// Whether the value is one of the sizing keywords: `min-content`, `max-content`,
    /// `fit-content`, `fit-content(...)` or `stretch`
    pub fn isSizingKeyword(self: CompactLength) bool {
        return switch (self) {
            .min_content, .max_content, .fit_content, .stretch => true,
            .fit_content_px, .fit_content_percent, .fit_content_calc => true,
            .length, .percent, .calc, .auto, .fr, .content => false,
        };
    }

    /// Whether the value is `max-content` or `fit-content(...)`
    pub fn isMaxOrFitContent(self: CompactLength) bool {
        return self == .max_content or self.isFitContent();
    }

    /// Whether the value behaves like `max-content` as a maximum track sizing function:
    /// `auto`, `max-content` or `fit-content(...)`
    pub fn isMaxContentAlike(self: CompactLength) bool {
        return self == .auto or self == .max_content or self.isFitContent();
    }

    pub fn isMinOrMaxContent(self: CompactLength) bool {
        return self == .min_content or self == .max_content;
    }

    /// Whether the value is sized by content: `auto`, `min-content`, `max-content` or
    /// `fit-content(...)`
    pub fn isIntrinsic(self: CompactLength) bool {
        return self == .auto or self == .min_content or self == .max_content or self.isFitContent();
    }

    /// Whether the resolved value depends on a percentage basis
    pub fn usesPercentage(self: CompactLength) bool {
        return switch (self) {
            .percent, .calc, .fit_content_percent, .fit_content_calc => true,
            else => false,
        };
    }

    /// The value of a `percent` or `calc()` against `parent_size`, or `null` for other kinds
    pub fn resolvedPercentageSize(self: CompactLength, parent_size: f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .percent => |fraction| fraction * parent_size,
            .calc => |handle| calc_resolver.resolveCalcValue(handle, parent_size),
            else => null,
        };
    }
};

/// Convert any integer or float to `f32`
pub fn toF32(value: anytype) f32 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .comptime_float => @floatCast(@as(f64, value)),
        .comptime_int => @floatCast(@as(f64, @floatFromInt(value))),
        .float => @floatCast(@as(f64, @floatCast(value))),
        .int => @floatCast(@as(f64, @floatFromInt(value))),
        else => @compileError("expected a number, found " ++ @typeName(T)),
    };
}

const testing = std.testing;

const all_kinds = [_]CompactLength{
    .{ .length = 3.0 },
    .{ .percent = 0.5 },
    .{ .calc = 7 },
    .auto,
    .{ .fr = 2.0 },
    .min_content,
    .max_content,
    .{ .fit_content_px = 4.0 },
    .{ .fit_content_percent = 0.25 },
    .{ .fit_content_calc = 9 },
    .fit_content,
    .stretch,
    .content,
};

test "every length value is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(CompactLength));
    try testing.expectEqual(all_kinds.len, @typeInfo(CompactLength).@"union".field_names.len);
}

test "predicates" {
    for (all_kinds) |value| {
        const kind = std.meta.activeTag(value);
        try testing.expectEqual(kind == .calc or kind == .fit_content_calc, value.hasCalc());
        try testing.expectEqual(kind == .length or kind == .percent, value.isLengthOrPercentage());
        try testing.expectEqual(kind == .length or kind == .percent or kind == .calc, value.isLengthPercentageOrCalc());
        const is_fit_content = kind == .fit_content_px or kind == .fit_content_percent or kind == .fit_content_calc;
        try testing.expectEqual(is_fit_content, value.isFitContent());
        try testing.expectEqual(is_fit_content or kind == .min_content or kind == .max_content or kind == .fit_content or kind == .stretch, value.isSizingKeyword());
        try testing.expectEqual(is_fit_content or kind == .max_content, value.isMaxOrFitContent());
        try testing.expectEqual(is_fit_content or kind == .max_content or kind == .auto, value.isMaxContentAlike());
        try testing.expectEqual(kind == .min_content or kind == .max_content, value.isMinOrMaxContent());
        try testing.expectEqual(is_fit_content or kind == .auto or kind == .min_content or kind == .max_content, value.isIntrinsic());
        try testing.expectEqual(kind == .percent or kind == .calc or kind == .fit_content_percent or kind == .fit_content_calc, value.usesPercentage());
        try testing.expect(value.eql(value));
        try testing.expect(!value.isZero());
    }
    try testing.expect(CompactLength.zero.isZero());
    try testing.expect(!(CompactLength{ .length = 3.0 }).eql(.{ .length = 4.0 }));
    try testing.expect(!(CompactLength{ .length = 3.0 }).eql(.{ .percent = 3.0 }));
}

test "fit-content keeps the kind of its limit" {
    try testing.expect(CompactLength.fitContent(CompactLength{ .length = 10.0 }).eql(.{ .fit_content_px = 10.0 }));
    try testing.expect(CompactLength.fitContent(CompactLength{ .percent = 0.5 }).eql(.{ .fit_content_percent = 0.5 }));
    try testing.expect(CompactLength.fitContent(CompactLength{ .calc = 4 }).eql(.{ .fit_content_calc = 4 }));
}

test "percentage and calc values resolve against a basis" {
    const calc: ConstCalc = .{ .value = 42.0 };
    try testing.expectEqual(@as(?f32, 50.0), (CompactLength{ .percent = 0.25 }).resolvedPercentageSize(200.0, calc));
    try testing.expectEqual(@as(?f32, 42.0), (CompactLength{ .calc = 1 }).resolvedPercentageSize(200.0, calc));
    try testing.expectEqual(@as(?f32, null), (CompactLength{ .length = 5.0 }).resolvedPercentageSize(200.0, calc));
    try testing.expectEqual(@as(f32, 0.0), (NoCalc{}).resolveCalcValue(1, 200.0));
}

test "widening and narrowing" {
    const Narrow = union(enum) { length: f32, auto };
    try testing.expect(CompactLength.from(Narrow{ .length = 2.0 }).eql(.{ .length = 2.0 }));
    try testing.expect(CompactLength.from(@as(Narrow, .auto)).eql(.auto));
    try testing.expectEqual(Narrow{ .length = 2.0 }, (CompactLength{ .length = 2.0 }).into(Narrow));
}

test "toF32 accepts integers and floats" {
    try testing.expectEqual(@as(f32, 5.0), toF32(5));
    try testing.expectEqual(@as(f32, 5.0), toF32(@as(u8, 5)));
    try testing.expectEqual(@as(f32, 0.5), toF32(@as(f64, 0.5)));
}
