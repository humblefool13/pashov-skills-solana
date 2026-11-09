# C. Account lifecycle and lamports

Accounts are created, resized, drained and closed by instructions the attacker can order. This module covers what is left behind, what can be revived, and what the runtime's rent rules let an attacker block.

Table of contents: C1 closing and revival, C2 realloc, C3 size and layout, C4 state-machine and paired-instruction asymmetry, C5 direct lamport manipulation, C6 rent-exempt DoS, C7 lamport donation breaking equality checks.

---

### C1 Closing accounts and revival
**What**: "Closing" an account by moving its lamports out leaves its data and owner in place until the transaction ends. Inside the same transaction, the attacker can refund the lamports (a system transfer to the account) so it survives with the old data, or call the same instruction again against the half-closed account. After the transaction the runtime purges only accounts with zero lamports. An account closed by an older pattern that zeroes lamports but not the data/discriminator can also be re-funded in a later transaction and read as valid.
**Vulnerable**:
```rust
**dest.lamports.borrow_mut() += **acct.lamports.borrow();
**acct.lamports.borrow_mut() = 0;      // data and discriminator untouched
```
**Fixed**: use Anchor's `close = recipient` (zeroes data, writes the closed-account discriminator, assigns to the system program, sweeps lamports). Native: zero the data, `assign` to the system program, `realloc(0)`, then move lamports. Constrain the recipient (`close = authority` with `has_one`). Add a state flag so a closed record cannot be used again.
**Three stages of manual closing, from most to least severe. Report the stage you find.**
1. *Lamports only* (data and discriminator untouched): the account is valid again as soon as it is re-funded in the same transaction, and any later instruction reads stale state. High.
2. *Lamports and data zeroed, no closed marker*: a re-funded account is a blank account owned by the program. If any instruction accepts blank accounts (Anchor `zero`, "initialize if empty" checks) the attacker re-initializes it and resets the state. Medium.
3. *Closed-account discriminator written, but the account is not reassigned to the System program or reallocated to 0 bytes*: Anchor deserialization rejects it, so revival fails, but the account stays allocated and owned by the program; lamports sent to it later cannot be reclaimed unless the program has a defund path (a `force_defund`-style instruction that sweeps accounts bearing the closed marker). Low, a lead.
Anchor's `close = recipient` performs every step. Also ask who is allowed to close: a close instruction with no authority check and an unconstrained recipient lets anyone take the rent of any such account.
**Detect**: grep `lamports.borrow_mut`, `close`, `**`; for each account that is "deleted", verify data wipe, closed marker, owner reassignment, the same-transaction refund path, the authority check and the recipient constraint.
**Seen**: "closing accounts" examples (three variants) in sealevel-attacks; the Solana docs on account lifecycle.

### C2 Realloc issues
**What**: `realloc` changes an account's data length in place. Failures: new bytes not zeroed (Anchor `realloc::zero = false` leaves stale or attacker-shaped bytes visible), shrinking without rent refund, growing without topping up rent (tx fails or account becomes rent-paying), the payer is a user-chosen account, and per-instruction growth is capped at 10,240 bytes.
**Fixed**: `realloc = new_len, realloc::payer = payer, realloc::zero = true`; bound the new length; gate resizes behind the account's authority; refund excess lamports on shrink to the right party.
**Detect**: grep `realloc`, `Vec<`, `String` fields in state structs; check `InitSpace` with `#[max_len]`; check growth paths for an upper bound.

### C3 Account size and layout
**What**: `space` too small (the write panics or truncates, DoS on a specific state), `space` too large, `InitSpace` missed for a `Vec`/`String`, enum variants of different sizes, forgetting the 8-byte discriminator, and zero-copy structs with padding or alignment bugs (`#[repr(C)]` missing, `u128` alignment).
**Detect**: compare `space = 8 + ...` against the struct; check `size_of::<T>()` for zero-copy; look for `Vec` fields without a bound.

