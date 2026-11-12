//! Helper functions to calculate dimensions during layout resolution (upstream `MaybeResolve`
//! and `ResolveOrZero` traits)
//!
//! Exposed as free functions that dispatch on the argument types at comptime:
//!
//!   - `maybeResolve(value, context, calc) MaybeResolveOutput(...)`: resolve a value that might
//!     depend on a context into a context-independent value, with `null` as the fallback.
//!   - `resolveOrZero(value, context, calc) ResolveOrZeroOutput(...)`: as above, but with zero as
//!     the fallback.
//!
//! Supported combinations (`value` / `context` -> result), as upstream:
//!
//!   - `maybeResolve`:
//!     - `LengthPercentage`, `LengthPercentageAuto` or `Dimension` / `?f32` or `f32` -> `?f32`
//!     - `Size(T)` / `Size(In)` -> `Size(Out)` (element-wise)
//!   - `resolveOrZero`:
//!     - `LengthPercentage`, `LengthPercentageAuto` or `Dimension` / `?f32` -> `f32`
//!       (an `f32` context is also accepted and treated as non-null)
//!     - `Size(T)` / `Size(In)` -> `Size(f32)` (element-wise)
//!     - `Rect(T)` / `Size(In)` -> `Rect(f32)` (left/right use the width, top/bottom the height)
//!     - `Rect(T)` / `?f32` or `f32` -> `Rect(f32)` (every side uses the same context)
//!
//! Comptime numbers are treated as `f32` and a bare `null` as `?f32`.
//!
//! `calc` is any value with a `resolveCalcValue(handle: CalcHandle, basis: f32) f32` method
//! (see `NoCalc` / `ConstCalc` in `style/compact_length.zig`). It is only called for `calc()` values.
const std = @import("std");
const CalcHandle = @import("../style/compact_length.zig").CalcHandle;
const geometry = @import("../geometry.zig");
const Size = geometry.Size;
const Rect = geometry.Rect;
const CompactLength = @import("../style/compact_length.zig").CompactLength;
const dimension = @import("../style/dimension.zig");
const LengthPercentage = dimension.LengthPercentage;
const LengthPercentageAuto = dimension.LengthPercentageAuto;
const Dimension = dimension.Dimension;

/// Normalizes literal types: comptime numbers become `f32`, `@TypeOf(null)` becomes `?f32`.
fn Norm(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_float, .comptime_int => f32,
        .null => ?f32,
        else => T,
    };
}

fn isLeaf(comptime T: type) bool {
    return T == LengthPercentage or T == LengthPercentageAuto or T == Dimension;
}

/// The result type of `maybeResolve` for a value of type `Value` and a context of type `Context`
pub fn MaybeResolveOutput(comptime Value: type, comptime Context: type) type {
    const C = Norm(Context);
    if (isLeaf(Value) and (C == ?f32 or C == f32)) return ?f32;
    if (geometry.isSize(Value) and geometry.isSize(C)) return Size(MaybeResolveOutput(Value.Inner, C.Inner));
    @compileError("MaybeResolve is not implemented for " ++ @typeName(Value) ++ " with context " ++ @typeName(Context));
}

/// The result type of `resolveOrZero` for a value of type `Value` and a context of type `Context`
pub fn ResolveOrZeroOutput(comptime Value: type, comptime Context: type) type {
    const C = Norm(Context);
    if (isLeaf(Value) and (C == ?f32 or C == f32)) return f32;
    if (geometry.isSize(Value) and geometry.isSize(C)) return Size(ResolveOrZeroOutput(Value.Inner, C.Inner));
    if (geometry.isRect(Value) and geometry.isSize(C)) return Rect(ResolveOrZeroOutput(Value.Inner, C.Inner));
    if (geometry.isRect(Value) and (C == ?f32 or C == f32)) return Rect(ResolveOrZeroOutput(Value.Inner, C));
    @compileError("ResolveOrZero is not implemented for " ++ @typeName(Value) ++ " with context " ++ @typeName(Context));
}

