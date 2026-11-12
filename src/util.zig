//! Helpful misc. utilities such as a function to debug print a tree
//!
//! Ported so far: `math` (upstream `MaybeMath`), `resolve` (upstream `MaybeResolve` and
//! `ResolveOrZero`), the float helpers of `sys`, and `print`. `slot_map` is laffy's replacement for
//! the `slotmap` crate used by `TaffyTree`. Upstream's `debug` logging module is not ported.
pub const math = @import("util/math.zig");
pub const resolve = @import("util/resolve.zig");
pub const sys = @import("util/sys.zig");
pub const print = @import("util/print.zig");
pub const slot_map = @import("util/slot_map.zig");

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

pub const printTree = print.printTree;
pub const writeTree = print.writeTree;

test {
    _ = math;
    _ = resolve;
    _ = sys;
    _ = print;
    _ = slot_map;
}
