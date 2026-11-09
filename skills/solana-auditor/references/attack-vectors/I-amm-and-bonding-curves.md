# I. AMM and bonding-curve economics

Dedicated module for constant-product pools (for example Raydium CP-Swap and its forks) and pump.fun-style launchpads. Read this module with D (rounding), E (vaults), F (bootstrap and ordering) and G (privileged keys). The goal is to find every way to leave a pool or curve with more value than you put in.

Table of contents: I1 k invariant, I2 round-trip extraction, I3 rounding per direction, I4 direction and vault mapping, I5 fee layering, I6 bonding-curve math, I7 graduation and migration, I8 creator-fee manipulation, I9 launch sniping and same-slot effects, I10 liquidity burn and rug paths, I11 intra-transaction price dependence, I12 virtual versus real reserves, I13 degenerate pools and amounts, I14 SOL-quoted curves and rent.

Quick formulas for reference (constant product, no fees, reserves `x`, `y`): exact-in output `dy = y * dx / (x + dx)` (floor); exact-out input `dx = ceil(x * dy / (y - dy))`; invariant `k = x * y` must not decrease across any swap once fees are included in the reserves. With a bonding curve using virtual reserves `(vx, vy)` and real reserves `(rx, ry)`, price comes from the virtual pair while payouts are limited by the real pair.

---

### I1 The k invariant
**Check**: after every swap, deposit and withdrawal, `new_x * new_y >= old_x * old_y` using the **actual post-transfer vault balances** minus fees owed to others (protocol, creator), not the amounts the instruction thought it moved. The check must run after the token transfers (and after `reload()`), and its inputs must come from the right accounts (I4).
**Break it with**: fee-on-transfer mints (received < sent), donations to the vault that raise `x` but not the books, fees that stay in the vault but are counted as reserves, rounding in the user's favour, a swap where input and output vault are aliased (E9, A10).
**Detect**: find the line that enforces `>= old_k`; if it uses computed amounts instead of balances, or runs before the transfer, flag it. Check what happens when `amount_in` is 0 or 1.

### I2 Round-trip extraction
**Check**: for any action followed by its inverse, the actor must not end with more value, including over many repetitions and at small sizes.
- buy then sell the same tokens on a curve: net tokens/SOL <= start minus fees;
- swap A to B then B to A: net <= start;
- deposit then withdraw immediately: LP burn returns <= deposit;
- exact-in then exact-out of the same quote: not cheaper than exact-in.
**Break it with**: amounts of 1 to 10 base units where ceiling/floor errors dominate; many tiny trades whose rounding errors all go the same way; a path (like exact-out) that rounds differently from its inverse.
**Test**: property test over random amounts with a ghost balance of the actor (see the `solana-fuzz` skill).

### I3 Rounding per direction
**Rule** (repeat of D2 for pools): output of a swap rounds down; required input of an exact-out swap rounds up; LP minted on deposit rounds down; tokens returned on LP burn round down; fee charged rounds up. In the CP-Swap lineage there are two paths (swap-base-input and swap-base-output), each needing its own rounding; MadShield's MAD_RAY_04 (High) was a ceiling division used on the wrong quantity in the swap-in path.
**Detect**: read both swap paths side by side; for each division, name who gains from the remainder. Check the zero-output case: `require!(amount_out > 0)`.

### I4 Trade direction and vault mapping
**What**: Programs that accept `input_vault` and `output_vault` and then compare them to the pool's `token_0_vault`/`token_1_vault` to determine direction can swap the roles by mistake. MadShield's MAD_RAY_03 (Critical, found by fuzzing): the code assigned the amounts to the wrong side after determining direction, so the constant-product-increasing check failed in a way that blocked swaps. A wrong mapping the other way would let a trader take the wrong asset.
**Check**: `input_vault` must give `amount_in`, `output_vault` must receive the debit; direction only selects which reserve is `x` and which `y`. Reserves must be read from the same vault the transfer touches. Verify mints of the user's accounts against the vaults' mints.
**Detect**: any `if input_vault.key() == pool.token_0_vault { (a,b) } else { (b,a) }` block: confirm the tuple order against its use.

