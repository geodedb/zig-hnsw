# Security Gap Analysis

Last updated: 2026-03-25

## Findings

| # | ID | Finding | Risk Level | Risk Score | CWE | File:Line | Status |
|---|-----|---------|-----------|------------|-----|-----------|--------|
| 1 | SEC-001 | Unvalidated neighbor indices in `persist.load()` | Critical | 90 | CWE-125 | `src/persist.zig:139-141` | **Closed** — bounds check added: `if (neighbor >= node_count) return error.InvalidNeighborIndex` |
| 2 | SEC-002 | Unvalidated `entry_point` in `persist.load()` | Critical | 88 | CWE-125 | `src/persist.zig:97-98` | **Closed** — validation added: `if (ep >= node_count) return error.InvalidEntryPoint` |
| 3 | SEC-003 | No bounds validation on deserialized header values | High | 75 | CWE-770 | `src/persist.zig:78-96` | **Closed** — dim, m, max_layers, ef_construction, ef_search, node_count all validated |
| 4 | SEC-004 | `debug.assert` for input validation — stripped in release | High | 72 | CWE-617 | `src/hnsw.zig` | **Closed** — replaced with runtime error returns (`DimensionMismatch`, `InvalidDimension`, `InvalidConfig`) |
| 5 | SEC-005 | u16 overflow in `Config.m0()` | Medium | 58 | CWE-190 | `src/hnsw.zig:40` | **Closed** — `m0()` now returns `u32`; config validates `m >= 2` |
| 6 | SEC-006 | NaN/Inf vectors cause incorrect results (injectable via persist) | Medium | 55 | CWE-682 | `src/distance.zig` | **Closed** — `persist.load()` validates all vector values for NaN/Inf |
| 7 | SEC-007 | Unvalidated `max_level` from snapshot | Medium | 50 | CWE-20 | `src/persist.zig:99` | **Closed** — validation added: `if (max_level >= max_layers) return error.InvalidMaxLevel` |
| 8 | SEC-008 | Node `level` not validated against `max_layers` | Medium | 48 | CWE-770 | `src/persist.zig:117` | **Closed** — validation added: `if (level >= max_layers) return error.InvalidNodeLevel` |
| 9 | SEC-009 | CI components pinned to semver tags instead of commit SHAs | Medium | 45 | CWE-829 | `.gitlab-ci.yml` | **Won't Do** — first-party components from same org; semver pinning accepted |
| 10 | SEC-010 | CODEOWNERS placeholder disables review gates | Medium | 40 | CWE-1188 | `CODEOWNERS:3` | **Closed** — replaced `@your-username` with `@benjiv` |
| 11 | SEC-011 | CI does not test ReleaseFast/ReleaseSmall | Low | 35 | CWE-1127 | `.gitlab-ci.yml` | **Closed** — CI now includes `test-release-fast`, `test-release-small`, `test-integration-release-safe`, and `test-integration-release-fast` jobs |
| 12 | SEC-012 | Pre-commit hooks use version tags not commit SHAs | Low | 30 | CWE-829 | `.pre-commit-config.yaml` | **Won't Do** — standard practice; auto-update manages versions |
| 13 | SEC-013 | No gitleaks pre-commit hook | Low | 25 | CWE-798 | `.pre-commit-config.yaml` | **Closed** — added `gitleaks/gitleaks` v8.24.0 pre-commit hook for defense-in-depth alongside CI gitleaks scanning |
| 14 | SEC-014 | Docker base image not pinned to digest | Low | 20 | CWE-829 | `.gitlab-ci.yml` | **Won't Do** — rolling security updates preferred for CI images |

## Summary

| Risk Level | Total | Closed | Won't Do | Deferred |
|-----------|-------|--------|----------|----------|
| Critical | 2 | 2 | 0 | 0 |
| High | 2 | 2 | 0 | 0 |
| Medium | 6 | 5 | 1 | 0 |
| Low | 4 | 2 | 2 | 0 |
| **Total** | **14** | **11** | **3** | **0** |
