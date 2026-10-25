// Rhyos Labs - Ephor
// The overseer of your Zig code
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");

/// EPH-I0291 flake forensics: print the build graph seed at the start of
/// every `zig build test` run. The runner prints the seed only on failure
/// (the "failed command" replay line), so a hang or a protocol desync
/// loses it. The seed labels the run. Test order is declaration order, so
/// the seed does not change what executes.
fn printTestSeed(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    std.log.info("test run seed: 0x{x}", .{step.owner.graph.random_seed});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // EPH-I0623 (documented arm): keep standardOptimizeOption without a
    // preferred mode. In Zig 0.16.0 a preferred mode deletes the -Doptimize
    // flag (std/Build.zig standardOptimizeOption registers only -Drelease on
    // that branch) and a bare `zig build` stays Debug by stdlib design. The
    // ReleaseSafe guarantee lives in the gate: scripts/gate.sh builds with
    // -Doptimize=ReleaseSafe explicitly.
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ephor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run Ephor");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);


}
