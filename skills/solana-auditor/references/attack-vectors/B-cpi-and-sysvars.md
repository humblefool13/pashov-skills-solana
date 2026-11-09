# B. Cross-program invocation, sysvars, ordering

A CPI hands control and signing power to another program. A sysvar is an account like any other: the caller supplies it, so the program must check which account it is. This module covers calls out, calls in, and the state that goes stale between them.

Table of contents: B1 arbitrary CPI and program-ID spoofing, B2 sysvar spoofing, B3 instruction introspection, B4 signer and privilege forwarding (confused deputy), B5 stale state after CPI and CPI ordering, B6 callbacks and re-entry, B7 return data and log trust.

---

### B1 Arbitrary CPI / program-ID spoofing
**What**: The program invokes "the token program" or "the oracle program" using an account the caller supplied, without checking its address. The attacker deploys a program with the same interface that does nothing (or something worse) and the victim program believes a transfer happened. The callee also receives the caller's signer privileges and PDA seeds.
**Vulnerable**:
```rust
pub token_program: AccountInfo<'info>,                      // any program
let ix = spl_token::instruction::transfer(token_program.key, ..)?;
invoke(&ix, &[src, dst, auth, token_program.clone()])?;     // runs whatever the caller named
```
**Fixed**: `Program<'info, Token>` / `Interface<'info, TokenInterface>` (address check built in), or `require_keys_eq!(token_program.key(), spl_token::ID)`. Use the typed CPI helpers (`token::transfer`) instead of raw `invoke` with a caller-chosen program. Accept both token programs only through `Interface` and then bind them to the mint's owner.
**Detect**: grep `invoke(`, `invoke_signed(`, `CpiContext::new(`; for each, trace where `program` comes from. Any `AccountInfo` or `UncheckedAccount` used as a program is a finding.
**Seen**: "arbitrary CPI" in sealevel-attacks; Neodyme pitfalls ("arbitrary signed program invocation"). Also relevant to the AMM's `initialize_with_permission` flow: the program that creates the pool must be the real one.

### B2 Sysvar spoofing
**What**: A sysvar (Clock, Rent, Instructions, SlotHashes, StakeHistory) passed as an account is trusted without verifying its address. The attacker passes a fabricated account whose data parses as the sysvar. The Wormhole bridge on Solana lost about 120,000 wETH (Feb 2022) because signature verification read the Instructions sysvar through a deprecated helper that did not check the account was the real sysvar. The attacker supplied a forged account that "proved" guardian signatures.
**Vulnerable**:
```rust
let ixs: AccountInfo = next_account_info(iter)?;
let current = solana_program::sysvar::instructions::load_current_index(&ixs.data.borrow()); // no address check
```
**Fixed**: `Sysvar<'info, Clock>` or `Clock::get()?` (reads from the runtime, no account needed); for Instructions use `load_current_index_checked` / `load_instruction_at_checked` (verify the account id) or `require_keys_eq!(ixs.key(), sysvar::instructions::ID)`.
**Detect**: grep `sysvar::`, `load_instruction_at`, `load_current_index`, `from_account_info`. Flag the deprecated unchecked instructions-sysvar helpers (`load_instruction_at`, `load_current_index`), and any sysvar whose bytes are parsed by hand from an `AccountInfo`. The `Sysvar` trait's `Rent::from_account_info` / `Clock::from_account_info` do verify the account id and return an error on mismatch, so they are fine (confirm the call is that trait method). An `AccountInfo` sysvar that is only used for its key or data without either check is the bug.
**Seen**: Wormhole, Feb 2022 (CertiK write-up below); "sysvar address checking" in sealevel-attacks.

### B3 Instruction introspection pitfalls
**What**: Programs that read other instructions in the transaction (to require a preceding ed25519/secp256k1 verification or a paired instruction) can be fooled. Common mistakes: not checking the verified instruction's *program id*, trusting the signature offsets (the signed message can live in a different instruction than the one checked), accepting an absolute index that an attacker reorders, and ignoring that the instruction may be a CPI context.
**Fixed**: check the program id of the introspected instruction, check that the signed message, pubkey and signature offsets all point inside that same instruction's data, use relative indexes, require exactly one such instruction, and bind the signed payload to the current action (domain, nonce, amount).
**Detect**: grep `instructions::`, `Ed25519`, `Secp256k1`, `get_instruction_relative`.
**Seen**: improper instruction introspection is one of the six classes in Trail of Bits' Solana catalog (linked below).

