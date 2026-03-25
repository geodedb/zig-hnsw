# Quality Gap Analysis

Last updated: 2026-03-25

## Findings

| # | ID | Finding | Severity | Score | File:Line | Status |
|---|-----|---------|----------|-------|-----------|--------|
| 1 | Q-001 | `insert()` leaks vec/conns on allocation failure | Critical | 90 | `src/hnsw.zig:138-154` | **Closed** — errdefer guards via scoped block |
| 2 | Q-002 | `insert()` partial graph mutation has no rollback | Critical | 80 | `src/hnsw.zig:193-205` | **Closed** — documented as expected; deinit cleans up |
| 3 | Q-003 | `Node` publicly exported with internal types | High | 70 | `src/root.zig:48` | **Closed** — removed from public re-exports |
| 4 | Q-004 | Duplicated Node cleanup pattern (DRY) | High | 70 | `src/hnsw.zig`, `src/persist.zig` | **Closed** — `Node.deinit()` method; used in both |
| 5 | Q-005 | `debug.assert` for dim validation stripped in release | High | 70 | `src/hnsw.zig` | **Closed** — `HnswError` returns (= SEC-004) |
| 6 | Q-006 | `Config.m=0` causes degenerate index | High | 70 | `src/hnsw.zig:107` | **Closed** — `Config.validate()` rejects m < 2, etc. |
| 7 | Q-007 | `knnSearch` ownership contract implicit | Medium | 60 | `src/hnsw.zig:232` | **Closed** — doc comments document allocator ownership |
| 8 | Q-008 | `unreachable` in `searchLayer` could trap | Medium | 60 | `src/hnsw.zig:336` | **Closed** — replaced with `orelse continue` |
| 9 | Q-009 | No negative tests for persist load error paths | Medium | 60 | `src/persist.zig` | **Closed** — 7 new error-path tests |
| 10 | Q-010 | Broken links in docs/README.md | Medium | 60 | `docs/README.md` | **Closed** — replaced with actual doc links |
| 11 | Q-011 | No duplicate-ID detection on insert() | Medium | 50 | `src/hnsw.zig:132` | **Won't Do** — duplicate IDs allowed by design |
| 12 | Q-012 | Persistence format has no standalone spec | Medium | 50 | `src/persist.zig` | **Closed** — byte-level format spec in module doc |
| 13 | Q-013 | REQUIREMENTS.md references stale Geode paths | Medium | 50 | `docs/REQUIREMENTS.md` | **Won't Do** — paths are Geode-origin evidence |
| 14 | Q-014 | knnSearch allocates zero-length slice | Low | 40 | `src/hnsw.zig:236` | **Closed** — returns empty slice literal |
| 15 | Q-015 | Dead code: `expectSuccess` never called | Low | 40 | `tests/integration.zig:279` | **Closed** — removed |
| 16 | Q-016 | Makefile and pre-commit omit examples/ | Low | 40 | `Makefile:45` | **Closed** — `examples/` added to both |
| 17 | Q-017 | CODEOWNERS has placeholder | Low | 40 | `CODEOWNERS:3` | **Closed** — set to `@benjiv` |
| 18 | Q-018 | No doc comment on Hnsw.allocator | Low | 40 | `src/hnsw.zig:84` | **Closed** — doc comment added |
| 19 | Q-019 | No comment on level_mult formula | Low | 40 | `src/hnsw.zig:107` | **Closed** — comment added |
| 20 | Q-020 | `persist.load()` exceeds 100-line guideline | Medium | 40 | `src/persist.zig:110` | **Closed** — extracted `loadNode`/`loadConnections` (77 lines) |
| 21 | Q-021 | `Node` still `pub` in hnsw.zig | Low | 30 | `src/hnsw.zig:84` | **Won't Do** — needed by persist.zig cross-file import; not re-exported |
| 22 | Q-022 | Deep nesting (5 levels) in 3 functions | Low | 30 | `src/hnsw.zig` | **Closed** — extracted `connectBidirectional`, `loadNode`, `loadConnections` |
| 23 | Q-023 | `distance.compute()` retains debug.assert | Low | 20 | `src/distance.zig:28` | **Won't Do** — internal invariant; public callers validate first |
| 24 | Q-024 | CI downloads Zig 5x per pipeline | Low | 30 | `.gitlab-ci.yml` | **Closed** — added `cache:` directive with zig version key |

## Summary

| Severity | Total | Closed | Won't Do |
|----------|-------|--------|----------|
| Critical | 2 | 2 | 0 |
| High | 4 | 4 | 0 |
| Medium | 8 | 6 | 2 (Q-011 by-design, Q-013 traceability) |
| Low | 10 | 8 | 2 (Q-021 Zig visibility, Q-023 internal assert) |
| **Total** | **24** | **20** | **4** |
