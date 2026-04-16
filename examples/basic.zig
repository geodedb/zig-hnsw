// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic vector insertion and nearest-neighbor search example.

const std = @import("std");
const hnsw = @import("hnsw");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &write_buf);
    const stdout = &file_writer.interface;

    try stdout.print("HNSW Nearest-Neighbor Search Example\n", .{});
    try stdout.print("====================================\n\n", .{});

    // Use a debug allocator
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a 3-dimensional index with Euclidean distance
    var index = try hnsw.Hnsw.init(allocator, 3, .euclidean, .{
        .m = 8,
        .ef_construction = 100,
        .ef_search = 50,
    });
    defer index.deinit();

    // Insert some named points
    const points = [_]struct { id: u64, name: []const u8, vec: [3]f32 }{
        .{ .id = 1, .name = "origin", .vec = .{ 0.0, 0.0, 0.0 } },
        .{ .id = 2, .name = "x-axis", .vec = .{ 1.0, 0.0, 0.0 } },
        .{ .id = 3, .name = "y-axis", .vec = .{ 0.0, 1.0, 0.0 } },
        .{ .id = 4, .name = "z-axis", .vec = .{ 0.0, 0.0, 1.0 } },
        .{ .id = 5, .name = "diagonal", .vec = .{ 1.0, 1.0, 1.0 } },
        .{ .id = 6, .name = "near-origin", .vec = .{ 0.1, 0.1, 0.1 } },
    };

    for (points) |p| {
        try index.insert(p.id, &p.vec);
        try stdout.print("Inserted: {s} ({d:.1}, {d:.1}, {d:.1})\n", .{
            p.name,
            p.vec[0],
            p.vec[1],
            p.vec[2],
        });
    }

    try stdout.print("\nIndex contains {d} vectors\n\n", .{index.count()});

    // Search for 3 nearest neighbors to a query point
    const query = [_]f32{ 0.2, 0.0, 0.0 };
    try stdout.print("Query: ({d:.1}, {d:.1}, {d:.1})\n", .{ query[0], query[1], query[2] });
    try stdout.print("Top 3 nearest neighbors:\n", .{});

    const results = try index.knnSearch(&query, 3);
    defer allocator.free(results);

    for (results, 1..) |r, rank| {
        // Find the name for this id
        var name: []const u8 = "unknown";
        for (points) |p| {
            if (p.id == r.id) {
                name = p.name;
                break;
            }
        }
        try stdout.print("  {d}. {s} (id={d}, distance={d:.4})\n", .{
            rank,
            name,
            r.id,
            r.distance,
        });
    }

    try stdout.print("\nExample completed successfully!\n", .{});
    try stdout.flush();
}
