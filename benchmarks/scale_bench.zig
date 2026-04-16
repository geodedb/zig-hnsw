// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Incremental scale benchmark for hnsw.
//!
//! Runs the same battery of operations at progressively larger index sizes
//! and emits structured JSON to stdout for tracking over time.
//! A human-readable summary table is printed to stderr via std.debug.print.
//!
//! Run via: zig build scale-bench
//! Save:   zig build scale-bench 2>/dev/null > results.json

const std = @import("std");
const builtin = @import("builtin");
const hnsw_mod = @import("hnsw");
const Hnsw = hnsw_mod.Hnsw;
const Config = hnsw_mod.Config;
const persist = hnsw_mod.persist;

const print = std.debug.print;

// ---------------------------------------------------------------------------
// Scale tier definitions
// ---------------------------------------------------------------------------

const DIM: u32 = 128;

const Tier = struct {
    name: []const u8,
    vector_count: usize,
    m: u16,
    ef_construction: u16,
    ef_search: u16,
    search_k: u32,
    search_iters: usize,
    insert_iters: usize,
};

const tiers = [_]Tier{
    .{
        .name = "1K",
        .vector_count = 1_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 500,
        .insert_iters = 1_000,
    },
    .{
        .name = "10K",
        .vector_count = 10_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 200,
        .insert_iters = 10_000,
    },
    .{
        .name = "50K",
        .vector_count = 50_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 100,
        .insert_iters = 50_000,
    },
    .{
        .name = "100K",
        .vector_count = 100_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 50,
        .insert_iters = 100_000,
    },
    .{
        .name = "250K",
        .vector_count = 250_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 20,
        .insert_iters = 250_000,
    },
    .{
        .name = "500K",
        .vector_count = 500_000,
        .m = 16,
        .ef_construction = 100,
        .ef_search = 50,
        .search_k = 10,
        .search_iters = 10,
        .insert_iters = 500_000,
    },
};

// ---------------------------------------------------------------------------
// Per-tier results
// ---------------------------------------------------------------------------

const TierResult = struct {
    name: []const u8,
    vector_count: u64,
    insert_ops_sec: f64,
    search_avg_ns: f64,
    search_k50_avg_ns: f64,
    search_ef200_avg_ns: f64,
    recall_at_10: f64,
    save_ms: f64,
    load_ms: f64,
    batch_insert_ops_sec: f64,
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,
};

/// Maximum wall-clock time for a single tier (15 minutes in ns).
const TIER_TIMEOUT_NS: u64 = 15 * 60 * std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs() u64 {
    const ts = std.Io.Timestamp.now(getIo(), .awake);
    return @intCast(@as(i128, ts.nanoseconds));
}

fn makeVector(buf: []f32, id: u64) void {
    var rng = std.Random.DefaultPrng.init(id);
    const random = rng.random();
    for (buf) |*v| {
        v.* = random.float(f32) * 2.0 - 1.0;
    }
}

/// Brute-force kNN for recall computation.
fn bruteForceKnn(
    allocator: std.mem.Allocator,
    vectors: []const [DIM]f32,
    query: []const f32,
    k: usize,
) ![]u64 {
    const Pair = struct { id: u64, dist: f32 };
    var all = try allocator.alloc(Pair, vectors.len);
    defer allocator.free(all);

    for (vectors, 0..) |vec, i| {
        var sum: f32 = 0;
        for (vec, query) |a, b| {
            const d = a - b;
            sum += d * d;
        }
        all[i] = .{ .id = @intCast(i), .dist = @sqrt(sum) };
    }

    std.mem.sort(Pair, all, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.dist < b.dist;
        }
    }.lessThan);

    const n = @min(k, all.len);
    const result = try allocator.alloc(u64, n);
    for (0..n) |i| {
        result[i] = all[i].id;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Individual benchmark functions
// ---------------------------------------------------------------------------

fn benchInsert(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
        .ef_search = tier.ef_search,
    });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;

    const start = nowNs();
    for (0..tier.insert_iters) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }
    const elapsed = nowNs() - start;

    const count_f: f64 = @floatFromInt(tier.insert_iters);
    const ns_f: f64 = @floatFromInt(elapsed);
    return if (ns_f > 0) count_f / (ns_f / 1_000_000_000.0) else 0;
}

