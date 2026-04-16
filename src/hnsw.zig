// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! HNSW (Hierarchical Navigable Small World) approximate nearest-neighbor index.
//!
//! Implements the algorithm described in "Efficient and robust approximate nearest
//! neighbor search using Hierarchical Navigable Small World graphs" (Malkov & Yashunin, 2018).
//!
//! The index builds a multi-layer graph where each layer is a navigable small world.
//! Higher layers contain fewer nodes and enable fast coarse-grained search, while
//! layer 0 contains all nodes for precise nearest-neighbor retrieval.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dist = @import("distance.zig");
const tp = @import("thread_pool");

pub const DistanceMetric = dist.DistanceMetric;

/// Result of a nearest-neighbor search, sorted by ascending distance.
pub const SearchResult = struct {
    id: u64,
    distance: f32,
};

pub const HnswError = error{
    /// Dimension must be > 0 and <= 65536.
    InvalidDimension,
    /// Vector length does not match the index dimension.
    DimensionMismatch,
    /// Config parameter out of valid range (m must be 2..32767,
    /// max_layers >= 1, ef_construction >= 1, ef_search >= 1).
    InvalidConfig,
};

/// Configuration for the HNSW index.
pub const Config = struct {
    /// Maximum bi-directional connections per node per layer (default: 16).
    /// Valid range: 2..32767.
    m: u16 = 16,
    /// Construction beam width (default: 200).
    ef_construction: u16 = 200,
    /// Search beam width (default: 50).
    ef_search: u16 = 50,
    /// Maximum number of layers (default: 16).
    max_layers: u8 = 16,
    /// Random seed for reproducible level assignment (default: 42).
    seed: u64 = 42,

    /// Maximum connections at layer 0 (2 * m by convention).
    pub fn m0(self: Config) u32 {
        return @as(u32, self.m) * 2;
    }

    /// Validate that all config parameters are in valid ranges.
    pub fn validate(self: Config) HnswError!void {
        if (self.m < 2) return HnswError.InvalidConfig;
        if (self.max_layers == 0) return HnswError.InvalidConfig;
        if (self.ef_construction == 0) return HnswError.InvalidConfig;
        if (self.ef_search == 0) return HnswError.InvalidConfig;
    }
};

// ============================================================================
// Internal types
// ============================================================================

const Candidate = struct {
    index: u32,
    dist: f32,
};

fn candidateMinOrder(_: void, a: Candidate, b: Candidate) std.math.Order {
    return std.math.order(a.dist, b.dist);
}

fn candidateMaxOrder(_: void, a: Candidate, b: Candidate) std.math.Order {
    return std.math.order(b.dist, a.dist);
}

const MinHeap = std.PriorityQueue(Candidate, void, candidateMinOrder);
const MaxHeap = std.PriorityQueue(Candidate, void, candidateMaxOrder);

/// A node in the HNSW graph. Internal representation.
pub const Node = struct {
    id: u64,
    vector: []f32,
    level: u8,
    /// connections[layer] holds neighbor indices at that layer.
    /// Length is level + 1.
    connections: []std.ArrayListUnmanaged(u32),

    /// Free all memory owned by this node.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        allocator.free(self.vector);
        for (self.connections) |*conn| {
            conn.deinit(allocator);
        }
        allocator.free(self.connections);
    }
};

// ============================================================================
// HNSW Index
// ============================================================================

