# A. Account validation

Solana programs receive every account from the caller. The runtime checks only that signers signed and that writable accounts are writable. Everything else (who owns an account, what it contains, whether it is the account the code expects) is the program's job. A bug in this module usually means "the caller swapped in an account the code trusts without checking".

Each vector: what it is, vulnerable pattern, fixed pattern, how to detect, where it has been seen. Code is illustrative Anchor/Rust, written for this file.

Table of contents: A1 signer, A2 owner, A3 address and relations, A4 type confusion, A5 PDA seeds and sharing, A6 bump canonicalization, A7 ambiguous seeds, A8 `remaining_accounts` and unchecked accounts, A9 Anchor footguns, A10 duplicate mutable accounts, A11 initialization hijack.

---

### A1 Missing signer check
**What**: An instruction treats an account as an authority (owner, admin, payer of a refund) but never requires that account to sign. Anyone can pass the victim's pubkey.
**Vulnerable**:
```rust
#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(mut, has_one = authority)]
    pub vault: Account<'info, Vault>,
    pub authority: AccountInfo<'info>, // has_one ties the key, nobody proves consent
}
```
**Fixed**: `pub authority: Signer<'info>` (native: `if !authority.is_signer { return Err(MissingRequiredSignature) }`).
**Detect**: for every field named `authority`, `owner`, `admin`, `creator`, `user`, `payer`, `delegate`, check the type is `Signer` or a manual `is_signer` exists. `has_one`/`address` alone proves identity, not consent. In native code grep `is_signer`.
If the instruction only reads or logs, report a lead; the same pattern on a state-changing sibling is a finding.
**Seen**: the most common critical finding class on Solana; see Neodyme's pitfalls post and the signer-authorization example in sealevel-attacks. Links at the end of the file.

### A2 Missing owner check
**What**: The program deserializes an account's data without confirming the account is owned by the expected program. The attacker creates their own account (owned by anyone) holding bytes that parse as the expected struct.
**Vulnerable**:
```rust
let cfg = Config::try_from_slice(&ctx.accounts.config.data.borrow())?; // AccountInfo, no owner check
require_keys_eq!(cfg.admin, ctx.accounts.signer.key());
```
**Fixed**: use `Account<'info, Config>` (checks owner = this program and the discriminator), or `require_keys_eq!(*acc.owner, crate::ID)`. For SPL accounts use `Account<TokenAccount>`/`InterfaceAccount` (owner is Token or Token-2022).
**Detect**: any `AccountInfo`/`UncheckedAccount` whose data is parsed (`try_from_slice`, `bytemuck`, `Pack::unpack`, `load`), any `try_borrow_data` followed by deserialization with no `owner` comparison.
**Seen**: Crema Finance (Jul 2022) accepted a forged tick account; a Solend config-update bypass (Aug 2021) accepted an attacker-owned lending market. Both are described in the sources below.

### A3 Missing address or relation check (account substitution)
**What**: The account has the right type and owner but is the wrong *instance*. Examples: another user's vault, a different pool's mint, a fee-receiver chosen by the caller, a config belonging to another market.
**Vulnerable**:
```rust
pub vault: Account<'info, Vault>,          // any vault
pub vault_token: Account<'info, TokenAccount>, // any token account, not vault.token
```
**Fixed**: `has_one = vault_token`, `constraint = vault.pool == pool.key()`, `address = config.fee_receiver`, `token::mint = pool.mint`, `token::authority = pool_authority`. Check every cross-reference in both directions.
**Detect**: draw the account graph. Every edge that is read from state (`state.x_account`) must be enforced by a constraint on the account passed for `x`. Fields that are stored but never compared are the bug.
**Seen**: Cashio (Mar 2022) validated the collateral chain only against itself, never against a trusted root, which let a forged chain through. See G3.

### A4 Account type confusion (missing or ignored discriminator)
**What**: Two account types with the same or compatible layout can be passed for each other. Native programs that tag nothing, or Anchor programs that bypass `Account<T>` with manual deserialization, accept `UserProfile` where `AdminConfig` is expected.
**Vulnerable**:
```rust
let admin = Admin::try_from_slice(&info.data.borrow())?; // no tag check; User layout also parses
```
**Fixed**: Anchor `Account<T>`/`AccountLoader<T>` verify the 8-byte discriminator. Native: write a type byte or tag on init, check it on every read, and make layouts differ. When using `try_from_slice_unchecked` or `bytemuck::from_bytes`, check the length and tag explicitly.
**Detect**: grep `try_from_slice`, `try_from_slice_unchecked`, `from_bytes`, `unpack_unchecked`, `AccountInfo.data`. Compare struct layouts for prefix-compatibility (same first N bytes and sizes).
**Seen**: "type cosplay" in sealevel-attacks; Neodyme pitfalls lists it as one of the five repeat findings.

