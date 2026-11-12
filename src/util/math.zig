//! Contains numerical helper functions (upstream `MaybeMath` trait)
//!
//! Upstream implements the `MaybeMath<In, Out>` trait for several `(Self, In)` combinations. laffy
//! exposes the five operations as free functions that dispatch on the argument types at comptime:
//!
//!   - `maybeMin(lhs, rhs)`
//!   - `maybeMax(lhs, rhs)`
//!   - `maybeClamp(lhs, min, max)`
//!   - `maybeAdd(lhs, rhs)`
//!   - `maybeSub(lhs, rhs)`
//!
//! Supported combinations (`lhs` / `rhs` -> result), exactly as upstream:
//!
//!   - `?f32` / `?f32` -> `?f32`
//!   - `?f32` / `f32` -> `?f32`
//!   - `f32` / `?f32` -> `f32`
//!   - `AvailableSpace` / `f32` -> `AvailableSpace`
//!   - `AvailableSpace` / `?f32` -> `AvailableSpace`
//!   - `Size(T)` / `Size(In)` -> `Size(Out)` where `T` / `In` -> `Out` is one of the above
//!
//! Comptime numbers are treated as `f32` and a bare `null` as `?f32`.
//!
//! Semantics: if the left-hand value is null, these operations return null.
//! If the right-hand value is null, it is ignored (the left-hand value is returned unchanged).
const std = @import("std");
const geometry = @import("../geometry.zig");
const Size = geometry.Size;
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;

/// Normalizes literal types: comptime numbers become `f32`, `@TypeOf(null)` becomes `?f32`.
fn Norm(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_float, .comptime_int => f32,
        .null => ?f32,
        else => T,
    };
}

/// The result type of a `MaybeMath` operation on `Lhs` and `Rhs`.
pub fn MaybeMathOutput(comptime Lhs: type, comptime Rhs: type) type {
    const L = Norm(Lhs);
    const R = Norm(Rhs);
    if (L == ?f32 and (R == ?f32 or R == f32)) return ?f32;
    if (L == f32 and R == ?f32) return f32;
    if (L == AvailableSpace and (R == f32 or R == ?f32)) return AvailableSpace;
    if (geometry.isSize(L) and geometry.isSize(R)) return Size(MaybeMathOutput(L.Inner, R.Inner));
    @compileError("MaybeMath is not implemented for " ++ @typeName(Lhs) ++ " with " ++ @typeName(Rhs));
}

/// Returns the minimum of `lhs` and `rhs`
pub fn maybeMin(lhs: anytype, rhs: anytype) MaybeMathOutput(@TypeOf(lhs), @TypeOf(rhs)) {
    const L = Norm(@TypeOf(lhs));
    const R = Norm(@TypeOf(rhs));
    const l: L = lhs;
    const r: R = rhs;
    if (L == ?f32 and R == ?f32) {
        if (l) |lv| {
            if (r) |rv| return @min(lv, rv);
            return l;
        }
        return null;
    } else if (L == ?f32 and R == f32) {
        return if (l) |val| @min(val, r) else null;
    } else if (L == f32 and R == ?f32) {
        return if (r) |val| @min(l, val) else l;
    } else if (L == AvailableSpace and R == f32) {
        return switch (l) {
            .definite => |val| .{ .definite = @min(val, r) },
            .min_content => .{ .definite = r },
            .max_content => .{ .definite = r },
        };
    } else if (L == AvailableSpace and R == ?f32) {
        return switch (l) {
            .definite => |val| if (r) |rv| .{ .definite = @min(val, rv) } else .{ .definite = val },
            .min_content => if (r) |rv| .{ .definite = rv } else .min_content,
            .max_content => if (r) |rv| .{ .definite = rv } else .max_content,
        };
    } else {
        return .{ .width = maybeMin(l.width, r.width), .height = maybeMin(l.height, r.height) };
    }
}