/// HNSW approximate nearest-neighbor index.
///
/// Supports insertion of vectors and k-nearest-neighbor search with
/// configurable distance metrics. All memory is managed through the
/// provided allocator, which must outlive the index. Results from
/// `knnSearch` must be freed with the same allocator.
///
/// Thread safety: concurrent `knnSearch` calls on a frozen index are safe.
/// Concurrent `insert` and `knnSearch` are protected by an internal `RwLock`.
/// The index uses `thread_pool` for parallel distance computations.
pub const Hnsw = struct {
    /// The allocator used for all owned memory. Results from `knnSearch`
    /// must be freed with this same allocator.
    allocator: Allocator,
    dim: u32,
    metric: DistanceMetric,
    config: Config,
    nodes: std.ArrayListUnmanaged(Node),
    entry_point: ?u32,
    max_level: u8,
    /// Mutex-protected PRNG for thread-safe level generation.
    /// Level generation is always done on the caller's thread before
    /// any forked work, but the mutex ensures safety for concurrent
    /// insert calls.
    prng_mutex: std.Io.Mutex,
    prng: std.Random.DefaultPrng,
    /// Level multiplier: 1/ln(M), per Malkov & Yashunin (2018) Section 4.
    level_mult: f64,
    /// Read-write lock: knnSearch acquires shared, insert acquires exclusive.
    rw_lock: std.Io.RwLock,
    /// Thread pool for parallel distance computations (heap-allocated
    /// because ThreadPool must not move after init — background threads
    /// hold pointers into it).
    pool: *tp.ThreadPool,

    /// Create a new empty HNSW index.
    ///
    /// Returns `InvalidDimension` if dim is 0 or > 65536.
    /// Returns `InvalidConfig` if any config parameter is out of range.
    pub fn init(allocator: Allocator, dim: u32, metric: DistanceMetric, config: Config) !Hnsw {
        if (dim == 0 or dim > 65536) return HnswError.InvalidDimension;
        try config.validate();
        const m: f64 = @floatFromInt(config.m);
        const pool = try allocator.create(tp.ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = try tp.ThreadPool.init(allocator, .{});
        return .{
            .allocator = allocator,
            .dim = dim,
            .metric = metric,
            .config = config,
            .nodes = .empty,
            .entry_point = null,
            .max_level = 0,
            .prng_mutex = std.Io.Mutex.init,
            .prng = std.Random.DefaultPrng.init(config.seed),
            .level_mult = 1.0 / @log(m),
            .rw_lock = std.Io.RwLock.init,
            .pool = pool,
        };
    }

    /// Free all memory owned by the index.
    pub fn deinit(self: *Hnsw) void {
        // Drain in-flight distance tasks before tearing down the pool so
        // workers don't observe freed `Node` storage (PAR-0003).
        self.pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    /// Number of vectors currently in the index.
    pub fn count(self: *const Hnsw) u32 {
        return @intCast(self.nodes.items.len);
    }

    /// Insert a vector into the index with the given user-defined id.
    ///
    /// The vector is copied; the caller retains ownership of the input.
    /// Returns `DimensionMismatch` if `vector.len != self.dim`.
    ///
    /// If an error occurs during graph construction (OOM), the node may
    /// be partially connected. The index remains safe to use and `deinit`
    /// will free all memory, but search quality may be degraded.
    ///
    /// Thread safety: acquires an exclusive write lock. Concurrent
    /// `knnSearch` calls will block until insertion completes.
    pub fn insert(self: *Hnsw, id: u64, vector: []const f32) !void {
        if (vector.len != self.dim) return HnswError.DimensionMismatch;
        self.rw_lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rw_lock.unlock(std.Io.Threaded.global_single_threaded.io());
        try self.insertUnlocked(id, vector);
    }

    /// Insert multiple vectors in a single batch.
    ///
    /// Takes the write lock once for the entire batch and pre-generates
    /// all random levels on the caller's thread. Each individual insertion
    /// benefits from parallelized distance computations in `searchLayer`.
    ///
    /// `ids` and `vectors` must have the same length. Each element of
    /// `vectors` must have length `self.dim`.
    pub fn batchInsert(self: *Hnsw, ids: []const u64, vectors: []const []const f32) !void {
        if (ids.len != vectors.len) return HnswError.DimensionMismatch;
        self.rw_lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rw_lock.unlock(std.Io.Threaded.global_single_threaded.io());
        for (ids, vectors) |id, vec| {
            try self.insertUnlocked(id, vec);
        }
    }

    /// Core insertion logic without locking. Caller must hold the write lock.
    fn insertUnlocked(self: *Hnsw, id: u64, vector: []const f32) !void {
        if (vector.len != self.dim) return HnswError.DimensionMismatch;

        const new_level = self.randomLevel();

        // Allocate node data with errdefer guards until ownership transfers
        const new_idx = blk: {
            const vec = try self.allocator.alloc(f32, self.dim);
            errdefer self.allocator.free(vec);
            @memcpy(vec, vector);

            const num_layers: usize = @as(usize, new_level) + 1;
            const conns = try self.allocator.alloc(std.ArrayListUnmanaged(u32), num_layers);
            errdefer self.allocator.free(conns);
            for (conns) |*c| {
                c.* = .empty;
            }

            const idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .id = id,
                .vector = vec,
                .level = new_level,
                .connections = conns,
            });
            break :blk idx;
        };

        // First node becomes the entry point
        if (self.entry_point == null) {
            self.entry_point = new_idx;
            self.max_level = new_level;
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        var current_ep = self.entry_point.?;

        // Phase 1: Greedy descent from top layer down to new_level + 1
        if (self.max_level > new_level) {
            var lc: u8 = self.max_level;
            while (lc > new_level) {
                current_ep = self.greedyClosest(self.nodes.items[new_idx].vector, current_ep, lc);
                if (lc == 0) break;
                lc -= 1;
            }
        }

        // Phase 2: Insert at layers min(new_level, max_level) down to 0
        const top_layer = @min(new_level, self.max_level);
        var eps: std.ArrayListUnmanaged(u32) = .empty;
        try eps.append(temp, current_ep);

        var lc: u8 = top_layer;
        while (true) {
            const neighbors = try self.searchLayer(temp, self.nodes.items[new_idx].vector, eps.items, self.config.ef_construction, lc);

            const max_conn: u32 = if (lc == 0) self.config.m0() else self.config.m;
            const n_selected = @min(neighbors.len, max_conn);
            const selected = neighbors[0..n_selected];

            // Connect new node to selected neighbors (bidirectional)
            for (selected) |neighbor| {
                try self.connectBidirectional(new_idx, neighbor.index, lc, max_conn);
            }

            // Use selected neighbors as entry points for the next layer down
            eps.clearRetainingCapacity();
            for (selected) |s| {
                try eps.append(temp, s.index);
            }
            if (eps.items.len == 0) {
                try eps.append(temp, current_ep);
            }

            if (lc == 0) break;
            lc -= 1;
        }

        // Promote entry point if new node reaches a higher level
        if (new_level > self.max_level) {
            self.entry_point = new_idx;
            self.max_level = new_level;
        }
    }

    /// Find the k nearest neighbors to the query vector.
    ///
    /// Returns a caller-owned slice of `SearchResult` sorted by ascending distance.
    /// Free the returned slice with `self.allocator.free(results)`.
    /// Returns `DimensionMismatch` if `query.len != self.dim`.
    ///
    /// Thread safety: acquires a shared read lock. Multiple concurrent
    /// `knnSearch` calls may proceed in parallel; they will block only
    /// while an `insert` is in progress.
    pub fn knnSearch(self: *const Hnsw, query: []const f32, k: u32) ![]SearchResult {
        if (query.len != self.dim) return HnswError.DimensionMismatch;
        // Cast away const for RwLock (the lock protects structural mutation,
        // knnSearch only reads).
        const mutable_self: *Hnsw = @constCast(self);
        mutable_self.rw_lock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer mutable_self.rw_lock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        if (self.entry_point == null or k == 0) {
            return &[_]SearchResult{};
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        var ep = self.entry_point.?;

        // Greedy descent from top layer to layer 1
        if (self.max_level > 0) {
            var lc: u8 = self.max_level;
            while (lc > 0) {
                ep = self.greedyClosest(query, ep, lc);
                lc -= 1;
            }
        }

        // Beam search at layer 0
        const ef: u16 = @max(self.config.ef_search, @as(u16, @intCast(@min(k, std.math.maxInt(u16)))));
        const eps = [_]u32{ep};
        const candidates = try self.searchLayer(temp, query, &eps, ef, 0);

        const n = @min(candidates.len, k);
        const results = try self.allocator.alloc(SearchResult, n);
        for (candidates[0..n], 0..) |c, i| {
            results[i] = .{
                .id = self.nodes.items[c.index].id,
                .distance = c.dist,
            };
        }
        return results;
    }

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn randomLevel(self: *Hnsw) u8 {
        self.prng_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.prng_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const random = self.prng.random();
        const r = random.float(f64);
        const clamped = @max(r, std.math.floatEps(f64));
        const raw: f64 = -@log(clamped) * self.level_mult;
        const max_val: f64 = @floatFromInt(@as(u16, self.config.max_layers) - 1);
        return @intFromFloat(@min(@floor(raw), max_val));
    }

    /// Greedy walk to find the single closest node at a given layer.
    fn greedyClosest(self: *const Hnsw, query: []const f32, ep: u32, layer: u8) u32 {
        var current = ep;
        var best_dist = dist.compute(self.metric, query, self.nodes.items[current].vector);

        var improved = true;
        while (improved) {
            improved = false;
            for (self.getConnections(current, layer)) |neighbor| {
                const d = dist.compute(self.metric, query, self.nodes.items[neighbor].vector);
                if (d < best_dist) {
                    current = neighbor;
                    best_dist = d;
                    improved = true;
                }
            }
        }
        return current;
    }

    /// Add a bidirectional edge between two nodes at a given layer, pruning if needed.
    fn connectBidirectional(self: *Hnsw, new_idx: u32, neighbor_idx: u32, layer: u8, max_conn: u32) !void {
        try self.nodes.items[new_idx].connections[layer].append(self.allocator, neighbor_idx);

        if (layer >= self.nodes.items[neighbor_idx].connections.len) return;

        const nconns = &self.nodes.items[neighbor_idx].connections[layer];
        try nconns.append(self.allocator, new_idx);

        if (nconns.items.len > max_conn) {
            self.shrinkConnections(neighbor_idx, layer, max_conn);
        }
    }

    /// Minimum batch size before parallel dispatch kicks in. Below this
    /// threshold the overhead of scheduling outweighs the parallelism gain.
    const parallel_distance_threshold: usize = 32;

    /// Maximum number of chunks to split a distance batch into.
    const MAX_CHUNKS: usize = 64;

    /// Arguments for a single chunk of parallel distance computation.
    ///
    /// WaitGroup bookkeeping is driven by `SubmitOptions.wait_group`, not by
    /// the task itself — the pool performs `wg.add(1)` at enqueue and
    /// `wg.done()` after the task runs.  Keeping a `wg` field here (and
    /// calling `done()` inside the task) would double-count.
    const DistChunkCtx = struct {
        indices: []const u32,
        distances: []f32,
        vectors: []const Node,
        query: []const f32,
        metric: DistanceMetric,
    };

    /// Task function for a single distance-computation chunk.
    fn distChunkTask(raw_ctx: *anyopaque, _: *tp.TaskContext) void {
        const ctx: *DistChunkCtx = @ptrCast(@alignCast(raw_ctx));
        for (ctx.indices, ctx.distances) |idx, *d| {
            d.* = dist.compute(ctx.metric, ctx.query, ctx.vectors[idx].vector);
        }
    }

    /// Beam search at a given layer. Returns candidates sorted by distance ascending.
    ///
    /// Distance computations for neighbor candidates are parallelized via
    /// thread_pool fork/join when the batch exceeds `parallel_distance_threshold`.
    fn searchLayer(
        self: *const Hnsw,
        temp: Allocator,
        query: []const f32,
        entry_points: []const u32,
        ef: u16,
        layer: u8,
    ) ![]Candidate {
        var visited = std.AutoHashMap(u32, void).init(temp);
        var candidates = MinHeap.initContext({});
        var results = MaxHeap.initContext({});

        // Pre-allocate heaps with known ef capacity
        try candidates.ensureTotalCapacity(temp, ef);
        try results.ensureTotalCapacity(temp, ef);

        for (entry_points) |ep| {
            if (visited.contains(ep)) continue;
            try visited.put(ep, {});
            const d = dist.compute(self.metric, query, self.nodes.items[ep].vector);
            const c = Candidate{ .index = ep, .dist = d };
            try candidates.push(temp, c);
            try results.push(temp, c);
        }

        // Temporary buffers for batch distance computation.
        // Sized to the maximum possible neighbors per iteration (m0).
        const max_neighbors: usize = self.config.m0();
        var unvisited_buf = try temp.alloc(u32, max_neighbors);
        var dist_buf = try temp.alloc(f32, max_neighbors);

        // Cast away const for pool access (pool is structurally immutable
        // during search — only internal thread-pool state changes).
        const mutable_self: *Hnsw = @constCast(self);

        while (candidates.count() > 0) {
            const nearest = candidates.pop().?;
            const farthest = results.peek() orelse break;

            if (nearest.dist > farthest.dist) break;

            // Phase 1: Collect unvisited neighbors.
            const connections = self.getConnections(nearest.index, layer);
            var unvisited_count: usize = 0;
            for (connections) |neighbor| {
                if (!visited.contains(neighbor)) {
                    try visited.put(neighbor, {});
                    if (unvisited_count < unvisited_buf.len) {
                        unvisited_buf[unvisited_count] = neighbor;
                        unvisited_count += 1;
                    }
                }
            }

            if (unvisited_count == 0) continue;

            const unvisited = unvisited_buf[0..unvisited_count];
            const distances = dist_buf[0..unvisited_count];

            // Phase 2: Compute distances — parallel via thread_pool for large batches.
            if (unvisited_count > parallel_distance_threshold) {
                // Chunk the work into at most MAX_CHUNKS slices and submit as a batch.
                const n_chunks = @min(unvisited_count, MAX_CHUNKS);
                const chunk_size = (unvisited_count + n_chunks - 1) / n_chunks;

                var chunk_ctxs: [MAX_CHUNKS]DistChunkCtx = undefined;
                var batch_tasks: [MAX_CHUNKS]tp.BatchTask = undefined;
                var wg = mutable_self.pool.waitGroup();

                for (0..n_chunks) |i| {
                    const start = i * chunk_size;
                    const end = @min(start + chunk_size, unvisited_count);
                    chunk_ctxs[i] = .{
                        .indices = unvisited[start..end],
                        .distances = distances[start..end],
                        .vectors = self.nodes.items,
                        .query = query,
                        .metric = self.metric,
                    };
                    batch_tasks[i] = .{
                        .task_fn = distChunkTask,
                        .ctx = @ptrCast(&chunk_ctxs[i]),
                    };
                }

                // `submitBatch` drives `wg.add(1)` per enqueued task; workers
                // call `wg.done()` after the task runs.  The task body does
                // NOT touch `wg` — see DistChunkCtx comment.
                const submitted: usize = if (mutable_self.pool.submitBatch(
                    batch_tasks[0..n_chunks],
                    .{ .wait_group = &wg },
                )) |r| r.submitted else |_| 0;
                // Run any chunks that did not get enqueued (partial submit or
                // full error) on the caller's thread.  `wg` has no accounting
                // for these because they never entered the pool.
                if (submitted < n_chunks) {
                    for (submitted..n_chunks) |i| {
                        for (chunk_ctxs[i].indices, chunk_ctxs[i].distances) |idx, *d| {
                            d.* = dist.compute(self.metric, query, self.nodes.items[idx].vector);
                        }
                    }
                }
                wg.wait();
            } else {
                for (unvisited, distances) |idx, *d| {
                    d.* = dist.compute(self.metric, query, self.nodes.items[idx].vector);
                }
            }

            // Phase 3: Update heaps sequentially.
            for (unvisited, distances) |neighbor, d| {
                const far = results.peek() orelse continue;

                if (d < far.dist or results.count() < ef) {
                    const c = Candidate{ .index = neighbor, .dist = d };
                    try candidates.push(temp, c);
                    try results.push(temp, c);

                    if (results.count() > ef) {
                        _ = results.pop();
                    }
                }
            }
        }

        // Drain max-heap in reverse to get ascending distance order
        const len = results.count();
        const sorted = try temp.alloc(Candidate, len);
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            sorted[i] = results.pop().?;
        }
        return sorted;
    }

    /// Return the neighbor list for a node at a given layer.
    fn getConnections(self: *const Hnsw, index: u32, layer: u8) []const u32 {
        const node = &self.nodes.items[index];
        if (layer >= node.connections.len) return &[_]u32{};
        return node.connections[layer].items;
    }

    /// Keep only the closest `max_conn` connections for a node at a layer.
    fn shrinkConnections(self: *Hnsw, node_idx: u32, layer: u8, max_conn: u32) void {
        const node = &self.nodes.items[node_idx];
        const conns = &node.connections[layer];
        if (conns.items.len <= max_conn) return;

        // Score each connection by distance to the node
        // Use simple selection: swap the closest max_conn to the front
        const items = conns.items;
        for (0..max_conn) |i| {
            var best = i;
            var best_d = dist.compute(self.metric, node.vector, self.nodes.items[items[best]].vector);
            for (i + 1..items.len) |j| {
                const d = dist.compute(self.metric, node.vector, self.nodes.items[items[j]].vector);
                if (d < best_d) {
                    best = j;
                    best_d = d;
                }
            }
            if (best != i) {
                const tmp = items[i];
                items[i] = items[best];
                items[best] = tmp;
            }
        }

        conns.shrinkRetainingCapacity(max_conn);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Hnsw init and deinit" {
    var index = try Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, 0), index.count());
    try std.testing.expect(index.entry_point == null);
}

