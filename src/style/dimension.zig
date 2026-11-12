//! Style types for representing lengths / sizes
//!
//! Each type wraps a `CompactLength` in its `inner` field (upstream's tuple field `.0`). The types
//! are `packed struct(u64)` so that values can be compared with `==` (bitwise, like upstream's
//! derived `PartialEq` on the tagged pointer).
//!
//! Naming: zero-argument constructors and upstream associated constants are declarations
//! (`Dimension.auto`, `Dimension.zero`, `Dimension.min_content`, ...); constructors that take
//! arguments are functions (`Dimension.fromLength(10)`, `Dimension.fitContentPx(5)`, ...).
const std = @import("std");
const compact_length = @import("compact_length.zig");
const CompactLength = compact_length.CompactLength;
const toF32 = compact_length.toF32;

/// A unit of linear measurement: a length, a percentage or a `calc()` value.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const LengthPercentage = packed struct(u64) {
    inner: CompactLength,

    /// Zero length (upstream `TaffyZero::ZERO`)
    pub const zero: LengthPercentage = .{ .inner = CompactLength.zero };

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) LengthPercentage {
        return .{ .inner = CompactLength.fromLength(val) };
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) LengthPercentage {
        return .{ .inner = CompactLength.fromPercent(val) };
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn calc(ptr: *const anyopaque) LengthPercentage {
        return .{ .inner = CompactLength.calc(ptr) };
    }

    /// Create a LengthPercentage from a raw `CompactLength`.
    /// The `CompactLength` must represent a valid variant for LengthPercentage.
    pub fn fromRaw(val: CompactLength) LengthPercentage {
        return .{ .inner = val };
    }

    /// Get the underlying `CompactLength` representation of the value
    pub fn intoRaw(self: LengthPercentage) CompactLength {
        return self.inner;
    }

    /// Expand the compact representation into an `ExpandedLengthPercentage` tagged union.
    pub fn expand(self: LengthPercentage) ExpandedLengthPercentage {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => .{ .length = self.inner.value() },
            CompactLength.percent_tag => .{ .percent = self.inner.value() },
            else => if (self.inner.isPlainCalc())
                .{ .calc = self.inner.calcValue() }
            else
                unreachable, // LengthPercentage contains a value with an invalid tag
        };
    }

    /// Convert an `ExpandedLengthPercentage` back into the compact form (upstream `From`)
    pub fn fromExpanded(value_: ExpandedLengthPercentage) LengthPercentage {
        return switch (value_) {
            .length => |val| fromLength(val),
            .percent => |val| fromPercent(val),
            .calc => |ptr| calc(ptr),
        };
    }
};

/// The expanded, non-compact representation of a `LengthPercentage`.
///
/// Obtained via `LengthPercentage.expand`. Can be converted back with `LengthPercentage.fromExpanded`.
pub const ExpandedLengthPercentage = union(enum) {
    /// An absolute length (see `LengthPercentage.length`)
    length: f32,
    /// A percentage length (see `LengthPercentage.percent`)
    percent: f32,
    /// A `calc()` value (see `LengthPercentage.calc`). The pointer is an opaque handle to the
    /// calc representation, exactly as passed to the constructor.
    calc: *const anyopaque,
};

