# Requirements

Last updated: 2026-03-21

## Functional Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| HNSW-REQ-001 | The library SHALL expose a reusable `DistanceMetric` enumeration. | `src/index/hnsw.zig:7` |
| HNSW-REQ-002 | The library SHALL expose a generic `Hnsw` index type with allocator-backed lifecycle. | `src/index/hnsw.zig:54`, `src/index/hnsw.zig:65` |
| HNSW-REQ-003 | The library SHALL support insertion of vectors/items into the index. | `src/index/hnsw.zig:236` |
| HNSW-REQ-004 | The library SHALL support `k`-nearest-neighbor search. | `src/index/hnsw.zig:499` |
| HNSW-REQ-005 | The library SHALL NOT depend on Geode planner or index-manager types. | `src/index/index_manager.zig:736`, `src/index/index_manager.zig:756` stay in Geode |

## Packaging Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| HNSW-PKG-001 | Geode SHALL stop creating a local internal `hnsw_mod` and consume this repo instead. | `build.zig:1129`, `build.zig:1133`, `build.zig:1136` |
| HNSW-PKG-002 | Persistence support SHALL be explicitly optional if retained. | `src/index/hnsw_persist.zig:25`, `src/index/hnsw_persist.zig:78` |
| HNSW-PKG-003 | Adapter logic for Geode vector and advanced-type indexes SHALL remain outside this repo. | `src/index/vector_index.zig:25`, `src/index/advanced_types_index.zig:464` |

## Test Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| HNSW-TEST-001 | Port vector insertion/search coverage. | `tests/integration/test_vector_index.zig:5`, `:34`, `:67`, `:94`, `:131`, `:170` |
| HNSW-TEST-002 | Preserve user-facing workflow coverage. | `tests/test_vector_documentation_integration.zig:9`, `:41`, `:71`, `:104`, `:138`, `:179` |
| HNSW-TEST-003 | Preserve performance baseline references. | `tests/integration/test_index_performance.zig:112`, `src/index/hnsw.zig:15` |

## Documentation Requirements

- Provide a minimal vector-search example.
- Document supported distance metrics and any dimensionality constraints.
- Document whether persistence is in-scope for this repo or provided separately.

## Migration Requirements

1. Replace Geode imports of local HNSW core with this repo.
2. Keep Geode’s typed wrappers and index-manager integration in the Geode tree.
3. Confirm test parity before removing the internal `build.zig` module seam.
