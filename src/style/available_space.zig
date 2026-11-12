//! Style type for representing available space as a sizing constraint
const std = @import("std");
const sys = @import("../util/sys.zig");
const toF32 = @import("compact_length.zig").toF32;

/// The amount of space available to a node in a given axis
/// <https://www.w3.org/TR/css-sizing-3/#available>
pub const AvailableSpace = union(enum) {
    /// The amount of space available is the specified number of pixels
    definite: f32,
    /// The amount of space available is indefinite and the node should be laid out under a min-content constraint
    min_content,
    /// The amount of space available is indefinite and the node should be laid out under a max-content constraint
    max_content,

    /// Upstream `TaffyZero::ZERO`
    pub const zero: AvailableSpace = .{ .definite = 0.0 };
    // Upstream `TaffyMinContent::MIN_CONTENT` / `TaffyMaxContent::MAX_CONTENT` are the
    // `.min_content` / `.max_content` variants themselves: `AvailableSpace.min_content` is valid
    // Zig, so `style_helpers.minContent(AvailableSpace)` works without extra declarations.

    /// Upstream `FromLength::from_length`
    pub inline fn fromLength(value: anytype) AvailableSpace {
        return .{ .definite = toF32(value) };
    }

    /// Upstream `From<f32>`
    pub inline fn fromF32(value: f32) AvailableSpace {
        return .{ .definite = value };
    }

    /// Upstream `From<Option<f32>>`: `null` becomes `max_content`
    pub inline fn fromOption(option: ?f32) AvailableSpace {
        return if (option) |value| .{ .definite = value } else .max_content;
    }

    /// Returns true for definite values, else false
    pub inline fn isDefinite(self: AvailableSpace) bool {
        return self == .definite;
    }

    /// Convert to Option
    /// Definite values become the value. Constraints become null.
    pub inline fn intoOption(self: AvailableSpace) ?f32 {
        return switch (self) {
            .definite => |value| value,
            else => null,
        };
    }

    /// Return the definite value or a default value
    pub inline fn unwrapOr(self: AvailableSpace, default: f32) f32 {
        return self.intoOption() orelse default;
    }

    /// Return the definite value. Panics if the value is not definite.
    pub inline fn unwrap(self: AvailableSpace) f32 {
        return self.intoOption().?;
    }

    /// Return self if definite or a default value
    pub inline fn @"or"(self: AvailableSpace, default: AvailableSpace) AvailableSpace {
        return switch (self) {
            .definite => self,
            else => default,
        };
    }

    /// Return self if definite or the result of the default value callback
    pub inline fn orElse(self: AvailableSpace, comptime default_cb: fn () AvailableSpace) AvailableSpace {
        return switch (self) {
            .definite => self,
            else => default_cb(),
        };
    }

    /// Return the definite value or the result of the default value callback
    pub inline fn unwrapOrElse(self: AvailableSpace, comptime default_cb: fn () f32) f32 {
        return self.intoOption() orelse default_cb();
    }

    /// If passed value is non-null then return `.definite` containing that value, else return self
    pub inline fn maybeSet(self: AvailableSpace, value: ?f32) AvailableSpace {
        return if (value) |v| .{ .definite = v } else self;
    }

    /// If self is definite, map its value with the passed function, else return self
    pub inline fn mapDefiniteValue(self: AvailableSpace, comptime map_function: fn (f32) f32) AvailableSpace {
        return switch (self) {
            .definite => |value| .{ .definite = map_function(value) },
            else => self,
        };
    }

    /// Compute free_space given the passed used_space
    pub inline fn computeFreeSpace(self: AvailableSpace, used_space: f32) f32 {
        return switch (self) {
            .max_content => std.math.inf(f32),
            .min_content => 0.0,
            .definite => |available_space| available_space - used_space,
        };
    }

    /// Compare equality with another AvailableSpace, treating definite values
    /// that are within f32::EPSILON of each other as equal
    pub fn isRoughlyEqual(self: AvailableSpace, other: AvailableSpace) bool {
        return switch (self) {
            .definite => |a| switch (other) {
                .definite => |b| sys.abs(a - b) < std.math.floatEps(f32),
                else => false,
            },
            .min_content => other == .min_content,
            .max_content => other == .max_content,
        };
    }

    /// Exact equality (upstream derived `PartialEq`)
    pub inline fn eql(self: AvailableSpace, other: AvailableSpace) bool {
        return switch (self) {
            .definite => |a| switch (other) {
                .definite => |b| a == b,
                else => false,
            },
            .min_content => other == .min_content,
            .max_content => other == .max_content,
        };
    }
};

const testing = std.testing;
const min_content: AvailableSpace = .min_content;
const max_content: AvailableSpace = .max_content;

test "AvailableSpace helpers" {
    const a: AvailableSpace = .{ .definite = 10.0 };
    try testing.expect(a.isDefinite());
    try testing.expect(!max_content.isDefinite());
    try testing.expectEqual(@as(?f32, 10.0), a.intoOption());
    try testing.expectEqual(@as(?f32, null), min_content.intoOption());
    try testing.expectEqual(@as(f32, 3.0), min_content.unwrapOr(3.0));
    try testing.expectEqual(@as(f32, 10.0), a.unwrap());
    try testing.expect(min_content.@"or"(a).eql(a));
    try testing.expect(a.@"or"(.max_content).eql(a));
    try testing.expect(max_content.maybeSet(5.0).eql(.{ .definite = 5.0 }));
    try testing.expect(max_content.maybeSet(null).eql(.max_content));
    try testing.expectEqual(std.math.inf(f32), max_content.computeFreeSpace(5.0));
    try testing.expectEqual(@as(f32, 0.0), min_content.computeFreeSpace(5.0));
    try testing.expectEqual(@as(f32, 5.0), a.computeFreeSpace(5.0));
    try testing.expect(a.isRoughlyEqual(.{ .definite = 10.0 + 1e-7 }));
    try testing.expect(!a.isRoughlyEqual(.max_content));
    try testing.expect(AvailableSpace.fromOption(null).eql(.max_content));
    try testing.expect(AvailableSpace.fromLength(4).eql(.{ .definite = 4.0 }));
    const double = struct {
        fn f(x: f32) f32 {
            return x * 2;
        }
    }.f;
    try testing.expect(a.mapDefiniteValue(double).eql(.{ .definite = 20.0 }));
    const cb = struct {
        fn f() AvailableSpace {
            return .{ .definite = 1.0 };
        }
    }.f;
    try testing.expect(min_content.orElse(cb).eql(.{ .definite = 1.0 }));
    const cbf = struct {
        fn f() f32 {
            return 2.0;
        }
    }.f;
    try testing.expectEqual(@as(f32, 2.0), min_content.unwrapOrElse(cbf));
}

test "Size(AvailableSpace) helpers" {
    const Size = @import("../geometry.zig").Size;
    const s: Size(AvailableSpace) = .{ .width = .{ .definite = 3.0 }, .height = .min_content };
    try testing.expectEqual(Size(?f32){ .width = 3.0, .height = null }, s.intoOptions());
    const set = s.maybeSet(.{ .width = null, .height = 7.0 });
    try testing.expect(set.width.eql(.{ .definite = 3.0 }));
    try testing.expect(set.height.eql(.{ .definite = 7.0 }));
    const z = Size(AvailableSpace).zero;
    try testing.expect(z.width.eql(.{ .definite = 0.0 }));
    const mc = Size(AvailableSpace).min_content;
    try testing.expect(mc.height.eql(.min_content));
}