/// A unit of linear measurement: a length, a percentage, `auto` or a `calc()` value.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const LengthPercentageAuto = packed struct(u64) {
    inner: CompactLength,

    /// Zero length (upstream `TaffyZero::ZERO`)
    pub const zero: LengthPercentageAuto = .{ .inner = CompactLength.zero };

    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes. (Upstream `auto()` and `TaffyAuto::AUTO`.)
    pub const auto: LengthPercentageAuto = .{ .inner = CompactLength.auto };

    /// Upstream `From<LengthPercentage>`
    pub fn fromLengthPercentage(input: LengthPercentage) LengthPercentageAuto {
        return .{ .inner = input.inner };
    }

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) LengthPercentageAuto {
        return .{ .inner = CompactLength.fromLength(val) };
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) LengthPercentageAuto {
        return .{ .inner = CompactLength.fromPercent(val) };
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn calc(ptr: *const anyopaque) LengthPercentageAuto {
        return .{ .inner = CompactLength.calc(ptr) };
    }

    /// Create a LengthPercentageAuto from a raw `CompactLength`.
    /// The `CompactLength` must represent a valid variant for LengthPercentageAuto.
    pub fn fromRaw(val: CompactLength) LengthPercentageAuto {
        return .{ .inner = val };
    }

    /// Get the underlying `CompactLength` representation of the value
    pub fn intoRaw(self: LengthPercentageAuto) CompactLength {
        return self.inner;
    }

    /// Returns:
    ///   - the length for Length variants
    ///   - the resolved value using the provided context for Percent (and calc) variants
    ///   - null for Auto variants
    pub fn resolveToOption(self: LengthPercentageAuto, context: f32, calc_resolver: anytype) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => self.inner.value(),
            CompactLength.percent_tag => context * self.inner.value(),
            CompactLength.auto_tag => null,
            else => if (self.inner.isPlainCalc())
                calc_resolver.resolveCalcValue(self.inner.calcValue(), context)
            else
                unreachable, // LengthPercentageAuto values cannot be constructed with other tags
        };
    }

    /// Returns true if value is LengthPercentageAuto::Auto
    pub fn isAuto(self: LengthPercentageAuto) bool {
        return self.inner.isAuto();
    }

    /// Expand the compact representation into an `ExpandedLengthPercentageAuto` tagged union.
    pub fn expand(self: LengthPercentageAuto) ExpandedLengthPercentageAuto {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => .{ .length = self.inner.value() },
            CompactLength.percent_tag => .{ .percent = self.inner.value() },
            CompactLength.auto_tag => .auto,
            else => if (self.inner.isPlainCalc())
                .{ .calc = self.inner.calcValue() }
            else
                unreachable, // LengthPercentageAuto contains a value with an invalid tag
        };
    }

    /// Convert an `ExpandedLengthPercentageAuto` back into the compact form (upstream `From`)
    pub fn fromExpanded(value_: ExpandedLengthPercentageAuto) LengthPercentageAuto {
        return switch (value_) {
            .length => |val| fromLength(val),
            .percent => |val| fromPercent(val),
            .auto => auto,
            .calc => |ptr| calc(ptr),
        };
    }
};

/// The expanded, non-compact representation of a `LengthPercentageAuto`.
pub const ExpandedLengthPercentageAuto = union(enum) {
    /// An absolute length (see `LengthPercentageAuto.length`)
    length: f32,
    /// A percentage length (see `LengthPercentageAuto.percent`)
    percent: f32,
    /// The automatic keyword (see `LengthPercentageAuto.auto`)
    auto,
    /// A `calc()` value (see `LengthPercentageAuto.calc`). The pointer is an opaque handle to
    /// the calc representation, exactly as passed to the constructor.
    calc: *const anyopaque,
};