### B4 Signer and privilege forwarding (confused deputy)
**What**: A CPI passes the caller's signer/writable privileges, or the program's PDA signature, to an account the caller chose. The callee then does something the user never agreed to: a PDA that owns a vault signs a transfer to an attacker-named destination; a user's signature meant for action X also authorizes action Y inside the callee.
**Vulnerable**:
```rust
// PDA signs; destination and amount both come from caller
token::transfer(CpiContext::new_with_signer(prog, Transfer{from: vault, to: ctx.accounts.dest.to_account_info(), authority: pda}, signer), amount)?;
```
**Fixed**: constrain the destination to a state-derived account (`token::authority = user`, `address = state.dest`), bound amounts by state, and pass only the accounts the callee needs. Do not forward `remaining_accounts` into a CPI with signer privilege.
**Detect**: for each `invoke_signed`/`new_with_signer`, list which fields are attacker-controlled, and which of them the PDA's power reaches.

### B5 Stale state after CPI, and CPI ordering
**What**: Anchor `Account<T>` and `InterfaceAccount<T>` are snapshots taken at instruction start. A CPI that changes an account (token transfer changes `amount`; a callee changes a state account) does not refresh the snapshot. Code that then reads `vault.amount`, computes a delta, or checks a balance sees the pre-CPI value. The reverse also bites: updating program state **after** an external call that fails open, or computing a price from reserves read **before** the transfer that changes them.
**Vulnerable**:
```rust
token::transfer(cpi_ctx, amount)?;
let received = ctx.accounts.vault.amount - before;   // vault is stale: reads same value as before -> 0
```
**Fixed**: call `ctx.accounts.vault.reload()?` after any CPI that touches the account, before reading it. Compute deltas from balances read immediately before and after. Follow checks-effects-interactions: update accounting, then CPI, then verify invariants against reloaded balances.
**Detect**: for every CPI, list accounts the callee can mutate; search for later reads of those accounts' fields without `reload()`. Check that `exit`-time serialization does not overwrite a callee's changes with a stale copy (for state accounts also mutated inside the callee).
**Seen**: a standard audit finding on every AMM/vault fork; Raydium CP-Swap and Orca-style programs reload vaults after transfers.

### B6 Callbacks and re-entry
**What**: Solana forbids a program from being re-entered through another program, except direct self-recursion. But hooks break the picture: Token-2022 transfer hooks run an arbitrary program during a transfer, and a CPI back into your own program is allowed one level deep. A hook can read half-updated state, or the hook program can be the attacker.
**Fixed**: finish state updates before CPIs that may call hooks; treat extra accounts for hooks as untrusted; if the chain lacks Token-2022 (some SVM chains do not have it), reject any mint carrying a TransferHook extension.
**Detect**: grep `invoke` inside functions that have not yet written their final state; grep `TransferHook` handling; check `is_supported_mint`.

### B7 Return data and log trust
**What**: `get_return_data()` returns the *last* program that set return data, not necessarily the program you called. Logs and events are strings any program can print. Neither is authenticated.
**Fixed**: check the program id returned by `get_return_data()`; never use logs as a source of truth in program logic; for indexers see G6.
**Detect**: grep `get_return_data`, `sol_log_data`, `emit!` consumers.

---

## Sources
- Wormhole (B2): https://www.certik.com/resources/blog/wormhole-bridge-exploit-incident-analysis
- sealevel-attacks, examples "arbitrary CPI" and "sysvar address checking": https://github.com/coral-xyz/sealevel-attacks
- Neodyme pitfalls (arbitrary CPI, signer): https://neodyme.io/blog/solana_common_pitfalls
- Trail of Bits Not So Smart Contracts, Solana (B1, B2, B3; AGPL-3.0, link only): https://github.com/crytic/building-secure-contracts/tree/master/not-so-smart-contracts/solana
- Solana CPI docs: https://solana.com/docs/core/cpi
- Anchor `reload`: https://www.anchor-lang.com/docs/references/account-types
