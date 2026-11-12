//! Ports of taffy's hand-written integration tests (upstream `tests/hand_written/`).
//! Each upstream file is one Zig file under `hand_written/`, imported below.
const std = @import("std");

pub const adversarial_styles = @import("hand_written/adversarial_styles.zig");
pub const absolute_replaced = @import("hand_written/absolute_replaced.zig");
pub const baseline = @import("hand_written/baseline.zig");
pub const caching = @import("hand_written/caching.zig");
pub const block_margin = @import("hand_written/block_margin.zig");
pub const block_replaced = @import("hand_written/block_replaced.zig");
pub const compressible_replaced = @import("hand_written/compressible_replaced.zig");
pub const border_and_padding = @import("hand_written/border_and_padding.zig");
pub const flex_line_count = @import("hand_written/flex_line_count.zig");
pub const floats = @import("hand_written/floats.zig");
pub const fit_content_calc = @import("hand_written/fit_content_calc.zig");
pub const initial_containing_block = @import("hand_written/initial_containing_block.zig");
pub const measure = @import("hand_written/measure.zig");
pub const min_max_overrides = @import("hand_written/min_max_overrides.zig");
pub const negative_available_space = @import("hand_written/negative_available_space.zig");
pub const position = @import("hand_written/position.zig");
pub const relayout = @import("hand_written/relayout.zig");
pub const root_constraints = @import("hand_written/root_constraints.zig");
pub const rounding = @import("hand_written/rounding.zig");
pub const detailed_grid_info = @import("hand_written/detailed_grid_info.zig");
pub const grid_percentage_rerun = @import("hand_written/grid_percentage_rerun.zig");
pub const oof_hoisting = @import("hand_written/oof_hoisting.zig");
pub const safe_alignment = @import("hand_written/safe_alignment.zig");
pub const scroll_size = @import("hand_written/scroll_size.zig");
pub const scrollable_overflow = @import("hand_written/scrollable_overflow.zig");

test {
    std.testing.refAllDecls(@This());
}
