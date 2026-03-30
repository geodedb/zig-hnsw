// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark comparison tool for hnsw.
//!
//! Reads two JSON result files (baseline and current), compares each metric
//! at each tier, and prints a table showing delta% and pass/fail.
//!
//! Usage: zig build compare-bench -- baseline.json current.json
//! Optional: zig build compare-bench -- baseline.json current.json 25
//!           (last arg is the regression threshold percentage, default 20)
//!
//! Exit code 0 if all pass, 1 if any regression exceeds threshold.

const std = @import("std");

const print = std.debug.print;

// ---------------------------------------------------------------------------
// JSON parsing types
// ---------------------------------------------------------------------------

const TierData = struct {
    name: []const u8 = "",
    vector_count: f64 = 0,
    insert_ops_sec: f64 = 0,
    search_avg_ns: f64 = 0,
    search_k50_avg_ns: f64 = 0,
    search_ef200_avg_ns: f64 = 0,
    recall_at_10: f64 = 0,
    save_ms: f64 = 0,
    load_ms: f64 = 0,
    batch_insert_ops_sec: f64 = 0,
    skipped: bool = false,
};

const BenchResult = struct {
    version: f64 = 0,
    tiers: []TierData = &[_]TierData{},
};

// ---------------------------------------------------------------------------
// Metric definitions
// ---------------------------------------------------------------------------

const MetricKind = enum {
    higher_is_better,
    lower_is_better,
    /// Recall — higher is better but very small absolute changes
    /// shouldn't flag as regressions.
    recall,
};

const Metric = struct {
    name: []const u8,
    kind: MetricKind,
    get: *const fn (TierData) f64,
};

fn getInsertOps(t: TierData) f64 {
    return t.insert_ops_sec;
}
fn getSearchAvg(t: TierData) f64 {
    return t.search_avg_ns;
}
fn getSearchK50(t: TierData) f64 {
    return t.search_k50_avg_ns;
}
fn getSearchEf200(t: TierData) f64 {
    return t.search_ef200_avg_ns;
}
fn getRecall(t: TierData) f64 {
    return t.recall_at_10;
}
fn getSave(t: TierData) f64 {
    return t.save_ms;
}
fn getLoad(t: TierData) f64 {
    return t.load_ms;
}
fn getBatchInsert(t: TierData) f64 {
    return t.batch_insert_ops_sec;
}

const metrics = [_]Metric{
    .{ .name = "insert_ops_sec", .kind = .higher_is_better, .get = getInsertOps },
    .{ .name = "search_avg_ns", .kind = .lower_is_better, .get = getSearchAvg },
    .{ .name = "search_k50_avg_ns", .kind = .lower_is_better, .get = getSearchK50 },
    .{ .name = "search_ef200_avg_ns", .kind = .lower_is_better, .get = getSearchEf200 },
    .{ .name = "recall_at_10", .kind = .recall, .get = getRecall },
    .{ .name = "save_ms", .kind = .lower_is_better, .get = getSave },
    .{ .name = "load_ms", .kind = .lower_is_better, .get = getLoad },
    .{ .name = "batch_insert_ops_sec", .kind = .higher_is_better, .get = getBatchInsert },
};

// ---------------------------------------------------------------------------
// File reading and parsing
// ---------------------------------------------------------------------------

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) !BenchResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        print("Error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(BenchResult, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        print("Error: failed to parse '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    _ = &parsed;

    return parsed.value;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn findTier(result: BenchResult, name: []const u8) ?TierData {
    for (result.tiers) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn computeDeltaPct(baseline_val: f64, current_val: f64) f64 {
    if (baseline_val == 0) return 0;
    return ((current_val - baseline_val) / baseline_val) * 100.0;
}

fn isRegression(delta_pct: f64, kind: MetricKind, threshold: f64) bool {
    return switch (kind) {
        .higher_is_better => delta_pct < -threshold,
        .lower_is_better => delta_pct > threshold,
        .recall => delta_pct < -threshold,
    };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = std.process.args();
    _ = args.next();

    const baseline_path = args.next() orelse {
        print("Usage: compare-bench <baseline.json> <current.json> [threshold%]\n", .{});
        std.process.exit(2);
    };
    const current_path = args.next() orelse {
        print("Usage: compare-bench <baseline.json> <current.json> [threshold%]\n", .{});
        std.process.exit(2);
    };

    var threshold: f64 = 20.0;
    if (args.next()) |thr_str| {
        threshold = std.fmt.parseFloat(f64, thr_str) catch 20.0;
    }

    const baseline = readJsonFile(allocator, baseline_path) catch {
        std.process.exit(2);
    };
    const current = readJsonFile(allocator, current_path) catch {
        std.process.exit(2);
    };

    print("\n{s}\n", .{"=" ** 94});
    print("  hnsw Benchmark Comparison\n", .{});
    print("  Baseline: {s}\n", .{baseline_path});
    print("  Current:  {s}\n", .{current_path});
    print("  Threshold: {d:.0}%\n", .{threshold});
    print("{s}\n\n", .{"=" ** 94});

    print("  {s:<6} {s:<20} {s:>14} {s:>14} {s:>10} {s:>6}\n", .{
        "Tier", "Metric", "Baseline", "Current", "Delta%", "Status",
    });
    print("  {s:<6} {s:<20} {s:>14} {s:>14} {s:>10} {s:>6}\n", .{
        "-" ** 6, "-" ** 20, "-" ** 14, "-" ** 14, "-" ** 10, "-" ** 6,
    });

    var any_regression = false;

    for (baseline.tiers) |base_tier| {
        if (base_tier.skipped) continue;

        const cur_tier = findTier(current, base_tier.name) orelse continue;
        if (cur_tier.skipped) continue;

        for (metrics) |m| {
            const base_val = m.get(base_tier);
            const cur_val = m.get(cur_tier);
            const delta = computeDeltaPct(base_val, cur_val);
            const regressed = isRegression(delta, m.kind, threshold);

            if (regressed) any_regression = true;

            const status: []const u8 = if (regressed) "FAIL" else "PASS";
            const sign: []const u8 = if (delta >= 0) "+" else "";

            print("  {s:<6} {s:<20} {d:>14.1} {d:>14.1} {s}{d:>8.1}% {s:>6}\n", .{
                base_tier.name,
                m.name,
                base_val,
                cur_val,
                sign,
                delta,
                status,
            });
        }

        print("\n", .{});
    }

    print("{s}\n", .{"=" ** 94});

    if (any_regression) {
        print("  RESULT: FAIL -- regression(s) detected above threshold\n\n", .{});
        std.process.exit(1);
    } else {
        print("  RESULT: PASS -- all metrics within threshold\n\n", .{});
    }
}