/// A unit of linear measurement, including the CSS sizing keywords.
///
/// This is commonly combined with `Rect`, `Point` and `Size`.
pub const Dimension = packed struct(u64) {
    inner: CompactLength,

    /// Zero length (upstream `TaffyZero::ZERO`)
    pub const zero: Dimension = .{ .inner = CompactLength.zero };

    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes. (Upstream `auto()` and `TaffyAuto::AUTO`.)
    pub const auto: Dimension = .{ .inner = CompactLength.auto };

    /// The size should be the "min-content" size.
    /// This is the smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    pub const min_content: Dimension = .{ .inner = CompactLength.min_content };

    /// The size should be the "max-content" size.
    /// This is the smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    pub const max_content: Dimension = .{ .inner = CompactLength.max_content };

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, stretch))`
    /// where `stretch` is the size the box would take if it filled the available space
    /// (upstream `Dimension::fit_content()`)
    pub const fit_content: Dimension = .{ .inner = CompactLength.fit_content_keyword };

    /// The size should be the "stretch-fit" size: the size the box would take
    /// if it filled the available space
    /// (<https://www.w3.org/TR/css-sizing-4/#stretch-fit-sizing>)
    pub const stretch: Dimension = .{ .inner = CompactLength.stretch };

    /// The size should be an automatic size based on the box's content
    /// (<https://www.w3.org/TR/css-flexbox-1/#valdef-flex-basis-content>)
    ///
    /// This keyword is only valid for `flex-basis`. In any other context it behaves as `auto`.
    pub const content: Dimension = .{ .inner = CompactLength.content };

    /// Upstream `From<LengthPercentage>`
    pub fn fromLengthPercentage(input: LengthPercentage) Dimension {
        return .{ .inner = input.inner };
    }

    /// Upstream `From<LengthPercentageAuto>`
    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) Dimension {
        return .{ .inner = input.inner };
    }

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) Dimension {
        return .{ .inner = CompactLength.fromLength(val) };
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) Dimension {
        return .{ .inner = CompactLength.fromPercent(val) };
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a LENGTH value
    pub fn fitContentPx(limit: f32) Dimension {
        return .{ .inner = CompactLength.fitContentPx(limit) };
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a PERCENTAGE value
    pub fn fitContentPercent(limit: f32) Dimension {
        return .{ .inner = CompactLength.fitContentPercent(limit) };
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn calc(ptr: *const anyopaque) Dimension {
        return .{ .inner = CompactLength.calc(ptr) };
    }

    /// A `fit-content()` value whose limit is a `calc()` value. The value passed here is treated as an opaque
    /// handle to the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn fitContentCalc(ptr: *const anyopaque) Dimension {
        return .{ .inner = CompactLength.fitContentCalc(ptr) };
    }

    /// Returns true if the value is a `fit-content()` value with a `calc()` limit
    pub fn isFitContentCalc(self: Dimension) bool {
        return self.inner.isFitContentCalc();
    }

    /// Get the calc() pointer (valid for `calc()` and `fit-content(calc())` values)
    pub fn calcValue(self: Dimension) *const anyopaque {
        return self.inner.calcValue();
    }

    /// Create a Dimension from a raw `CompactLength`.
    /// The `CompactLength` must represent a valid variant for Dimension.
    pub fn fromRaw(val: CompactLength) Dimension {
        return .{ .inner = val };
    }

    /// Get the underlying `CompactLength` representation of the value
    pub fn intoRaw(self: Dimension) CompactLength {
        return self.inner;
    }

    /// Get Length value if value is Length variant
    pub fn intoOption(self: Dimension) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => self.inner.value(),
            else => null,
        };
    }

    /// Returns true if value is Auto
    pub fn isAuto(self: Dimension) bool {
        return self.inner.isAuto();
    }

    /// Returns true if value is min-content, max-content, fit-content, fit-content(...), or stretch
    pub fn isSizingKeyword(self: Dimension) bool {
        return self.inner.isSizingKeyword();
    }

    /// Returns true if value is the stretch keyword
    pub fn isStretch(self: Dimension) bool {
        return self.inner.tag() == CompactLength.stretch_tag;
    }

    /// Returns true if value is the content keyword
    pub fn isContent(self: Dimension) bool {
        return self.inner.isContent();
    }

    /// Get the raw `CompactLength` tag
    pub fn tag(self: Dimension) usize {
        return self.inner.tag();
    }

    /// Get the raw `CompactLength` value for non-calc variants that have a numeric parameter
    pub fn value(self: Dimension) f32 {
        return self.inner.value();
    }

    /// Expand the compact representation into an `ExpandedDimension` tagged union.
    pub fn expand(self: Dimension) ExpandedDimension {
        const v = self.inner;
        return switch (v.tag()) {
            CompactLength.length_tag => .{ .length = v.value() },
            CompactLength.percent_tag => .{ .percent = v.value() },
            CompactLength.auto_tag => .auto,
            CompactLength.min_content_tag => .min_content,
            CompactLength.max_content_tag => .max_content,
            CompactLength.fit_content_px_tag => .{ .fit_content_px = v.value() },
            CompactLength.fit_content_percent_tag => .{ .fit_content_percent = v.value() },
            CompactLength.fit_content_keyword_tag => .fit_content,
            CompactLength.stretch_tag => .stretch,
            CompactLength.content_tag => .content,
            else => if (v.isFitContentCalc())
                .{ .fit_content_calc = v.calcValue() }
            else if (v.isPlainCalc())
                .{ .calc = v.calcValue() }
            else
                unreachable, // Dimension contains a value with an invalid tag
        };
    }

    /// Convert an `ExpandedDimension` back into the compact form (upstream `From`)
    pub fn fromExpanded(value_: ExpandedDimension) Dimension {
        return switch (value_) {
            .length => |val| fromLength(val),
            .percent => |val| fromPercent(val),
            .auto => auto,
            .min_content => min_content,
            .max_content => max_content,
            .fit_content_px => |val| fitContentPx(val),
            .fit_content_percent => |val| fitContentPercent(val),
            .fit_content => fit_content,
            .fit_content_calc => |ptr| fitContentCalc(ptr),
            .stretch => stretch,
            .content => content,
            .calc => |ptr| calc(ptr),
        };
    }
};

/// The expanded, non-compact representation of a `Dimension`.
pub const ExpandedDimension = union(enum) {
    /// An absolute length (see `Dimension.length`)
    length: f32,
    /// A percentage length (see `Dimension.percent`)
    percent: f32,
    /// The automatic keyword (see `Dimension.auto`)
    auto,
    /// The `min-content` keyword (see `Dimension.min_content`)
    min_content,
    /// The `max-content` keyword (see `Dimension.max_content`)
    max_content,
    /// A `fit-content(...)` value with a length limit (see `Dimension.fitContentPx`)
    fit_content_px: f32,
    /// A `fit-content(...)` value with a percentage limit (see `Dimension.fitContentPercent`)
    fit_content_percent: f32,
    /// The size is the fit-content size with a `calc()` limit (an opaque handle to the calc representation)
    fit_content_calc: *const anyopaque,
    /// The `fit-content` keyword with no limit (see `Dimension.fit_content`)
    fit_content,
    /// The `stretch` keyword (see `Dimension.stretch`)
    stretch,
    /// The `content` keyword (see `Dimension.content`)
    content,
    /// A `calc()` value (see `Dimension.calc`). The pointer is an opaque handle to the calc
    /// representation, exactly as passed to the constructor.
    calc: *const anyopaque,
};

const testing = std.testing;

/// A valid `calc()` handle for tests: a non-null pointer whose low three bits are zero.
var calc_handle_storage: u64 align(8) = 0;
fn calcHandle() *const anyopaque {
    return &calc_handle_storage;
}

test "LengthPercentage round trips" {
    const cases = [_]LengthPercentage{ LengthPercentage.fromLength(12.0), LengthPercentage.fromPercent(0.5), LengthPercentage.zero };
    for (cases) |value| {
        try testing.expect(LengthPercentage.fromExpanded(value.expand()) == value);
    }
    try testing.expectEqual(ExpandedLengthPercentage{ .length = 3.0 }, LengthPercentage.fromLength(3.0).expand());
    try testing.expectEqual(ExpandedLengthPercentage{ .percent = 0.25 }, LengthPercentage.fromPercent(0.25).expand());
}

test "LengthPercentageAuto round trips" {
    const cases = [_]LengthPercentageAuto{ LengthPercentageAuto.fromLength(12.0), LengthPercentageAuto.fromPercent(0.5), LengthPercentageAuto.auto };
    for (cases) |value| {
        try testing.expect(LengthPercentageAuto.fromExpanded(value.expand()) == value);
    }
    try testing.expectEqual(ExpandedLengthPercentageAuto.auto, LengthPercentageAuto.auto.expand());
}

test "Dimension round trips all keywords" {
    const cases = [_]Dimension{
        Dimension.fromLength(12.0),
        Dimension.fromPercent(0.5),
        Dimension.auto,
        Dimension.min_content,
        Dimension.max_content,
        Dimension.fitContentPx(30.0),
        Dimension.fitContentPercent(0.75),
        Dimension.fit_content,
        Dimension.stretch,
        Dimension.content,
    };
    for (cases) |value| {
        try testing.expect(Dimension.fromExpanded(value.expand()) == value);
    }
    try testing.expectEqual(ExpandedDimension{ .fit_content_px = 30.0 }, Dimension.fitContentPx(30.0).expand());
    try testing.expectEqual(ExpandedDimension.content, Dimension.content.expand());
}

test "calc round trips" {
    const handle = calcHandle();
    try testing.expectEqual(ExpandedLengthPercentage{ .calc = handle }, LengthPercentage.calc(handle).expand());
    try testing.expect(LengthPercentage.fromExpanded(.{ .calc = handle }) == LengthPercentage.calc(handle));
    try testing.expectEqual(ExpandedDimension{ .calc = handle }, Dimension.calc(handle).expand());
    try testing.expectEqual(ExpandedDimension{ .fit_content_calc = handle }, Dimension.fitContentCalc(handle).expand());
    try testing.expect(Dimension.fromExpanded(.{ .fit_content_calc = handle }) == Dimension.fitContentCalc(handle));
    try testing.expectEqual(ExpandedLengthPercentageAuto{ .calc = handle }, LengthPercentageAuto.calc(handle).expand());
}

test "LengthPercentageAuto resolveToOption" {
    const NoCalc = compact_length.NoCalc;
    try testing.expectEqual(@as(?f32, 5.0), LengthPercentageAuto.fromLength(5.0).resolveToOption(100.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, 50.0), LengthPercentageAuto.fromPercent(0.5).resolveToOption(100.0, NoCalc{}));
    try testing.expectEqual(@as(?f32, null), LengthPercentageAuto.auto.resolveToOption(100.0, NoCalc{}));
    const handle = calcHandle();
    try testing.expectEqual(@as(?f32, 42.42), LengthPercentageAuto.calc(handle).resolveToOption(100.0, compact_length.ConstCalc{ .value = 42.42 }));
    try testing.expectEqual(@as(?f32, 7.0), Dimension.fromLength(7.0).intoOption());
    try testing.expectEqual(@as(?f32, null), Dimension.fromPercent(0.5).intoOption());
}
