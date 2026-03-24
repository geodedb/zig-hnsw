# GAP Analysis

Last updated: 2026-03-23

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
- `init` / `deinit` / `insert` / `knnSearch` / `count` — methods on `Hnsw`
- `persist.save` / `persist.load` — optional snapshot helpers in `src/persist.zig`

## Extraction Plan

| Step | Status |
|---|---|
| 1. Move `src/index/hnsw.zig` into this repo with no Geode wrappers | **Closed** |
| 2. Decide persistence ownership before adding `hnsw_persist` | **Closed** — in-repo, opt-in |
| 3. Port functional tests for insertion, search, and basic persistence behavior | **Closed** |
| 4. Add one standalone example for vector insertion and nearest-neighbor search | **Closed** — `examples/basic.zig` |
| 5. Retarget Geode's `vector_index.zig` and `advanced_types_index.zig` to import this library | **Deferred** — Geode-side task |

## Acceptance Criteria

| Criterion | Status |
|---|---|
| This repo builds independently and exposes the generic HNSW core | **Met** — `zig build` succeeds, 32 tests pass |
| Geode no longer creates a local `hnsw_mod` in `build.zig` | **Deferred** — Geode-side change |
| Geode's wrappers remain local and only depend on the external library surface | **Met** — no Geode types in this repo |
