const std = @import("std");

const Build = std.Build;
const Pkg = Build.Pkg;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const reedsolomon_module = b.addModule("reedsolomon", .{ .source_file = .{
        .path = "src/reedsolomon.zig",
    } });

    const test_exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "test/all_tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_exe.addModule("reedsolomon", reedsolomon_module);

    b.installArtifact(test_exe);
    const run_cmd = b.addRunArtifact(test_exe);

    const run_step = b.step("test", "Run tests");
    run_step.dependOn(&run_cmd.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "benchmark/benchmark.zig" },
        .target = target,
        .optimize = optimize,
    });
    benchmark_exe.linkLibC();
    benchmark_exe.addModule("reedsolomon", reedsolomon_module);

    b.installArtifact(benchmark_exe);
    const run_benchmark_cmd = b.addRunArtifact(benchmark_exe);

    const run_benchmark_step = b.step("benchmark", "Run benchmarks");
    run_benchmark_step.dependOn(&run_benchmark_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());
}
