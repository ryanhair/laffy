//! Development runner: `zig build conformance -- [group ...] [--filter substring] [--verbose]`.
const std = @import("std");
const fixtures = @import("fixtures.zig");
const runner = @import("support/runner.zig");

const usage =
    \\usage: zig build conformance -- [group ...] [--filter substring] [--verbose]
    \\
    \\Runs taffy's XML fixtures against laffy. With no group, runs the enabled groups.
    \\Groups: block blockflex blockgrid contain flex float grid gridflex leaf
    \\--filter  only fixtures whose name contains the substring
    \\--verbose print the expected/actual diff of every failure (done automatically
    \\         when at most 3 fixtures fail)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    var groups: std.ArrayList([]const u8) = .empty;
    var filter: ?[]const u8 = null;
    var verbose = false;

    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll(usage);
                try out.flush();
                std.process.exit(2);
            }
            filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try out.writeAll(usage);
            try out.flush();
            std.process.exit(2);
        } else {
            try groups.append(arena, arg);
        }
    }
    if (groups.items.len == 0) {
        for (fixtures.enabled_groups) |g| try groups.append(arena, g);
    }

    var total_failed: usize = 0;
    var total_run: usize = 0;
    var total_skipped: usize = 0;
    const start = std.Io.Clock.awake.now(io);

    for (groups.items) |group| {
        var result = runner.runGroup(gpa, io, group, filter, runner.default_fixtures_root) catch |err| {
            try out.print("{s}: cannot run group ({s})\n", .{ group, @errorName(err) });
            total_failed += 1;
            continue;
        };
        defer result.deinit(gpa);
        total_run += result.total;
        try out.print("{s}: {d}/{d}", .{ group, result.passed, result.total });
        if (result.skipped > 0) try out.print(" ({d} skipped: algorithm not ported)", .{result.skipped});
        try out.writeByte('\n');
        total_skipped += result.skipped;
        total_failed += result.failures.items.len;

        const show_diff = verbose or result.failures.items.len <= 3;
        for (result.failures.items) |f| {
            try out.print("  FAIL {s}\n", .{f.name});
            if (show_diff) {
                var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, f.report, "\n"), '\n');
                while (lines.next()) |line| try out.print("    {s}\n", .{line});
            }
        }
    }

    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try out.print("{d} fixtures, {d} failed, {d} skipped, {d} ms\n", .{ total_run, total_failed, total_skipped, @divTrunc(elapsed.toNanoseconds(), std.time.ns_per_ms) });
    try out.flush();
    if (total_failed != 0) std.process.exit(1);
}
