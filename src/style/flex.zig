//! Style types for Flexbox layout
//!
//! The `FlexboxContainerStyle` and `FlexboxItemStyle` accessor interfaces are documented in
//! `src/style.zig` together with the other style accessor interfaces.
const std = @import("std");
const AbsoluteAxis = @import("../geometry.zig").AbsoluteAxis;

/// Controls whether flex items are forced onto one line or can wrap onto multiple lines.
///
/// Defaults to `FlexWrap.no_wrap`
///
/// [Specification](https://www.w3.org/TR/css-flexbox-1/#flex-wrap-property)
pub const FlexWrap = enum(u8) {
    /// Items will not wrap and stay on a single line
    no_wrap,
    /// Items will wrap according to this item's `FlexDirection`
    wrap,
    /// Items will wrap in the opposite direction to this item's `FlexDirection`
    wrap_reverse,
    /// Items will wrap according to this item's `FlexDirection`, and be balanced across
    /// lines such that the largest line is as small as possible
    ///
    /// [Specification](https://drafts.csswg.org/css-flexbox-2/#balance-values)
    balance,
    /// Items will wrap in the opposite direction to this item's `FlexDirection`, and be
    /// balanced across lines such that the largest line is as small as possible
    ///
    /// [Specification](https://drafts.csswg.org/css-flexbox-2/#balance-values)
    balance_reverse,

    /// The default value
    pub const default: FlexWrap = .no_wrap;

    /// Is this a wrapping mode (any value other than `no_wrap`)?
    pub inline fn isMultiLine(self: FlexWrap) bool {
        return self != .no_wrap;
    }

    /// Do lines stack in the opposite direction to the cross axis?
    pub inline fn isReverse(self: FlexWrap) bool {
        return switch (self) {
            .wrap_reverse => true,
            .balance_reverse => true,
            else => false,
        };
    }

    /// Are items balanced across lines?
    pub inline fn isBalance(self: FlexWrap) bool {
        return self == .balance or self == .balance_reverse;
    }
};

/// The direction of the flexbox layout main axis.
///
/// There are always two perpendicular layout axes: main (or primary) and cross (or secondary).
/// Adding items will cause them to be positioned adjacent to each other along the main axis.
/// By varying this value throughout your tree, you can create complex axis-aligned layouts.
///
/// Items are always aligned relative to the cross axis, and justified relative to the main axis.
///
/// The default behavior is `FlexDirection.row`.
///
/// [Specification](https://www.w3.org/TR/css-flexbox-1/#flex-direction-property)
pub const FlexDirection = enum(u8) {
    /// Defines +x as the main axis
    ///
    /// Items will be added from left to right in a row.
    row,
    /// Defines +y as the main axis
    ///
    /// Items will be added from top to bottom in a column.
    column,
    /// Defines -x as the main axis
    ///
    /// Items will be added from right to left in a row.
    row_reverse,
    /// Defines -y as the main axis
    ///
    /// Items will be added from bottom to top in a column.
    column_reverse,

    /// The default value
    pub const default: FlexDirection = .row;

    /// Is the direction `row` or `row_reverse`?
    pub inline fn isRow(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }

    /// Is the direction `column` or `column_reverse`?
    pub inline fn isColumn(self: FlexDirection) bool {
        return self == .column or self == .column_reverse;
    }

    /// Is the direction `row_reverse` or `column_reverse`?
    pub inline fn isReverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }

    /// Is the main axis the (single) axis that a size was requested for?
    ///
    /// `axis` is a `RequestedAxis` (defined with the tree types): any enum with the variants
    /// `horizontal`, `vertical` and `both`.
    pub inline fn mainAxisIsRequestedAxis(self: FlexDirection, axis: anytype) bool {
        return switch (axis) {
            .horizontal => self.isRow(),
            .vertical => self.isColumn(),
            .both => false,
        };
    }

    /// The `AbsoluteAxis` that corresponds to the main axis
    pub inline fn mainAxis(self: FlexDirection) AbsoluteAxis {
        return switch (self) {
            .row, .row_reverse => .horizontal,
            .column, .column_reverse => .vertical,
        };
    }

    /// The `AbsoluteAxis` that corresponds to the cross axis
    pub inline fn crossAxis(self: FlexDirection) AbsoluteAxis {
        return switch (self) {
            .row, .row_reverse => .vertical,
            .column, .column_reverse => .horizontal,
        };
    }
};

const testing = std.testing;

test "flex_direction_is_row" {
    try testing.expect(FlexDirection.row.isRow());
    try testing.expect(FlexDirection.row_reverse.isRow());
    try testing.expect(!FlexDirection.column.isRow());
    try testing.expect(!FlexDirection.column_reverse.isRow());
}

test "flex_direction_is_column" {
    try testing.expect(!FlexDirection.row.isColumn());
    try testing.expect(!FlexDirection.row_reverse.isColumn());
    try testing.expect(FlexDirection.column.isColumn());
    try testing.expect(FlexDirection.column_reverse.isColumn());
}

test "flex_direction_is_reverse" {
    try testing.expect(!FlexDirection.row.isReverse());
    try testing.expect(FlexDirection.row_reverse.isReverse());
    try testing.expect(!FlexDirection.column.isReverse());
    try testing.expect(FlexDirection.column_reverse.isReverse());
}

test "flex direction axes and requested axis" {
    const RequestedAxis = enum { horizontal, vertical, both };
    try testing.expect(FlexDirection.row.mainAxisIsRequestedAxis(RequestedAxis.horizontal));
    try testing.expect(!FlexDirection.row.mainAxisIsRequestedAxis(RequestedAxis.vertical));
    try testing.expect(FlexDirection.column_reverse.mainAxisIsRequestedAxis(RequestedAxis.vertical));
    try testing.expect(!FlexDirection.column.mainAxisIsRequestedAxis(RequestedAxis.both));
    try testing.expectEqual(AbsoluteAxis.horizontal, FlexDirection.row_reverse.mainAxis());
    try testing.expectEqual(AbsoluteAxis.horizontal, FlexDirection.column.crossAxis());
}

test "flex wrap helpers" {
    try testing.expect(!FlexWrap.no_wrap.isMultiLine());
    try testing.expect(FlexWrap.balance.isMultiLine());
    try testing.expect(FlexWrap.wrap_reverse.isReverse());
    try testing.expect(FlexWrap.balance_reverse.isReverse());
    try testing.expect(!FlexWrap.wrap.isReverse());
    try testing.expect(FlexWrap.balance.isBalance());
    try testing.expect(!FlexWrap.wrap.isBalance());
}