### I5 Fee layering
**What**: Pools often stack several fees: trade fee (LP), protocol fee, fund fee, creator fee (often chosen by token creators within a capped range), and transfer fee of the mint. Failure patterns: fees taken from different bases on the buy and sell paths; sum of component fees exceeding the total after rounding; the creator fee taken from the output on one path and from the input on the other so a buy then sell cycle nets positive for the creator; fee accumulators counted inside the reserves used for pricing; a fee cap enforced in `create_config` but not `update_config`.
**Check**: write `in = out + reserves_delta + sum(fees)` for each instruction and each rounding case; check each accumulator has exactly one claimant and a claim that cannot withdraw more than accrued; check that fee changes do not apply retroactively to accrued positions.
**Detect**: `fee`, `bps`, `rate`, `creator`, `protocol`, `fund` identifiers across files; diff the buy and sell formulas.

### I6 Bonding-curve math
**Check**:
- *Endpoints*: price and quantities at supply 0, at the maximum tradeable supply, and at the graduation threshold. Division by zero when a reserve reaches 0.
- *Overshoot*: a buy that would cross the graduation threshold must be clamped to the remaining supply and refund the excess, not mint beyond the curve or revert in a way that blocks completion.
- *Sell more than bought*: the curve must never pay out more SOL than the real reserve holds (real-reserve underflow, I12); a sequence of buys and sells must keep `real_sol >= 0`.
- *Integer approximations*: curves implemented with `u128` and truncated divisions drift; compare the integral-based expected cost with the implemented cost over a long random sequence; check that the cost to buy `n` tokens then `n` again equals the cost to buy `2n` within a small stated bound in the protocol's favour.
- *Decimals*: token decimals (usually 6) versus SOL lamports (9): a swapped scale makes the price 1000x wrong.
**Seen**: a flash-loan funded buy at a manipulated price was the core of the Nirvana exploit (about $3.5 million, Jul 2022). Any curve whose price can be moved and then used inside one transaction needs a check that the result is not dependent on same-transaction manipulation (I11).

### I7 Graduation and migration
Graduation moves liquidity from the curve to a DEX pool. This is the highest-value single transaction in a launchpad.
**Check**:
1. **Trigger**: who can call it, and are the on-chain conditions strict (real reserve >= threshold, curve not already complete)? A privileged-only trigger is the pump.fun insider path (G2); a fully permissionless trigger needs the destination to be fixed.
2. **Exactness**: the amounts moved equal the curve's accounting, with rounding in the pool's favour; leftover tokens are burned or locked, not left claimable by the creator.
3. **Destination**: the pool address is derived from fixed seeds; the program verifies the pool is the intended one (G3 chain of trust ends at the config).
4. **Pre-creation**: if an attacker created the pool for this pair first (F4), migration must not revert and must not deposit at the attacker's price. With `initialize_with_permission`, verify that nobody else can create the pair before the launchpad does, and that the permission cannot be replayed.
5. **LP handling**: LP tokens are burned (or provably locked) in the same transaction; check the burn, not just the intention (I10).
6. **Idempotency and double-migration**: a second call after completion must fail; a failed migration must leave the curve in a recoverable state, not half-moved.
7. **Slippage**: the pool-initial price should equal the curve's final price within a tolerance; compare the two.
8. **Mint and freeze authorities** are revoked before graduation (E4).
9. **Account budget**: the migration instruction must fit the account limit on a chain without lookup tables (H2).
**Seen**: pump.fun's May 2024 loss (G2); pump.fun later moved graduation to its own AMM (PumpSwap, Mar 2025), which removed the pool-creation fee and the gap between completion and pool creation, according to The Block's report.

### I8 Creator-fee manipulation
**What**: Creators set a fee within 0 to 5% and receive the fee on trades. Attack shapes:
- creator raises the fee right before a large buy or at graduation (applies to in-flight users);
- creator wash-trades with their own accounts to collect fees and rebates funded by other users;
- fee receiver account is caller-supplied (A3) or the receiver is a fresh account that makes payouts fail (C6), blocking trading;
- the fee is skimmed from the graduation liquidity;
- the creator can claim fees that were not accrued (accumulator and claim path mismatch, I5);
- creator identity can change (authority transfer without the pending-fee settlement, G8).
**Check**: fee fixed at creation or bounded in change rate; fee base identical on buys and sells; payout is pull-based; creator authority transfer settles pending fees first.

