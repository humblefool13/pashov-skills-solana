# D. Math, rounding and accounting

Rust integers wrap silently in release builds unless `overflow-checks = true`, and Solana builds with `cargo build-sbf` use the release profile. Every `+ - * /` on user-influenced values needs a reason. Money math also needs a rounding direction chosen on purpose.

Table of contents: D1 overflow and casts, D2 rounding direction, D3 precision loss, D4 inverse transfer-fee math, D5 fee accounting drift, D6 wide math and curve helpers, D7 time assumptions.

**Rounding rule of thumb** (the protocol must never lose to rounding): amounts the user pays **round up**, amounts the user receives **round down**, shares minted **round down**, shares burned for a fixed payout **round up**, fees charged **round up**, fees refunded **round down**. Test the rule at 1 and 2 base units.

---

### D1 Overflow, underflow and unchecked casts
**What**: `a + b`, `a * b`, `a - b` on `u64`/`u128` wrap in release mode (check `[profile.release] overflow-checks = true` in the workspace `Cargo.toml`; Anchor templates set it). `as u64`, `as u32` truncate silently; `as i64` flips the sign; `u128 as u64` drops high bits.
**Vulnerable**:
```rust
let out = (reserve_out * amount_in / (reserve_in + amount_in)) as u64; // product may exceed u64 before the division
```
**Fixed**: `checked_mul(..).ok_or(ErrorCode::MathOverflow)?`, widen to `u128` (or a 256-bit type) for products, then `u64::try_from(x).map_err(..)?`. Prefer `saturating_*` only when saturation is the intended semantics.
**Detect**: grep bare `+`, `-`, `*`, `as u`, `as i`, `.unwrap()` in files that touch amounts, shares, fees, prices, time. Check the `Cargo.toml` profile. In `u128` code ask whether the *product of two u128* can overflow.
**Seen**: Neodyme lists overflow as a repeat finding (the "Rust protects me" misconception applies only in debug).

### D2 Rounding direction
**What**: A division rounds down by default. Used on the wrong side it hands value to the user each call. Small per-call dust becomes real money through loops, batching, or flash-loaned size.
**Vulnerable**: swap-in uses a ceiling division where the *output* must be rounded down (the user receives more than the curve allows), or a floor on the required input of an exact-out swap.
**Fixed**: separate functions per direction (exact-in rounds the output down; exact-out rounds the required input up), and write the rounding direction as a test.
**Detect**: for each division in a value-moving function, name the party who benefits from the rounded-away remainder. Check the `RoundDirection`/`ceil_div` calls pair with the correct side.
**Seen**: Raydium CP-Swap audit by MadShield, finding MAD_RAY_04 (High): swap-in used a ceiling division on the wrong quantity so users received fewer tokens than the optimum; swap-out was right. Also the SPL token-lending rounding disclosure by Neodyme (rounding on withdrawal produced slightly more tokens than deposited, exploitable in a loop) and the SPL token-swap rounding writeup by OtterSec.

### D3 Precision loss and decimal mismatch
**What**: Division before multiplication (`a / b * c`), fee `amount * bps / 10_000` that truncates to 0 for small `amount`, prices stored with too few decimals, mixing tokens with 6 and 9 decimals, a hard-coded `1e9` where the mint has 6.
**Fixed**: multiply first in a wider type; compute fee with ceiling; use `mint.decimals` from the mint account; reject zero results (`require!(out > 0)`) in swaps, deposits and mints.
**Detect**: grep `/ 10_000`, `/ 1_000_000`, `* 1_000_000_000`, `decimals`; test amounts of 1, 2, 3 base units and `fee_bps * amount < 10_000`.

