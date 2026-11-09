# E. Tokens, mints and vaults

A token account is just an account the program is told about. Its owner field says which token program holds it; its `owner` data field says who may spend it; its `mint` field says which asset it holds; its `delegate`, `close_authority` and (Token-2022) extensions say who else has power over it. Programs that move or hold tokens must check all of these.

Table of contents: E1 token account authority, E2 mint and token-program checks, E3 delegate and close authority, E4 freeze and mint authority (pools, launchpads), E5 vault reconciliation, E6 Token-2022 extension hazards, E7 native SOL and wrapped SOL, E8 ATA and token-program confusion, E9 self-transfer and aliasing.

---

### E1 Token account authority and ownership
**What**: The program takes a token account from the caller and moves tokens out of it, or credits tokens into it, without checking `token_account.owner` (the data field) equals the expected authority. Out-of-pool vaults, user-chosen destination accounts, and "fee receiver" accounts are the usual targets.
**Vulnerable**:
```rust
pub vault: Account<'info, TokenAccount>,   // any token account
pub user_dest: Account<'info, TokenAccount>, // credit goes to an account of the attacker's choosing (fine) but withdraw amount is not tied to who signed
```
**Fixed**: `token::authority = pool_authority` on the vault, `token::mint = pool.mint`, and for user accounts `constraint = user_ta.owner == user.key()` where the instruction pays out on behalf of that user. Re-derive vault addresses from seeds where possible so there is exactly one valid vault.
**Detect**: for every `Account<TokenAccount>`/`InterfaceAccount<TokenAccount>`, list which of `mint`, `authority`, `address` constraints exist; absent ones are findings unless a state comparison does the same job.

### E2 Mint and token-program checks
**What**: Two accounts of different mints are mixed in one operation (fake mint pool, collateral of mint B used as if mint A), or a program id for the token program is not checked (B1). With Token-2022 present there are two token programs; the mint's owner decides which one applies.
**Fixed**: `token::mint = expected_mint`; for pools `token_0_mint != token_1_mint` and enforce an ordering; `token::token_program = token_program`; compare `mint.to_account_info().owner` with `token_program.key()`.
**Detect**: draw the mint graph: every token account in an instruction must connect to a mint stored in state or derived from seeds. This is the Cashio failure shape (G3): a chain of validations that never reached a trusted root.

### E3 Delegate and close authority
**What**: A token account can have a `delegate` with a spending allowance and a `close_authority`. A vault that was funded by a user account with a delegate, or whose delegate was set by an earlier owner, lets the delegate spend or close it. For user-supplied token accounts the program may rely on `amount` while a delegate can spend the same tokens, and an account with a `close_authority` set can be closed and recreated.
**Fixed**: for program-owned vaults, require `delegate.is_none()` and `close_authority.is_none()` at creation or when first bound; use freshly created PDA-owned vaults (the program creates them, so they start clean); do not treat a delegated allowance as ownership.
**Detect**: grep `delegate`, `close_authority`, `Approve`, `SetAuthority`; check vault creation (who funded and initialized it), and whether a pre-existing ATA is adopted as a vault.

### E4 Freeze authority and mint authority (pools and launchpads)
**What**:
- *Freeze authority*: if a mint has a freeze authority, its holder can freeze any token account, including the pool vault. A frozen vault blocks every swap/withdraw (permanent DoS) and can be used to extort or trap liquidity.
- *Mint authority*: if a mint has an active mint authority, its holder can mint unlimited tokens, dilute the pool's counterpart asset and drain the quote side by selling. This is the classic rug on an open pool.
- For a **launchpad**, the program must itself revoke both authorities (set to `None`) once the supply is minted, and prove it before opening trading.
**Fixed**: in pool creation, `require!(mint.freeze_authority.is_none())` and `require!(mint.mint_authority.is_none())` for non-whitelisted mints (the quote asset such as wrapped SOL or a stablecoin may be allowed explicitly); in a launchpad, mint the full supply into the curve and call `set_authority(MintTokens, None)` and `set_authority(FreezeAccount, None)`, then re-read the mint. Reject Token-2022 mints with `PermanentDelegate`, `TransferHook` or `DefaultAccountState = Frozen` unless supported.
**Detect**: grep `freeze_authority`, `mint_authority`, `COption`, `set_authority`, `initialize_mint`. In pool initializers look for a check on both mints; in the launchpad look for the revocation and for who holds the mint authority between creation and revocation.
**Seen**: widespread. In Raydium CP-Swap (checked at commit 609780f), `is_supported_mint` returns `true` for every plain SPL Token mint, freezable or mintable included; only Token-2022 mints go through an extension allowlist. A fork that wants safe open pools must add the authority check itself; for launchpad-graduated pools the launchpad can instead prove both authorities are revoked before it calls `initialize_with_permission`.

