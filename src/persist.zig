// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Optional persistence support for HNSW indexes.
//!
//! Provides snapshot save and load using a compact binary format.
//! The format uses little-endian integers and native-endian floats,
//! so snapshots are portable across little-endian platforms sharing
//! the same IEEE 754 float representation.
//!
//! ## Binary Format (version 1)
//!
//! Header (27 bytes):
//!   magic:            [4]u8    "HNSW"
//!   version:          u32 LE   1
//!   dim:              u32 LE   vector dimension
//!   metric:           u8       DistanceMetric enum value
//!   m:                u16 LE   max connections per layer
//!   ef_construction:  u16 LE   construction beam width
//!   ef_search:        u16 LE   search beam width
//!   max_layers:       u8       max graph layers
//!   seed:             u64 LE   PRNG seed
//!
//! Index state (9 bytes):
//!   node_count:       u32 LE   number of nodes
//!   entry_point:      u32 LE   entry node index (0xFFFFFFFF = null)
//!   max_level:        u8       highest occupied layer
//!
//! Per node:
//!   id:               u64 LE   user-provided ID
//!   level:            u8       max layer for this node
//!   vector:           [dim]f32 native byte order
//!   per layer (0..level):
//!     conn_count:     u32 LE   number of connections
//!     connections:    [conn_count]u32 LE  neighbor indices

const std = @import("std");
const Allocator = std.mem.Allocator;
const hnsw_mod = @import("hnsw.zig");
const Hnsw = hnsw_mod.Hnsw;
const Config = hnsw_mod.Config;
const Node = hnsw_mod.Node;
const DistanceMetric = hnsw_mod.DistanceMetric;

const MAGIC = [4]u8{ 'H', 'N', 'S', 'W' };
const FORMAT_VERSION: u32 = 1;

/// Maximum dimension accepted during load to prevent DoS.
const MAX_DIM: u32 = 65536;
/// Maximum node count accepted during load to prevent DoS.
const MAX_NODE_COUNT: u32 = 10_000_000;

pub const PersistError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidMetric,
    InvalidDimension,
    InvalidConfig,
    InvalidEntryPoint,
    InvalidNodeLevel,
    InvalidMaxLevel,
    InvalidNeighborIndex,
    InvalidVector,
    NodeCountTooLarge,
};

/// Serialize an HNSW index to the given writer.
pub fn save(index: *const Hnsw, writer: anytype) !void {
    // Header
    try writer.writeAll(&MAGIC);
    try writeU32(writer, FORMAT_VERSION);
    try writeU32(writer, index.dim);
    try writer.writeByte(@intFromEnum(index.metric));
    try writeU16(writer, index.config.m);
    try writeU16(writer, index.config.ef_construction);
    try writeU16(writer, index.config.ef_search);
    try writer.writeByte(index.config.max_layers);
    try writeU64(writer, index.config.seed);

    // Index state
    const node_count: u32 = @intCast(index.nodes.items.len);
    try writeU32(writer, node_count);
    try writeU32(writer, index.entry_point orelse std.math.maxInt(u32));
    try writer.writeByte(index.max_level);

    // Nodes
    for (index.nodes.items) |node| {
        try writeU64(writer, node.id);
        try writer.writeByte(node.level);

        // Vector as raw bytes (native float layout)
        try writer.writeAll(std.mem.sliceAsBytes(node.vector));

        // Connections per layer
        for (node.connections) |conn| {
            const conn_count: u32 = @intCast(conn.items.len);
            try writeU32(writer, conn_count);
            for (conn.items) |neighbor| {
                try writeU32(writer, neighbor);
            }
        }
    }
}

