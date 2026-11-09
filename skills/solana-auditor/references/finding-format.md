# Finding and Output Format

This file is a format specification for the skill, not a report. It defines the shape of one finding block and of the assembled output.

## The one rule

**The output must not overstate its own coverage.** It may print less than the scan found (a dead agent, an unreadable block) and must say so in words. It may never look like it printed more. (Rule and output shape follow the Pashov Audit Group skills, MIT licence.)

## Who writes what

The orchestrator writes one **finding block file** per gated finding or lead into `.solana-auditor/runs/{stamp}/blocks/` during Turn 4, while it still has the context. `scripts/assemble.sh` then builds the final document from those files with no model judgment: it sorts by confidence, applies the 75 threshold, counts, and prints. The orchestrator does not re-word, re-order or summarize the assembled output.

## Finding block file

File name: `NN.md` (any unique name). Header lines first, then a blank line, then the body.

```
kind: FINDING
conf: 90
title: Pool accepts any token account as the vault
loc: amm::swap_base_input
key: amm|swap_base_input|account-substitution
agents: 5

**Description**
Any caller can pass their own token account as the vault, so the program pays out to the attacker.

**Fix**

```diff
- pub vault: Account<'info, TokenAccount>,
+ #[account(mut, address = pool.token_0_vault)]
+ pub vault: Account<'info, TokenAccount>,
```
```

Rules:
- `kind` is `FINDING` or `LEAD`. A LEAD has no `conf` line and no Fix; it carries `smells:` and a one- or two-sentence body.
- `conf` is an integer 1 to 100 from `judging.md`. At or above 75 the block carries a Fix; below 75 it carries the description only. A promoted partial-path finding at 75 has no Fix by design.
- `title`: one clause, 12 words or fewer, present tense, naming the defect or its effect.
- `loc`: `program::instruction` spelled as the source spells it.
- `key`: `program|instruction|bug-class` (the dedup key).
- The body uses the headings `**Description**` and `**Fix**` exactly.
- Language: plain technical English as in `shared-rules.md` (one sentence, 25 words or fewer, active voice, no severity adjectives). The diff inside the Fix block is code, pasted verbatim from the agent's fix.
- If two or more distinct fixes exist for one instruction, write each as `**Fix (Option A: label)**` and `**Fix (Option B: label)**`, verbatim from the agents.

Lead block example:

```
kind: LEAD
title: Graduation may revert if the pool address is pre-funded
loc: launchpad::graduate
key: launchpad|graduate|pool-precreation
smells: raw create_account to a PDA, no check for existing lamports
agents: 2

Migration calls create_account for the pool PDA without handling a pre-funded address. We did not confirm that the DEX program rejects a pre-funded target.
```

## Assembled output (what `assemble.sh` emits)

```
# Solana Security Review: {project}

## Scope
|  |  |
| --- | --- |
| **Mode** | default / filename |
| **Files reviewed** | `a.rs` · `b.rs` (3 per line) |
| **Commit** | abc1234 |
| **Confidence threshold (1-100)** | 75 |
| **Blocks** | N findings, M leads read; K unreadable |

## Findings
[95] **1. Title**
`program::instruction` · Confidence: 95 · agents: 5
**Description** ... **Fix** ...
---
(blocks under 75: Description only)

Findings List
| # | Confidence | Title |
|---|---|---|
| 1 | [95] | Title |
|   |      | **Below Confidence Threshold** |
| 2 | [60] | Title |

## Leads
- **Title** — `program::instruction` — Code smells: ... — description

> AI-generated review. It cannot prove the absence of vulnerabilities. Use it together with a human audit, tests, fuzzing and monitoring.
```

Rules the assembler holds:
- Findings sorted by confidence, highest first; ties keep file order.
- The "Below Confidence Threshold" row appears whenever at least one finding is under 75.
- Empty cases say so in words: `_None. This scan raised no findings._` and `_None._` under Leads.
- A block the assembler cannot parse is counted in the Scope `Blocks` row; it never silently disappears.
- More than 20 findings: the terminal prints the Scope table, a "top 3 of N" list and the path of `full-report.md`; the file always holds everything.
- `--file-output` copies `full-report.md` to `{project}-solana-audit-{stamp}.md` in the working directory. A copy, not a second build.