fn benchSearch(allocator: std.mem.Allocator, tier: Tier, k: u32, ef: u16) !f64 {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
        .ef_search = ef,
    });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..tier.vector_count) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    var query_buf: [DIM]f32 = undefined;
    const start = nowNs();
    for (0..tier.search_iters) |i| {
        makeVector(&query_buf, tier.vector_count + i);
        const results = try index.knnSearch(&query_buf, k);
        if (results.len > 0) allocator.free(results);
    }
    const elapsed = nowNs() - start;

    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(tier.search_iters);
    return ns_f / count_f;
}

fn benchRecall(allocator: std.mem.Allocator, tier: Tier) !f64 {
    const vec_count = @min(tier.vector_count, 5_000); // cap for brute-force
    const queries = 50;

    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
        .ef_search = 100, // Higher ef for recall measurement
    });
    defer index.deinit();

    var vectors = try allocator.alloc([DIM]f32, vec_count);
    defer allocator.free(vectors);

    for (0..vec_count) |i| {
        makeVector(&vectors[i], i);
        try index.insert(@intCast(i), &vectors[i]);
    }

    var total_recall: f64 = 0;
    var query_buf: [DIM]f32 = undefined;

    for (0..queries) |q| {
        makeVector(&query_buf, vec_count + q);

        const hnsw_results = try index.knnSearch(&query_buf, 10);
        defer if (hnsw_results.len > 0) allocator.free(hnsw_results);

        const bf_results = try bruteForceKnn(allocator, vectors[0..vec_count], &query_buf, 10);
        defer allocator.free(bf_results);

        // Count overlap
        var hits: f64 = 0;
        for (hnsw_results) |hr| {
            for (bf_results) |br| {
                if (hr.id == br) {
                    hits += 1;
                    break;
                }
            }
        }
        const k_f: f64 = @floatFromInt(bf_results.len);
        total_recall += if (k_f > 0) hits / k_f else 0;
    }

    return total_recall / @as(f64, @floatFromInt(queries));
}

fn benchSave(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
    });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..tier.vector_count) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    const buf_size = tier.vector_count * (DIM * 4 + 256) + 65536;
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    const start = nowNs();
    var w = std.Io.Writer.fixed(buf);
    try persist.save(&index, &w);
    const elapsed = nowNs() - start;

    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

fn benchLoad(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
    });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..tier.vector_count) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    const buf_size = tier.vector_count * (DIM * 4 + 256) + 65536;
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    var w = std.Io.Writer.fixed(buf);
    try persist.save(&index, &w);
    const written = w.end;

    const start = nowNs();
    var r = std.Io.Reader.fixed(buf[0..written]);
    var loaded = try persist.load(allocator, &r);
    loaded.deinit();
    const elapsed = nowNs() - start;

    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

fn benchBatchInsert(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{
        .m = tier.m,
        .ef_construction = tier.ef_construction,
    });
    defer index.deinit();

    const count = tier.vector_count;
    var ids = try allocator.alloc(u64, count);
    defer allocator.free(ids);
    var vec_ptrs = try allocator.alloc([]const f32, count);
    defer allocator.free(vec_ptrs);
    var vec_storage = try allocator.alloc([DIM]f32, count);
    defer allocator.free(vec_storage);

    for (0..count) |i| {
        ids[i] = @intCast(i);
        makeVector(&vec_storage[i], i);
        vec_ptrs[i] = &vec_storage[i];
    }

    const start = nowNs();
    try index.batchInsert(ids, vec_ptrs);
    const elapsed = nowNs() - start;

    const count_f: f64 = @floatFromInt(count);
    const ns_f: f64 = @floatFromInt(elapsed);
    return if (ns_f > 0) count_f / (ns_f / 1_000_000_000.0) else 0;
}

// ---------------------------------------------------------------------------
// Run a single tier
// ---------------------------------------------------------------------------

