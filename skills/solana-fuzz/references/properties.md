# Property catalog for Solana AMMs, bonding curves and launchpads

Use this to turn the x-ray `Fuzz hint` lines and the `solana-auditor` vector library into executable properties. Each property gets an id (`GL-NN` global, `SP-NN` specific to an instruction), a **guarantee tag**, and a status box in `PROPERTIES.md`. (The guarantee-tag idea comes from Pashov's `fizz` skill, MIT licence: a violated SHOULD-HOLD property is a confirmed bug; a violated EXPLORATORY property is a lead for a human.)

- **SHOULD-HOLD**: stated by a spec or doc, an exact accounting identity, or a closed-form math fact.
- **EXPLORATORY**: inferred from code or common DeFi practice; a violation needs review.

Table of contents: conservation and solvency, pricing and rounding, lifecycle and state, authority and admin, adversarial accounts, liveness, launchpad and curve, regression rule.

## Conservation and solvency (SHOULD-HOLD)
- **GL-01 vault covers books**: for every pool vault `vault.amount >= reserve_books + accrued_protocol_fees + accrued_creator_fees`, after every successful instruction (reload first). Donations may raise the left side only. (E5)
- **GL-02 token conservation**: total tokens in = total tokens out + change in vault balances + fees, per instruction and over the whole sequence, using the ghost ledger of actors. (D5)
- **GL-03 LP supply**: `lp_mint.supply == sum(actor LP) + locked LP`; locked LP never decreases. (F5)
- **GL-04 supply conservation (launchpad)**: curve + pool + burned + held == total supply; mint authority is `None` after launch. (E4)
- **GL-05 lamport vaults**: for SOL-holding accounts `lamports - rent_minimum >= owed`. (I14, C5)
- **GL-06 failed transactions change nothing**: snapshot all touched accounts before; if the transaction errors, they are identical afterwards. (atomicity, catches partial-state bugs)

## Pricing and rounding
- **GL-10 k monotonic**: after any swap `k_after >= k_before`, with fees counted as reserves or tracked separately and excluded consistently. (I1)
- **GL-11 no round-trip profit**: for any actor, any amount including 1 and 2 base units, swap and swap-back, buy and sell, deposit and withdraw never end with more value than the start. Also check n repetitions of dust trades. (I2, D2)
- **GL-12 zero in, zero out; no free value**: a swap with output 0 is rejected or costs nothing; a deposit that mints 0 LP is rejected. (D3)
- **GL-13 directional rounding**: exact-in output is `<=` the real-valued output; exact-out input is `>=` the real-valued input; fees `>=` the real-valued fee. Compare to a `u128`/rational model. (I3)
- **GL-14 quote equals execution**: any view/quote function equals the amount the instruction delivers for the same inputs and state. (invariant agent: view vs write)
- **GL-15 fee layering**: `lp_fee + protocol_fee + creator_fee <= total_fee_taken`; each accumulator has one claimant and claim `<=` accrued. (I5)
- **GL-16 first deposit**: after pool creation and a donation of any size, a deposit of a normal amount mints more than 0 LP and recovers at least `deposit - dust`. (F5)

## Lifecycle and state
- **SP-20 closed means dead**: after `close`, the account cannot be read as valid or revived by re-funding in the same transaction or later. (C1)
- **SP-21 one-shot flags**: `initialized`, `graduated`, `complete` change once and stay; instructions invalid in a state fail in that state (run every instruction in every state). (C4)
- **SP-22 pair symmetry**: init then close returns rent to the right party; buy then sell does not leave residue that blocks later actions. (C4)
- **SP-23 realloc bounds**: growth never exceeds the cap; new bytes are zero. (C2)

## Authority and admin (default rule: no admin path may move user funds)
- **GL-30 admin cannot touch user vaults**: for every instruction callable by admin, owner, creator, fee authority, migration authority: user-funded vault balances (and users' token accounts) are unchanged except by documented fee receivers within caps. Run each privileged instruction with hostile destination accounts. (G1, G2)
- **GL-31 caps hold in every setter**: after any sequence of setter calls, `fee <= MAX` and `creator_fee <= 5%` (and the same in `initialize`). (G7)
- **GL-32 pause never traps exits**: while paused, user exit paths still succeed (or the doc says otherwise); no instruction is silently exempt. (G5)
- **SP-33 authority transfer**: two-step; cannot set to the default pubkey; old authority loses power. (G8)

## Adversarial accounts (negative tests; each must FAIL with a specific error)
For every instruction, a generated test that substitutes one account at a time:
- wrong owner program (A2), wrong type with same size (A4), another pool's vault or mint (A3, E2), the same account for two mutable slots (A10), a non-signer where a signer is required (A1), a fake token program or fake CPI target (B1), a fake sysvar account (B2), a non-canonical PDA bump or seeds (A5, A6), pre-funded PDA address on creation (C6), a recipient with 0 lamports for a small payout (C6; LiteSVM 0.7.1 does not enforce the rent rule for empty accounts, so prove this one on `solana-test-validator` or by asserting the program's own minimum-balance check), a mint with freeze or mint authority, or a Token-2022 mint on a chain that lacks the program (E4, E6), a vault with a delegate or close authority (E3).
Each case is `assert!(res.is_err())` plus a check that no state changed.

## Liveness (DoS properties)
- **GL-40 exits stay possible**: for any reachable state, a holder with a balance can withdraw/sell their full position within the compute budget. (H1, H7)
- **GL-41 graduation completes**: when the threshold is reached, the migration succeeds even if the destination pool address was pre-funded or pre-created by an attacker. (F4, I7)
- **GL-42 worst-case compute**: the heaviest instruction at the largest allowed state stays under 200k CU (or the requested budget). (H1)
- **GL-43 no panic reachable**: random argument and account fuzzing never produces a panic/abort; all failures are typed errors. (H5)

## Launchpad and curve specifics
- **SP-50 curve solvency**: real SOL reserve covers the maximum possible payout at every reachable state. (I12)
- **SP-51 threshold exactness**: the buy that crosses the graduation threshold is clamped and refunded; `complete` flips exactly once. (I6)
- **SP-52 graduation exactness**: tokens and SOL moved to the pool equal the curve's accounting; leftovers burned; LP burned. (I7, I10)
- **SP-53 creator-fee base**: buy and sell charge the same fee base; fee changes never apply to in-flight positions. (I8)
- **SP-54 authority revocation**: mint and freeze authority of the launched token are `None` before the first buy. (E4)

## Regression rule
Every confirmed audit finding becomes `tests/regression_<id>.rs`: a deterministic LiteSVM test that fails on the vulnerable commit and passes on the fix. Keep the vulnerable variant reproducible (a feature flag or a patch file in `tests/regressions/`). Name tests after the finding key (`amm_swap_account_substitution`).

## PROPERTIES.md entry format
```
- [ ] GL-11 [SHOULD-HOLD] No round-trip profit: swap(x) then swap back <= x for x in 1..=2^40.
      Driver: model_round_trip_never_profits, onchain_round_trip. Mutation: floor->ceil in swap_base_input (must fail). Status: green | red | pending.
```
Flip `[ ]` to `[x]` only when the property is implemented, passes on the current code, and fails under its recorded mutation.
