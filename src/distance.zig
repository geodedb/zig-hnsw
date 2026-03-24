// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Distance metrics for vector similarity computation.
//!
//! Supports Euclidean, Cosine, Dot Product, and Manhattan distances.
//! All metrics return non-negative values where lower means more similar
//! (dot product is negated to maintain this convention).

const std = @import("std");

/// Supported distance metrics for nearest-neighbor search.
pub const DistanceMetric = enum(u8) {
    /// L2 (Euclidean) distance: sqrt(sum((a_i - b_i)^2)).
    euclidean = 0,
    /// Cosine distance: 1 - cos(a, b). Range [0, 2].
    cosine = 1,
    /// Negative dot product. Lower values indicate higher similarity.
    dot_product = 2,
    /// L1 (Manhattan) distance: sum(|a_i - b_i|).
    manhattan = 3,
};

/// Compute the distance between two vectors using the given metric.
///
/// Both vectors must have the same length. Asserted in debug builds.
pub fn compute(metric: DistanceMetric, a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    return switch (metric) {
        .euclidean => euclidean(a, b),
        .cosine => cosine(a, b),
        .dot_product => dotProduct(a, b),
        .manhattan => manhattan(a, b),
    };
}

fn euclidean(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |av, bv| {
        const d = av - bv;
        sum += d * d;
    }
    return @sqrt(sum);
}

fn cosine(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (a, b) |av, bv| {
        dot += av * bv;
        na += av * av;
        nb += bv * bv;
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom == 0) return 1.0;
    return 1.0 - dot / denom;
}

fn dotProduct(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    for (a, b) |av, bv| {
        dot += av * bv;
    }
    return -dot;
}

fn manhattan(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |av, bv| {
        sum += @abs(av - bv);
    }
    return sum;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "euclidean distance" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const d = compute(.euclidean, &a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(@as(f32, 2.0))), d, 1e-6);
}

test "euclidean distance identical vectors" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const d = compute(.euclidean, &a, &a);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d, 1e-6);
}

test "cosine distance orthogonal vectors" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0 };
    const d = compute(.cosine, &a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d, 1e-6);
}

test "cosine distance identical direction" {
    const a = [_]f32{ 1.0, 1.0 };
    const b = [_]f32{ 2.0, 2.0 };
    const d = compute(.cosine, &a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d, 1e-6);
}

test "cosine distance zero vector" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 1.0, 1.0 };
    const d = compute(.cosine, &a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d, 1e-6);
}

test "dot product distance" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const d = compute(.dot_product, &a, &b);
    // dot = 1*4 + 2*5 + 3*6 = 32, negated = -32
    try std.testing.expectApproxEqAbs(@as(f32, -32.0), d, 1e-6);
}

test "manhattan distance" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 6.0, 3.0 };
    const d = compute(.manhattan, &a, &b);
    // |1-4| + |2-6| + |3-3| = 3 + 4 + 0 = 7
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), d, 1e-6);
}

test "DistanceMetric enum backing values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DistanceMetric.euclidean));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(DistanceMetric.cosine));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(DistanceMetric.dot_product));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(DistanceMetric.manhattan));
}