### I9 Launch sniping and same-slot effects
**What**: The first buyers on a curve get the lowest price. Attackers bundle "create token" and "buy" in the same transaction or slot, buy through many wallets, or front-run the creator's own initial buy. Without per-wallet caps or an initial-buy rule, supply concentrates immediately and the curve is dumped at the next step.
**Check**: whether the creator's initial purchase is atomic with creation and priced like any other buy; whether any limit exists per wallet or per slot; whether the program leaks an advantage to the creator (free allocation outside the curve).
**Note**: some of this is product design rather than a bug; report as a lead with the economic effect stated.

### I10 Liquidity burn and rug paths
**What**: "LP burned" is a promise that must be verifiable. Check that the burn instruction destroys the LP tokens in the same transaction, that the LP mint authority cannot mint more, that the pool's own withdrawal logic cannot be reached by a hidden authority (an admin `withdraw`), that the creator cannot hold a mint or freeze authority (E4), that LP tokens are not merely transferred to an address the creator controls or to a PDA with a withdraw path.
**Detect**: follow the LP token from mint to burn; then grep every instruction that burns or moves vault tokens and list its authority.

### I11 Intra-transaction price dependence
**What**: Anything that reads the pool or curve price and then acts on it inside the same transaction is exposed to manipulation by the instruction before it (F2, F6). The launchpad reading its own curve price to decide graduation, a fee computed from the post-trade price, or an external program using the pool as oracle.
**Check**: decisions about thresholds should use accumulated, monotone state (total raised), not an instantaneous ratio; spot price must not feed any access or minting decision.

### I12 Virtual versus real reserves
**What**: Curves with virtual reserves compute price from `(vx, vy)` and pay from `(rx, ry)`. Desync cases: a sell that pays based on virtual math more than the real balance (underflow or a revert that traps sellers); a buy that credits real reserves before the transfer; a donation that raises real balance but not state; a graduation that moves real balances but leaves virtual state.
**Check**: assert `rx <= vault_balance` and `payout <= rx` on each sell; check the solvency invariant: sum of all possible sell payouts at the current state does not exceed real SOL (or the system is designed to leave the last sellers short, in which case that must be documented).

### I13 Degenerate pools and amounts
**Check each of**: `amount = 0`, `amount = 1`, `amount = max`; both reserves 0; one reserve 0; `token_0 == token_1`; mints with 0 decimals or 18+ decimals; mint supply 1; pool with only locked LP; withdrawal of the last LP; deposit that mints 0 LP; swap that outputs 0 but takes input (user loses, pool gains: still a problem if the instruction can be used to grief via others' approvals).

### I14 SOL-quoted curves and rent
**What**: If the curve's SOL reserve is stored as lamports in a program account, the rent-exempt minimum is included in `lamports()`. Subtract it when computing the real reserve; never let a sell reduce the account below the rent minimum; wrapped SOL has no rent floor but needs `sync_native` (E7).
**Detect**: `lamports()` used as a reserve; compare against `Rent::get()?.minimum_balance(...)`.

---

## Properties worth turning into tests (hand to `solana-fuzz`)
1. `k_after >= k_before` for swaps (with fee-adjusted balances).
2. No profit from buy-sell or swap-swap cycles at any size, including 1 unit.
3. `sum(all LP) == lp_supply`; LP value per share non-decreasing without donations.
4. `vault.amount >= reserve_books + accrued_fees` after every instruction.
5. Curve solvency: `real_sol_reserve >= max payout` across reachable states.
6. After graduation, curve instructions fail; tokens in the pool + burned + held == total supply.
7. No instruction callable by an admin/creator key reduces a user-funded vault.

## Sources
- MadShield, Raydium CP-Swap audit (MAD_RAY_03, MAD_RAY_04, MAD_RAY_02): https://github.com/raydium-io/raydium-docs/blob/master/audit/MadShield%20Q1%202024/raydium-cp-swap-v-1.0.0.pdf
- Raydium CP-Swap source: https://github.com/raydium-io/raydium-cp-swap
- Raydium CPMM math notes: https://docs.raydium.io/products/cpmm/math
- Nirvana Finance: https://ackee.xyz/blog/2022-solana-hacks-explained-nirvana/
- pump.fun May 2024: https://www.theblock.co/post/295029/pump-fun-post-mortem
- PumpSwap launch: https://www.theblock.co/post/347360/pump-fun-launches-dex-called-pumpswap-to-instantly-migrate-graduated-tokens
- OtterSec SPL swap rounding: https://osec.io/blog/2022-04-26-spl-swap-rounding
