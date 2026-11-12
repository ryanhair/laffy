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
}
