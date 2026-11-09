# Protocol-Type Threat Profiles (Solana)

Use these to decide **who threatens the protocol** and **what to look at first**. They are identification aids, not report prose: translate them into investigation pointers (see the surface-list rule in `templates.md`). The attack-vector library of the `solana-auditor` skill (`references/attack-vectors/`) holds the detail behind each ID cited here.

Table of contents: classification signals, DEX/AMM, launchpad/bonding curve, hybrid, temporal phases, composability.

## Classification signals

| Type | Signals in code |
|---|---|
| DEX / AMM | `swap`, `deposit`/`withdraw` liquidity, `initialize` pool, LP mint/burn, constant-product math, `sqrt` on init, fee tiers or `amm_config`, vault pairs `token_0/token_1`, `observation`/TWAP state, `trade_fee`, `protocol_fee`, `fund_fee` |
| Launchpad / bonding curve | `create_token`/`create`, `buy`/`sell` against a curve, `virtual_*_reserves`, `real_*_reserves`, `complete`/`graduated`, `migrate`/`graduate`, creator fee, metadata CPI, mint authority revocation, LP burn |
| Lending | `borrow`, `repay`, `liquidate`, collateral factors, interest indexes |
| Vault / staking | share price, `deposit`/`redeem`, rewards per share, lockups |
| Bridge | message nonces, guardian or validator sets, signature verification via sysvar |
| Stablecoin | collateral mint, peg logic |

Rank by signal density. State the primary type first and the secondary types after it; merge adversary lists with the primary first and de-duplicated.

## DEX / AMM

**Adversaries, ranked**
1. *Ordering attacker* (sandwich, back-run, bundle control): extracts from every swap without a binding slippage bound.
2. *Rounding extractor / round-trip looper*: small repeated trades whose rounding favours the trader.
3. *First-liquidity and pool-bootstrap attacker*: sets the initial price, pre-creates the pool, inflates LP value by donation.
4. *Hostile token creator*: freeze or mint authority, Token-2022 extensions, fee-on-transfer, decimals tricks, mints with a transfer hook.
5. *Compromised or malicious admin / config owner*: fee changes, pool-creation fee receiver, upgrade authority.
6. *Account-substitution attacker*: fake vaults, fake config, duplicate accounts, wrong token program.

**What to look at first**
1. Swap math in both directions: rounding per direction, k check on actual post-transfer balances, vault-direction mapping (vector ids D2, I1, I3, I4).
2. Pool creation and LP mint: initial LP, locked minimum, zero-LP deposits, who can create which pair, address derivation (F4, F5).
3. Every instruction's account bindings: vault, mints, config, observation state, token program (A3, E1, E2).
4. Fee layering and who can claim what (I5, G7).
5. Mint admission rules: freeze authority, mint authority, extension allowlist, what the chain lacks (E4, E6).
6. Oracle/TWAP exposure to other programs (F2, F7).

**Critical invariants**: pool value `k` non-decreasing across swaps; LP supply equals the sum of positions; no profit from deposit-then-withdraw or swap-then-swap-back; vault balances cover books plus accrued fees; fees only leave to their stored receivers.

## Launchpad / bonding curve

**Adversaries, ranked**
1. *Insider or compromised privileged key*: withdraw or migration authority, upgrade authority (G1, G2, G4).
2. *Atomic manipulator* (flash-loan funded buyer, bundle sniper): moves the curve inside one transaction, snipes launches, completes curves at the edge.
3. *Graduation attacker*: pre-creates or pre-funds the destination pool, forces a revert, or captures the migration price (F4, I7).
4. *Hostile token creator*: creator-fee manipulation, wash trading, fee receiver substitution, last-moment fee changes (I8).
5. *Rounding extractor* on the curve (I2, I6).
6. *Griefer*: makes buy, sell or graduation fail for everyone (payout to a fresh account, pre-funded PDA, panic on edge state) (C6, H5, H7).

**What to look at first**
1. Graduation and migration: trigger rules, destination derivation, exact amounts, leftover tokens, LP burn proof, double-migration, behaviour when the pool already exists (I7, I10).
2. Curve math at the edges: first buy, last buy, the buy that crosses the threshold, sells that exceed real reserves, virtual versus real reserves (I6, I12).
3. Authority handling on the new mint: mint and freeze authority revoked and verified before trading, metadata update authority (E4).
4. Privileged instructions and what they can reach (G1 to G9).
5. Creator-fee mechanics: caps, change rules, claim path, recipient substitution (I8).
6. Dependencies on chain features that may be missing: wrapped-native mint, Token-2022, lookup tables (E6, E7, H2).

**Critical invariants**: the curve never pays out more than it holds; total supply is conserved across curve, pool, burned and held; graduation happens once and only after the threshold; mint and freeze authorities are `None` after launch; no instruction callable by the creator or admin reduces a user-funded vault; fees accrued equal fees claimable.

## Hybrid (for example an AMM + launchpad that graduates into the AMM)

Primary: whichever has more signals (usually the launchpad, for the graduation path; the AMM for value at rest). Add the seam threats: the permissioned pool creation used by the launchpad (`initialize_with_permission`) and what it trusts; price continuity between the curve's final price and the pool's initial price; LP custody and burn across the two programs; fee layers that stack when a graduated token is traded on the AMM; cross-program state reads (X-IDs in `invariants.md`).

## Temporal phases

Include only phases that add new information beyond the surface list.
- **Deployment and initialization** (the most dangerous window): initialization front-running, config owner set to the deployer, test parameters left in, upgrade authority not yet moved, program id mismatch between `declare_id!` and `Anchor.toml`, IDL authority, empty-state behaviour on the first pool and the first curve.
- **Steady state**: parameter drift, fee accrual bookkeeping, dust accumulation, account growth.
- **Launch peaks and market stress**: compute and transaction-size limits under load, congested bundles, same-slot ordering, oracle staleness, vault imbalance after a large exit.
- **Graduation windows**: the gap between completion and migration, mismatched prices, pending sells in the same slot.
- **Governance, rotation and upgrades**: authority transfers, pause and unpause, changing fee receivers, program upgrades that change account layouts (migration of old accounts, discriminator reuse).
- **Wind-down**: closing pools and curves, reclaiming rent, leftover lamports and tokens, program closure (OptiFi lesson, G4).

## Composability and dependency risks

For each dependency record: what is assumed, what is validated (or NONE), mutability (immutable, upgradeable by whom), on failure (revert, fail-open, stuck).
- **Token programs and extensions** (E): SPL Token versus Token-2022, which extensions are admitted, freeze and mint authorities, decimals, native mint.
- **Metaplex Token Metadata and similar**: update authority, mutable metadata, creator verification, who pays rent.
- **Oracles** (F1): feed id, staleness, confidence, owner.
- **Other first-party programs** (the AMM called by the launchpad): pinned program id, version coupling, layout coupling, upgrade order.
- **Off-chain components**: indexers parsing logs (G6), keepers with signer power, frontends computing slippage, RPC assumptions.
- **Shared state exposure**: other programs reading this pool's price or reserves (F7); this program's behaviour when another program holds its LP tokens or vault ATA.
