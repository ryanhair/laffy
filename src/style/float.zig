//! Style types for float layout
const std = @import("std");

/// Floats a box to the left or right.
/// This property only applies to children of a block layout
///
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/float>
pub const Float = enum(u8) {
    /// The box is floated to the left
    left,
    /// The box is floated to the right
    right,
    /// The box is not floated
    none,

    /// The default value
    pub const default: Float = .none;

    /// Whether the box is floated
    pub inline fn isFloated(self: Float) bool {
        return self == .left or self == .right;
    }

    /// Converts `Float` into `?FloatDirection`
    pub inline fn floatDirection(self: Float) ?FloatDirection {
        return switch (self) {
            .left => .left,
            .right => .right,
            .none => null,
        };
    }
};

/// Whether a box that is definitely floated is floated to the left
/// of to the right.
///
/// This type is only used in the low-level parts of the float layout code.
pub const FloatDirection = enum(u8) {
    /// The box is floated to the left
    left = 0,
    /// The box is floated to the right
    right = 1,

    /// The opposite side: `right` for `left` and `left` for `right`
    pub inline fn opposite(self: FloatDirection) FloatDirection {
        return switch (self) {
            .left => .right,
            .right => .left,
        };
    }
};

/// Gives a box "clearance", which moves it below floated boxes which precede
/// it in the tree.
///
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/clear>
pub const Clear = enum(u8) {
    /// The box clears left-floated boxes
    left,
    /// The box clears right-floated boxes
    right,
    /// The box clears boxes floated in either direction
    both,
    /// The box does not clear floated boxes
    none,

    /// The default value
    pub const default: Clear = .none;
};

test "float helpers" {
    try std.testing.expect(Float.left.isFloated());
    try std.testing.expect(!Float.none.isFloated());
    try std.testing.expectEqual(@as(?FloatDirection, .right), Float.right.floatDirection());
    try std.testing.expectEqual(@as(?FloatDirection, null), Float.none.floatDirection());
    try std.testing.expectEqual(FloatDirection.left, FloatDirection.right.opposite());
}
