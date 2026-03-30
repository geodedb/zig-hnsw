// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Performance benchmark harness for the hnsw library.
//!
//! Benchmarks: single insert, batch insert, kNN search (varying k and ef),
//! recall quality, and persistence save/load.
//!
//! Run via: zig build bench
//!      or: make bench

const std = @import("std");
const hnsw_mod = @import("hnsw");
const Hnsw = hnsw_mod.Hnsw;
const Config = hnsw_mod.Config;
const persist = hnsw_mod.persist;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const DIM: u32 = 128;
const INSERT_COUNT: usize = 10_000;
const BATCH_SIZE: usize = 10_000;
const SEARCH_ITERATIONS: usize = 1_000;
const PERSIST_NODE_COUNT: usize = 5_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BenchResult = struct {
    name: []const u8,
    count: usize,
    total_ns: u64,

    fn ops_per_sec(self: BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        const count_f: f64 = @floatFromInt(self.count);
        const ns_f: f64 = @floatFromInt(self.total_ns);
        return count_f / (ns_f / 1_000_000_000.0);
    }

    fn avg_ns(self: BenchResult) f64 {
        if (self.count == 0) return 0;
        const ns_f: f64 = @floatFromInt(self.total_ns);
        const count_f: f64 = @floatFromInt(self.count);
        return ns_f / count_f;
    }
};

const print = std.debug.print;

fn printHeader() void {
    print("\n{s}\n", .{"=" ** 78});
    print("  hnsw benchmark suite (dim={d})\n", .{DIM});
    print("{s}\n\n", .{"=" ** 78});
    print("  {s:<30} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "Benchmark", "Count", "Total (ms)", "Avg (ns)", "ops/sec",
    });
    print("  {s:<30} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "-" ** 30, "-" ** 10, "-" ** 14, "-" ** 12, "-" ** 10,
    });
}

fn printResult(r: BenchResult) void {
    const total_ms = @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0;
    print("  {s:<30} {d:>10} {d:>14.2} {d:>12.1} {d:>10.0}\n", .{
        r.name,
        r.count,
        total_ms,
        r.avg_ns(),
        r.ops_per_sec(),
    });
}

fn printFooter() void {
    print("\n{s}\n\n", .{"=" ** 78});
}

/// Generate a deterministic random vector for a given id.
fn makeVector(buf: []f32, id: u64) void {
    var rng = std.Random.DefaultPrng.init(id);
    const random = rng.random();
    for (buf) |*v| {
        v.* = random.float(f32) * 2.0 - 1.0;
    }
}

// ---------------------------------------------------------------------------
// Individual benchmarks
// ---------------------------------------------------------------------------

fn benchSingleInsert(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 100 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;

    var timer = try std.time.Timer.start();

    for (0..INSERT_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "single insert", .count = INSERT_COUNT, .total_ns = elapsed };
}

fn benchBatchInsert(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 100 });
    defer index.deinit();

    // Pre-allocate vectors and ids
    var ids: [BATCH_SIZE]u64 = undefined;
    var vectors: [BATCH_SIZE][]const f32 = undefined;
    var vec_storage: [BATCH_SIZE][DIM]f32 = undefined;

    for (0..BATCH_SIZE) |i| {
        ids[i] = @intCast(i);
        makeVector(&vec_storage[i], i);
        vectors[i] = &vec_storage[i];
    }

    var timer = try std.time.Timer.start();
    try index.batchInsert(&ids, &vectors);
    const elapsed = timer.read();

    return BenchResult{ .name = "batch insert", .count = BATCH_SIZE, .total_ns = elapsed };
}

fn benchSearchK10(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 200, .ef_search = 50 });
    defer index.deinit();

    // Build index
    var vec_buf: [DIM]f32 = undefined;
    for (0..INSERT_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    // Search
    var query_buf: [DIM]f32 = undefined;
    var timer = try std.time.Timer.start();

    for (0..SEARCH_ITERATIONS) |i| {
        makeVector(&query_buf, INSERT_COUNT + i);
        const results = try index.knnSearch(&query_buf, 10);
        if (results.len > 0) allocator.free(results);
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "kNN search (k=10)", .count = SEARCH_ITERATIONS, .total_ns = elapsed };
}