/// Returns the maximum of `lhs` and `rhs`
pub fn maybeMax(lhs: anytype, rhs: anytype) MaybeMathOutput(@TypeOf(lhs), @TypeOf(rhs)) {
    const L = Norm(@TypeOf(lhs));
    const R = Norm(@TypeOf(rhs));
    const l: L = lhs;
    const r: R = rhs;
    if (L == ?f32 and R == ?f32) {
        if (l) |lv| {
            if (r) |rv| return @max(lv, rv);
            return l;
        }
        return null;
    } else if (L == ?f32 and R == f32) {
        return if (l) |val| @max(val, r) else null;
    } else if (L == f32 and R == ?f32) {
        return if (r) |val| @max(l, val) else l;
    } else if (L == AvailableSpace and R == f32) {
        return switch (l) {
            .definite => |val| .{ .definite = @max(val, r) },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else if (L == AvailableSpace and R == ?f32) {
        return switch (l) {
            .definite => |val| if (r) |rv| .{ .definite = @max(val, rv) } else .{ .definite = val },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else {
        return .{ .width = maybeMax(l.width, r.width), .height = maybeMax(l.height, r.height) };
    }
}

/// Returns `lhs` clamped between `min` and `max` (computed as `min(max_value).max(min_value)`)
pub fn maybeClamp(lhs: anytype, min: anytype, max: anytype) MaybeMathOutput(@TypeOf(lhs), @TypeOf(min)) {
    const L = Norm(@TypeOf(lhs));
    const R = Norm(@TypeOf(min));
    if (Norm(@TypeOf(max)) != R) @compileError("maybeClamp: min and max must have the same type");
    const l: L = lhs;
    const lo: R = min;
    const hi: R = max;
    if (L == ?f32 and R == ?f32) {
        const base = l orelse return null;
        if (lo) |min_v| {
            if (hi) |max_v| return @max(@min(base, max_v), min_v);
            return @max(base, min_v);
        } else {
            if (hi) |max_v| return @min(base, max_v);
            return l;
        }
    } else if (L == ?f32 and R == f32) {
        return if (l) |val| @max(@min(val, hi), lo) else null;
    } else if (L == f32 and R == ?f32) {
        if (lo) |min_v| {
            if (hi) |max_v| return @max(@min(l, max_v), min_v);
            return @max(l, min_v);
        } else {
            if (hi) |max_v| return @min(l, max_v);
            return l;
        }
    } else if (L == AvailableSpace and R == f32) {
        return switch (l) {
            .definite => |val| .{ .definite = @max(@min(val, hi), lo) },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else if (L == AvailableSpace and R == ?f32) {
        return switch (l) {
            .definite => |val| blk: {
                if (lo) |min_v| {
                    if (hi) |max_v| break :blk .{ .definite = @max(@min(val, max_v), min_v) };
                    break :blk .{ .definite = @max(val, min_v) };
                } else {
                    if (hi) |max_v| break :blk .{ .definite = @min(val, max_v) };
                    break :blk .{ .definite = val };
                }
            },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else {
        return .{
            .width = maybeClamp(l.width, lo.width, hi.width),
            .height = maybeClamp(l.height, lo.height, hi.height),
        };
    }
}

/// Adds `lhs` and `rhs`.
pub fn maybeAdd(lhs: anytype, rhs: anytype) MaybeMathOutput(@TypeOf(lhs), @TypeOf(rhs)) {
    const L = Norm(@TypeOf(lhs));
    const R = Norm(@TypeOf(rhs));
    const l: L = lhs;
    const r: R = rhs;
    if (L == ?f32 and R == ?f32) {
        if (l) |lv| {
            if (r) |rv| return lv + rv;
            return l;
        }
        return null;
    } else if (L == ?f32 and R == f32) {
        return if (l) |val| val + r else null;
    } else if (L == f32 and R == ?f32) {
        return if (r) |val| l + val else l;
    } else if (L == AvailableSpace and R == f32) {
        return switch (l) {
            .definite => |val| .{ .definite = val + r },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else if (L == AvailableSpace and R == ?f32) {
        return switch (l) {
            .definite => |val| if (r) |rv| .{ .definite = val + rv } else .{ .definite = val },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else {
        return .{ .width = maybeAdd(l.width, r.width), .height = maybeAdd(l.height, r.height) };
    }
}

/// Subtracts `rhs` from `lhs`, treating null values as default
pub fn maybeSub(lhs: anytype, rhs: anytype) MaybeMathOutput(@TypeOf(lhs), @TypeOf(rhs)) {
    const L = Norm(@TypeOf(lhs));
    const R = Norm(@TypeOf(rhs));
    const l: L = lhs;
    const r: R = rhs;
    if (L == ?f32 and R == ?f32) {
        if (l) |lv| {
            if (r) |rv| return lv - rv;
            return l;
        }
        return null;
    } else if (L == ?f32 and R == f32) {
        return if (l) |val| val - r else null;
    } else if (L == f32 and R == ?f32) {
        return if (r) |val| l - val else l;
    } else if (L == AvailableSpace and R == f32) {
        return switch (l) {
            .definite => |val| .{ .definite = val - r },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else if (L == AvailableSpace and R == ?f32) {
        return switch (l) {
            .definite => |val| if (r) |rv| .{ .definite = val - rv } else .{ .definite = val },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    } else {
        return .{ .width = maybeSub(l.width, r.width), .height = maybeSub(l.height, r.height) };
    }
}

const testing = std.testing;
const none: ?f32 = null;

fn some(v: f32) ?f32 {
    return v;
}

test "lhs ?f32, rhs ?f32: maybeMin" {
    try testing.expectEqual(some(3.0), maybeMin(some(3.0), some(5.0)));
    try testing.expectEqual(some(3.0), maybeMin(some(5.0), some(3.0)));
    try testing.expectEqual(some(3.0), maybeMin(some(3.0), none));
    try testing.expectEqual(none, maybeMin(none, some(3.0)));
    try testing.expectEqual(none, maybeMin(none, none));
}

test "lhs ?f32, rhs ?f32: maybeMax" {
    try testing.expectEqual(some(5.0), maybeMax(some(3.0), some(5.0)));
    try testing.expectEqual(some(5.0), maybeMax(some(5.0), some(3.0)));
    try testing.expectEqual(some(3.0), maybeMax(some(3.0), none));
    try testing.expectEqual(none, maybeMax(none, some(3.0)));
    try testing.expectEqual(none, maybeMax(none, none));
}

test "lhs ?f32, rhs ?f32: maybeAdd" {
    try testing.expectEqual(some(8.0), maybeAdd(some(3.0), some(5.0)));
    try testing.expectEqual(some(8.0), maybeAdd(some(5.0), some(3.0)));
    try testing.expectEqual(some(3.0), maybeAdd(some(3.0), none));
    try testing.expectEqual(none, maybeAdd(none, some(3.0)));
    try testing.expectEqual(none, maybeAdd(none, none));
}

test "lhs ?f32, rhs ?f32: maybeSub" {
    try testing.expectEqual(some(-2.0), maybeSub(some(3.0), some(5.0)));
    try testing.expectEqual(some(2.0), maybeSub(some(5.0), some(3.0)));
    try testing.expectEqual(some(3.0), maybeSub(some(3.0), none));
    try testing.expectEqual(none, maybeSub(none, some(3.0)));
    try testing.expectEqual(none, maybeSub(none, none));
}

test "lhs ?f32, rhs f32: maybeMin" {
    try testing.expectEqual(some(3.0), maybeMin(some(3.0), @as(f32, 5.0)));
    try testing.expectEqual(some(3.0), maybeMin(some(5.0), @as(f32, 3.0)));
    try testing.expectEqual(none, maybeMin(none, @as(f32, 3.0)));
}

test "lhs ?f32, rhs f32: maybeMax" {
    try testing.expectEqual(some(5.0), maybeMax(some(3.0), @as(f32, 5.0)));
    try testing.expectEqual(some(5.0), maybeMax(some(5.0), @as(f32, 3.0)));
    try testing.expectEqual(none, maybeMax(none, @as(f32, 3.0)));
}

test "lhs ?f32, rhs f32: maybeAdd" {
    try testing.expectEqual(some(8.0), maybeAdd(some(3.0), @as(f32, 5.0)));
    try testing.expectEqual(some(8.0), maybeAdd(some(5.0), @as(f32, 3.0)));
    try testing.expectEqual(none, maybeAdd(none, @as(f32, 3.0)));
}

test "lhs ?f32, rhs f32: maybeSub" {
    try testing.expectEqual(some(-2.0), maybeSub(some(3.0), @as(f32, 5.0)));
    try testing.expectEqual(some(2.0), maybeSub(some(5.0), @as(f32, 3.0)));
    try testing.expectEqual(none, maybeSub(none, @as(f32, 3.0)));
}

test "lhs f32, rhs ?f32: maybeMin" {
    try testing.expectEqual(@as(f32, 3.0), maybeMin(@as(f32, 3.0), some(5.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeMin(@as(f32, 5.0), some(3.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeMin(@as(f32, 3.0), none));
}

test "lhs f32, rhs ?f32: maybeMax" {
    try testing.expectEqual(@as(f32, 5.0), maybeMax(@as(f32, 3.0), some(5.0)));
    try testing.expectEqual(@as(f32, 5.0), maybeMax(@as(f32, 5.0), some(3.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeMax(@as(f32, 3.0), none));
}

test "lhs f32, rhs ?f32: maybeAdd" {
    try testing.expectEqual(@as(f32, 8.0), maybeAdd(@as(f32, 3.0), some(5.0)));
    try testing.expectEqual(@as(f32, 8.0), maybeAdd(@as(f32, 5.0), some(3.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeAdd(@as(f32, 3.0), none));
}

test "lhs f32, rhs ?f32: maybeSub" {
    try testing.expectEqual(@as(f32, -2.0), maybeSub(@as(f32, 3.0), some(5.0)));
    try testing.expectEqual(@as(f32, 2.0), maybeSub(@as(f32, 5.0), some(3.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeSub(@as(f32, 3.0), none));
}

test "maybeClamp combinations" {
    try testing.expectEqual(some(4.0), maybeClamp(some(5.0), some(1.0), some(4.0)));
    try testing.expectEqual(some(2.0), maybeClamp(some(1.0), some(2.0), none));
    try testing.expectEqual(some(1.0), maybeClamp(some(1.0), none, none));
    try testing.expectEqual(none, maybeClamp(none, some(2.0), some(3.0)));
    try testing.expectEqual(some(3.0), maybeClamp(some(9.0), @as(f32, 1.0), @as(f32, 3.0)));
    try testing.expectEqual(none, maybeClamp(none, @as(f32, 1.0), @as(f32, 3.0)));
    try testing.expectEqual(@as(f32, 3.0), maybeClamp(@as(f32, 9.0), some(1.0), some(3.0)));
    try testing.expectEqual(@as(f32, 9.0), maybeClamp(@as(f32, 9.0), some(1.0), none));
    try testing.expectEqual(@as(f32, 3.0), maybeClamp(@as(f32, 9.0), none, some(3.0)));
    // min wins over max when they conflict (min(max).max(min))
    try testing.expectEqual(@as(f32, 5.0), maybeClamp(@as(f32, 9.0), some(5.0), some(3.0)));
}

test "AvailableSpace combinations" {
    const definite: AvailableSpace = .{ .definite = 10.0 };
    const min_c: AvailableSpace = .min_content;
    const max_c: AvailableSpace = .max_content;
    try testing.expect(maybeMin(definite, @as(f32, 5.0)).eql(.{ .definite = 5.0 }));
    try testing.expect(maybeMin(min_c, @as(f32, 5.0)).eql(.{ .definite = 5.0 }));
    try testing.expect(maybeMin(max_c, some(5.0)).eql(.{ .definite = 5.0 }));
    try testing.expect(maybeMin(max_c, none).eql(.max_content));
    try testing.expect(maybeMin(definite, none).eql(definite));
    try testing.expect(maybeMax(definite, @as(f32, 15.0)).eql(.{ .definite = 15.0 }));
    try testing.expect(maybeMax(min_c, @as(f32, 15.0)).eql(.min_content));
    try testing.expect(maybeMax(max_c, some(15.0)).eql(.max_content));
    try testing.expect(maybeClamp(definite, @as(f32, 1.0), @as(f32, 5.0)).eql(.{ .definite = 5.0 }));
    try testing.expect(maybeClamp(definite, some(12.0), none).eql(.{ .definite = 12.0 }));
    try testing.expect(maybeClamp(min_c, some(12.0), none).eql(.min_content));
    try testing.expect(maybeAdd(definite, @as(f32, 1.0)).eql(.{ .definite = 11.0 }));
    try testing.expect(maybeAdd(definite, none).eql(definite));
    try testing.expect(maybeAdd(max_c, some(1.0)).eql(.max_content));
    try testing.expect(maybeSub(definite, some(1.0)).eql(.{ .definite = 9.0 }));
    try testing.expect(maybeSub(min_c, @as(f32, 1.0)).eql(.min_content));
}

test "Size combinations" {
    const a: Size(?f32) = .{ .width = 3.0, .height = null };
    const b: Size(?f32) = .{ .width = 5.0, .height = 4.0 };
    try testing.expectEqual(Size(?f32){ .width = 3.0, .height = null }, maybeMin(a, b));
    try testing.expectEqual(Size(?f32){ .width = 8.0, .height = null }, maybeAdd(a, b));
    const c: Size(f32) = .{ .width = 10.0, .height = 10.0 };
    try testing.expectEqual(Size(f32){ .width = 3.0, .height = 10.0 }, maybeMin(c, a.@"or"(.{ .width = 5.0, .height = null })));
    try testing.expectEqual(Size(f32){ .width = 7.0, .height = 10.0 }, maybeSub(c, a));
    try testing.expectEqual(Size(f32){ .width = 10.0, .height = 10.0 }, maybeMax(c, a));
    try testing.expectEqual(Size(f32){ .width = 5.0, .height = 4.0 }, maybeClamp(c, a, b));
    const s: Size(?f32) = .{ .width = 1.0, .height = null };
    const f: Size(f32) = .{ .width = 2.0, .height = 2.0 };
    try testing.expectEqual(Size(?f32){ .width = 2.0, .height = null }, maybeMax(s, f));
    const avail: Size(AvailableSpace) = .{ .width = .{ .definite = 10.0 }, .height = .max_content };
    const result = maybeSub(avail, Size(f32){ .width = 1.0, .height = 1.0 });
    try testing.expect(result.width.eql(.{ .definite = 9.0 }));
    try testing.expect(result.height.eql(.max_content));
}

test "literal arguments" {
    try testing.expectEqual(some(3.0), maybeMin(some(3.0), 5.0));
    try testing.expectEqual(@as(f32, 3.0), maybeMin(@as(f32, 3.0), null));
    try testing.expectEqual(some(3.0), maybeMin(some(3.0), null));
}