### D4 Inverse transfer-fee math (Token-2022)
**What**: With the TransferFee extension, the amount that leaves the sender differs from the amount that arrives. A program that must deliver exactly `X` net must solve for the gross amount. The inverse is not a simple division: the fee is capped by `maximum_fee`, the rate can be 100% (10,000 bps), and rounding must not leave the recipient one unit short.
**Seen**: MadShield's Raydium CP-Swap audit, finding MAD_T22_01 (Critical): the SPL Token-2022 helper that computes the inverse fee returned a wrong result for mints with a 10,000 bps fee rate and for the max-fee case, so a transfer could move nothing where a fee top-up was required. Raydium used its own inverse calculation, so the program was not affected, but the lesson is that library inverse helpers need their own tests at the edges (rate 0, 1, 9,999, 10,000 bps; max_fee reached; amount 0 and 1; epoch boundary where the fee schedule changes).
**Fixed**: compute gross = smallest value such that `gross - fee(gross) >= net`; verify by calling the forward fee function on the result; test the cap and the 100% case; reject unsupported fee configs at pool creation if you cannot handle them.
**Detect**: grep `calculate_inverse_fee`, `calculate_inverse_epoch_fee`, `get_transfer_inverse_fee`, `calculate_epoch_fee`. Check every place the vault received amount is assumed equal to the requested amount.
**Fork note**: the upstream Raydium CP-Swap code (checked at commit 609780f) special-cases a 10,000 bps fee (uses `maximum_fee`), calls the library inverse otherwise, then cross-checks it with the forward fee and errors if they differ. It also uses `.unwrap()` on the library results, so an overflow panics instead of returning a typed error: check whether an attacker-chosen mint config can reach those unwraps.
**Chain note**: if the target chain has no Token-2022 program, that code path is dead there, but the pool must still reject Token-2022 mints it cannot price correctly, and the audit should check the rejection.

### D5 Fee accounting drift
**What**: Fees are charged in the wrong asset, on the wrong base, twice, or never reconciled. Examples: the protocol fee is taken from `amount_in` but the k-check uses the pre-fee balance; fees accrue in state but stay inside the reserve used for pricing (LP and fee owners share the same tokens); the creator fee is computed on the post-fee amount for buys and the pre-fee amount for sells; the sum `lp_fee + protocol_fee + creator_fee` exceeds the fee actually collected after rounding.
**Detect**: write the conservation identity for each instruction: `tokens_in = tokens_out + fees + change_in_reserves` and check it holds exactly, including rounding remainder. Verify each accrued-fee counter is excluded from reserves in the pricing path and is paid out from a distinct claim path.

### D6 Wide math, square roots and curve helpers
**What**: `integer_sqrt` rounding direction for LP minting (floor is the safe direction), `pow`/`exp` approximations, `U256` conversions that panic on overflow (a panic is a DoS), signed math (`i128`) where the sign of a delta flips, price-to-tick conversions with off-by-one at boundaries.
**Detect**: grep `sqrt`, `pow`, `U256`, `U128`, `to_u64`, `as_u64`; check that every conversion back to `u64` is `try_from` with an error and that the error path cannot be forced by an attacker in a way that blocks other users.

### D7 Time and slot assumptions
**What**: `Clock::unix_timestamp` is an estimate agreed by validators and can lag or jump; `slot` advances unevenly; epoch boundaries change fee schedules. Code that requires `now > start` for a launch, or uses time deltas of zero for division, breaks at edges. Same-slot repeated calls are normal.
**Fixed**: guard divisions by elapsed time against zero; do not use the timestamp as a randomness source; treat deadlines as ranges, not exact points.
**Detect**: grep `unix_timestamp`, `slot`, `epoch`; look for `/ elapsed`, `/ (end - start)`.

---

## Sources
- MadShield, Raydium CP-Swap v1.0.0 audit (MAD_T22_01, MAD_RAY_03, MAD_RAY_04): https://github.com/raydium-io/raydium-docs/blob/master/audit/MadShield%20Q1%202024/raydium-cp-swap-v-1.0.0.pdf
- SPL Token-2022 inverse fee issue: https://github.com/solana-labs/solana-program-library/issues/6451
- Neodyme, SPL token-lending rounding disclosure: https://neodyme.io/blog/lending_disclosure
- OtterSec, SPL swap rounding: https://osec.io/blog/2022-04-26-spl-swap-rounding
- Neodyme pitfalls (integer overflow): https://neodyme.io/blog/solana_common_pitfalls
- Raydium docs on Token-2022 transfer fees: https://docs.raydium.io/algorithms/token-2022-transfer-fees