fn benchSearchK50(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 200, .ef_search = 100 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..INSERT_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    var query_buf: [DIM]f32 = undefined;
    var timer = try std.time.Timer.start();

    for (0..SEARCH_ITERATIONS) |i| {
        makeVector(&query_buf, INSERT_COUNT + i);
        const results = try index.knnSearch(&query_buf, 50);
        if (results.len > 0) allocator.free(results);
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "kNN search (k=50)", .count = SEARCH_ITERATIONS, .total_ns = elapsed };
}

fn benchSearchHighEf(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 200, .ef_search = 200 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..INSERT_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    const iterations: usize = 500;
    var query_buf: [DIM]f32 = undefined;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        makeVector(&query_buf, INSERT_COUNT + i);
        const results = try index.knnSearch(&query_buf, 10);
        if (results.len > 0) allocator.free(results);
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "kNN search (ef=200)", .count = iterations, .total_ns = elapsed };
}

fn benchPersistSave(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 100 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..PERSIST_NODE_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    // Allocate a large buffer and serialize into it
    const buf = try allocator.alloc(u8, 128 * 1024 * 1024); // 128 MB
    defer allocator.free(buf);

    const iterations: usize = 10;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var fbs = std.io.fixedBufferStream(buf);
        try persist.save(&index, fbs.writer());
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "persist save (5k nodes)", .count = iterations, .total_ns = elapsed };
}

fn benchPersistLoad(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .euclidean, .{ .m = 16, .ef_construction = 100 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..PERSIST_NODE_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    // Serialize once
    const buf = try allocator.alloc(u8, 128 * 1024 * 1024);
    defer allocator.free(buf);
    var fbs = std.io.fixedBufferStream(buf);
    try persist.save(&index, fbs.writer());
    const written = fbs.pos;

    const iterations: usize = 10;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var read_stream = std.io.fixedBufferStream(buf[0..written]);
        var loaded = try persist.load(allocator, read_stream.reader());
        loaded.deinit();
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "persist load (5k nodes)", .count = iterations, .total_ns = elapsed };
}

fn benchCosineSearch(allocator: std.mem.Allocator) !BenchResult {
    var index = try Hnsw.init(allocator, DIM, .cosine, .{ .m = 16, .ef_construction = 200, .ef_search = 50 });
    defer index.deinit();

    var vec_buf: [DIM]f32 = undefined;
    for (0..INSERT_COUNT) |i| {
        makeVector(&vec_buf, i);
        try index.insert(@intCast(i), &vec_buf);
    }

    var query_buf: [DIM]f32 = undefined;
    var timer = try std.time.Timer.start();

    for (0..SEARCH_ITERATIONS) |i| {
        makeVector(&query_buf, INSERT_COUNT + i);
        const results = try index.knnSearch(&query_buf, 10);
        if (results.len > 0) allocator.free(results);
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "cosine search (k=10)", .count = SEARCH_ITERATIONS, .total_ns = elapsed };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn runBench(allocator: std.mem.Allocator, comptime func: *const fn (std.mem.Allocator) anyerror!BenchResult) void {
    const result = func(allocator) catch |err| {
        print("  FAILED: {s}\n", .{@errorName(err)});
        return;
    };
    printResult(result);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    printHeader();

    runBench(allocator, benchSingleInsert);
    runBench(allocator, benchBatchInsert);
    runBench(allocator, benchSearchK10);
    runBench(allocator, benchSearchK50);
    runBench(allocator, benchSearchHighEf);
    runBench(allocator, benchCosineSearch);
    runBench(allocator, benchPersistSave);
    runBench(allocator, benchPersistLoad);

    printFooter();
}