/// Resolve a value that might be dependent on a context, with `null` as the fallback value
pub fn maybeResolve(value: anytype, context: anytype, calc: anytype) MaybeResolveOutput(@TypeOf(value), @TypeOf(context)) {
    const V = @TypeOf(value);
    const C = Norm(@TypeOf(context));
    if (comptime isLeaf(V)) {
        // Upstream implements `MaybeResolve<f32>` generically by wrapping the context in `Some`
        const ctx: ?f32 = @as(C, context);
        return resolveLeaf(value, ctx, calc);
    } else {
        const ctx: C = context;
        return .{
            .width = maybeResolve(value.width, ctx.width, calc),
            .height = maybeResolve(value.height, ctx.height, calc),
        };
    }
}

/// Resolve a value that might be dependent on a context, with zero as the fallback value
pub fn resolveOrZero(value: anytype, context: anytype, calc: anytype) ResolveOrZeroOutput(@TypeOf(value), @TypeOf(context)) {
    const V = @TypeOf(value);
    const C = Norm(@TypeOf(context));
    const ctx: C = context;
    if (comptime isLeaf(V)) {
        return resolveLeaf(value, @as(?f32, ctx), calc) orelse 0.0;
    } else if (comptime geometry.isSize(V)) {
        return .{
            .width = resolveOrZero(value.width, ctx.width, calc),
            .height = resolveOrZero(value.height, ctx.height, calc),
        };
    } else if (comptime geometry.isSize(C)) {
        // Rect resolved against a Size
        return .{
            .left = resolveOrZero(value.left, ctx.width, calc),
            .right = resolveOrZero(value.right, ctx.width, calc),
            .top = resolveOrZero(value.top, ctx.height, calc),
            .bottom = resolveOrZero(value.bottom, ctx.height, calc),
        };
    } else {
        // Rect resolved against a single context
        return .{
            .left = resolveOrZero(value.left, ctx, calc),
            .right = resolveOrZero(value.right, ctx, calc),
            .top = resolveOrZero(value.top, ctx, calc),
            .bottom = resolveOrZero(value.bottom, ctx, calc),
        };
    }
}

/// `maybeResolve` for `LengthPercentage`, `LengthPercentageAuto` and `Dimension`
inline fn resolveLeaf(value: anytype, context: ?f32, calc: anytype) ?f32 {
    // This runs for every side of every box, so each type gets its own switch on its own tag
    // instead of first being widened to a common type
    if (@TypeOf(value) == LengthPercentage) {
        return switch (value) {
            .length => |length| length,
            .percent => |fraction| if (context) |dim| dim * fraction else null,
            .calc => |handle| if (context) |dim| calc.resolveCalcValue(handle, dim) else null,
        };
    }
    return switch (value) {
        .length => |length| length,
        .percent => |fraction| if (context) |dim| dim * fraction else null,
        .calc => |handle| if (context) |dim| calc.resolveCalcValue(handle, dim) else null,
        // `auto` has no definite size. The `content` keyword is only valid for flex-basis; in
        // any other context it behaves as `auto`. Intrinsic sizing keywords cannot be resolved
        // to a definite size out of context: layout algorithms that support them must handle
        // them explicitly.
        else => null,
    };
}

const testing = std.testing;
const ConstCalc = @import("../style/compact_length.zig").ConstCalc;
const calc_42 = ConstCalc{ .value = 42.42 };
const none: ?f32 = null;

fn some(v: f32) ?f32 {
    return v;
}

fn mrCase(input: anytype, context: anytype, expected: MaybeResolveOutput(@TypeOf(input), @TypeOf(context))) !void {
    try testing.expectEqual(expected, maybeResolve(input, context, calc_42));
}

fn rozCase(input: anytype, context: anytype, expected: ResolveOrZeroOutput(@TypeOf(input), @TypeOf(context))) !void {
    try testing.expectEqual(expected, resolveOrZero(input, context, calc_42));
}

// maybe_resolve_dimension

// `Dimension.auto` should always return `null`
//
// The parent / context should not affect the outcome.
test "maybe_resolve_dimension: resolve_auto" {
    try mrCase(@as(Dimension, .auto), none, none);
    try mrCase(@as(Dimension, .auto), some(5.0), none);
    try mrCase(@as(Dimension, .auto), some(-5.0), none);
    try mrCase(@as(Dimension, .auto), some(0.0), none);
}

// `Dimension.length` should always return the inner absolute length.
//
// The parent / context should not affect the outcome.
test "maybe_resolve_dimension: resolve_length" {
    try mrCase(Dimension.fromLength(1.0), none, some(1.0));
    try mrCase(Dimension.fromLength(1.0), some(5.0), some(1.0));
    try mrCase(Dimension.fromLength(1.0), some(-5.0), some(1.0));
    try mrCase(Dimension.fromLength(1.0), some(0.0), some(1.0));
}

