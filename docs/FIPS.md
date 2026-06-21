# FIPS-140-3 Status — hnsw

**REQ-ID:** REQ-FIPS-EXEMPT-001 — non-security crypto/hash/RNG sites are
allow-listed (exempt) from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** This library performs only **non-security** random-number operations:
HNSW graph layer-assignment coin-flips. It is **exempt** from the workspace
FIPS-140-3 routing requirement (see `fips` package spec
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). No site produces,
protects, or verifies a secret, key, credential, authentication tag, or
signature; therefore none is routed through the `crypto_backend` seam and none
links the OpenSSL FIPS provider. When a consumer builds with `-Dfips=true`,
this library is unaffected: it adds no `-Dfips` flag and changes no behavior.

## Exempt call sites

| File:Line | Primitive | Use | Why non-security (exempt) |
|-----------|-----------|-----|---------------------------|
| `src/hnsw.zig:133` | `std.Random.DefaultPrng` | HNSW layer-assignment coin-flips (Malkov & Yashunin 2018 §4) | Index-structure randomness, deterministically seeded by `config.seed` for reproducible indexes; not a secret |
| `src/hnsw.zig:175` | `std.Random.DefaultPrng` | Initialize the layer-assignment PRNG from `config.seed` | Index-structure randomness; not a secret |
| `src/persist.zig:199` | `std.Random.DefaultPrng` | Restore the layer-assignment PRNG on load | Index-structure randomness; not a secret |

Line numbers are pre-annotation approximations.

## zlint allow-list

Every site above carries an inline `// fips-exempt: non-security — <reason>`
annotation so the `zlint` FIPS rule treats it as allow-listed rather than a
violation. Adding a new `std.crypto` / `std.hash` / `std.Random` use to this
library REQUIRES adding both the inline annotation and a row in the table
above.