/// Deserialize an HNSW index from the given reader.
///
/// The returned index owns all its memory through the provided allocator.
/// Validates all indices, dimensions, and configuration to reject
/// malformed or malicious snapshot files.
pub fn load(allocator: Allocator, reader: anytype) !Hnsw {
    // Header
    var magic_buf: [4]u8 = undefined;
    try reader.readNoEof(&magic_buf);
    if (!std.mem.eql(u8, &magic_buf, &MAGIC)) return PersistError.InvalidMagic;

    const version = try readU32(reader);
    if (version != FORMAT_VERSION) return PersistError.UnsupportedVersion;

    const dim = try readU32(reader);
    if (dim == 0 or dim > MAX_DIM) return PersistError.InvalidDimension;

    const metric_byte = try reader.readByte();
    const metric = std.meta.intToEnum(DistanceMetric, metric_byte) catch return PersistError.InvalidMetric;

    const m = try readU16(reader);
    const ef_construction = try readU16(reader);
    const ef_search = try readU16(reader);
    const max_layers = try reader.readByte();
    const seed = try readU64(reader);

    // Validate config parameters
    if (m < 2) return PersistError.InvalidConfig;
    if (max_layers == 0) return PersistError.InvalidConfig;
    if (ef_construction == 0 or ef_search == 0) return PersistError.InvalidConfig;

    const config = Config{
        .m = m,
        .ef_construction = ef_construction,
        .ef_search = ef_search,
        .max_layers = max_layers,
        .seed = seed,
    };

    // Index state
    const node_count = try readU32(reader);
    if (node_count > MAX_NODE_COUNT) return PersistError.NodeCountTooLarge;

    const raw_ep = try readU32(reader);
    const entry_point: ?u32 = if (raw_ep == std.math.maxInt(u32)) null else raw_ep;

    // Validate entry_point
    if (entry_point) |ep| {
        if (ep >= node_count) return PersistError.InvalidEntryPoint;
    }

    const max_level = try reader.readByte();
    if (node_count > 0 and max_level >= max_layers) return PersistError.InvalidMaxLevel;

    // Nodes
    var nodes: std.ArrayListUnmanaged(Node) = .{};
    errdefer {
        for (nodes.items) |*node| {
            node.deinit(allocator);
        }
        nodes.deinit(allocator);
    }
    try nodes.ensureTotalCapacity(allocator, node_count);

    for (0..node_count) |_| {
        const node = try loadNode(allocator, reader, dim, max_layers, node_count);
        nodes.appendAssumeCapacity(node);
    }

    const m_float: f64 = @floatFromInt(config.m);
    return Hnsw{
        .allocator = allocator,
        .dim = dim,
        .metric = metric,
        .config = config,
        .nodes = nodes,
        .entry_point = entry_point,
        .max_level = max_level,
        .prng = std.Random.DefaultPrng.init(seed),
        .level_mult = 1.0 / @log(m_float),
    };
}

// ============================================================================
// Deserialization helpers
// ============================================================================

/// Read and validate a single node from the binary stream.
fn loadNode(allocator: Allocator, reader: anytype, dim: u32, max_layers: u8, node_count: u32) !Node {
    const id = try readU64(reader);
    const level = try reader.readByte();
    if (level >= max_layers) return PersistError.InvalidNodeLevel;

    const vec = try allocator.alloc(f32, dim);
    errdefer allocator.free(vec);
    try reader.readNoEof(std.mem.sliceAsBytes(vec));

    for (vec) |v| {
        if (std.math.isNan(v) or std.math.isInf(v)) return PersistError.InvalidVector;
    }

    const conns = try loadConnections(allocator, reader, level, node_count);
    return .{ .id = id, .vector = vec, .level = level, .connections = conns };
}

/// Read and validate connection lists for all layers of a node.
fn loadConnections(allocator: Allocator, reader: anytype, level: u8, node_count: u32) ![]std.ArrayListUnmanaged(u32) {
    const num_layers: usize = @as(usize, level) + 1;
    const conns = try allocator.alloc(std.ArrayListUnmanaged(u32), num_layers);
    errdefer allocator.free(conns);

    for (conns) |*conn| {
        conn.* = .{};
    }
    errdefer for (conns) |*conn| {
        conn.deinit(allocator);
    };

    for (conns) |*conn| {
        const conn_count = try readU32(reader);
        try conn.ensureTotalCapacity(allocator, conn_count);
        for (0..conn_count) |_| {
            const neighbor = try readU32(reader);
            if (neighbor >= node_count) return PersistError.InvalidNeighborIndex;
            conn.appendAssumeCapacity(neighbor);
        }
    }
    return conns;
}

// ============================================================================
// Serialization helpers
// ============================================================================