### A5 PDA seed validation: missing seeds, PDA sharing, seed collision between roles
**What**: A PDA is used as authority or as data account but the program does not re-derive it from seeds, or the seeds are too coarse. If one PDA signs for many users (for example seeds = `[mint]` over a shared vault), any user who can make the program sign with it can touch every other user's funds.
**Vulnerable**:
```rust
// authority PDA seeds = [pool_mint]; used for every user's token account
let seeds = &[ctx.accounts.pool_mint.key().as_ref(), &[bump]];
token::transfer(CpiContext::new_with_signer(.., signer = &[seeds]), amount)?; // destination chosen by caller
```
**Fixed**: include the principal in the seeds (`[b"vault", pool.key(), user.key()]`), re-derive with `seeds = [...], bump = state.bump` on the account, and bind destination accounts via `has_one`/`token::authority`.
**Detect**: for each `invoke_signed`/`CpiContext::new_with_signer`, list what the signer PDA authorizes and who chooses the accounts it acts on. Narrow seeds so one PDA = one trust domain. Also ask where the seed inputs come from: if they are fields of a state account the caller can create (a `pool` they initialize with `mint = victim_mint`, `vault = victim_vault`), the PDA is only as unique as that account's binding. A `has_one` between the pool and the vault does not help when the pool itself is attacker-made; bind the pool by `seeds`/`bump` or store the PDA authority in the vault.
**Seen**: "PDA sharing" example in sealevel-attacks; Neodyme's workshop exercises.

### A6 Bump seed canonicalization
**What**: `create_program_address` accepts any bump that lands off-curve. If the caller supplies the bump, several PDAs exist for the same seeds. Uniqueness assumptions break (two "singleton" accounts, two vaults per user).
**Vulnerable**:
```rust
let pda = Pubkey::create_program_address(&[b"vault", user.as_ref(), &[bump_from_ix_data]], &crate::ID)?;
```
**Fixed**: derive with `find_program_address` once and store the canonical bump; later read `bump = account.bump` in the constraint. Never accept a bump from instruction data for an existing PDA. Anchor `seeds=[..], bump` (no value) on `init` finds the canonical bump.
**Detect**: grep `create_program_address`, `bump` as instruction argument, `bump = <arg>`.
**Seen**: sealevel-attacks "bump seed canonicalization"; the Solana docs on PDAs.

### A7 Ambiguous seed concatenation
**What**: Seeds built from variable-length inputs collide: `["pool", "ab", "c"]` equals `["pool", "a", "bc"]` when joined. An attacker picks inputs so that two logical keys map to the same PDA.
**Vulnerable**: `seeds = [b"market", name.as_bytes(), symbol.as_bytes()]`.
**Fixed**: use fixed-width seeds (pubkeys, u64 little-endian), add a length prefix or separator that user input cannot contain, or hash the user string.
**Detect**: any seed made from `String`, `&[u8]`, or `Vec<u8>` of user choice next to another variable-length seed. Note the 32-byte-per-seed and 16-seeds limits.

### A8 `remaining_accounts` and unchecked accounts
**What**: `ctx.remaining_accounts`, `UncheckedAccount`, and `AccountInfo` skip Anchor's checks. Every `/// CHECK:` comment is a promise the code must keep manually. A frequent failure: the code loops over remaining accounts and trusts their owner, signer flag, mint, or order.
**Vulnerable**:
```rust
for acc in ctx.remaining_accounts.iter() {
    let ta = TokenAccount::try_deserialize(&mut &acc.data.borrow()[..])?; // no owner check, no mint check
    total += ta.amount;
}
```
**Fixed**: for each remaining account verify `owner`, `key` (derive or compare with state), mint, writable/signer flags, and uniqueness (see A10). Prefer typed accounts for fixed counts; for variable counts, bound the loop and validate each item with the same constraints a typed account would give.
**Detect**: grep `remaining_accounts`, `UncheckedAccount`, `AccountInfo<'info>`, `/// CHECK`. For each, find the exact line that checks the property the comment claims.
**Seen**: Anchor and Solana security checklists name this as a top audit finding. A common project rule: never use `remaining_accounts` without explicit validation.