test "Hnsw init rejects dim=0" {
    const result = Hnsw.init(std.testing.allocator, 0, .euclidean, .{});
    try std.testing.expectError(HnswError.InvalidDimension, result);
}

test "Hnsw init rejects m=0" {
    const result = Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .m = 0 });
    try std.testing.expectError(HnswError.InvalidConfig, result);
}

test "Hnsw init rejects m=1" {
    const result = Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .m = 1 });
    try std.testing.expectError(HnswError.InvalidConfig, result);
}

test "Hnsw init rejects max_layers=0" {
    const result = Hnsw.init(std.testing.allocator, 3, .euclidean, .{ .max_layers = 0 });
    try std.testing.expectError(HnswError.InvalidConfig, result);
}

test "Hnsw insert rejects wrong dimension" {
    var index = try Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();
    const result = index.insert(1, &[_]f32{ 1.0, 2.0 });
    try std.testing.expectError(HnswError.DimensionMismatch, result);
}

test "Hnsw knnSearch rejects wrong dimension" {
    var index = try Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();
    const result = index.knnSearch(&[_]f32{ 1.0, 2.0 }, 5);
    try std.testing.expectError(HnswError.DimensionMismatch, result);
}

test "Hnsw insert single vector" {
    var index = try Hnsw.init(std.testing.allocator, 3, .euclidean, .{});
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(u32, 1), index.count());
    try std.testing.expect(index.entry_point != null);
}