### E5 Vault reconciliation
**What**: The program keeps its own books (`total_deposited`, reserves, `virtual_reserve`) and also holds real tokens. Books and balance can diverge: direct transfers to the vault (donation) raise the balance only; fee-on-transfer or rounding lowers it; a bug that credits the books without receiving tokens, or sends tokens without debiting the books, drains value.
**Fixed**: define one source of truth for each quantity and assert the relationship after every state-changing instruction: `vault.amount >= books.reserve + books.accrued_fees` (reload first, see B5). Use balance deltas (`before` and `after` reload) for amounts received. Decide how donations are treated (ignored, swept to treasury, or credited to LPs) and test it.
**Detect**: for each instruction, list every token movement and every state variable changed; confirm they match one-to-one. The lamport version of this (SOL vault holding rent plus user funds) needs the rent floor excluded: `lamports - rent_minimum >= owed`.

### E6 Token-2022 extension hazards
Applies if the target chain has Token-2022 (some SVM chains do not ship it; verify against the chain's facts file, and verify the program rejects Token-2022 mints cleanly rather than assuming they never appear).
| Extension | Hazard | Check |
|---|---|---|
| TransferFeeConfig | received != sent; inverse math (D4); fee schedule changes at epoch boundary; withheld fees stuck in vault accounts | use balance deltas; handle max_fee and 10,000 bps; handle `withdraw_withheld` |
| TransferHook | arbitrary program runs on each transfer; may revert (DoS) or read half-updated state | reject unless the hook program is allow-listed; extra accounts are untrusted |
| PermanentDelegate | delegate can move or burn tokens from any holder, including the vault | reject for pool mints |
| MintCloseAuthority | mint can be closed when supply is 0 and re-created with different properties | reject or monitor |
| DefaultAccountState (Frozen) | new token accounts start frozen; pool vaults frozen on creation | reject or thaw path required |
| NonTransferable | transfers fail; pool locks | reject |
| ConfidentialTransfer | balances hidden; accounting checks can't read amounts | reject |
| InterestBearing / ScaledUiAmount | UI amount differs from raw; display-based math misprices | use raw amounts only |
| Pausable | issuer can pause transfers; vault DoS | reject for open pools |
| MetadataPointer / TokenMetadata | multiple accounts can claim to describe a mint; names/symbols spoof | do not trust metadata for identity |
| CpiGuard | blocks some CPI transfers from user accounts; tx fails unexpectedly | handle the error; do not assume CPI transfers always succeed |
Use an allowlist of extensions, not a denylist. Check the mint's extension list at pool creation **and** treat a later extension change as impossible only for extensions that cannot be added after init.
**Seen**: Neodyme's Token-2022 article ("don't shoot yourself in the foot with extensions") and its 2024 audit of Token-2022; MadShield MAD_T22_01 (D4).

### E7 Native SOL and wrapped SOL
**What**: Wrapped SOL is a token account of the native mint whose `amount` must be synced with lamports (`sync_native`); closing it returns lamports to the owner. Mistakes: crediting `amount` without `sync_native`, closing a WSOL vault and losing the rent, treating a lamport donation to a WSOL account as a deposit (or missing it), and assuming a wrapped-native mint exists on the chain (the target chain's facts say it is missing, so a quote-asset design must not depend on it).
**Detect**: grep `native_mint`, `sync_native`, `close_account`, `is_native`; verify the WSOL path is reachable or cleanly rejected.

### E8 ATA and token-program confusion
**What**: Associated token accounts are derived from `[wallet, token_program, mint]`. Creating an ATA with `create` fails if it exists (a front-runner creating it first makes your `create` revert: DoS); `create_idempotent` avoids this. Passing a Token-2022 ATA where a Token ATA is derived produces a different address.
**Fixed**: use `init_if_needed` with `associated_token::*` constraints for ATAs only, or `create_idempotent`; derive with the right token program.

### E9 Self-transfer and aliasing
**What**: Source and destination token accounts the same (A10), or the user token account equal to the pool vault. Transfers to self pass runtime checks and can distort accounting that assumes two distinct balances changed.
**Fixed**: `constraint = from.key() != to.key()` and `constraint = user_ta.key() != vault.key()`.

---

## Sources
- Neodyme, SPL Token-2022 extensions: https://neodyme.io/blog/token-2022
- Solana token extensions docs: https://solana.com/docs/tokens/extensions
- MadShield / Raydium CP-Swap audit (MAD_T22_01): https://github.com/raydium-io/raydium-docs/blob/master/audit/MadShield%20Q1%202024/raydium-cp-swap-v-1.0.0.pdf
- Cashio (E2, mint graph): https://www.halborn.com/blog/post/explained-the-cashio-hack-march-2022
- SPL Token program reference: https://spl.solana.com/token