// `Dimension.percent` should return `null` if context is `null`.
// Otherwise it should return the inner value of the percent * context value.
//
// The parent / context __should__ affect the outcome.
test "maybe_resolve_dimension: resolve_percent" {
    try mrCase(Dimension.fromPercent(1.0), none, none);
    try mrCase(Dimension.fromPercent(1.0), some(5.0), some(5.0));
    try mrCase(Dimension.fromPercent(1.0), some(-5.0), some(-5.0));
    try mrCase(Dimension.fromPercent(1.0), some(50.0), some(50.0));
}

// maybe_resolve_size_dimension

// Size(Dimension.auto) should always return Size(null)
//
// The parent / context should not affect the outcome.
test "maybe_resolve_size_dimension: maybe_resolve_auto" {
    try mrCase(Size(Dimension).auto, Size(?f32).none, Size(?f32).none);
    try mrCase(Size(Dimension).auto, Size(?f32).new(5.0, 5.0), Size(?f32).none);
    try mrCase(Size(Dimension).auto, Size(?f32).new(-5.0, -5.0), Size(?f32).none);
    try mrCase(Size(Dimension).auto, Size(?f32).new(0.0, 0.0), Size(?f32).none);
}

// Size(Dimension.length) should always return the absolute lengths.
//
// The parent / context should not affect the outcome.
test "maybe_resolve_size_dimension: maybe_resolve_length" {
    try mrCase(Size(Dimension).fromLengths(5.0, 5.0), Size(?f32).none, Size(?f32).new(5.0, 5.0));
    try mrCase(Size(Dimension).fromLengths(5.0, 5.0), Size(?f32).new(5.0, 5.0), Size(?f32).new(5.0, 5.0));
    try mrCase(Size(Dimension).fromLengths(5.0, 5.0), Size(?f32).new(-5.0, -5.0), Size(?f32).new(5.0, 5.0));
    try mrCase(Size(Dimension).fromLengths(5.0, 5.0), Size(?f32).new(0.0, 0.0), Size(?f32).new(5.0, 5.0));
}

// `Size(Dimension.percent)` should return `Size(null)` if context is `Size(null)`.
// Otherwise it should return the inner value of the percent * context value.
//
// The context __should__ affect the outcome.
test "maybe_resolve_size_dimension: maybe_resolve_percent" {
    try mrCase(Size(Dimension).fromPercents(5.0, 5.0), Size(?f32).none, Size(?f32).none);
    try mrCase(Size(Dimension).fromPercents(5.0, 5.0), Size(?f32).new(5.0, 5.0), Size(?f32).new(25.0, 25.0));
    try mrCase(Size(Dimension).fromPercents(5.0, 5.0), Size(?f32).new(-5.0, -5.0), Size(?f32).new(-25.0, -25.0));
    try mrCase(Size(Dimension).fromPercents(5.0, 5.0), Size(?f32).new(0.0, 0.0), Size(?f32).new(0.0, 0.0));
}

// resolve_or_zero_dimension_to_option_f32

test "resolve_or_zero_dimension_to_option_f32: resolve_or_zero_auto" {
    try rozCase(@as(Dimension, .auto), none, 0.0);
    try rozCase(@as(Dimension, .auto), some(5.0), 0.0);
    try rozCase(@as(Dimension, .auto), some(-5.0), 0.0);
    try rozCase(@as(Dimension, .auto), some(0.0), 0.0);
}

test "resolve_or_zero_dimension_to_option_f32: resolve_or_zero_length" {
    try rozCase(Dimension.fromLength(5.0), none, 5.0);
    try rozCase(Dimension.fromLength(5.0), some(5.0), 5.0);
    try rozCase(Dimension.fromLength(5.0), some(-5.0), 5.0);
    try rozCase(Dimension.fromLength(5.0), some(0.0), 5.0);
}

test "resolve_or_zero_dimension_to_option_f32: resolve_or_zero_percent" {
    try rozCase(Dimension.fromPercent(5.0), none, 0.0);
    try rozCase(Dimension.fromPercent(5.0), some(5.0), 25.0);
    try rozCase(Dimension.fromPercent(5.0), some(-5.0), -25.0);
    try rozCase(Dimension.fromPercent(5.0), some(0.0), 0.0);
}

