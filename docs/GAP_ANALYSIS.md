# GAP Analysis

Last updated: 2026-03-30 (spice parallelism integration)

Repository status: **core HNSW library implemented** with distance metrics, insertion, k-NN search, optional persistence, and comprehensive tests.

## Goal

Extract Geode's reusable HNSW approximate nearest-neighbor index into a standalone Zig library.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here | Status |
|---|---|---|
| `src/index/hnsw.zig:7` | Shared `DistanceMetric` enumeration | **Closed** — `src/distance.zig` |
| `src/index/hnsw.zig:16` | Node representation | **Closed** — `src/hnsw.zig:Node` |
| `src/index/hnsw.zig:54` and `src/index/hnsw.zig:65` | Core `Hnsw` type and initialization | **Closed** — `src/hnsw.zig:Hnsw` |
| `src/index/hnsw.zig:236` | Generic insertion path | **Closed** — `Hnsw.insert()` |
| `src/index/hnsw.zig:499` | Generic `knnSearch` behavior | **Closed** — `Hnsw.knnSearch()` |
| `src/index/hnsw_persist.zig:25` and `src/index/hnsw_persist.zig:78` | Optional snapshot save/load support if persistence belongs in-repo | **Closed** — `src/persist.zig` (opt-in module) |

Keep in Geode:

| Geode source | Why it stays | Status |
|---|---|---|
| `src/index/vector_index.zig:8`, `src/index/vector_index.zig:25`, `src/index/vector_index.zig:48`, `src/index/vector_index.zig:64` | Geode-specific typed wrapper over the generic HNSW core | **Closed** — not present in this repo |
| `src/index/advanced_types_index.zig:452`, `src/index/advanced_types_index.zig:464`, `src/index/advanced_types_index.zig:479` | Advanced-types bridge layer | **Closed** — not present in this repo |
| `src/index/index_manager.zig:736` and `src/index/index_manager.zig:756` | Geode index-manager integration | **Closed** — not present in this repo |

## Concrete Gaps

| Gap | Evidence | Impact | Required fix | Status |
|---|---|---|---|---|
| Persistence boundary is still undecided | `src/index/hnsw_persist.zig:25`, `src/index/hnsw_persist.zig:78` | Affects public API and dependency surface | Decide whether persistence lives here, in a sibling package, or as a Geode adapter | **Closed** — persistence lives in this repo as `src/persist.zig`, explicitly opt-in per HNSW-PKG-002 |
| Build seam exists only inside Geode today | `build.zig:1129`, `build.zig:1133`, `build.zig:1136` | Extraction path is obvious but not completed | Repoint Geode to depend on this repo instead of local module creation | **Deferred** — this repo builds independently; Geode repointing is a Geode-side task (HNSW-PKG-001) |
| Adapter surface is mixed into higher-level indexes | `src/index/vector_index.zig`, `src/index/advanced_types_index.zig` | Easy to over-extract | Keep all product wrappers local | **Closed** — no Geode adapter types exist in this repo |
| Fuzz target missing `hnsw_lib` module dependency | Geode's `fuzz/targets/hnsw_snapshot_fuzz.zig` build step provides `-Mhnsw=src/index/hnsw.zig` but does NOT supply the `hnsw_lib` module that Geode's `src/index/hnsw.zig:2` imports (`const hnsw_lib = @import("hnsw_lib")`). The standalone library lives at `~/src/gl/devnw/zig/hnsw` (separate repo, NOT a sibling of Geode) | Fuzz target fails to compile: `error: no module named 'hnsw_lib' available within module 'hnsw'`. Blocks 1/68 `test-e2e` build steps (all 64/64 actual test cases pass unaffected) | Add `hnsw_lib` as a module dependency in Geode's fuzz target build step pointing to `~/src/gl/devnw/zig/hnsw`, or complete Step 5 (repoint Geode to this library as a proper package dependency) so the module is resolved through the package system | **Blocked** — Geode-side task; unblock by either: (1) adding `hnsw_lib` module dep in Geode's fuzz build step, or (2) completing Extraction Plan Step 5 to consume this repo as a Zig package |

## Parallelism & Concurrency Gaps

Last updated: 2026-03-30 (spice integration pass)

The HNSW index now uses the `spice` heartbeat-scheduling library for parallel distance computations, `std.Thread.Mutex` for PRNG safety, and `std.Thread.RwLock` for concurrent read/write access.

### Current State

- **`spice` dependency**: declared in `build.zig.zon` as a path dependency (`../spice`), wired into all build targets
- **Thread pool**: heap-allocated `*spice.ThreadPool` on `Hnsw` struct, started at `init`, stopped at `deinit`
- **RwLock**: `insert` acquires exclusive write lock; `knnSearch` acquires shared read lock
- **Mutex-protected PRNG**: `randomLevel()` is guarded by `prng_mutex`
- **Parallel distance computation**: `searchLayer` batches unvisited neighbors, computes distances via spice fork/join (recursive divide-and-conquer) for batches > 32
- **Batch insert API**: `batchInsert(ids, vectors)` takes write lock once, inserts sequentially with spice-parallelized `searchLayer`

### Parallelism Gaps

