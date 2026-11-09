# LiteSVM + proptest harness (primary backend)

LiteSVM is an in-process Solana VM for fast tests (https://github.com/LiteSVM/litesvm, Apache-2.0). Paired with `proptest` it gives random action sequences, shrinking and reproducible failures, with every account under your control. This is the recommended primary harness for Anchor 0.32.1 / Agave 2.3 because every dependency is a documented, pinned crate and no code generation is involved.

## Version pins (verified against crates.io on 2026-10-30)

| Crate | Pin | Why |
|---|---|---|
| `litesvm` | `=0.7.1` | The 0.7 line depends on Agave `^2.3` crates (`solana-program-runtime ^2.3`, `agave-feature-set ^2.3`, ...). 0.6.x is the 2.2 line, 0.8.x and later move to Agave 3.0 (`~3.0`). Do not mix lines in one build. MSRV 1.86 |
| `litesvm-token` | `=0.7.1` | Matches litesvm 0.7, uses `spl-token ^8` |
| `solana-sdk` | `~2.3` | Types shared with the program's dependency tree and with Trident |
| `proptest` | `=1.10.0` | MSRV 1.84; newer 1.12 needs Rust 1.88 |

If the project later upgrades to Agave 3.x, move litesvm and litesvm-token to the 0.8+ line together and re-pin everything else.

The template at `templates/litesvm-proptest/` has these pins, a shared `Env`, a model layer and an ignored on-chain driver. It was compiled and its tests were run on Linux (Rust 1.99.1, `cargo test --test properties`: 5 passed, 1 ignored) when this skill was written. A first build downloads and compiles roughly 1,300 crates (about 5 minutes); `cargo test` also needs its own `CARGO_HOME` if another cargo process (for example an `anchor build`) is holding the package-cache lock.

## Layout

```
<workspace>/fuzz-tests/            # standalone crate, NOT a workspace member
  Cargo.toml                        # has an empty [workspace] table
  tests/common/mod.rs               # Env: LiteSVM + payer + helpers
  tests/ix.rs                       # instruction builders (hand-written or from the IDL)
  tests/properties.rs               # model layer + on-chain driver
  tests/regression_<finding>.rs     # one deterministic test per audit finding or fuzz failure
  PROPERTIES.md                     # spec of every property with id, guarantee tag, status
```

Keep it a separate crate so the test stack's `solana-*` versions never fight the program's pinned `anchor-lang`/`solana-program`. Build the program first (`anchor build`), then point `PROGRAM_SO` at `target/deploy/<name>.so`.

## Core pieces

1. **Environment** (`common/mod.rs`): `LiteSVM::new()`, `airdrop`, `add_program_from_file(program_id, path)`, `send_transaction`, `get_account`, `expire_blockhash()` between sends so repeated identical transactions are not rejected as duplicates. The template exposes `Env::send`, `new_mint`, `new_ata`, `mint_to`, `token_balance`.
2. **Instruction builders** (`ix.rs`): build `Instruction { program_id, accounts: Vec<AccountMeta>, data }` yourself, with the 8-byte Anchor discriminator `sha256("global:<ix_name>")[..8]` followed by Borsh args. Pull the account order from the IDL. Hand-written builders make hostile variants easy: swap one account, duplicate one, flip a signer flag.
3. **Action enum and strategy**: one variant per user-reachable instruction, with clamped arguments (a few boundary values `1, 2, max/4`, a mid-range, a pool-proportional value), plus hostile variants. Keep sequences 1..40 long.
4. **Ghost state**: track what the test knows independently of the program: per-actor token in and out, total minted, expected fees, books. Properties compare the program's accounts with the ghost.
5. **Properties after every step**, on success and on failure: see `properties.md`. A failed transaction must leave every account unchanged (check by snapshot).
6. **Shrinking and replay**: proptest shrinks the action list; keep the printed seed; commit `proptest-regressions/`. Then freeze the shrunk sequence as `tests/regression_<name>.rs` with explicit values (every finding becomes a regression test).

## Useful LiteSVM operations

- Set arbitrary account data (forged vault, fake mint, wrong-owner account): `svm.set_account(pubkey, Account { lamports, data, owner, executable: false, rent_epoch: 0 })`. This is how adversarial-account tests are written, for example a token-account-shaped account owned by another program (A2), or a sysvar-shaped account at a random address (B2).
- Time and slots: `svm.warp_to_slot(n)`, and the Clock sysvar via `svm.get_sysvar::<Clock>()` / `set_sysvar`, for fee schedules, launch windows and TWAP tests.
- Compute: check `meta.compute_units_consumed` of the largest paths against the budget; loop-heavy instructions get a worst-case test.
- Verbose logs: failed transactions expose logs through `FailedTransactionMetadata` (the template's `send` returns them).
- Mirror the chain: the target chain has System, SPL Token, ATA, Metaplex Token Metadata and Compute Budget, and lacks Token-2022, Memo and ALTs. `LiteSVM::new()` loads a default program set that may include programs the chain lacks, so add a test that Token-2022 mints are rejected by the program, and do not rely on those defaults in positive tests. Confirm what `LiteSVM::new()` loads in the pinned version before depending on its absence.

## Known gaps in LiteSVM 0.7.1 (checked in its source)

- **Rent-state check skips empty accounts.** LiteSVM's `check_accounts_rent` only checks writable accounts that already hold data. On a real validator, a transfer that leaves a zero-data account with fewer lamports than the rent-exempt minimum fails with an insufficient-funds-for-rent error. In LiteSVM 0.7.1 it succeeds (the template pins this with `known_gap_litesvm_skips_rent_check_for_empty_accounts`). So **rent-exempt DoS tests (vector C6) against system or empty recipients cannot be proved with LiteSVM**: assert the program's own minimum-balance logic, use accounts that carry data, or confirm on `solana-test-validator`.
- `LiteSVM::new()` enables all features, builtins, sysvars, precompiles and the default programs. To mirror a chain with fewer programs, start from `LiteSVM::default()` and chain `.with_feature_set(..).with_builtins().with_sysvars().with_precompiles()` then add only the programs the chain has; verify what the default set contains in the pinned version before depending on its absence.
- It is not the chain's validator: runtime feature gates and loader versions follow the crate's Agave line, not necessarily your target chain's node (for example a chain on an older Agave or a different SBF version). Confirm anything version-sensitive on a real validator of that chain.

## Mutation sanity (run it, it catches vacuous properties)

For every property, break the program (or the model) in the smallest way that should violate it and confirm the suite fails: change a `ceil_div` to floor, drop the `reload()`, remove a `has_one`. A property that stays green under its own mutation is not testing anything. Record the mutation in `PROPERTIES.md`.

Worked example from the template (run when this skill was written): turning the swap output from floor to ceiling is caught by all three model properties (minimal failing input found by proptest: `x = 1000, y = 1000, fee = 0, dx = 1`), but only after the strategies were widened to draw `fee = 0` and small reserves; with a 2.5% fee and large reserves the same mutation stayed green because the fee hid the one-unit gain. Turning the fee from ceiling to floor survives all three, because the fee stays in the reserves either way. That survivor is correct information: fee accounting needs its own property (GL-15), not a stronger k check.

## Running

```bash
cargo test --test properties                      # model layer, fast
PROGRAM_SO=../web3/target/deploy/amm.so cargo test --test properties -- --ignored
PROPTEST_CASES=5000 cargo test --release --test properties
```
On Windows run the Rust and Solana toolchain inside WSL; from Git Bash write commands to a `.sh` file and run it with `wsl -- bash -l <path>.sh` so `$vars` are not expanded by the outer shell.

## Optional: Mollusk for single-instruction unit tests

Mollusk (https://github.com/anza-xyz/mollusk) tests one instruction against supplied accounts with compute-unit reporting. Its releases track Agave versions closely (check the crate's `solana-*` requirements against Agave 2.3 before adding it: older 0.1.x/0.2.x lines are on the 2.2 family). Useful for per-instruction negative tests (wrong owner, missing signer) and CU baselines; LiteSVM covers the same ground, so add it only if you want fixture-based benchmarks.
