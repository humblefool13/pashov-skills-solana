# Shared Scan Rules

## Bundle contents

Your bundle is these concatenated files: the in-scope source (`source.md`), the account map (`account-map.md`, a mechanical list of instructions, accounts and risk signals), the senior-auditor mindset (SOP), your specialty file (WHAT to hunt), the attack-vector modules your specialty needs (the reference library), and these rules.

Read the whole bundle once. It contains all in-scope source. Use Read/Grep only for cross-file searches and out-of-scope context (the `Cargo.toml` of a dependency, a vendored crate, the IDL, a test that shows intended behaviour). Do not re-read in-scope files for the first pass.

The account map is a starting aid, not evidence. It is produced by regular expressions; it misses macros and it flags things that are fine. Verify every claim against the source.

## How to attack a Solana program

Every instruction is a function whose **inputs include the whole account list**, chosen by the caller. For each instruction ask:

1. Which accounts can the caller replace, and what stops them? (Signer, owner, address, seeds, has_one, constraint.)
2. Which accounts can the caller pass **twice** or in an unexpected order?
3. What does the instruction trust that the chain does not prove? (State fields, remaining accounts, a CPI callee's behaviour, a sysvar, a price.)
4. What did the code read *before* a CPI that the CPI may have changed?
5. What is the cheapest sequence of transactions, from an unprivileged wallet, that ends with the attacker holding more value?

## Cross-instruction patterns

When you find a bug in one instruction, **search every other instruction for the same shape**, by name and by code pattern. A missing check on `withdraw` means you check `withdraw_fees`, `close`, `migrate`, `claim` and every sibling. A repeat instance missed is an audit failure.

After scanning: escalate each finding to its worst exploitable variant (a DoS may hide fund theft; a rounding bug may be loopable). Then revisit each function with a finding and attack its other branches.

## Do not report

Admin-only functions doing admin things with no path to user funds. Gas/compute micro-optimizations. Style, naming, missing docs. Self-harm-only bugs (the victim is the caller). "Admin can rug" with no concrete mechanism (but DO report a concrete mechanism: which instruction, which accounts, which funds). Findings that need a compromised validator or a broken runtime.
Anything the safe-patterns list in `judging.md` says is fine.

## Output

Return findings as structured blocks. FINDINGs have a concrete, unguarded, exploitable path. LEADs have a real code smell with a partial path: default to LEAD over dropping.

**Every FINDING needs a `proof:` field**: concrete values, an account list, a transaction sequence, or quoted code lines from the source. No proof means LEAD, with no exceptions.

**One vulnerability per item.** Same root cause = one item. Different fixes needed = separate items.

```
FINDING | program: name | instruction: ix_name | bug_class: kebab-tag | group_key: program | instruction | bug-class
path: caller (accounts they control) -> instruction -> state/token change -> impact
proof: account list, values, or quoted lines demonstrating the bug
description: one sentence
fix: one-sentence suggestion (optionally a short diff)

LEAD | program: name | instruction: ix_name | bug_class: kebab-tag | group_key: program | instruction | bug-class
code_smells: what you found
description: one sentence: the trail and what remains unverified
```

`group_key` drives deduplication: `program | instruction | bug_class`. For native programs use the handler function name as `instruction`. Use the bug-class labels from the vector library when one fits (for example `missing-signer`, `missing-owner`, `account-substitution`, `type-confusion`, `non-canonical-bump`, `arbitrary-cpi`, `sysvar-spoof`, `stale-after-cpi`, `closing-revival`, `duplicate-mutable`, `rounding-direction`, `overflow`, `fee-drift`, `vault-desync`, `freeze-authority`, `mint-authority`, `token-2022-extension`, `first-depositor`, `pool-precreation`, `oracle-manipulation`, `slippage`, `admin-fund-path`, `upgrade-authority`, `pause-trap`, `rent-dos`, `compute-dos`, `reinitialization`). Agents may add custom fields.

## Language (mandatory)

Your `description:` and `fix:` sentences are pasted into the report. Write them in plain technical English: one sentence, 25 words or fewer, active voice, simple present tense, no `-ing` clause, no metaphor, no severity adjectives. Name who acts and what they get. Example: "Any caller can pass their own token account as the vault, so the program pays out to the attacker." Keep identifiers, the bug-class label and quoted code exactly as in the source. Your `path:` and `proof:` fields are working notes: keep them concrete.
