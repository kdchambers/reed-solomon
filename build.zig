const std = @import("std");

const Build = std.Build;
const Pkg = Build.Pkg;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "reed_solomon_test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run example reed-solomon encoder");
    run_step.dependOn(&run_cmd.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/benchmark.zig" },
        .target = target,
        .optimize = optimize,
    });
    benchmark_exe.linkLibC();

    b.installArtifact(benchmark_exe);
    const run_benchmark_cmd = b.addRunArtifact(benchmark_exe);

    const run_benchmark_step = b.step("benchmark", "Run benchmarks");
    run_benchmark_step.dependOn(&run_benchmark_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());
}