test "Hnsw insert multiple vectors" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    const vectors = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
        .{ 0.5, 0.5 },
    };
    for (vectors, 0..) |v, i| {
        try index.insert(@intCast(i), &v);
    }
    try std.testing.expectEqual(@as(u32, 5), index.count());
}

test "Hnsw knnSearch empty index" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{});
    defer index.deinit();

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 5);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Hnsw knnSearch finds exact match" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(42, &[_]f32{ 1.0, 0.0 });
    try index.insert(43, &[_]f32{ 0.0, 1.0 });
    try index.insert(44, &[_]f32{ 1.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0 }, 1);
    defer index.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 42), results[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), results[0].distance, 1e-6);
}

test "Hnsw knnSearch returns correct order" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    // Insert points at known distances from origin
    try index.insert(1, &[_]f32{ 1.0, 0.0 }); // distance 1.0
    try index.insert(2, &[_]f32{ 3.0, 0.0 }); // distance 3.0
    try index.insert(3, &[_]f32{ 2.0, 0.0 }); // distance 2.0
    try index.insert(4, &[_]f32{ 0.5, 0.0 }); // distance 0.5

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 4);
    defer index.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 4), results.len);
    // Should be sorted by distance ascending
    try std.testing.expectEqual(@as(u64, 4), results[0].id); // 0.5
    try std.testing.expectEqual(@as(u64, 1), results[1].id); // 1.0
    try std.testing.expectEqual(@as(u64, 3), results[2].id); // 2.0
    try std.testing.expectEqual(@as(u64, 2), results[3].id); // 3.0
}

