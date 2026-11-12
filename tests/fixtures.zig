//! Conformance tests: runs taffy's Chrome-generated XML fixtures against laffy.
const std = @import("std");

pub const xml = @import("support/xml.zig");
pub const style_parse = @import("support/style_parse.zig");

test {
    std.testing.refAllDecls(@This());
}
