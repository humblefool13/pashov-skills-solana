# G. Privileged keys, upgrades, pauses and off-chain trust

Many of the largest Solana losses were not clever arithmetic. A key was stolen, an insider used a legitimate authority, or a validation chain never reached a trusted root. This module asks: who can do what, with which key, with what delay, and what does the program believe that the chain does not prove.

Table of contents: G1 admin key compromise, G2 privileged migration or withdraw keys, G3 fake-account collateral validation (root of trust), G4 upgrade authority, G5 emergency pause, G6 event and indexer spoofing, G7 parameter setters, G8 authority transfer, G9 permissioned entry points, G10 keys and deployment hygiene.

**Invariant to test everywhere** (if the project states it, and by default for non-custodial protocols): "No admin path may ever move user funds". Treat each privileged instruction as an attack path and trace what it can reach: vault withdrawals, fee redirection, mint authority, pool parameters that change price or fees retroactively, program upgrade.

---

### G1 Admin key compromise (Raydium, Dec 2022)
**What**: One externally owned key held a pool-owner/admin role. After it was compromised (reported cause: malware; the exact route was not confirmed), the attacker used the admin-only `withdraw_pnl` path to drain pools. Reported losses were around $4.4 million (estimates vary; early reports said about $2 million). Raydium removed the admin control over those parameters and moved AMM v4 upgrade control behind a multisig.
**Lesson**: the *capability*, not the key, is the bug. An admin function that can reach user-controlled funds is a design flaw even if the key is "secure".
**Fixed**: no admin instruction may transfer vault tokens to an arbitrary destination; fees go only to a fee receiver stored in state, and changing that receiver is itself two-step and time-locked; admin instructions that change economics (fee rates, curve parameters) have hard caps in code and apply only to future operations; use a multisig (Squads) and a timelock for the roles that remain.
**Detect**: list every instruction gated by an admin/owner/authority check. For each, write which accounts it can move value from or to. Anything that can touch a user-funded vault, a mint, or a recipient it can set is a finding unless capped and delayed.

### G2 Privileged migration or withdraw keys (pump.fun, May 2024)
**What**: A launchpad kept a privileged "withdraw authority" over bonding-curve liquidity. A former employee who still had access used it: reported steps were flash-loaning SOL, buying tokens until bonding curves completed, then withdrawing the curves' liquidity and repaying. About 12,300 SOL (around $1.9 million) was taken before trading was paused.
**Lesson**: a key that can complete or drain curves is as dangerous as the contract's worst bug, and insider access is part of the threat model.
**Fixed**: graduation and migration are permissionless or have exactly one narrowly scoped destination (the DEX pool PDA); the privileged key cannot choose where the liquidity goes; rotate and revoke keys at offboarding; split signing power across a multisig.
**Detect**: find the instruction that moves liquidity out of a curve. Who can call it, what conditions must hold on-chain (not just "authority signed"), and where can the funds go? See I7.

### G3 Fake-account collateral validation / missing root of trust (Cashio, Mar 2022)
**What**: Cashio verified a collateral account by checking that its fields matched fields on *another* account the caller also supplied. All the accounts could be forged together, so the chain was only ever compared to itself. The attacker passed a fake chain, deposited worthless collateral and minted about 2 billion CASH; reported losses range from about $28 million (early reports) to $52.8 million.
**Fixed**: every validation chain must end at an account whose address or authority is hard-coded or stored under admin control (the root). Walk the chain: mint, then pool, then config, then stored admin-set address.
**Detect**: pick the value-bearing input (collateral, LP token, mint amount). Follow how the program decides it is genuine, one hop at a time, until you reach a constant, a PDA derived with known seeds, or an admin-set field. If the walk ends at another caller-supplied account, it is a finding.

### G4 Upgrade authority risk
**What**: The upgrade authority of a program can replace its code. If it is a single hot key, an upgrade is a total-loss path; if it is revoked incorrectly, bugs cannot be fixed; if mismanaged, the program can be closed by mistake. OptiFi (Aug 2022) closed its own mainnet program with `solana program close` while trying to recover a buffer account, which locked about $661,000 in program-controlled accounts.
**Fixed**: upgrade authority held by a multisig with a timelock (or revoked once the program is final); separate the deployer key from the upgrade key; publish a verifiable build (`solana-verify`) so users can compare the deployed hash with source; document the deploy runbook so that `program close` and `set-upgrade-authority` are never typed against the wrong address.
**Detect**: read deployment scripts and docs (`Anchor.toml`, `scripts/`, `docs/`): who holds the upgrade authority at launch, what is the plan to move it, is there a timelock. In the program: is there an admin instruction that CPIs the loader (rare, high risk)?