fn runTier(allocator: std.mem.Allocator, tier: Tier) TierResult {
    const tier_start = nowNs();

    // --- Insert throughput ---
    var insert_ops_sec: f64 = 0;
    if (benchInsert(allocator, tier)) |r| {
        insert_ops_sec = r;
    } else |err| {
        print("ERROR in benchInsert: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Search k=10 ---
    var search_avg_ns: f64 = 0;
    if (benchSearch(allocator, tier, 10, tier.ef_search)) |r| {
        search_avg_ns = r;
    } else |err| {
        print("ERROR in benchSearch k=10: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Search k=50 ---
    var search_k50_avg_ns: f64 = 0;
    if (benchSearch(allocator, tier, 50, 100)) |r| {
        search_k50_avg_ns = r;
    } else |err| {
        print("ERROR in benchSearch k=50: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Search ef=200 ---
    var search_ef200_avg_ns: f64 = 0;
    if (benchSearch(allocator, tier, 10, 200)) |r| {
        search_ef200_avg_ns = r;
    } else |err| {
        print("ERROR in benchSearch ef=200: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Recall ---
    var recall_at_10: f64 = 0;
    if (benchRecall(allocator, tier)) |r| {
        recall_at_10 = r;
    } else |err| {
        print("ERROR in benchRecall: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Save ---
    var save_ms: f64 = 0;
    if (benchSave(allocator, tier)) |r| {
        save_ms = r;
    } else |err| {
        print("ERROR in benchSave: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Load ---
    var load_ms: f64 = 0;
    if (benchLoad(allocator, tier)) |r| {
        load_ms = r;
    } else |err| {
        print("ERROR in benchLoad: {any}\n", .{err});
    }
    if (nowNs() - tier_start > TIER_TIMEOUT_NS) return skipResult(tier, "timeout (>15min)");

    // --- Batch insert ---
    var batch_insert_ops_sec: f64 = 0;
    if (benchBatchInsert(allocator, tier)) |r| {
        batch_insert_ops_sec = r;
    } else |err| {
        print("ERROR in benchBatchInsert: {any}\n", .{err});
    }

    return TierResult{
        .name = tier.name,
        .vector_count = @intCast(tier.vector_count),
        .insert_ops_sec = insert_ops_sec,
        .search_avg_ns = search_avg_ns,
        .search_k50_avg_ns = search_k50_avg_ns,
        .search_ef200_avg_ns = search_ef200_avg_ns,
        .recall_at_10 = recall_at_10,
        .save_ms = save_ms,
        .load_ms = load_ms,
        .batch_insert_ops_sec = batch_insert_ops_sec,
    };
}

fn skipResult(tier: Tier, reason: []const u8) TierResult {
    return TierResult{
        .name = tier.name,
        .vector_count = @intCast(tier.vector_count),
        .insert_ops_sec = 0,
        .search_avg_ns = 0,
        .search_k50_avg_ns = 0,
        .search_ef200_avg_ns = 0,
        .recall_at_10 = 0,
        .save_ms = 0,
        .load_ms = 0,
        .batch_insert_ops_sec = 0,
        .skipped = true,
        .skip_reason = reason,
    };
}

// ---------------------------------------------------------------------------
// JSON output to stdout
// ---------------------------------------------------------------------------

fn writeJsonOutput(w: *std.Io.Writer, results: []const TierResult) !void {
    try w.writeAll("{\n");
    try w.writeAll("  \"version\": 1,\n");

    const io = getIo();
    const now_ts = std.Io.Timestamp.now(io, .real);
    const epoch_secs: u64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try w.print("  \"timestamp\": \"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",\n", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });

    try w.writeAll("  \"git_commit\": \"unknown\",\n");

    try w.print("  \"system\": {{ \"os\": \"{s}\", \"arch\": \"{s}\" }},\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

    try w.print("  \"dim\": {d},\n", .{DIM});

    try w.writeAll("  \"tiers\": [\n");
    for (results, 0..) |r, i| {
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\",\n", .{r.name});
        try w.print("      \"vector_count\": {d},\n", .{r.vector_count});
        if (r.skipped) {
            try w.writeAll("      \"skipped\": true,\n");
            if (r.skip_reason) |reason| {
                try w.print("      \"skip_reason\": \"{s}\",\n", .{reason});
            }
        }
        try w.print("      \"insert_ops_sec\": {d:.0},\n", .{r.insert_ops_sec});
        try w.print("      \"search_avg_ns\": {d:.0},\n", .{r.search_avg_ns});
        try w.print("      \"search_k50_avg_ns\": {d:.0},\n", .{r.search_k50_avg_ns});
        try w.print("      \"search_ef200_avg_ns\": {d:.0},\n", .{r.search_ef200_avg_ns});
        try w.print("      \"recall_at_10\": {d:.4},\n", .{r.recall_at_10});
        try w.print("      \"save_ms\": {d:.1},\n", .{r.save_ms});
        try w.print("      \"load_ms\": {d:.1},\n", .{r.load_ms});
        try w.print("      \"batch_insert_ops_sec\": {d:.0}\n", .{r.batch_insert_ops_sec});
        if (i < results.len - 1) {
            try w.writeAll("    },\n");
        } else {
            try w.writeAll("    }\n");
        }
    }
    try w.writeAll("  ]\n");
    try w.writeAll("}\n");
    try w.flush();
}

// ---------------------------------------------------------------------------
// Human-readable summary to stderr
// ---------------------------------------------------------------------------

fn writeSummary(results: []const TierResult) void {
    print("\n", .{});
    print("{s}\n", .{"=" ** 120});
    print("  hnsw incremental scale benchmark (dim={d})\n", .{DIM});
    print("{s}\n\n", .{"=" ** 120});

    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>12} {s:>12} {s:>10} {s:>10} {s:>10} {s:>12}\n", .{
        "Tier", "Vectors", "Insert/s", "Search(ns)", "K50(ns)", "EF200(ns)", "Recall@10", "Save(ms)", "Load(ms)", "Batch/s",
    });
    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>12} {s:>12} {s:>10} {s:>10} {s:>10} {s:>12}\n", .{
        "-" ** 6, "-" ** 8, "-" ** 12, "-" ** 12, "-" ** 12, "-" ** 12, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 12,
    });

    for (results) |r| {
        if (r.skipped) {
            print("  {s:<6} {d:>8} SKIPPED ({s})\n", .{
                r.name, r.vector_count, r.skip_reason orelse "unknown",
            });
        } else {
            print("  {s:<6} {d:>8} {d:>12.0} {d:>12.0} {d:>12.0} {d:>12.0} {d:>10.4} {d:>10.1} {d:>10.1} {d:>12.0}\n", .{
                r.name,
                r.vector_count,
                r.insert_ops_sec,
                r.search_avg_ns,
                r.search_k50_avg_ns,
                r.search_ef200_avg_ns,
                r.recall_at_10,
                r.save_ms,
                r.load_ms,
                r.batch_insert_ops_sec,
            });
        }
    }

    print("\n{s}\n\n", .{"=" ** 120});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var max_tier_count: usize = tiers.len;
    if (args.next()) |arg| {
        for (tiers, 0..) |t, i| {
            if (std.mem.eql(u8, arg, t.name)) {
                max_tier_count = i + 1;
                break;
            }
        }
    }

    var results: [tiers.len]TierResult = undefined;
    var completed: usize = 0;

    for (tiers[0..max_tier_count], 0..) |tier, i| {
        print("  Running tier {s} ({d} vectors)...\n", .{ tier.name, tier.vector_count });
        results[i] = runTier(allocator, tier);
        completed = i + 1;

        if (results[i].skipped) {
            print("  Tier {s} skipped: {s}\n", .{
                tier.name, results[i].skip_reason orelse "unknown",
            });
        } else {
            print("  Tier {s} complete.\n", .{tier.name});
        }
    }

    writeSummary(results[0..completed]);

    // Write JSON to stdout
    const io = getIo();
    const stdout = std.Io.File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var file_writer = stdout.writerStreaming(io, &stdout_buf);
    try writeJsonOutput(&file_writer.interface, results[0..completed]);
}
