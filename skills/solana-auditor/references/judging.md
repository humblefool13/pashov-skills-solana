# Finding Validation

Every finding passes four sequential gates. Fail a gate and the finding is **rejected** or **demoted** to a lead; later gates are not evaluated for it. (Gate structure and confidence scoring follow the Pashov Audit Group method, MIT licence.)

You are not defending the code. The gates check that the attacker's claimed exploit fires end to end: anything that interrupts the attack between the attacker's transaction and the harm means the claim does not execute, and only then does it fail.

## Gate 1: Attack execution

Trace the claimed path from the attacker's transaction to the harm. Read every constraint, `require!`, runtime rule and callee check on that path. Confirm none stops the exploit before the harm step.

Things that **do** interrupt an attack (quote the line or rule and trace it):
- an Anchor constraint or manual check that rejects the attacker's account or value;
- the runtime: a non-signer cannot pass `is_signer`; only an account's owner program can debit its lamports or modify its data; a PDA can be signed for only by its deriving program; writable and signer flags come from the transaction message; an account must end with zero lamports or the rent-exempt minimum; the tx must fit the size and compute limits;
- a typed Anchor account (`Account<T>`, `Program<T>`, `Signer`, `Sysvar<T>`) that already performs the claimed missing check;
- an arithmetic check that makes the overflow unreachable for any reachable input.

Things that do **not** interrupt an attack: "the deployer would never do that", "a frontend prevents it", "a user would notice". Speculative interruptions clear the gate.

- A specific guard stops the exploit before harm (quote and trace it): **REJECTED**, or **DEMOTE** if a related smell remains.
- Interruption is speculative: **clears**.

## Gate 2: Reachability

Prove the vulnerable state exists on a live deployment of this program on the target chain.

- Structurally impossible (an enforced invariant prevents it, or the feature needs a program the chain lacks, for example Token-2022 or lookup tables on a chain that lacks them, per the project's chain-facts file): **REJECTED**. A path that only runs with a missing program is still a **lead** if the code does not reject it explicitly, because the chain may add the program later.
- Needs a privileged action outside normal operation: **DEMOTE**.
- Reachable by normal use or common token behaviour (fee-on-transfer, freezable mint, delegated token account, pre-funded address): **clears**.

## Gate 3: Trigger

Prove an unprivileged actor executes the attack.

- Only trusted roles can trigger: **DEMOTE**.
- Unprivileged actor triggers profitably: **clears**.

**Admin-action findings.** Reject unless an unprivileged amplifier is named: a *race* (admin sets X mid-flow, an unprivileged user exploits the window), a *retroactive sweep* (an admin update rewrites a value already credited), an *asymmetric formula* (admin output feeds a formula an unprivileged user profits from), or an *access gap* (missing signer, wrong owner check, tautological auth, missing init guard: the access mechanism itself is the bug).

**Project override (applies when the project states the rule, for example in `CLAUDE.md`, and by default for non-custodial protocols)**: "no admin path may ever move user funds". An admin-reachable instruction that can move, redirect or freeze user-funded tokens or lamports to an address the admin chooses, or that can change the program's code without delay, is reported as a finding on its own, labelled `admin-fund-path`, even with no unprivileged amplifier. Score it by how direct the path is (a single admin call = high confidence). A path that moves only protocol fees to a stored fee receiver is not a finding.

## Gate 4: Impact

Prove material harm to an identifiable victim.

- Self-harm only: **REJECTED**.
- Dust-level with no compounding: **DEMOTE**. (A rounding gain that repeats in a loop compounds: not dust.)
- Material loss, permanent freeze, or blocked exit for identifiable users: **CONFIRMED**.

## Confidence

Start at **100**, deduct: partial attack path **-20**; bounded non-compounding impact **-15**; requires a specific but achievable state **-10**. Confidence >= 75 gets a description and a fix; below 75 gets the description only.

**The threshold is 75.** It is set here and read from here by `finding-format.md` and `scripts/assemble.sh`. Lead promotions below all land at exactly 75; changing the threshold means changing them too.

## Optional proof gate (PoC)

For any CONFIRMED finding at confidence >= 90 whose fix is non-trivial, the orchestrator may ask for an executable proof: a LiteSVM test written in the scratchpad (never inside the audited repo) using the `solana-fuzz` skill's LiteSVM template. A passing exploit test raises confidence to 100 (LiteSVM 0.7.1 does not enforce the rent rule for empty accounts, so rent-DoS claims need a real validator); a test that cannot reproduce it lowers the finding to a lead with the failure noted.

## Safe patterns (do not flag)

- Typed Anchor accounts doing the claimed check: `Account<T>` (owner + discriminator), `Signer`, `Program<T>`/`Interface<T>` (address), `Sysvar<T>`, `Box<Account<..>>`.
- `seeds = [...], bump` re-derivation with a stored canonical bump; `init` (fails on existing accounts).
- `has_one`/`address`/`token::mint`/`token::authority` that cover the edge in question.
- `checked_*` arithmetic with typed errors; `overflow-checks = true` in the release profile with a reason for any bare arithmetic.
- Locking a minimum LP amount forever on first deposit (CP-Swap `lock_lp_amount`).
- `close = authority` with the recipient constrained.
- `reload()` immediately after every CPI that changes an account the code reads next.
- Consistent protocol-favouring rounding, unless compounding or zero-rounding.
- `Clock::get()` and `Rent::get()` (no account to spoof).

## Lead promotion

Before finalizing leads, promote where warranted:
- **Cross-instruction echo.** The same root cause is a FINDING in one instruction: promote every instruction with the identical pattern.
- **Multi-agent convergence.** Two or more agents flagged the same area and the lead was demoted (not rejected): promote to FINDING at confidence 75.
- **Partial-path completion.** The only weakness is an incomplete trace, but the path is reachable and unguarded: promote to FINDING at confidence 75, **description only** (a deliberate exception: no fix block, because the trace the fix would address is incomplete).

## Leads

High-signal trails for manual investigation. No confidence score, no fix: title, code smells, and what remains unverified.

## Do not report

Compute micro-optimizations, naming, comments, missing docs. Admin privileges by design (unless the project override applies). Missing events. Centralization without an exploit path. Implausible preconditions (but fee-on-transfer, freezable mints, delegates, pre-funded addresses and hostile mints ARE plausible for programs that accept arbitrary tokens).
