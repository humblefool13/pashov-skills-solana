# Trident (Ackee Blockchain) reference

Trident is a manually guided, stateful fuzzer for Solana programs: it generates a harness from the program's Anchor IDL and runs transaction sequences on an in-process SVM (TridentSVM, built on Anza's SVM crates). Licence MIT. Docs: https://ackee.xyz/trident/docs/latest/ . Repo: https://github.com/Ackee-Blockchain/trident .

## Compatibility with the pinned stack (Anchor 0.32.1, Solana/Agave 2.3)

Checked on 2026-10-30 against crates.io metadata, the Trident repo's `Cargo.toml`, `CHANGELOG.md` and GitHub releases. **Not run end to end against a real program.**

| Question | Finding | Confidence |
|---|---|---|
| Latest stable | `trident-cli` / `trident-fuzz` **0.12.0**, released 2025-11-27 | verified |
| Newer | `0.13.0-rc.1` to `0.13.0-rc.4` (rc.4 published 2026-05-14), all pre-releases | verified |
| Solana line | 0.12.0 depends on `solana-sdk ^2.3`; `trident-svm 0.2.0` depends on `solana-svm ^2.3`. Changelog 0.12.0: "Support for general solana-sdk version 2.3 and higher". This matches the Agave 2.3 line | verified |
| Anchor line | The harness is generated from the Anchor IDL in `target/idl/*.json`. The repo's own examples pin `anchor-lang = "0.31.1"`. **No statement about 0.32.x was found.** 0.32.1 and 0.31.1 share the same IDL spec generation in principle, but that is an inference | **uncertain** |
| Rust toolchain | No `rust-version` is declared on the crates; `cargo install trident-cli` compile requirements are not documented. A current toolchain is newer than the Rust 1.87 the older research note records, so installation is likely fine; on 1.87 it is untested | **uncertain** |
| Token-2022 | 0.12.0 added Token-2022 program support. The target chain lacks Token-2022, so the harness must not generate Token-2022 accounts and the program must reject them | verified feature, project-specific caveat |
| Chain runtime | TridentSVM runs the compiled `.so` itself (SBF), not the chain's validator; chain-specific behaviour (missing programs, feature gates) is not reproduced | inference |
| Maintenance | Repo active; slower cadence than LiteSVM | verified |

**Decision rule.** Treat Trident as an *additional* harness, not the primary one, until `trident init` and one fuzz run succeed on a copy of this workspace. If it works, use it for coverage-guided instruction-sequence discovery; keep the LiteSVM + proptest suite (see `litesvm-proptest.md`) for deterministic invariants, regression tests and PoCs. If it fails to build or its generated types disagree with the 0.32.1 IDL, record the exact error in the report and continue with the fallback. Do not pin or downgrade the program's Anchor version to suit the fuzzer.

## Workflow (confirm each command with `trident --help`; names can change between releases)

```bash
cargo install trident-cli          # check the version it installs: should be 0.12.0
# from the Anchor workspace root, after `anchor build` (the IDL must exist):
trident init                       # creates trident-tests/ with Trident.toml, fuzz_0/, types
# edit trident-tests/fuzz_0/test_fuzz.rs: flows and invariants
trident fuzz run fuzz_0            # run the campaign
```

Harness shape from the project's README (the generated file has typed transaction builders for each instruction; adapt names after `trident init`):

```rust
#[init]
fn start(&mut self) {
    let mut tx = InitializeTransaction::build(&mut self.trident, &mut self.fuzz_accounts);
    self.trident.execute_transaction(&mut tx, Some("Initialize"));
}

#[flow]
fn flow1(&mut self) {
    let mut tx = SwapTransaction::build(&mut self.trident, &mut self.fuzz_accounts);
    self.trident.execute_transaction(&mut tx, Some("Swap"));
}
```

## What to put in a Trident harness

- *Flows*: one per user-reachable instruction, plus a few multi-instruction flows that mimic real sequences (create pool then deposit then swap; create token then buy then sell then graduate).
- *Hostile variants*: let the builder pick wrong accounts sometimes (another user's vault, a duplicate account, a second pool's mint). Trident's account storage lets flows reuse previously created addresses; use it to mix accounts across pools.
- *Invariants*: assertions after each transaction, taken from the property list in `properties.md`. Trident 0.12 treats invariants as plain assertions.
- *Coverage*: enable the coverage option in `Trident.toml` when available (added in 0.11) and look at which instruction branches were never reached before trusting a clean run.
- *Seeds and reproduction*: record the seed of any failure; convert it into a deterministic LiteSVM regression test.

## When Trident is the wrong tool

Pure math (curve, rounding, fee layering): faster and sharper with proptest on the extracted function. Exact PoCs for audit findings: LiteSVM, where each account is set by hand. Anything that depends on chain features absent from TridentSVM.