### G5 Emergency pause abuse
**What**: A pause switch is an admin power. Failures: pause blocks withdrawals and exits (user funds trapped by the admin or by anyone who obtains the key); pause covers swaps but not admin withdrawals; unpause by a different (weaker) key; pause state not checked on a path (a bypass); pause can be triggered by an unprivileged caller.
**Fixed**: pause stops new risk (buys, deposits, creates) but never stops exits for users; pause authority can pause but not unpause (or unpause is delayed); every state-changing instruction either checks the flag or is explicitly exempt with a reason; admin cannot move funds while paused either.
**Detect**: build a table of instructions x `paused` check; for each exempt one, ask whether it moves user funds.

### G6 Event and indexer spoofing
**What**: Off-chain indexers and UIs that parse transaction logs can be fooled: any program can print a string that looks like your program's event; events emitted with `emit!` live in logs that may be truncated at 10 KB; a failed inner CPI can still leave log lines. Indexers that credit balances or show "bought" based on logs can be spoofed or can miss events.
**Fixed**: emit events via self-CPI (`emit_cpi!`) so the instruction data carries the event and the program id is checkable; indexers must verify the program id of the emitting instruction and use account state as the source of truth; never gate on-chain logic on logs.
**Detect**: `emit!` versus `emit_cpi!`; indexer code in `web3/` or SDKs that parses `Program log:`; events carrying amounts that differ from state (MadShield found a swap event logging the wrong vault amounts, a minor record-keeping bug).

### G7 Parameter setters
**What**: Fee and curve parameters changed by an admin or by a token creator (creator fee 0 to 5%) can be abused: raise a fee just before a large exit, change a fee on in-flight positions, set a fee above the cap because the cap is checked in one setter but not another, or set a recipient that makes payouts fail (C6).
**Fixed**: caps enforced in every setter and in `initialize`; changes take effect for new operations only (store the rate that applied at entry) or after a delay; creator-chosen fees are bounded at creation and immutable or bounded in how fast they can change.
**Detect**: for each stored parameter, list all writers (initialize, setters, graduation) and diff their validation.

### G8 Authority transfer
**What**: Setting `admin` to a wrong address locks the program; one-step transfer to a typo is permanent; transfer to `Pubkey::default()` bricks it; `admin` left as the deployer.
**Fixed**: two-step transfer (propose, then accept signed by the new authority); reject the default pubkey; emit an event.

### G9 Permissioned entry points
**What**: Functions such as `initialize_with_permission` rely on a permission account or authority. The check must validate the permission's *address* (PDA or stored key) and *signer*, and the creator-fee/config chosen there must be bounded. A permission check that reads a flag from a caller-supplied account is the Cashio shape (G3).
**Detect**: read the gate line by line: owner, address, signer, replay (can the permission be used twice?).

### G10 Keys and deployment hygiene
Program keypairs, deployer keypairs, `id.json` and `.env` files must not be in the repo. Check `.gitignore`, history, CI logs, and `declare_id!` against the intended address. Verify `Anchor.toml` cluster and program ids per environment.

---

## Sources
- Raydium Dec 2022: https://www.certik.com/blog/raydium-protocol-exploit-incident-analysis
- pump.fun May 2024: https://www.theblock.co/post/295029/pump-fun-post-mortem and https://cointelegraph.com/news/solana-memecoin-tool-pumpfun-claims-ex-employee-exploiter
- Cashio: https://www.certik.com/blog/cashio-app-incident-analysis and https://www.halborn.com/blog/post/explained-the-cashio-hack-march-2022
- OptiFi: https://www.theblock.co/post/166445/optifi-locks-up-661000-by-accidentally-shutting-itself-down
- Verified builds: https://solana.com/developers/guides/advanced/verified-builds
- Squads multisig: https://squads.so