### C4 State machines and paired-instruction asymmetry
**What**: Lifecycle bugs live where two instructions should mirror each other (init/close, deposit/withdraw, buy/sell, create/graduate, lock/unlock, open/settle): one updates a counter, flag or accumulator and the other forgets. Typical: a "graduated" flag set but the buy path does not check it; a `complete` boolean that `sell` does not respect; a counter incremented on create but not decremented on close.
**Detect**: for each pair, write the list of state fields each side writes and reads; diff them. Enumerate every instruction against every state of the state machine (pre-launch, active, graduated, paused, closed).

### C5 Direct lamport manipulation
**What**: Programs that move lamports by writing `**lamports.borrow_mut()` bypass the System program's checks. Only the owner can debit; anyone can credit. Mistakes: moving lamports out of an account the program does not own (runtime error, tx-wide failure), breaking the sum of lamports (error), draining a PDA below rent-exempt minimum (account may be purged or rejected), using this to pay fees out of a data account.
**Fixed**: use the System program transfer for system-owned accounts, `try_borrow_mut_lamports` with `checked_sub/add`, and `Rent::get()?.minimum_balance(len)` as a floor.
**Detect**: grep `lamports()`, `borrow_mut_lamports`, `**.*lamports`.

### C6 Rent-exempt DoS from lamport transfers to fresh accounts
**What**: After a transaction, every account must hold either zero lamports or at least the rent-exempt minimum for its size; otherwise the runtime fails the transaction with an insufficient-funds-for-rent error. A payout that transfers a small amount (a creator fee, a refund, a reward) to an address with **zero** lamports (a fresh wallet, an unfunded PDA) fails if the amount is below the minimum for that account (about 0.00089 SOL for a 0-byte account). One failing payout inside a shared instruction blocks every user of that instruction. The mirror image: an attacker pre-funds an address the program wants to `create_account` at, so a naive `create_account` fails because the target already has lamports (Anchor's `init` handles this; hand-written native code often does not).
**Vulnerable**:
```rust
// fee_receiver is caller-supplied or an address that may hold 0 lamports
system_program::transfer(cpi_ctx, creator_fee_lamports)?; // fails when fee < rent minimum and receiver is empty
```
**Fixed**: skip or accumulate sub-minimum payouts (pull-based claims), require recipient accounts to already be funded/initialized, pay into a program-owned accumulator the creator drains later, and for PDA creation use the transfer + allocate + assign sequence rather than a bare `create_account`.
**Detect**: grep every `system_program::transfer` and lamport credit to an account not owned by the program. Ask: can that recipient hold zero lamports, and what is the smallest amount that can reach it (rounding can produce 1 lamport).
**Testing note**: LiteSVM 0.7.1 skips its rent-state check for writable accounts with empty data, so a LiteSVM test will not reproduce the failure for a fresh system account. Prove this class on `solana-test-validator`, or assert the program's own minimum-balance logic.
**Seen**: general runtime rule documented by Solana; Anchor's `init` was changed to survive pre-funded targets for this reason.

### C7 Lamport donation breaking equality checks
**What**: Anyone can send lamports to any account. Code that asserts `account.lamports() == expected`, or derives state from a lamport balance, is broken by a donation. The same applies to token accounts: `vault.amount == tracked` fails after a direct token transfer (see E5).
**Fixed**: use inequalities (`>=`), track accounting in program state, and treat extra lamports/tokens as donations.
**Detect**: grep `lamports() ==`, `lamports() !=`, `.amount ==` in constraints and requires.

---

## Sources
- sealevel-attacks, "closing accounts": https://github.com/coral-xyz/sealevel-attacks
- Solana accounts and rent: https://solana.com/docs/core/accounts
- Anchor constraints (`close`, `realloc`): https://www.anchor-lang.com/docs/references/account-constraints
- Neodyme workshop (lifecycle exercises): https://github.com/neodyme-labs/neodyme-breakpoint-workshop