| ID | Gap | Evidence | Impact | Required fix | Status |
|---|---|---|---|---|---|
| PAR-001 | `spice` dependency not declared | `build.zig.zon` | Cannot use `spice` fork/join anywhere | Add `spice` as a Zig package dependency | **Closed** — `build.zig.zon` declares `spice` path dep; `build.zig` wires module into all targets |
| PAR-002 | No parallel kNN search at layer 0 | `src/hnsw.zig` `searchLayer` | Search throughput limited to single core | Parallelize distance computations with spice fork/join | **Closed** — `searchLayer` refactored into 3 phases: collect unvisited, batch compute distances via `computeDistancesBatch` (spice fork/join), update heaps |
| PAR-003 | No parallel batch insert API | `src/hnsw.zig` `insert()` | Users must insert vectors sequentially | Add `batchInsert` method | **Closed** — `batchInsert(ids, vectors)` added; takes write lock once, each insert uses spice-parallelized `searchLayer` |
| PAR-004 | PRNG prevents concurrent insert | `src/hnsw.zig` `prng` field | Data race on `self.prng` | Protect PRNG with mutex | **Closed** — `prng_mutex: std.Thread.Mutex` guards `randomLevel()`; also resolves PERF-008 |
| PAR-005 | No concurrent read/write support | `src/hnsw.zig` | Concurrent `insert` + `knnSearch` is UB | Add RwLock | **Closed** — `rw_lock: std.Thread.RwLock`; `insert`/`batchInsert` take exclusive lock, `knnSearch` takes shared lock |
| PAR-006 | Distance computations are scalar and sequential | `src/distance.zig` | No parallelism across multiple candidates | Batch via spice fork/join | **Closed** — `computeDistancesBatch` uses spice recursive fork/join for batches > 32; SIMD vectorization (PERF-001) remains deferred |
| PAR-007 | Persistence I/O is synchronous | `src/persist.zig` | Save/load blocks calling thread | Async I/O or background save | **Deferred** — blocking I/O is acceptable for v0.1.0; async persistence deferred to v0.2.0+ |
| PAR-008 | `searchLayer` visited set is not thread-safe | `src/hnsw.zig` `AutoHashMap` | Shared data structure under parallelism | Thread-safe visited set | **Closed** — visited set stays single-threaded; only the main thread modifies it. Forked spice workers compute pure distance values with no shared mutable state |

### Architecture Notes

`spice` uses heartbeat scheduling — a cooperative fork/join model where:
- Every parallel function takes a `*spice.Task` parameter
- `fork()` signals work that *can* run on another thread
- `join()` either collects the parallel result or falls back to sequential execution
- Overhead is sub-nanosecond when parallelism isn't triggered (heartbeat fires every ~100μs)

Implementation approach in this library:
- **`searchLayer`**: refactored into collect/compute/update phases. The compute phase calls `computeDistancesBatch` which recursively splits work, forking the right half and computing the left. Falls back to sequential for batches <= 32 elements
- **`batchInsert`**: single write lock for entire batch; parallelism comes from spice-enabled `searchLayer` within each insertion
- **`greedyClosest`**: remains sequential — each step depends on the previous best (inherently serial)
- **`ThreadPool`**: heap-allocated to avoid pointer invalidation when `Hnsw` struct moves on the stack

## Tests And Benchmarks To Carry Over

| Geode test / benchmark | Coverage provided | Status |
|---|---|---|
| `tests/integration/test_vector_index.zig:5`, `:34`, `:67`, `:94`, `:131`, `:170` | Core vector-index functional coverage | **Closed** — `tests/integration.zig` covers insert/search for all 4 metrics |
| `tests/test_hnsw_index_optimizer_integration.zig:278`, `:319`, `:362`, `:394`, `:440`, `:497` | Planner/index integration references for parity checks | **N/A** — planner is Geode-specific (HNSW-REQ-005) |
| `tests/test_vector_documentation_integration.zig:9`, `:41`, `:71`, `:104`, `:138`, `:179` | User-facing vector workflows | **Closed** — `examples/basic.zig` + integration tests |
| `tests/integration/test_index_performance.zig:112` | Integration benchmark for vector index performance | **Closed** — recall quality test against brute-force baseline |
| `src/index/hnsw.zig:15` | CANARY benchmark reference to `benchmarks/phase3_benchmarks.zig` | **N/A** — Geode-specific benchmark |

## Proposed Public API

Initial public surface (all implemented):

- `DistanceMetric` — `src/distance.zig`
- `Hnsw` — `src/hnsw.zig`
- `Config` — `src/hnsw.zig`
- `SearchResult` — `src/hnsw.zig`
- `Node` — `src/hnsw.zig`
- `init` / `deinit` / `insert` / `batchInsert` / `knnSearch` / `count` — methods on `Hnsw`
- `persist.save` / `persist.load` — optional snapshot helpers in `src/persist.zig`

## Extraction Plan

| Step | Status |
|---|---|
| 1. Move `src/index/hnsw.zig` into this repo with no Geode wrappers | **Closed** |
| 2. Decide persistence ownership before adding `hnsw_persist` | **Closed** — in-repo, opt-in |
| 3. Port functional tests for insertion, search, and basic persistence behavior | **Closed** |
| 4. Add one standalone example for vector insertion and nearest-neighbor search | **Closed** — `examples/basic.zig` |
| 5. Retarget Geode's `vector_index.zig` and `advanced_types_index.zig` to import this library | **Deferred** — Geode-side task (blocks fuzz target compilation; see "Fuzz target missing `hnsw_lib` module dependency" gap above) |

## Acceptance Criteria

| Criterion | Status |
|---|---|
| This repo builds independently and exposes the generic HNSW core | **Met** — `zig build` succeeds, 32 tests pass |
| Geode no longer creates a local `hnsw_mod` in `build.zig` | **Deferred** — Geode-side change |
| Geode's wrappers remain local and only depend on the external library surface | **Met** — no Geode types in this repo |
