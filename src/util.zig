//! Helpful misc. utilities
//!
//! Ported so far: `math` (upstream `MaybeMath`), `resolve` (upstream `MaybeResolve` and
//! `ResolveOrZero`) and the float helpers of `sys`.
pub const math = @import("util/math.zig");
pub const resolve = @import("util/resolve.zig");
pub const sys = @import("util/sys.zig");

pub const maybeMin = math.maybeMin;
pub const maybeMax = math.maybeMax;
pub const maybeClamp = math.maybeClamp;
pub const maybeAdd = math.maybeAdd;
pub const maybeSub = math.maybeSub;
pub const MaybeMathOutput = math.MaybeMathOutput;

pub const maybeResolve = resolve.maybeResolve;
pub const resolveOrZero = resolve.resolveOrZero;
pub const MaybeResolveOutput = resolve.MaybeResolveOutput;
pub const ResolveOrZeroOutput = resolve.ResolveOrZeroOutput;

test {
    _ = math;
    _ = resolve;
    _ = sys;
}
