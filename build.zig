const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("laffy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Conformance tests against the vendored taffy fixtures. They read fixture
    // files at runtime, so they run from the project root.
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "laffy", .module = mod }},
        }),
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    run_fixture_tests.setCwd(b.path("."));
    run_fixture_tests.has_side_effects = true;

    const fixtures_step = b.step("fixtures", "Run fixture conformance tests");
    fixtures_step.dependOn(&run_fixture_tests.step);

    // Ports of upstream's hand-written integration tests.
    const hand_written_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/hand_written.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "laffy", .module = mod }},
        }),
    });
    const run_hand_written_tests = b.addRunArtifact(hand_written_tests);

    const hand_written_step = b.step("hand-written", "Run ported hand-written integration tests");
    hand_written_step.dependOn(&run_hand_written_tests.step);

    // Development runner for the fixtures: `zig build conformance -- [group ...] [--filter s] [--verbose]`.
    // Built in ReleaseSafe by default so that full groups run quickly.
    const conformance_optimize: std.builtin.OptimizeMode = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const conformance_mod = b.addModule("laffy_conformance", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = conformance_optimize,
    });
    const conformance_exe = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = conformance_optimize,
            .imports = &.{.{ .name = "laffy", .module = conformance_mod }},
        }),
    });
    const run_conformance = b.addRunArtifact(conformance_exe);
    run_conformance.setCwd(b.path("."));
    run_conformance.has_side_effects = true;
    run_conformance.addPassthruArgs();

    const conformance_step = b.step("conformance", "Run fixture groups: [group ...] [--filter substring] [--verbose]");
    conformance_step.dependOn(&run_conformance.step);
}
