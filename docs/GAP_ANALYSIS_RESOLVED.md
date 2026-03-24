# GAP Analysis — Resolved Items

Items closed during gap-close on 2026-03-23.

## Functional Requirements

| ID | Requirement | Resolution |
|---|---|---|
| HNSW-REQ-001 | Expose `DistanceMetric` enumeration | `src/distance.zig:DistanceMetric` — Euclidean, Cosine, DotProduct, Manhattan |
| HNSW-REQ-002 | Expose generic `Hnsw` index type | `src/hnsw.zig:Hnsw` with allocator-backed `init`/`deinit` |
| HNSW-REQ-003 | Support insertion of vectors | `Hnsw.insert(id, vector)` copies vector and builds graph layers |
| HNSW-REQ-004 | Support k-nearest-neighbor search | `Hnsw.knnSearch(query, k)` returns sorted `[]SearchResult` |
| HNSW-REQ-005 | No dependency on Geode types | Zero Geode imports; no planner, index-manager, or wrapper types |

## Packaging Requirements

| ID | Requirement | Resolution |
|---|---|---|
| HNSW-PKG-002 | Persistence explicitly optional | `src/persist.zig` is a separate module; users import it only if needed |
| HNSW-PKG-003 | Adapter logic stays outside this repo | No adapter types present |

## Test Requirements

| ID | Requirement | Resolution |
|---|---|---|
| HNSW-TEST-001 | Port vector insertion/search coverage | 8 unit tests + 5 integration tests for insert/search |
| HNSW-TEST-002 | Preserve user-facing workflow coverage | Integration tests across all 4 distance metrics + working example |
| HNSW-TEST-003 | Preserve performance baseline references | Recall quality test against brute-force baseline (80%+ threshold) |

## Documentation Requirements

| Requirement | Resolution |
|---|---|
| Minimal vector-search example | `examples/basic.zig` — buildable with `zig build example` |
| Document supported distance metrics | README table + doc comments in `src/distance.zig` |
| Document persistence scope | README persistence section + `src/persist.zig` doc comments |

## Concrete Gaps Resolved

| Gap | Resolution |
|---|---|
| Persistence boundary undecided | Persistence lives in-repo as `src/persist.zig`, opt-in by import |
| Adapter surface mixed into indexes | No adapter types extracted; all Geode wrappers stay in Geode |

## Deferred Items

| Item | Reason |
|---|---|
| HNSW-PKG-001: Geode consumes this repo | Geode-side `build.zig` change; blocked on Geode team |
| Extraction Plan step 5: Retarget Geode imports | Same as above |
