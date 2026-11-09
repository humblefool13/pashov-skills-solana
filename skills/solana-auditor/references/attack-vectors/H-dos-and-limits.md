# H. Resource limits and denial of service

The runtime enforces hard limits. A program that meets a limit does not degrade; the transaction fails. If an attacker can push shared state toward a limit, one user's action blocks everyone else's. Also check each limit against the target chain: some chains have no Address Lookup Tables, so transactions are legacy-format only and the account limit is tighter.

Table of contents: H1 compute budget, H2 transaction size and account count, H3 stack and heap, H4 account growth and unbounded state, H5 panics as DoS, H6 CPI depth and nested cost, H7 blocking dependencies.

Limits to keep in mind (confirm against the Solana docs and the chain's runtime version; they can change between releases): default 200,000 compute units per instruction and 1.4 million per transaction; 1,232 bytes per serialized transaction; 4 KiB stack frame per function; 32 KiB default heap; CPI depth 4; account data up to 10 MiB, with at most 10,240 bytes of growth per instruction; up to 16 seeds of at most 32 bytes each per PDA.

---

### H1 Compute budget exhaustion
**What**: Loops proportional to attacker-influenced data (number of remaining accounts, vector length, ticks crossed, orders matched), repeated hashing or sqrt, large deserialization and many CPIs consume compute. A state that makes a critical instruction cost more than the maximum budget freezes it permanently (liquidation, claim, graduation).
**Vulnerable**:
```rust
for holder in state.holders.iter() { distribute(holder)?; } // holders: Vec grows without bound
```
**Fixed**: bound every loop by a constant; paginate; use pull-based claims; keep per-user state in per-user PDAs instead of vectors in a shared account; test worst-case compute with LiteSVM and compare against the budget.
**Detect**: grep `for `, `while`, `.iter()`, `.retain`, `.sort`, `Vec<` in instruction handlers; trace what controls the length. Look for `msg!` of large data and format strings on hot paths (they cost compute).

### H2 Transaction size and account count
**What**: An instruction that needs many accounts (multi-hop swap, batch operation, a CPI chain with many token accounts) can exceed 1,232 bytes; without lookup tables the practical ceiling is about 30 to 35 accounts. If the protocol's own flow, such as graduation or a migration that creates a pool, needs more accounts than fit, the flow cannot run on this chain.
**Fixed**: design instructions around the legacy limit; split flows across multiple instructions with a state machine; avoid requiring `remaining_accounts` lists of arbitrary length.
**Detect**: count the accounts in the largest `#[derive(Accounts)]` struct plus CPI-only accounts; add signatures (64 bytes each), the blockhash, and instruction data. Treat anything above about 30 accounts as unverified until a simulation proves it.

### H3 Stack and heap limits
**What**: Anchor `Accounts` structs with many `init` fields, large local arrays, and big `Box`-less structs overflow the 4 KiB stack frame. The error appears at runtime ("stack offset exceeded") and may only show in the BPF build. MadShield found exactly this in Raydium CP-Swap's `initialize` (five `init` constraints in one Accounts context) and recommended creating the vaults inside the handler instead (MAD_RAY_02, Critical, resolved). Heap exhaustion (`Vec` growth, `String` building) fails at 32 KiB.
**Fixed**: `Box<Account<..>>`/`Box<InterfaceAccount<..>>` for large accounts, split large instructions, create accounts in the handler, avoid large stack arrays, test the real SBF binary (not only `cargo test`).
**Detect**: count fields in the biggest Accounts structs, check for `Box<>`; run the instruction on a LiteSVM test with the compiled `.so`.

### H4 Account growth and unbounded state
**What**: A shared account that grows per user (a `Vec<Pubkey>` of participants, a growing order list) eventually cannot be realloc'd (10 KiB per instruction, 10 MiB total) or makes every access cost more. An attacker adds junk entries at minimal cost.
**Fixed**: per-user PDAs; fixed-size ring buffers; caps with explicit errors; charge a deposit that outlives the attack's value.
**Detect**: `Vec`, `realloc`, `push` in state structs.

### H5 Panics as DoS
**What**: `.unwrap()`, `.expect()`, array indexing `v[i]`, slicing `data[a..b]`, division by zero, `U256` conversions and `try_into().unwrap()` panic on bad data. A panic aborts the transaction with an opaque error. If an attacker can set the data that triggers it, for example by creating a pool with a zero reserve, a weird mint, or an account near a boundary, the shared instruction fails for every user.
**Fixed**: return typed errors (`ok_or(ErrorCode::..)?`); validate divisors; use `get(i)`.
**Detect**: grep `unwrap()`, `expect(`, `[` indexing in non-test code; for each, ask whether an attacker controls the value.

### H6 CPI depth and nested cost
**What**: The CPI stack is limited to 4 levels. Programs that CPI into other programs that CPI again (router, then AMM, then token, then hook) can hit the limit when composed by a third party; a program that is typically called at depth 2 may be uncallable from deeper contexts. Compute is shared across the whole stack.
**Detect**: map the deepest realistic call chain, including Token-2022 transfer hooks if present.

### H7 Blocking dependencies
**What**: A shared instruction that depends on something an attacker can poison (a frozen vault, a blacklisted token account, an oracle that reverts, a receiver that cannot accept lamports) fails for everyone. Examples in AMM and launchpad domains: a creator-fee payout to an account below the rent minimum (C6), a frozen quote vault (E4), a pool-creation PDA pre-funded by an attacker (C6/F4), a graduation that requires a pool address already taken (F4).
**Fixed**: isolate optional payouts so they cannot revert the main action (accumulate and let the beneficiary pull); handle dependency failure explicitly.

---

## Sources
- Solana program limitations and compute: https://solana.com/docs/programs/limitations and https://solana.com/docs/core/fees
- MadShield, Raydium CP-Swap (MAD_RAY_02 stack limit): https://github.com/raydium-io/raydium-docs/blob/master/audit/MadShield%20Q1%202024/raydium-cp-swap-v-1.0.0.pdf
- Solana transaction size: https://solana.com/docs/core/transactions