### A9 Anchor-specific footguns
- `init_if_needed`: allows re-entry into an initialized account; if fields are re-set in the handler, an attacker resets state (see A11). Require it only for ATAs.
- `#[account(mut)]` on an `AccountInfo` payer without `Signer`.
- `Account<'info, T>` fields declared **after** a CPI that changes them are stale (see B5).
- Constraint order: `constraint = ...` expressions evaluate in field order; a check that reads a later account's data may read it before validation.
- `close = recipient` sends lamports to any account the caller names unless constrained (see C1).
- `Program<'info, System>` vs `AccountInfo` for programs (see B1).
- `Interface<'info, TokenInterface>` accepts both token programs: check `token_program.key()` against the mint's owner.
- `realloc` constraint needs `realloc::payer`, `realloc::zero` (see C2).
- `AccountLoader` zero-copy: discriminator is checked on `load()`, not on `load_unchecked()`.
**Detect**: read every `#[derive(Accounts)]` struct top to bottom and ask what is **not** constrained.

### A10 Duplicate mutable accounts
**What**: The same account passed for two `mut` parameters. The program updates a local copy of each, then the later write wins: `from` and `to` both point at one balance, so a "transfer" mints value.
**Vulnerable**:
```rust
let mut a = Balance::load(&ctx.accounts.from)?;  a.amount -= x;
let mut b = Balance::load(&ctx.accounts.to)?;    b.amount += x;   // same account: net +x
a.save(); b.save();
```
**Fixed**: `require_keys_neq!(from.key(), to.key())` or `constraint = from.key() != to.key()`. With Anchor `Account<T>` each handle serializes on exit, so the last one written wins. Anchor 1.0.0 rejects duplicate mutable accounts by default (opt out with `dup`, per its changelog), but Anchor 0.32.x and earlier do not: check by hand. For pools, reject `token_0 == token_1` and vault == user account.
**Detect**: any instruction with two or more `mut` accounts of the same type or both token accounts of the same mint.
**Seen**: "duplicate mutable accounts" in sealevel-attacks.

### A11 Initialization hijack and reinitialization
**What**: `initialize` can be called by anyone, called twice, or called with attacker-chosen authority before the real deployer. The first caller owns the program's config. Native programs that test `data_is_empty()` but not a stored flag can be re-initialized after the account is zeroed or re-sized.
**Vulnerable**:
```rust
pub fn initialize(ctx: Context<Init>, admin: Pubkey) -> Result<()> { ctx.accounts.config.admin = admin; Ok(()) }
// Init uses init_if_needed or an AccountInfo; no deployer/upgrade-authority gate
```
**Fixed**: `#[account(init, ...)]` (fails if the account exists), require the signer to equal a hard-coded deployer or the program's upgrade authority, store an `initialized` flag, never use `init_if_needed` for config. For pool creation see F4.
**Detect**: find all `init`/`initialize`/`create_*` instructions and ask who may call, how many times, and whether a front-runner can pick parameters first. When a flag guards initialization (`discriminator`, `initialized`, `is_set`), read the direction of the test: `if !flag { return Err }` rejects fresh accounts and lets initialized ones be overwritten, the reverse of what is intended. Run the instruction mentally twice on one account.
**Seen**: "initialization" example in sealevel-attacks; pool and config front-running risks in Raydium-style permissionless pools.

---

## Sources (links for further reading; text above is original)
- Neodyme, Solana smart contracts: common pitfalls: https://neodyme.io/blog/solana_common_pitfalls
- sealevel-attacks (examples of A1, A2, A4, A5, A6, A10, A11): https://github.com/coral-xyz/sealevel-attacks
- Trail of Bits, Not So Smart Contracts (Solana): https://github.com/crytic/building-secure-contracts/tree/master/not-so-smart-contracts/solana (AGPL-3.0, linked only)
- Anchor account constraints: https://www.anchor-lang.com/docs/references/account-constraints
- Crema Finance (A2): https://www.halborn.com/blog/post/explained-the-crema-finance-hack-july-2022
- Solend market-owner bypass (A2, secondary write-up): https://hackmd.io/@prastut/r1wMdtcf3
- Cashio (A3): https://www.certik.com/blog/cashio-app-incident-analysis
