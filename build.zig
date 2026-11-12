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

    // Benchmarks: `zig build bench -- [filter] [--verify]`. Always ReleaseFast, linked against libc
    // so that the allocator is malloc (as in the Rust comparison program).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benches/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "laffy", .module = bench_mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true;
    run_bench.addPassthruArgs();

    const bench_step = b.step("bench", "Run benchmarks: [filter] [--verify]");
    bench_step.dependOn(&run_bench.step);

    // The C API (src/c_api.zig, include/laffy.h): `zig build` installs zig-out/lib/liblaffy.a
    // (or the shared library with -Dlinkage=dynamic) and zig-out/include/laffy.h.
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Linkage of the C library (default: static)") orelse .static;
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_lib = b.addLibrary(.{ .name = "laffy", .linkage = linkage, .root_module = c_api_mod });
    c_lib.installHeader(b.path("include/laffy.h"), "laffy.h");
    b.installArtifact(c_lib);

    // `zig build c-test`: a C99 program that drives the C API end to end against the library
    // (and checks for leaks with a counting allocator), plus a C++ compile check of the header.
    const c_test_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    c_test_mod.addCSourceFile(.{
        .file = b.path("tests/c/test_c_api.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
    });
    c_test_mod.linkLibrary(c_lib);
    const c_test_exe = b.addExecutable(.{ .name = "test_c_api", .root_module = c_test_mod });
    const run_c_test = b.addRunArtifact(c_test_exe);
    run_c_test.expectExitCode(0);
    const cpp_check_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    cpp_check_mod.addCSourceFile(.{
        .file = b.path("tests/c/header_check.cpp"),
        .flags = &.{ "-std=c++11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
    });
    cpp_check_mod.addIncludePath(b.path("include"));
    const cpp_header_check = b.addObject(.{ .name = "header_check", .root_module = cpp_check_mod });
    const c_test_step = b.step("c-test", "Build the C library and run the C API test program");
    c_test_step.dependOn(&run_c_test.step);
    c_test_step.dependOn(&cpp_header_check.step);
}
