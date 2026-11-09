# F. Oracles, ordering attacks and pool bootstrap

An attacker on Solana can place transactions in an exact order inside a block (bundles), borrow without collateral inside one transaction (flash loans), and watch pending pool creations. Treat every price the program reads, and every first interaction with an empty pool, as attacker-influenced unless proven otherwise.

Table of contents: F1 oracle validation, F2 spot price and TWAP manipulation, F3 slippage and sandwiching, F4 pool pre-creation and initial price, F5 first depositor and LP inflation, F6 flash loans and just-in-time liquidity, F7 pools as oracles for other programs.

---

### F1 Oracle validation (Pyth, Switchboard, custom feeds)
**What**: The program reads a price from an account without checking all of: account owner (the oracle program), feed id (is it the feed for *this* asset), staleness (publish time within N seconds / slots), confidence interval relative to price, status/trading flag, exponent handling, and non-positive prices. Missing any one lets a stale, wrong-asset, or wide-confidence price drive a trade or a liquidation.
**Fixed**: use the vendor SDK's checked getter (`get_price_no_older_than(clock, max_age)` style), compare feed id to a stored constant, require `conf * K <= price`, reject `price <= 0`, scale by exponent in wide math, and decide what happens on failure (revert; never fall back to a spot price silently).
**Detect**: grep `load_price`, `PriceUpdateV2`, `get_price`, `price_feed`, `switchboard`, `publish_time`, `conf`, `expo`; check each field in the list.
**Seen**: Mango Markets (Oct 2022) was drained by moving a thin market that fed the oracle (F2); validation gaps in oracle reads recur in lending audits.

### F2 Spot price and TWAP manipulation
**What**: Any price derived from a pool's reserve ratio can be moved inside one transaction with enough capital (borrowed with a flash loan or simply bought). A TWAP over too short a window, a window that can be reset, or a cumulative-price accumulator that is only updated on trade (stale in quiet blocks) lets an attacker steer it cheaply. Thin liquidity sets the cost of manipulation: cost ~ liquidity depth x desired move.
**Mango Markets (Oct 2022)**: the attacker took opposite sides of a large MNGO perpetual position with two accounts, bought spot MNGO on thin venues to push the reference price up several-fold, then borrowed against the inflated position and left with the pool's assets. Loss figures differ by source (about $100 million to $116 million).
**Fixed**: use an external oracle with a confidence band for anything that gates borrowing or minting; cap price change per slot; require TWAP windows long relative to the manipulation cost; never use the same-slot reserve ratio as a price for another action in the same transaction.
**Detect**: grep reserve-ratio expressions (`reserve_a * x / reserve_b`) used outside the swap itself; check window length and update rules of any accumulator (`last_update`, `cumulative`); ask who can call the updater and when.

### F3 Slippage parameters and sandwiching
**What**: A swap or buy executes at whatever price the pool has when it lands. An attacker who sees the pending transaction (public mempool relays, or leader-adjacent infrastructure) places a trade before it to move the price and a trade after it to return, keeping the difference. The only defence in the program is the caller's bound, so the program must enforce one that cannot be left at zero.
**Vulnerable**:
```rust
pub fn swap(ctx: Context<Swap>, amount_in: u64, minimum_amount_out: u64) -> Result<()> { // 0 accepted
    ...
}
```
**Fixed**: require `minimum_amount_out` (or `maximum_amount_in` for exact-out) to be checked **against the value actually delivered** (post-fee, post-transfer-fee); consider rejecting `0` for user-facing instructions; add a deadline in slots or time for orders that can sit; compare against a protocol-level price bound for admin/keeper-driven swaps (`amountOutMin = 0` for a keeper is a self-sandwich). Check bonding-curve buys the same way (`max_sol_cost`, `min_tokens_out`).
**Detect**: grep `minimum_amount_out`, `min_out`, `max_in`, `max_sol_cost`, `slippage`; confirm the check uses the net amount after fees and compares in the right direction. Look at graduation and migration swaps and rebalance paths run by a privileged key.
**Seen**: ordinary AMM risk; Raydium's docs describe bounds on the exact-out path (compare `maximum_amount_in` with the gross including transfer fee).

