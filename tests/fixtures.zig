//! Conformance tests: runs taffy's Chrome-generated XML fixtures against laffy.
const std = @import("std");

pub const xml = @import("support/xml.zig");
pub const style_parse = @import("support/style_parse.zig");
pub const measure = @import("support/measure.zig");
pub const runner = @import("support/runner.zig");

/// Fixture groups that are expected to pass completely. `zig build fixtures` fails unless every
/// fixture in these groups passes. Add a group here when its algorithm is ported.
/// (`zig build conformance -- <group>` runs any group, enabled or not.)
pub const enabled_groups = [_][]const u8{"leaf"};

test {
    std.testing.refAllDecls(@This());
}

test "enabled fixture groups pass" {
    const gpa = std.testing.allocator;
    var failed: usize = 0;
    for (enabled_groups) |group| {
        var result = try runner.runGroup(gpa, std.testing.io, group, null, runner.default_fixtures_root);
        defer result.deinit(gpa);
        try std.testing.expect(result.total > 0);
        if (result.failures.items.len == 0) continue;
        std.debug.print("group {s}: {d}/{d} passed; failing fixtures:\n", .{ group, result.passed, result.total });
        for (result.failures.items) |f| std.debug.print("  {s}\n", .{f.name});
        failed += result.failures.items.len;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
