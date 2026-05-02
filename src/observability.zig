// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! observability.zig — single-file otel seam for hnsw.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` / `otel.instrumentation.http` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break a vector
//! insert / search / delete.
//!
//! NOTE: deviation from the recipe template — hnsw operations don't fit
//! the HTTP `instrumentation.http.startClientSpan` shape (HTTP method/url
//! is meaningless for an in-process vector index). We expose the generic
//! `startClientSpan` / `startServerSpan` helpers for symmetry with prior
//! consumers (and to keep the seam template-compatible), AND a
//! db-shaped `startVectorOpSpan(operation)` helper that constructs a
//! span via `otel.api.trace.Tracer.startSpan` directly with a
//! db-shaped span name (`"hnsw.{operation}"`) and the OpenTelemetry
//! `db.*` semantic conventions (`db.system="hnsw"`, `db.operation`).
//! `endVectorOpSpan` records `hnsw.results` for query-shaped operations
//! so search call sites can publish the returned count without a second
//! attribute helper.

const std = @import("std");
// 2026-05-02: hardcoded enabled=false and removed the build_options
// import + the conditional otel import. The previous pattern surfaced
// a Zig 0.16 module-dedup quirk when the lib was reached through
// multiple paths in a downstream build graph (geode), producing
// "build_options" vs "build_options0" diamonds at this file. The
// seam is preserved as a permanent no-op for forward-compat;
// restore the conditional once the upstream Zig dedup issue is
// resolved.
pub const enabled: bool = false;

const otel = struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Helper: reads either a `[]const u8` field OR a function-typed field
/// returning `[]const u8`, so the seam accepts both shapes — the closure
/// shape the recipe template ships AND the plain-string-field shape used
/// at hot-path call sites.
inline fn accessOr(req: anytype, comptime field: []const u8) []const u8 {
    const T = @TypeOf(@field(req, field));
    return switch (@typeInfo(T)) {
        .pointer => @field(req, field),
        .@"fn" => @field(req, field)(),
        else => @compileError("observability: unsupported field type for " ++ field),
    };
}

/// Start a span for a generic outbound operation. Kept for template
/// symmetry; hnsw hot paths use `startVectorOpSpan` instead.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for a generic inbound operation. Kept for template
/// symmetry; hnsw has no authoritative-server entry point.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .route = accessOr(req, "route"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Start a span for an hnsw vector-index operation.
///
/// Span shape:
///   - name: `"hnsw.{operation}"` (e.g. `"hnsw.insert"`,
///     `"hnsw.search"`, `"hnsw.delete"`, `"hnsw.build"`)
///   - kind: `.client` (the index acts as a client to its underlying
///     graph storage; the OpenTelemetry `db.*` semantic conventions
///     specify `client` for the calling side of a database interaction).
///   - attributes:
///       * `db.system = "hnsw"`
///       * `db.operation = operation`
///
/// `operation` MUST be a string literal or a slice whose lifetime
/// outlives the span. The SDK dupes the span name into the span arena,
/// but the `db.operation` attribute is stored by reference at the
/// stringified value layer; using a stable string keeps the recorder
/// safe from dangling slices.
///
/// NOTE: vector contents are NEVER attached as span attributes (they
/// can be large and may be sensitive). Vector *dimension* is safe and
/// is added at the call site via `setIntAttribute("vector.dim", N)`.
pub fn startVectorOpSpan(operation: []const u8) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    // Compose the span name on the stack; the SDK dupes the name into
    // the span arena, so a pointer to a stack buffer is safe here.
    var name_buf: [128]u8 = undefined;
    const span_name = std.fmt.bufPrint(
        name_buf[0..],
        "hnsw.{s}",
        .{operation},
    ) catch "hnsw";
    const span = tracer.startSpan(.empty(), span_name, .{ .kind = .client }) catch return Span{};
    // Best-effort attribute attachment. Failures (OOM in the attribute
    // set) cannot block the vector operation — telemetry is non-fatal.
    span.setStringAttribute("db.system", "hnsw") catch {};
    span.setStringAttribute("db.operation", operation) catch {};
    return span;
}

/// Close a vector-op span, recording success/failure and an optional
/// result count.
///
/// On `ok = true` we set status `.ok` and (when `result_count > 0`)
/// publish the count under `hnsw.results` — useful for search-shaped
/// operations whose return slice length is the natural result-cardinality
/// signal. On `ok = false` we set status `.@"error"`; result_count is
/// ignored in that branch (the call site already knows the operation
/// failed). The span is then ended.
///
/// Callers typically pair this with `defer span.end(null)` at the call
/// site so the span is always ended regardless of which path is taken.
/// `setStatus` + `end` are idempotent for status reporting (only the
/// first status write wins; the deferred `end(null)` is a redundant
/// no-op).
pub fn endVectorOpSpan(span: Span, ok: bool, result_count: usize) void {
    if (!enabled) return;
    if (ok) {
        // Only emit `hnsw.results` when the call site actually has a
        // count to publish. `0` is ambiguous (empty-result vs.
        // not-applicable for insert/delete), so we suppress it.
        if (result_count > 0) {
            // setIntAttribute takes i64; usize fits in i64 for any
            // reasonable result-set size.
            span.setIntAttribute("hnsw.results", @intCast(result_count)) catch {};
        }
        span.setStatus(.ok, "");
    } else {
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig.
        span.setStatus(.@"error", "");
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