### F4 Pool pre-creation and initial price front-running
**What**: Permissionless pool creation lets the first caller choose the initial ratio (price). An attacker can:
1. create the pool for a token pair **before** the intended creator, at a hostile price, so the honest creator's transaction fails or lands on a pool whose price the attacker already set (the attacker then takes the first swaps at the real market price);
2. create the canonical pool for a launchpad token **before graduation**, so the migration step, which assumes the pool does not exist, reverts forever (DoS) or deposits liquidity at the attacker's price;
3. pre-fund the PDA address so a naive `create_account` fails (C6).
**Fixed**: derive the pool address from `(config, mint_a, mint_b)` so there is exactly one pool per pair and config; for launchpad tokens use `initialize_with_permission` or an equivalent gate so only the launchpad's authority can create the pair before graduation; make migration idempotent (if the pool exists with the expected state, join instead of reverting) and check the initial price at the point of deposit against the curve's final price; require the creator to supply both amounts in one transaction and bound the deviation from an expected ratio when the creator is a program.
**Detect**: read the pool-creation instruction as "who can call it, with what price, before whom". Read the migration instruction as "what if the pool already exists with a different price".
**Seen**: this is the failure mode motivating permissioned pool creation in launchpad-to-DEX flows; the project's launchpad design (graduation through `initialize_with_permission`) addresses it, so audit that the permission cannot be bypassed and that the call is not blockable.

### F5 First depositor and LP inflation
**What**: With zero or tiny LP supply, the first depositor sets the share price. A donation of tokens directly to the vault raises the value of each share unit while shares stay at 1, so later depositors receive `floor(deposit * supply / assets) = 0` shares and the first depositor redeems everything.
**Fixed**: lock a minimum liquidity amount forever (mint to a dead address or just never mint it) so supply can never be tiny; compute shares from internal books, not from `vault.amount`; reject deposits that mint zero shares; use virtual shares/assets offset.
**Seen**: ERC-4626 style bug class; Raydium CP-Swap computes initial LP as `sqrt(a*b)` and locks 100 LP units (`lock_lp_amount = 100`) in the upstream commit audited (609780f). Check that every pool-creation path of the fork keeps that lock, including `initialize_with_permission`, and that the lock is large enough for the token decimals in use.
**Detect**: find every `if supply == 0` branch; test first deposit 1 unit, donation of 1e12, second deposit 1e6.

### F6 Flash loans and just-in-time liquidity
**What**: A transaction can borrow, trade, and repay. JIT liquidity adds liquidity just before a large swap and removes it right after to capture fees. Lending programs offer flash loans in-transaction (reports name Solend as the lender in the Crema and Nirvana exploits). Any rule that holds "between transactions" fails inside one.
**Fixed**: do not depend on a balance being stable across the transaction; apply minimum holding periods for fee accrual if JIT matters; recompute fees per share at entry (checkpoint) rather than paying the pool's accumulated fees to the newest LP.
**Seen**: Crema Finance (Jul 2022, about $8.7 million): forged tick data (A2) combined with flash-loaned liquidity inflated fee claims. Nirvana (Jul 2022, about $3.5 million): a flash loan was used to buy at a manipulated price from the protocol and sell out.

### F7 Pools as oracles for other programs
**What**: If another program (a lending market, a launchpad, a vault) reads this pool's spot price, manipulating the pool steals from that program. Even if this program does not consume prices, the project's own launchpad and DEX may read each other's state.
**Fixed**: expose a manipulation-resistant price (TWAP with a long window, or none) and document that spot is not an oracle; do not read the DEX pool's spot price inside the launchpad to value anything.
**Detect**: list cross-program reads of reserves, `lp_supply`, curve state.

---

## Sources
- Mango Markets: https://www.certik.com/blog/mango-market
- Crema Finance: https://www.halborn.com/blog/post/explained-the-crema-finance-hack-july-2022 and https://ackee.xyz/blog/2022-solana-hacks-explained-crema-finance/
- Nirvana Finance: https://ackee.xyz/blog/2022-solana-hacks-explained-nirvana/ and https://www.certik.com/blog/nirvana-finance-incident-analysis
- Raydium docs on exact-out and transfer-fee bounds: https://docs.raydium.io/algorithms/token-2022-transfer-fees
- Pyth integration guidance: https://docs.pyth.network/price-feeds/use-real-time-data/solana
- Raydium CP-Swap source (initialize, `lock_lp_amount`): https://github.com/raydium-io/raydium-cp-swap
