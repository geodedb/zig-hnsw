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

## Security Gaps Resolved (gap-close 2026-03-25)

| ID | Finding | Resolution |
|---|---|---|
| SEC-011 | CI does not test ReleaseFast/ReleaseSmall | CI pipeline now includes `test-release-fast`, `test-release-small`, `test-integration-release-safe`, and `test-integration-release-fast` jobs |
| SEC-013 | No gitleaks pre-commit hook | Added `gitleaks/gitleaks` v8.24.0 pre-commit hook for defense-in-depth alongside CI gitleaks scanning |

## Performance Gaps Resolved (gap-close 2026-03-25)

| ID | Finding | Resolution |
|---|---|---|
| PERF-016 | No ReleaseFast CI test | CI pipeline now includes ReleaseFast, ReleaseSmall, and ReleaseSafe test jobs for both unit and integration tests |

## Deferred Items

| Item | Reason |
|---|---|
| HNSW-PKG-001: Geode consumes this repo | Geode-side `build.zig` change; blocked on Geode team |
| Extraction Plan step 5: Retarget Geode imports | Same as above |

## Blocked Items

| Item | Reason | Unblock Steps |
|---|---|---|
| Fuzz target missing `hnsw_lib` module dependency | Geode-side task; this repo has no control over Geode's build.zig | (1) Add `hnsw_lib` module dep in Geode's fuzz build step, or (2) Complete Extraction Plan Step 5 to consume this repo as a Zig package |
