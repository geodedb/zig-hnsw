// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Thread pool parallelism dependency
    const thread_pool_dep = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    });
    const thread_pool_module = thread_pool_dep.module("thread_pool");

    // Main library module
    const module = b.addModule("hnsw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thread_pool", .module = thread_pool_module },
        },
    });

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate test file with module import)
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    // Example executable
    const example_step = b.step("example", "Build and run the basic example");
    const example = b.addExecutable(.{
        .name = "hnsw-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
            },
        }),
    });
    const run_example = b.addRunArtifact(example);
    example_step.dependOn(&run_example.step);

    // Check step for IDE integration (fast syntax validation)
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
        }),
    });
    check_step.dependOn(&check.step);

    // -----------------------------------------------------------------------
    // Benchmarks (ReleaseFast for accurate timing)
    // -----------------------------------------------------------------------

    // Basic benchmark
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Incremental scale benchmark
    const scale_bench_step = b.step("scale-bench", "Run incremental scale benchmarks with JSON output");
    const scale_bench_exe = b.addExecutable(.{
        .name = "scale-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/scale_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
            },
        }),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| {
        run_scale_bench.addArgs(args);
    }
    scale_bench_step.dependOn(&run_scale_bench.step);

    // Benchmark comparison tool
    const compare_bench_step = b.step("compare-bench", "Compare benchmark results against a baseline");
    const compare_bench_exe = b.addExecutable(.{
        .name = "compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| {
        run_compare_bench.addArgs(args);
    }
    compare_bench_step.dependOn(&run_compare_bench.step);
}
