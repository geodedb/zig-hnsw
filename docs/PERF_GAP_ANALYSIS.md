# Performance Gap Analysis

Last updated: 2026-03-23

## Findings

| # | ID | Finding | PerfSev | Speedup | File:Line | Status |
|---|-----|---------|---------|---------|-----------|--------|
| 1 | PERF-001 | Scalar distance loops without SIMD | P0 | 2-8x | `src/distance.zig:37-73` | **Deferred** — architectural optimization for v0.2.0 |
| 2 | PERF-002 | Pointer-chasing node layout | P0 | 2-4x | `src/hnsw.zig:65-72` | **Deferred** — requires SoA refactoring for v0.2.0 |
| 3 | PERF-003 | shrinkConnections: selection sort + no heuristic pruning | P0 | 2-5x insert | `src/hnsw.zig:369-395` | **Deferred** — Algorithm 4 implementation for v0.2.0 |
| 4 | PERF-004 | Unnecessary sqrt in euclidean | P1 | 15-20% | `src/distance.zig:43` | **Deferred** — API change (squared distances) for v0.2.0 |
| 5 | PERF-005 | Cosine recomputes query norm | P1 | 10-15% | `src/distance.zig:46-57` | **Deferred** — requires pre-normalization strategy for v0.2.0 |
| 6 | PERF-006 | AutoHashMap for visited set | P1 | 20-40% | `src/hnsw.zig:312` | **Deferred** — bitset replacement for v0.2.0 |
| 7 | PERF-007 | No benchmark suite | P1 | N/A | CI/Makefile | **Deferred** — benchmark harness for v0.2.0 |
| 8 | PERF-008 | PRNG on struct prevents concurrency | P1 | N/A | `src/hnsw.zig:91` | **Deferred** — architectural; documented as single-threaded |
| 9 | PERF-009 | Per-operation ArenaAllocator | P2 | 5-15% | `src/hnsw.zig:163,239` | **Deferred** — reusable arena for v0.2.0 |
| 10 | PERF-010 | PriorityQueue heaps not pre-allocated | P2 | 5-10% | `src/hnsw.zig:313-314` | **Closed** — `ensureTotalCapacity(ef)` added |
| 11 | PERF-011 | Persistence per-element I/O | P2 | 2-5x I/O | `src/persist.zig:56-63` | **Deferred** — bulk I/O for v0.2.0 |
| 12 | PERF-012 | No prefetching of neighbor vectors | P2 | 10-30% | `src/hnsw.zig:331-347` | **Deferred** — depends on SoA layout (PERF-002) |
| 13 | PERF-013 | No bulk insert API | P2 | 10-20% | `src/hnsw.zig:132` | **Deferred** — API addition for v0.2.0 |
| 14 | PERF-014 | Connection lists use separate allocations | P2 | moderate | `src/hnsw.zig:71` | **Deferred** — depends on SoA layout (PERF-002) |
| 15 | PERF-015 | Tests only use tiny datasets | P2 | N/A | `tests/` | **Deferred** — requires benchmark harness (PERF-007) |
| 16 | PERF-016 | No ReleaseFast CI test | P3 | N/A | `.gitlab-ci.yml` | **Deferred** — CI change |

## Summary

| PerfSeverity | Total | Closed | Deferred |
|-------------|-------|--------|----------|
| P0 | 3 | 0 | 3 |
| P1 | 5 | 0 | 5 |
| P2 | 7 | 1 | 6 |
| P3 | 1 | 0 | 1 |
| **Total** | **16** | **1** | **15** |

All P0-P1 items are architectural optimizations appropriate for v0.2.0, not v0.1.0 correctness release. The single closed item (PERF-010) was a low-effort fix applied during the security hardening pass.
