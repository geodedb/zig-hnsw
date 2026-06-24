// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dwith_otel: compile in otel instrumentation. OFF by default;
    // when off the otel dependency is never resolved and the seam
    // collapses to a comptime-known no-op (verified by
    // otel/scripts/verify-consumer-noop.sh).
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    // Thread pool parallelism dependency
    const thread_pool_dep = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    });
    const thread_pool_module = thread_pool_dep.module("thread_pool");

    // Materialize ONE shared `build_options` module. Each consumer
    // module imports the SAME module instance via `addImport` to avoid
    // Zig 0.16's "file exists in modules X and X0" error when two
    // independent `addOptions` modules end up sharing a transitive
    // file path.
    const build_options = b.addOptions();
    build_options.addOption(bool, "with_otel", with_otel);
    build_options.addOption([]const u8, "package_name", "hnsw");
    const build_options_mod = build_options.createModule();

    // Observability seam (otel). Declared as a SHARED NAMED MODULE so
    // every consumer (lib, tests, example, plus the seam tests) resolves
    // to the same source file via `@import("observability")`. Using a
    // relative `@import("observability.zig")` from each module would
    // trip Zig's "file exists in modules X and Y" error because the
    // file would be pulled into multiple module trees. The seam's
    // `enabled` flag tracks `build_options.with_otel`; when off, every
    // helper compiles to a comptime-known no-op and the otel dependency
    // is never resolved.
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Gated otel dependency. The `lazy = true` entry in build.zig.zon
    // means Zig only fetches the package when this branch executes;
    // with the flag off the dependency is never resolved and the
    // produced artifacts contain zero otel symbols (verified by
    // otel/scripts/verify-consumer-noop.sh).
    var otel_mod: ?*std.Build.Module = null;
    var observability_init_mod: ?*std.Build.Module = null;
    if (with_otel) {
        if (b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        })) |otel_dep| {
            const m = otel_dep.module("otel");
            otel_mod = m;
            // The seam itself imports `otel` when enabled.
            observability_mod.addImport("otel", m);

            // Bootstrap helper. Only registered when `-Dwith_otel=true`
            // so the disabled build never compiles otel-touching code.
            // Surfaced from root.zig via
            // `if (observability.enabled) @import("observability_init")`.
            observability_init_mod = b.addModule("observability_init", .{
                .root_source_file = b.path("src/observability_init.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "otel", .module = m },
                    .{ .name = "observability", .module = observability_mod },
                },
            });
        }
    }

    // Main library module
    const module = b.addModule("hnsw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thread_pool", .module = thread_pool_module },
            .{ .name = "observability", .module = observability_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    if (otel_mod) |m| module.addImport("otel", m);
    if (observability_init_mod) |m| module.addImport("observability_init", m);

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = thread_pool_module },
                .{ .name = "observability", .module = observability_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (otel_mod) |m| unit_tests.root_module.addImport("otel", m);
    if (observability_init_mod) |m| unit_tests.root_module.addImport("observability_init", m);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Observability seam tests. Two targets:
    //   - `observability_disabled_test.zig` runs under BOTH flag
    //     values. Each test inside it is skip-guarded via
    //     `if (hnsw.observability.enabled) return error.SkipZigTest;`
    //     so the disabled-mode invariants only fire when the flag is
    //     off.
    //   - `observability_enabled_test.zig` is registered under both
    //     flag values too, but every test inside it skips when the
    //     flag is off. The `otel` import is wired only when
    //     `with_otel = true`; the stub branch in the test file
    //     (`const otel = if (build_options.with_otel) ...`) ensures
    //     the file still compiles cleanly under the disabled build.
    const obs_disabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_obs_disabled = b.addRunArtifact(obs_disabled_tests);
    test_step.dependOn(&run_obs_disabled.step);

    const obs_enabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_enabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hnsw", .module = module },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (otel_mod) |m| obs_enabled_tests.root_module.addImport("otel", m);
    const run_obs_enabled = b.addRunArtifact(obs_enabled_tests);
    test_step.dependOn(&run_obs_enabled.step);

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
                .{ .name = "observability", .module = observability_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (otel_mod) |m| check.root_module.addImport("otel", m);
    if (observability_init_mod) |m| check.root_module.addImport("observability_init", m);
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