fn writeU16(writer: anytype, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeU32(writer: anytype, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeU64(writer: anytype, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readU16(reader: anytype) !u16 {
    var buf: [2]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u16, &buf, .little);
}

fn readU32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(reader: anytype) !u64 {
    var buf: [8]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

// ============================================================================
// Test helpers
// ============================================================================

fn buildTestHeader(buf: []u8, overrides: struct {
    magic: [4]u8 = MAGIC,
    version: u32 = FORMAT_VERSION,
    dim: u32 = 2,
    metric: u8 = 0,
    m: u16 = 4,
    ef_construction: u16 = 100,
    ef_search: u16 = 50,
    max_layers: u8 = 16,
    seed: u64 = 42,
    node_count: u32 = 0,
    entry_point: u32 = std.math.maxInt(u32),
    max_level: u8 = 0,
}) usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll(&overrides.magic) catch unreachable;
    writeU32(w, overrides.version) catch unreachable;
    writeU32(w, overrides.dim) catch unreachable;
    w.writeByte(overrides.metric) catch unreachable;
    writeU16(w, overrides.m) catch unreachable;
    writeU16(w, overrides.ef_construction) catch unreachable;
    writeU16(w, overrides.ef_search) catch unreachable;
    w.writeByte(overrides.max_layers) catch unreachable;
    writeU64(w, overrides.seed) catch unreachable;
    writeU32(w, overrides.node_count) catch unreachable;
    writeU32(w, overrides.entry_point) catch unreachable;
    w.writeByte(overrides.max_level) catch unreachable;
    return fbs.pos;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "save and load empty index" {
    var index = try Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try save(&index, fbs.writer());

    fbs.pos = 0;
    var loaded = try load(std.testing.allocator, fbs.reader());
    defer loaded.deinit();

    try std.testing.expectEqual(index.dim, loaded.dim);
    try std.testing.expectEqual(index.metric, loaded.metric);
    try std.testing.expectEqual(index.count(), loaded.count());
    try std.testing.expect(loaded.entry_point == null);
}

test "save and load index with vectors" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(10, &[_]f32{ 1.0, 2.0 });
    try index.insert(20, &[_]f32{ 3.0, 4.0 });
    try index.insert(30, &[_]f32{ 5.0, 6.0 });

    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try save(&index, fbs.writer());

    fbs.pos = 0;
    var loaded = try load(std.testing.allocator, fbs.reader());
    defer loaded.deinit();

    try std.testing.expectEqual(index.dim, loaded.dim);
    try std.testing.expectEqual(index.count(), loaded.count());
    try std.testing.expectEqual(index.entry_point, loaded.entry_point);
    try std.testing.expectEqual(index.max_level, loaded.max_level);

    // Verify search still works after load
    const results = try loaded.knnSearch(&[_]f32{ 1.0, 2.0 }, 1);
    defer loaded.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 10), results[0].id);
}

test "load rejects invalid magic" {
    const bad_data = [_]u8{ 'B', 'A', 'D', '!' } ++ [_]u8{0} ** 32;
    var fbs = std.io.fixedBufferStream(&bad_data);
    const result = load(std.testing.allocator, fbs.reader());
    try std.testing.expectError(PersistError.InvalidMagic, result);
}

test "load rejects unsupported version" {
    var buf: [128]u8 = undefined;
    const pos = buildTestHeader(&buf, .{ .version = 99 });
    _ = pos;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.UnsupportedVersion, load(std.testing.allocator, fbs.reader()));
}

test "load rejects dim=0" {
    var buf: [128]u8 = undefined;
    _ = buildTestHeader(&buf, .{ .dim = 0 });
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.InvalidDimension, load(std.testing.allocator, fbs.reader()));
}

test "load rejects invalid metric" {
    var buf: [128]u8 = undefined;
    _ = buildTestHeader(&buf, .{ .metric = 255 });
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.InvalidMetric, load(std.testing.allocator, fbs.reader()));
}

test "load rejects m=0" {
    var buf: [128]u8 = undefined;
    _ = buildTestHeader(&buf, .{ .m = 0 });
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.InvalidConfig, load(std.testing.allocator, fbs.reader()));
}

test "load rejects max_layers=0" {
    var buf: [128]u8 = undefined;
    _ = buildTestHeader(&buf, .{ .max_layers = 0 });
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.InvalidConfig, load(std.testing.allocator, fbs.reader()));
}

test "load rejects invalid entry_point" {
    var buf: [128]u8 = undefined;
    // node_count=0 but entry_point=5 (not null)
    _ = buildTestHeader(&buf, .{ .node_count = 0, .entry_point = 5 });
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(PersistError.InvalidEntryPoint, load(std.testing.allocator, fbs.reader()));
}
