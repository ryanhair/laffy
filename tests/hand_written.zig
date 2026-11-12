//! Ports of taffy's hand-written integration tests (upstream `tests/hand_written/`).
//! Each upstream file is one Zig file under `hand_written/`, imported below.
const std = @import("std");

pub const absolute_replaced = @import("hand_written/absolute_replaced.zig");
pub const baseline = @import("hand_written/baseline.zig");
pub const block_margin = @import("hand_written/block_margin.zig");
pub const block_replaced = @import("hand_written/block_replaced.zig");
pub const border_and_padding = @import("hand_written/border_and_padding.zig");
pub const flex_line_count = @import("hand_written/flex_line_count.zig");
pub const floats = @import("hand_written/floats.zig");
pub const initial_containing_block = @import("hand_written/initial_containing_block.zig");
pub const measure = @import("hand_written/measure.zig");
pub const min_max_overrides = @import("hand_written/min_max_overrides.zig");
pub const root_constraints = @import("hand_written/root_constraints.zig");
pub const rounding = @import("hand_written/rounding.zig");

test {
    std.testing.refAllDecls(@This());
}
