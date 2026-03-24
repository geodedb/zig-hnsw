// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # hnsw
//!
//! A standalone Zig library for Hierarchical Navigable Small World (HNSW)
//! approximate nearest-neighbor search.
//!
//! ## Features
//!
//! - Generic HNSW index with configurable distance metrics
//! - Euclidean, Cosine, Dot Product, and Manhattan distances
//! - Allocator-backed lifecycle with no hidden allocations
//! - Optional binary snapshot persistence
//!
//! ## Quick Start
//!
//! ```zig
//! const hnsw = @import("hnsw");
//!
//! var index = try hnsw.Hnsw.init(allocator, 128, .euclidean, .{});
//! defer index.deinit();
//!
//! try index.insert(1, &my_vector);
//! const results = try index.knnSearch(&query, 10);
//! defer allocator.free(results);
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version.
pub const version = "0.1.0";

// Core modules
pub const distance = @import("distance.zig");
pub const hnsw = @import("hnsw.zig");
pub const persist = @import("persist.zig");

// Top-level re-exports for convenience
pub const DistanceMetric = distance.DistanceMetric;
pub const Hnsw = hnsw.Hnsw;
pub const HnswError = hnsw.HnswError;
pub const Config = hnsw.Config;
pub const SearchResult = hnsw.SearchResult;

// ============================================================================
// Unit Tests — ensure all submodule tests are discovered
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}
