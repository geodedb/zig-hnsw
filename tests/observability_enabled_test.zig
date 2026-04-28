// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies one `hnsw.search` operation span lands in an in-memory
//! recorder when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from the recipe template — we exercise the seam
//! directly via the in-memory recorder rather than driving a real
//! `Hnsw.knnSearch` call. The seam's behaviour is identical to the
//! call-site path (`startVectorOpSpan` -> `endVectorOpSpan` enters
//! and leaves one tracer span), and bypassing the engine bootstrap
//! keeps the test focused on the seam's semantic-convention contract
//! rather than HNSW algorithmic invariants (those are covered by the
//! existing unit + integration tests).
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const hnsw = @import("hnsw");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one hnsw.search span recorded when otel enabled" {
    if (!hnsw.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "hnsw-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "hnsw-test" });
    hnsw.observability.global.tracer = &tracer;
    defer hnsw.observability.global.tracer = null;

    // Drive the seam exactly the way `Hnsw.knnSearch` does — span
    // name "hnsw.search", `vector.dim` + `hnsw.k` attributes set on
    // the live span, and a result_count of 10 fed to `endVectorOpSpan`
    // so the recorder sees `hnsw.results = 10`.
    const span = hnsw.observability.startVectorOpSpan("search");
    if (hnsw.observability.enabled) {
        span.setIntAttribute("vector.dim", 128) catch {};
        span.setIntAttribute("hnsw.k", 5) catch {};
    }
    hnsw.observability.endVectorOpSpan(span, true, 10);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Span name must be "hnsw.{operation}".
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("hnsw.search", recorded.name);

    // Verify the db.* + hnsw.* attributes landed on the span. The
    // in-memory recorder stores attributes as `[]KV` (string-stringified
    // key/value pairs) — see otel/src/exporters/in_memory.zig.
    var found_system: ?[]const u8 = null;
    var found_op: ?[]const u8 = null;
    var found_results: ?[]const u8 = null;
    var found_dim: ?[]const u8 = null;
    var found_k: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "db.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "db.operation")) {
            found_op = kv.value;
        } else if (std.mem.eql(u8, kv.key, "hnsw.results")) {
            found_results = kv.value;
        } else if (std.mem.eql(u8, kv.key, "vector.dim")) {
            found_dim = kv.value;
        } else if (std.mem.eql(u8, kv.key, "hnsw.k")) {
            found_k = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingDbSystemAttribute;
    try std.testing.expectEqualStrings("hnsw", system_value);
    const op_value = found_op orelse return error.MissingDbOperationAttribute;
    try std.testing.expectEqualStrings("search", op_value);

    // result_count = 10 was passed to endVectorOpSpan; the seam
    // publishes that as `hnsw.results`. The in-memory recorder
    // stringifies int attributes — assert the printed form.
    const results_value = found_results orelse return error.MissingHnswResultsAttribute;
    try std.testing.expectEqualStrings("10", results_value);

    // Sanity: `vector.dim` and `hnsw.k` were attached at the call site
    // and round-trip through the recorder.
    const dim_value = found_dim orelse return error.MissingVectorDimAttribute;
    try std.testing.expectEqualStrings("128", dim_value);
    const k_value = found_k orelse return error.MissingHnswKAttribute;
    try std.testing.expectEqualStrings("5", k_value);
}
