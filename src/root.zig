//! laffy: a Zig port of the taffy UI layout library (flexbox, CSS grid, block and float layout).
//!
//! The port tracks the upstream commit recorded in `tests/fixtures/UPSTREAM`.
const std = @import("std");

/// The taffy release this port tracks.
pub const upstream_version = "0.15.0";

test {
    std.testing.refAllDecls(@This());
}
