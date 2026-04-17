// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for hnsw
//!
//! These tests verify end-to-end functionality including insertion, search,
//! multiple distance metrics, persistence round-trips, and recall quality.

const std = @import("std");
const lib = @import("hnsw");

// ============================================================================
// Basic Integration Tests
// ============================================================================

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", lib.version);
}

test "integration: create index, insert, and search" {
    var index = try lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 0.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 1.0, 0.0, 0.0 });
    try index.insert(3, &[_]f32{ 0.0, 1.0, 0.0 });
    try index.insert(4, &[_]f32{ 0.0, 0.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 0.1, 0.0, 0.0 }, 2);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
}

// ============================================================================
// Distance Metric Tests
// ============================================================================

test "integration: euclidean search" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 10.0, 10.0 });

    const results = try index.knnSearch(&[_]f32{ 0.1, 0.1 }, 1);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(u64, 1), results[0].id);
}

test "integration: cosine search" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .cosine, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 2.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0 }, 1);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), results[0].distance, 1e-6);
}

test "integration: manhattan search" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .manhattan, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 1.0 });
    try index.insert(2, &[_]f32{ 5.0, 5.0 });

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 1);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), results[0].distance, 1e-6);
}

test "integration: dot product search" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .dot_product, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.5, 0.0 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0 }, 1);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(u64, 1), results[0].id);
}

// ============================================================================
// Persistence Round-Trip Tests
// ============================================================================

test "integration: save and load preserves search results" {
    var index = try lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .m = 4 });
    defer index.deinit();

    const vectors = [_][3]f32{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 1.0 },
    };
    for (vectors, 0..) |v, i| {
        try index.insert(@intCast(i), &v);
    }

    const query = [_]f32{ 1.0, 0.0, 0.0 };
    const before = try index.knnSearch(&query, 3);
    defer std.testing.allocator.free(before);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try lib.persist.save(&index, &w);
    const written = w.end;

    var r = std.Io.Reader.fixed(buf[0..written]);
    var loaded = try lib.persist.load(std.testing.allocator, &r);
    defer loaded.deinit();

    const after = try loaded.knnSearch(&query, 3);
    defer std.testing.allocator.free(after);

    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |b, a| {
        try std.testing.expectEqual(b.id, a.id);
        try std.testing.expectApproxEqAbs(b.distance, a.distance, 1e-6);
    }
}

// ============================================================================
// Input Validation Tests
// ============================================================================

test "integration: init rejects invalid config" {
    try std.testing.expectError(
        lib.HnswError.InvalidDimension,
        lib.Hnsw.init(std.testing.allocator, 0, .euclidean, .{}),
    );
    try std.testing.expectError(
        lib.HnswError.InvalidConfig,
        lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .m = 0 }),
    );
    try std.testing.expectError(
        lib.HnswError.InvalidConfig,
        lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .max_layers = 0 }),
    );
}

test "integration: insert rejects dimension mismatch" {
    var index = try lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();
    try std.testing.expectError(
        lib.HnswError.DimensionMismatch,
        index.insert(1, &[_]f32{ 1.0, 2.0 }),
    );
}

test "integration: knnSearch rejects dimension mismatch" {
    var index = try lib.Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();
    try std.testing.expectError(
        lib.HnswError.DimensionMismatch,
        index.knnSearch(&[_]f32{1.0}, 5),
    );
}

// ============================================================================
// Recall Quality Tests
// ============================================================================

test "integration: recall quality against brute force (50 vectors)" {
    const dim: u32 = 8;
    const n: u32 = 50;
    const k: u32 = 5;

    var index = try lib.Hnsw.init(std.testing.allocator, dim, .euclidean, .{
        .m = 8,
        .ef_construction = 100,
        .ef_search = 50,
    });
    defer index.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var all_vectors: [n][dim]f32 = undefined;
    for (0..n) |i| {
        for (0..dim) |d| {
            all_vectors[i][d] = random.float(f32) * 2.0 - 1.0;
        }
        try index.insert(@intCast(i), &all_vectors[i]);
    }

    var query: [dim]f32 = undefined;
    for (0..dim) |d| {
        query[d] = random.float(f32) * 2.0 - 1.0;
    }

    const hnsw_results = try index.knnSearch(&query, k);
    defer std.testing.allocator.free(hnsw_results);

    var distances: [n]struct { id: u32, dist: f32 } = undefined;
    for (0..n) |i| {
        distances[i] = .{
            .id = @intCast(i),
            .dist = lib.distance.compute(.euclidean, &query, &all_vectors[i]),
        };
    }
    for (0..k) |i| {
        var best = i;
        for (i + 1..n) |j| {
            if (distances[j].dist < distances[best].dist) {
                best = j;
            }
        }
        if (best != i) {
            const tmp = distances[i];
            distances[i] = distances[best];
            distances[best] = tmp;
        }
    }

    var hits: u32 = 0;
    for (hnsw_results) |hr| {
        for (0..k) |j| {
            if (hr.id == distances[j].id) {
                hits += 1;
                break;
            }
        }
    }

    const recall = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(k));
    try std.testing.expect(recall >= 0.8);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "integration: search single element index" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(99, &[_]f32{ 5.0, 5.0 });

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 3);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 99), results[0].id);
}

test "integration: k=0 returns empty" {
    var index = try lib.Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 0);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "integration: many insertions without memory leak" {
    var index = try lib.Hnsw.init(std.testing.allocator, 4, .euclidean, .{ .m = 8 });
    defer index.deinit();

    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();

    for (0..200) |i| {
        const vec = [_]f32{
            random.float(f32),
            random.float(f32),
            random.float(f32),
            random.float(f32),
        };
        try index.insert(@intCast(i), &vec);
    }

    try std.testing.expectEqual(@as(u32, 200), index.count());

    const results = try index.knnSearch(&[_]f32{ 0.5, 0.5, 0.5, 0.5 }, 10);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 10), results.len);
}

test "integration: Hnsw.registerQueryThread lets each query worker hold a submitter slot" {
    const allocator = std.testing.allocator;

    var index = try lib.Hnsw.init(allocator, 4, .cosine, .{ .m = 4 });
    defer index.deinit();

    // Simulate a query worker opting in.
    const slot = try index.registerQueryThread();
    try std.testing.expect(slot < 64);

    // A query on the registered thread must still succeed — the
    // per-submitter fast path is transparent to callers.
    const vec = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    try index.insert(0, &vec);

    const results = try index.knnSearch(&vec, 1);
    defer allocator.free(results);
    try std.testing.expect(results.len <= 1);

    index.releaseQueryThread(slot);

    // Another register+release cycle must succeed.
    const slot2 = try index.registerQueryThread();
    defer index.releaseQueryThread(slot2);
    try std.testing.expect(slot2 < 64);
}
