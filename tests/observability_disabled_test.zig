// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies the no-op invariant when `-Dwith_otel=false` (the default).
//!
//! hnsw publishes its public surface as the "hnsw" module rooted at
//! src/root.zig. The seam is exposed as `hnsw.observability` so this
//! test can drive the disabled-mode invariants through the public root.
//!
//! Each test is skip-guarded so the file compiles & runs cleanly under
//! BOTH flag values: the disabled-mode invariants only fire when the
//! flag is off; under `-Dwith_otel=true` every test in this file
//! returns `error.SkipZigTest` and the enabled-mode test file picks up
//! the live invariants instead.

const std = @import("std");
const hnsw = @import("hnsw");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    // The "default" assertion only holds for the disabled build. When
    // the operator forces `-Dwith_otel=true`, this test runs against
    // the enabled module and must skip rather than misreport the
    // default.
    if (build_options.with_otel) return error.SkipZigTest;
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, hnsw.observability.enabled);
}

test "client/server seams are no-ops when otel disabled" {
    if (hnsw.observability.enabled) return error.SkipZigTest;
    var span = hnsw.observability.startClientSpan(.{
        .method = "GET",
        .url = "https://example.test/",
    });
    hnsw.observability.endClientSpan(span, 200);
    // Belt-and-suspenders: the seam's `endClientSpan` already covers
    // the lifecycle; this line just verifies the no-op fallback's
    // signature matches the real API's `Span.end(?u64) void`.
    span.end(null);

    var sspan = hnsw.observability.startServerSpan(.{
        .method = "GET",
        .route = "/",
        .url = "/",
    });
    hnsw.observability.endServerSpan(sspan, 200);
    sspan.end(null);
}

test "vector-op span helper is a no-op when otel disabled" {
    if (hnsw.observability.enabled) return error.SkipZigTest;

    // Cover each shape the seam wrapper will see at call sites:
    // insert (count=0 -> hnsw.results suppressed in enabled mode),
    // search (count>0 -> hnsw.results published in enabled mode),
    // delete (count=0), and the optional bulk-build path.
    var ins_span = hnsw.observability.startVectorOpSpan("insert");
    hnsw.observability.endVectorOpSpan(ins_span, true, 0);
    ins_span.end(null);

    var srch_span = hnsw.observability.startVectorOpSpan("search");
    hnsw.observability.endVectorOpSpan(srch_span, true, 10);
    srch_span.end(null);

    var del_span = hnsw.observability.startVectorOpSpan("delete");
    hnsw.observability.endVectorOpSpan(del_span, false, 0);
    del_span.end(null);

    var build_span = hnsw.observability.startVectorOpSpan("build");
    hnsw.observability.endVectorOpSpan(build_span, true, 0);
    build_span.end(null);
}

test "Span is zero-sized when otel disabled" {
    if (hnsw.observability.enabled) return error.SkipZigTest;
    // The whole point of the no-op fallback is that the optimizer
    // can drop the call sites. The strongest guarantee we can assert
    // at test time is that the `Span` type itself carries no payload.
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(hnsw.observability.Span));
}