test "Hnsw knnSearch k greater than count" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 10);
    defer index.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "Hnsw Config m0 returns u32" {
    const config = Config{ .m = 16 };
    try std.testing.expectEqual(@as(u32, 32), config.m0());
}

test "Hnsw Config m0 no overflow for large m" {
    const config = Config{ .m = 32000 };
    try std.testing.expectEqual(@as(u32, 64000), config.m0());
}

test "Hnsw batchInsert" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .m = 4 });
    defer index.deinit();

    const ids = [_]u64{ 10, 20, 30, 40, 50 };
    const v0 = [_]f32{ 0.0, 0.0 };
    const v1 = [_]f32{ 1.0, 0.0 };
    const v2 = [_]f32{ 0.0, 1.0 };
    const v3 = [_]f32{ 1.0, 1.0 };
    const v4 = [_]f32{ 0.5, 0.5 };
    const vectors = [_][]const f32{ &v0, &v1, &v2, &v3, &v4 };

    try index.batchInsert(&ids, &vectors);
    try std.testing.expectEqual(@as(u32, 5), index.count());

    // Search should still work after batch insert
    const results = try index.knnSearch(&[_]f32{ 0.0, 0.0 }, 1);
    defer index.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 10), results[0].id);
}

test "Hnsw randomLevel stays in bounds" {
    var index = try Hnsw.init(std.testing.allocator, 2, .euclidean, .{ .max_layers = 4 });
    defer index.deinit();

    // Generate many levels and verify they're all within bounds
    for (0..1000) |_| {
        const level = index.randomLevel();
        try std.testing.expect(level < 4);
    }
}