// resolve_or_zero_rect_dimension_to_rect

test "resolve_or_zero_rect_dimension_to_rect: resolve_or_zero_auto" {
    try rozCase(Rect(Dimension).auto, Size(?f32).none, Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, Size(?f32).new(5.0, 5.0), Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, Size(?f32).new(-5.0, -5.0), Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, Size(?f32).new(0.0, 0.0), Rect(f32).zero);
}

test "resolve_or_zero_rect_dimension_to_rect: resolve_or_zero_length" {
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), Size(?f32).none, Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), Size(?f32).new(5.0, 5.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), Size(?f32).new(-5.0, -5.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), Size(?f32).new(0.0, 0.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
}

test "resolve_or_zero_rect_dimension_to_rect: resolve_or_zero_percent" {
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), Size(?f32).none, Rect(f32).zero);
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), Size(?f32).new(5.0, 5.0), Rect(f32).new(25.0, 25.0, 25.0, 25.0));
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), Size(?f32).new(-5.0, -5.0), Rect(f32).new(-25.0, -25.0, -25.0, -25.0));
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), Size(?f32).new(0.0, 0.0), Rect(f32).zero);
}

// resolve_or_zero_rect_dimension_to_rect_f32_via_option

test "resolve_or_zero_rect_dimension_to_rect_f32_via_option: resolve_or_zero_auto" {
    try rozCase(Rect(Dimension).auto, none, Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, some(5.0), Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, some(-5.0), Rect(f32).zero);
    try rozCase(Rect(Dimension).auto, some(0.0), Rect(f32).zero);
}

test "resolve_or_zero_rect_dimension_to_rect_f32_via_option: resolve_or_zero_length" {
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), none, Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), some(5.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), some(-5.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
    try rozCase(Rect(Dimension).fromLengths(5.0, 5.0, 5.0, 5.0), some(0.0), Rect(f32).new(5.0, 5.0, 5.0, 5.0));
}

test "resolve_or_zero_rect_dimension_to_rect_f32_via_option: resolve_or_zero_percent" {
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), none, Rect(f32).zero);
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), some(5.0), Rect(f32).new(25.0, 25.0, 25.0, 25.0));
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), some(-5.0), Rect(f32).new(-25.0, -25.0, -25.0, -25.0));
    try rozCase(Rect(Dimension).fromPercents(5.0, 5.0, 5.0, 5.0), some(0.0), Rect(f32).zero);
}

// Additional coverage (not upstream): other leaf types, f32 contexts, keywords and calc()

test "maybeResolve other leaf types and contexts" {
    try mrCase(LengthPercentage.fromPercent(0.5), @as(f32, 10.0), some(5.0));
    try mrCase(@as(LengthPercentageAuto, .auto), @as(f32, 10.0), none);
    try mrCase(@as(Dimension, .content), some(10.0), none);
    try mrCase(@as(Dimension, .min_content), some(10.0), none);
    try mrCase(Dimension.fitContentPx(3.0), some(10.0), none);
    try rozCase(LengthPercentage.fromLength(3.0), none, 3.0);
    try rozCase(LengthPercentageAuto.fromPercent(0.5), some(4.0), 2.0);
    try rozCase(Size(LengthPercentage).fromPercent(0.5), Size(?f32){ .width = 4.0, .height = null }, Size(f32){ .width = 2.0, .height = 0.0 });
    try rozCase(Rect(LengthPercentage).fromPercent(0.5), @as(f32, 8.0), Rect(f32).new(4.0, 4.0, 4.0, 4.0));
    try mrCase(Dimension.fromLength(2.0), 7.0, some(2.0));
    try mrCase(Dimension.fromPercent(0.5), null, none);
}

test "maybeResolve calc values" {
    const handle: CalcHandle = 1;
    try mrCase(Dimension.fromCalc(handle), some(10.0), some(42.42));
    try mrCase(Dimension.fromCalc(handle), none, none);
    try mrCase(LengthPercentage.fromCalc(handle), some(10.0), some(42.42));
    try mrCase(LengthPercentageAuto.fromCalc(handle), @as(f32, 1.0), some(42.42));
    try mrCase(Dimension.fitContentCalc(handle), some(10.0), none);
    try rozCase(Dimension.fromCalc(handle), none, 0.0);
}
