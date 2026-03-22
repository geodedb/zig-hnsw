# GAP Analysis

Last updated: 2026-03-21

Repository status: bootstrapped from `../zig-template`; no Geode code has been moved yet.

## Goal

Extract Geode’s reusable HNSW approximate nearest-neighbor index into a standalone Zig library.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here |
|---|---|
| `src/index/hnsw.zig:7` | Shared `DistanceMetric` enumeration |
| `src/index/hnsw.zig:16` | Node representation |
| `src/index/hnsw.zig:54` and `src/index/hnsw.zig:65` | Core `Hnsw` type and initialization |
| `src/index/hnsw.zig:236` | Generic insertion path |
| `src/index/hnsw.zig:499` | Generic `knnSearch` behavior |
| `src/index/hnsw_persist.zig:25` and `src/index/hnsw_persist.zig:78` | Optional snapshot save/load support if persistence belongs in-repo |

Keep in Geode:

| Geode source | Why it stays |
|---|---|
| `src/index/vector_index.zig:8`, `src/index/vector_index.zig:25`, `src/index/vector_index.zig:48`, `src/index/vector_index.zig:64` | Geode-specific typed wrapper over the generic HNSW core |
| `src/index/advanced_types_index.zig:452`, `src/index/advanced_types_index.zig:464`, `src/index/advanced_types_index.zig:479` | Advanced-types bridge layer |
| `src/index/index_manager.zig:736` and `src/index/index_manager.zig:756` | Geode index-manager integration |

## Concrete Gaps

| Gap | Evidence | Impact | Required fix |
|---|---|---|---|
| Persistence boundary is still undecided | `src/index/hnsw_persist.zig:25`, `src/index/hnsw_persist.zig:78` | Affects public API and dependency surface | Decide whether persistence lives here, in a sibling package, or as a Geode adapter |
| Build seam exists only inside Geode today | `build.zig:1129`, `build.zig:1133`, `build.zig:1136` | Extraction path is obvious but not completed | Repoint Geode to depend on this repo instead of local module creation |
| Adapter surface is mixed into higher-level indexes | `src/index/vector_index.zig`, `src/index/advanced_types_index.zig` | Easy to over-extract | Keep all product wrappers local |

## Tests And Benchmarks To Carry Over

| Geode test / benchmark | Coverage provided |
|---|---|
| `tests/integration/test_vector_index.zig:5`, `:34`, `:67`, `:94`, `:131`, `:170` | Core vector-index functional coverage |
| `tests/test_hnsw_index_optimizer_integration.zig:278`, `:319`, `:362`, `:394`, `:440`, `:497` | Planner/index integration references for parity checks |
| `tests/test_vector_documentation_integration.zig:9`, `:41`, `:71`, `:104`, `:138`, `:179` | User-facing vector workflows |
| `tests/integration/test_index_performance.zig:112` | Integration benchmark for vector index performance |
| `src/index/hnsw.zig:15` | CANARY benchmark reference to `benchmarks/phase3_benchmarks.zig` |

## Proposed Public API

Initial public surface should include:

- `DistanceMetric`
- `Hnsw`
- `init`
- `insert`
- `knnSearch`
- optional snapshot helpers if persistence lands in the library

## Extraction Plan

1. Move `src/index/hnsw.zig` into this repo with no Geode wrappers.
2. Decide persistence ownership before adding `hnsw_persist`.
3. Port functional tests for insertion, search, and basic persistence behavior.
4. Add one standalone example for vector insertion and nearest-neighbor search.
5. Retarget Geode’s `vector_index.zig` and `advanced_types_index.zig` to import this library.

## Acceptance Criteria

- This repo builds independently and exposes the generic HNSW core.
- Geode no longer creates a local `hnsw_mod` in `build.zig`.
- Geode’s wrappers remain local and only depend on the external library surface.
