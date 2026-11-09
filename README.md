# Pashov Skills for Solana

Solana / SVM ports of the [Pashov Audit Group skills](https://github.com/pashov/skills). The originals are Solidity and EVM only. This repo gives you the same three workflows for **Anchor, native Rust and Pinocchio programs**.

> Unofficial community port. Not affiliated with or endorsed by Pashov Audit Group. The method comes from their work (MIT); the Solana attack-vector library and tooling here are separate. See [Credits](#credits-and-license).

**Original repository: https://github.com/pashov/skills**

An AI audit finds bugs fast. It does not prove their absence, and it is not a substitute for a human audit.

## The skills

| Skill | Solana port of | What it does |
|---|---|---|
| [`solana-xray`](skills/solana-xray) | `x-ray` | Pre-audit briefing written to `x-ray/`: architecture, trust model and privileged roles, PDA and account graph, external CPIs, invariants, ranked attack surface, test and git signals, readiness verdict. |
| [`solana-auditor`](skills/solana-auditor) | `solidity-auditor` | Multi-agent security audit. Twelve parallel specialist attackers, then dedupe, gating, scoring and a report with confidence and fixes. |
| [`solana-fuzz`](skills/solana-fuzz) | `fizz` | Builds a property and invariant test suite (LiteSVM + proptest by default, Trident optional) and turns audit findings into regression tests. |

They chain: **x-ray** finds what matters and lists invariants, **auditor** hunts bugs, **fuzz** proves invariants and locks each finding in as a regression test.

## How it works

### solana-auditor

1. **Scope.** Finds the program crates (`.rs` files, build output and tests excluded), or only the files you name. `Anchor.toml` and `Cargo.toml` stay in scope because they carry upgrade authorities and keys.
2. **Bundle.** Copies the source once into a temp bundle together with the attack-vector library, the judging rules and a short `project-facts.md` it writes from your docs (chain facts, toolchain versions, intended privileged roles).
3. **Twelve attackers in parallel**, all read-only on your repo:
   - account validation, CPI and sysvars, account lifecycle, math and rounding
   - tokens and vaults (including Token-2022), AMM and bonding-curve economics
   - privileged keys, upgrades and governance, DoS and runtime limits
   - a first-principles agent and three gap-hunters (lifecycle and flows, numeric and economic, trust boundaries)
4. **Judge.** The orchestrator deduplicates and runs each candidate through gates: does the runtime or Anchor already prevent it, is it reachable, is there a concrete path with accounts and values. Unproven claims stay as leads. Findings get a confidence score.
5. **Assemble.** A shell script (`assemble.sh`) prints the report from the finding files, so no model judgement can drop a finding. Output goes to `.solana-auditor/`, and `--file-output` also copies `full-report.md` into your working directory.

The attack-vector library (`references/attack-vectors/`) has nine modules, A to I: account validation, CPI and sysvars, state lifecycle, math and accounting, tokens, oracles and MEV, governance and ops, DoS and limits, AMMs and bonding curves. Each ends with links to its sources (Neodyme, MadShield, sealevel-attacks, post-mortems).

### solana-xray

Three phases: enumerate and measure (a script lists crates, instructions, accounts, deps, docs and git history), read sources and synthesize, then write the x-ray files. A threat profile is picked by protocol type (AMM, launchpad, hybrid and others) and weights the attack surface. Privilege is recorded as capability, not just key: what each role can reach, instant versus delayed, single key versus multisig versus PDA.

### solana-fuzz

Preflight (toolchain and build), choose a backend, scaffold the harness, wire setup, add handlers per instruction, discover invariants with specialised passes, implement them, run campaigns, triage failures, and produce deterministic repro tests. The default template is a LiteSVM + proptest crate with a ghost-state model, adversarial-account negative tests and conservation and round-trip properties.

## Install

These are Agent Skills for [Claude Code](https://claude.com/claude-code). Copy the folders you want into your skills directory.

**Global (all projects):**

```bash
git clone https://github.com/humblefool13/pashov-skills-solana.git
cp -r pashov-skills-solana/skills/solana-* ~/.claude/skills/
```

**Per project:**

```bash
mkdir -p .claude/skills
cp -r pashov-skills-solana/skills/solana-* .claude/skills/
```

On Windows, `~/.claude/skills` is `%USERPROFILE%\.claude\skills`. Start a new session so the skills are picked up.

Requirements: `bash`, `python3` and `git` for the helper scripts. For `solana-fuzz` you also need a Rust toolchain, the Solana CLI and Anchor to build your program. On Windows, run the Rust and Solana toolchain in WSL.

## Usage

Run from your Anchor workspace root (the directory with `Anchor.toml`). Invoke by name or in plain words.

```
/solana-xray
x-ray the programs and tell me what the auditors should look at first
```

```
/solana-auditor
run solana-auditor on programs/amm/src/lib.rs programs/amm/src/swap.rs
run solana-auditor with --passes 3 --file-output
```

```
/solana-fuzz
fuzz the amm program and add regression tests for the audit findings
```

### Auditor flags

| Flag | Meaning |
|---|---|
| *(none)* | Audit every program crate in the workspace |
| `file ...` | Audit only the named files |
| `--passes N` | 1 to 5 full passes. Each later pass is told what earlier ones found and hunts new ground. One combined report. Each pass is 12 agents over the full source, so cost scales with N. |
| `--file-output` | Also copy the report into the working directory |
| `--model opus\|sonnet\|haiku` | Model for the 12 agents. Otherwise you are asked once. |

### Tips

- Target the files you are actively changing. Smaller scope gives each agent denser context and better findings.
- Use 3 passes before a release. Output is non-deterministic, so later passes find different things.
- Run **x-ray first**. Its invariants and ranked surface make both the audit and the fuzz suite better.
- Give the skills your project facts: a `CLAUDE.md` or `docs/` with chain facts (which programs exist, SBF version), intended roles and rules such as "no admin path may move user funds". The auditor turns these into a `project-facts.md` for the agents and treats stated rules as intended design.
- Read `full-report.md`. The terminal only shows a summary.

## Differences from the Solidity originals

- Solana's attack surface is the **caller-chosen account list**, so the skills reason over accounts, PDAs and the checks that bind them rather than call graphs and storage slots.
- The vector library is Solana-native: missing owner, signer and discriminator checks, PDA seed and bump issues, arbitrary CPI, stale account data after CPI, duplicate mutable accounts, account closing and revival, Token-2022 extensions, rent and compute limits, upgrade authority, and AMM and bonding-curve rounding.
- Checks respect the **target chain**. Some SVM chains lack Token-2022 or Address Lookup Tables. The skills read your chain facts and reject structurally impossible paths, but keep missing-program paths as leads when the code does not reject them explicitly.
- Fuzzing uses LiteSVM + proptest (and optionally Trident) instead of Echidna and Medusa.

## Limits

- Version pins in `solana-fuzz` (Anchor 0.32.1, Agave 2.3, LiteSVM 0.7.1, proptest 1.10.0) were checked when the skills were written. Trident compatibility with Anchor 0.32.1 is unverified. Re-check pins against your stack.
- LiteSVM is not your chain's validator. Anything version-sensitive, and rent-related DoS, needs a real validator.
- Skills are prompts. Review what they write before trusting it.

## Layout

```
skills/
  solana-xray/       SKILL.md, references/, scripts/
  solana-auditor/    SKILL.md, references/ (attack-vectors, hacking-agents, judging...), scripts/
  solana-fuzz/       SKILL.md, references/, templates/litesvm-proptest/
```

## Contributing

Issues and PRs are welcome: new attack vectors (with a source link and a "Seen" example), corrections to version pins, new threat profiles. Do not copy code from AGPL or non-commercial sources; link them instead.

## Credits and license

- Method, orchestration shape and scoring come from [pashov/skills](https://github.com/pashov/skills) (MIT, pinned at commit `eacfc09`). Its license is kept in [LICENSE-pashov-skills](LICENSE-pashov-skills).
- Trail of Bits' Not So Smart Contracts is AGPL-3.0 and is linked from the vector library, never copied.
- This repository is released under the [MIT License](LICENSE).
