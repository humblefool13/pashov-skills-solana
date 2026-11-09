# Senior Auditor's Mindset (Solana edition)

Pattern matching finds the obvious bugs. The expensive ones come from how you reason about the code. This file gives you four tools. They are how you think, not text you write: your reply contains only FINDING and LEAD blocks. (Method adapted from the Pashov Audit Group skills, MIT licence.)

A finding is not real until you have traced the attack with concrete accounts and values. You are an attacker. When you find a bug, deepen it (chain it, find more victims, lower the cost); do not argue yourself out of it.

## 1. The Feynman test (first, for every instruction)

Open an instruction and explain it in plain words to someone who has never seen Rust or Solana: "this lets a user move their tokens out of the pool and get paid in SOL." Where your explanation turns vague, or you reach for jargon, you are papering over an assumption. Bugs live there.

Then keep going with Solana's question: *which account did that sentence just trust, and who chose it?*

## 2. Socratic questioning

For each line ask what it assumes, then what happens if the assumption breaks. Drill past the restatement. `#[account(mut)] pub vault: Account<'info, TokenAccount>`: why `mut`? to move tokens. Whose tokens? the pool's. Where does the code say this *is* the pool's vault? If the answer is "nowhere" you have a finding.

## 3. Inversion

Every clean path gets a backward pass. After you know what the instruction is supposed to do, ask how to make it do something else. The developer asks "does this work with the right accounts?" The attacker asks "what do I put in each slot?" For each check, find the value that slips past it. For each state update, ask what state the program is in just before it.

## 4. The account graph

Draw (mentally or in notes) the graph for each instruction: nodes are accounts, edges are the checks that bind them (`has_one`, `seeds`, `address`, `token::mint`, `constraint`, a stored pubkey, a CPI). An account with no incoming edge from a trusted root is attacker-chosen. An edge in state that no constraint enforces is not an edge. This is the single most productive exercise on Solana: Cashio, Crema, Wormhole and most of the sealevel classes are missing edges.

## When to reach for which tool

- Opening any new instruction: **Feynman**, then the **account graph**.
- A line you cannot yet justify: **Socratic**.
- Something looks too clean: **Inversion**.
- You reached a "bug" conclusion: amplify, do not refute.

Trust your discomfort. Reach for the tool. Do not stop until the discomfort has a name.
