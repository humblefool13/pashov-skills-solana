---
name: solana-fuzz
description: Generates property-based and invariant test harnesses for Solana/Anchor programs - Trident fuzz harnesses and, as the verified default, a LiteSVM plus proptest suite with a ghost-state model, adversarial-account negative tests, round-trip and conservation properties, mutation checks and deterministic regression tests for audit findings. Use this skill whenever the user asks to fuzz a Solana program, write invariant or property tests, build a fuzzing harness, test an AMM, DEX, bonding curve or launchpad for rounding or solvency bugs, reproduce an audit finding as a test, add regression tests after an audit, or says Trident, LiteSVM, proptest, stateful fuzzing or invariant suite for Anchor or SBF programs. Pairs with solana-xray (properties) and solana-auditor (findings to regress).
---

# Solana Fuzz

Generate a fuzz and invariant suite for a Solana program and run it. The shape follows the Pashov Audit Group `fizz` skill (https://github.com/pashov/skills, MIT licence, commit eacfc09), which builds stateful Echidna/Medusa suites for Solidity: understand the protocol, select entry points, scaffold a harness, wire setup, add handlers, iterate on coverage, discover invariants with specialised passes, implement them, run campaigns, triage by guarantee tag, turn failures into deterministic repros, and report. Here the engines are LiteSVM + proptest (primary) and Trident (optional), and the invariant sources are Solana's.

## Choose the backend first

Read `references/trident.md` (compatibility facts) and `references/litesvm-proptest.md` (pins and layout). In short, for the pinned stack (Anchor 0.32.1, Solana/Agave 2.3):

- **LiteSVM `=0.7.1` + `litesvm-token =0.7.1` + `solana-sdk ~2.3` + `proptest =1.10.0`** is verified to sit on the Agave 2.3 line and is the default. The template in `templates/litesvm-proptest/` compiles and its tests run (5 pass, 1 ignored until wired). Known limit: LiteSVM 0.7.1 does not enforce the rent rule for empty accounts, so rent-DoS cases need a real validator (see `references/litesvm-proptest.md`).
- **Trident 0.12.0** is the current stable release and targets `solana-sdk ^2.3`, but **compatibility with Anchor 0.32.1 is unverified** (its examples pin 0.31.1). Try it on a copy; if `trident init` or a run fails, report the error and continue with LiteSVM. Never change the program's Anchor version for the fuzzer.

State the chosen backend and why in the first line of your report.

## Parameters

- `WORKSPACE`: the Anchor workspace root (default: the directory with `Anchor.toml`; it may be a subfolder such as `programs/` or `web3/`; confirm with the user before writing anywhere).
- `SUITE_DIR`: `<WORKSPACE>/fuzz-tests` (standalone crate). Trident harnesses live in `<WORKSPACE>/trident-tests`.
- Optional program names narrow the suite to specific programs. `--no-properties` skips discovery and only scaffolds. `--max` uses the strongest model for discovery subagents.

## Workflow (follow in order; stop and report a blocker rather than skipping ahead)

**Step 1: Preflight.** Run the Rust commands in the project's toolchain environment (for example WSL on Windows, a container, or native Linux/macOS). Check `rustc --version`, `solana --version`, `anchor --version`, `cargo build-sbf --version`. Confirm the program builds (`anchor build`) and note the `.so` paths and program ids. If the build fails, stop and report; fuzzing a program that does not build tests nothing. Never edit program source.

**Step 2: Understand the protocol.** If `x-ray/x-ray.md` exists, read it and `invariants.md`, `entry-points.md` (the `Fuzz hint` lines are your first property list). Otherwise read the sources and write down: instructions and who may call them, accounts and PDAs, state machines, token flows, privileged roles, chain constraints (missing Token-2022 / ALT / wrapped-native), and the dependencies that need real programs (SPL Token, ATA, Metaplex metadata) or fakes.

**Step 3: Select entry points.** Keep the user-reachable instructions that move value or change state; mark admin setters as *secondary* (called rarely). Always keep the instructions that create the system's state (config, pool, token creation).

**Step 4: Scaffold.** Copy `templates/litesvm-proptest/` to `SUITE_DIR`. Edit `Cargo.toml` (program crate path, features), keep the pins. Build instruction builders in `tests/ix.rs` from the IDL (account order, 8-byte discriminators, Borsh args). Write `setup_*` functions that create configs, mints, pools and funded actors the same way a real deployment would. Run `cargo test --test properties` to see the model layer pass, then compile the on-chain driver.

**Step 5: Reach coverage before properties.** Run random action sequences with the properties disabled and check which instructions and branches execute (count successful and failed calls per instruction; use `cargo llvm-cov` on the program crate only if available). Do not move on while core instructions (swap, deposit, withdraw, buy, sell, graduate) are rarely reachable successfully: improve the clamping, the setup, the actor balances and the preconditions. Document unreachable paths and why.

**Step 6: Discover properties.** Read `references/properties.md`. Run five focused passes (use parallel subagents when the tool exists, one prompt each, then merge): (1) conservation and solvency, (2) round-trip and rounding (`D`/`I` vectors), (3) state machine and lifecycle, (4) adversarial accounts and authority (`A`, `B`, `E`, `G` vectors, the project's no-admin-fund-path rule), (5) protocol-type specifics (AMM, curve, launchpad). Merge, deduplicate, prioritise, and write `PROPERTIES.md` with ids `GL-NN` / `SP-NN`, each tagged SHOULD-HOLD or EXPLORATORY with a one-line derivation and a recorded mutation.

**Step 7: Implement.** Implement each property in the model layer when it is pure math, and in the on-chain driver when it depends on account state. Prefer the adversarial-account negative tests as a table-driven test over all instructions. Prefer a commented TODO to a brittle assertion when a property is low confidence.

**Step 8: Prove the properties can fail (mutation sanity).** For every property apply its recorded mutation (flip a rounding direction, drop a `reload()`, remove a constraint, in a scratch copy of the program, never the user's tree) and confirm the suite goes red. A property that stays green is vacuous: fix or drop it.

**Step 9: Run campaigns.** `cargo test --release` with `PROPTEST_CASES` raised (start 1,000 and go to 10,000+ for the math properties; sequences of 1..40 actions). Run Trident separately if it was verified. Wrapper rule: long runs go in the background with output captured to a log; do not poll.

**Step 10: Triage.** For each failure: (a) rule out a harness or property bug first, (b) read the shrunk sequence, (c) if the property is SHOULD-HOLD it is a confirmed bug, if EXPLORATORY present it as a lead for human review, (d) turn the shrunk sequence into `tests/regression_<name>.rs` with explicit values, which must fail on the current code. Report each with the failing property, its tag, the minimal sequence and the account states.

**Step 11: Report.** Print: backend and versions; instructions covered with success/failure counts; the property table (id, tag, status, mutation checked); campaign size and duration; failures with repro file names; gaps (unreachable code, features not mirrored from the chain, properties still TODO); the exact commands to re-run. Do not claim the program is safe: a clean run shows only that these properties held for these inputs.

## Rules that keep the suite honest

- **Read-only on program source.** Mutations happen in a scratch copy. Tests, `PROPERTIES.md` and fixtures live under `SUITE_DIR`.
- **Mirror the chain.** Positive tests use only programs the target chain has; add explicit negative tests for what it lacks (a Token-2022 mint must be rejected cleanly).
- **Keep the model honest.** If a property uses a Rust model of the math, copy the formulas from the program or call the program's math module, and add a test that compares the model to the on-chain result on random inputs.
- **Determinism.** Commit `proptest-regressions/`; fix seeds for CI jobs that must be reproducible; log the seed of every failure.
- **Every audit finding becomes a regression test** (recommended practice). When `solana-auditor` reports a finding, the first fuzz task is its `regression_*.rs`.

## Files

- `references/trident.md`: Trident versions, compatibility with this stack, what is and is not verified, harness shape.
- `references/litesvm-proptest.md`: pins, layout, LiteSVM operations, mutation sanity, running.
- `references/properties.md`: the property catalog and the `PROPERTIES.md` entry format.
- `templates/litesvm-proptest/`: `Cargo.toml`, `tests/common/mod.rs`, `tests/properties.rs` (model layer + ignored on-chain driver).
