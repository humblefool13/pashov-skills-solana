#!/usr/bin/env bash
# Step 1 of solana-xray: enumerate programs, sizes, tests, tooling and git history.
# Read-only. No network. Prints labelled sections consumed by the skill.
#
#   enumerate.sh [project-root] [src-root ...]
#
# src-root defaults to the directories that hold program crates (found below).
set -u
ROOT="${1:-.}"; [ $# -gt 0 ] && shift
cd "$ROOT" || { echo "enumerate.sh: cannot cd to $ROOT" >&2; exit 2; }

EXCL=( -not -path '*/target/*' -not -path '*/node_modules/*' -not -path '*/.git/*' \
       -not -path '*/.anchor/*' -not -path '*/dist/*' -not -path '*/.audit-*/*' -not -path '*/.solana-auditor/*' )

echo "=== Toolchain ==="
for f in Anchor.toml rust-toolchain rust-toolchain.toml Cargo.toml; do [ -f "$f" ] && { echo "--- $f"; head -40 "$f"; }; done
[ -f package.json ] && { echo "--- package.json (anchor/solana deps)"; grep -E '"(@coral-xyz/anchor|@solana/web3.js|@solana/kit|@solana/spl-token|litesvm|solana-bankrun|@lightprotocol)[^"]*"' package.json; }

echo "=== Program crates ==="
# a program crate: Cargo.toml mentioning anchor-lang / solana-program / pinocchio, not under target
PROGS=()
while IFS= read -r t; do
  if grep -qE 'anchor-lang|solana-program|pinocchio' "$t" 2>/dev/null && grep -qE 'cdylib|\[lib\]' "$t" 2>/dev/null; then
    d=$(dirname "$t"); PROGS+=("$d"); echo "$d"
  fi
done < <(find . -name Cargo.toml "${EXCL[@]}" | sort)
[ ${#PROGS[@]} -eq 0 ] && echo "(none found; pass src roots explicitly)"
[ $# -gt 0 ] && PROGS=("$@")

echo "=== declare_id ==="
for d in "${PROGS[@]}"; do grep -rnE 'declare_id!|declare_program!' "$d" --include='*.rs' 2>/dev/null | head -3; done

echo "=== Source (with line counts) ==="
for d in "${PROGS[@]}"; do
  find "$d" -type f -name '*.rs' "${EXCL[@]}" -not -path '*/tests/*' -not -name 'build.rs' | sort | xargs wc -l 2>/dev/null
done

echo "=== nSLOC (non-blank, non-comment lines) ==="
total=0
for d in "${PROGS[@]}"; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    t=$(grep -cE '[^[:space:]]' "$f" || true)
    c=$(grep -cE '^[[:space:]]*(//|/\*|\*|\*/)' "$f" || true)
    n=$((t - c)); total=$((total + n)); printf '%s: %d\n' "$f" "$n"
  done < <(find "$d" -type f -name '*.rs' "${EXCL[@]}" -not -path '*/tests/*' -not -name 'build.rs' | sort)
done
echo "TOTAL: $total"

echo "=== Instructions and accounts ==="
for d in "${PROGS[@]}"; do
  ix=$(grep -rhE 'pub fn [a-z_0-9]+.*Context<' "$d" --include='*.rs' 2>/dev/null | wc -l)
  as=$(grep -rhE 'derive\(.*Accounts' "$d" --include='*.rs' 2>/dev/null | wc -l)
  nat=$(grep -rhE 'fn [a-z_0-9]+.*&\[\s*AccountInfo' "$d" --include='*.rs' 2>/dev/null | wc -l)
  echo "$d: anchor_instructions=$ix accounts_structs=$as native_handlers=$nat"
done

echo "=== CPI targets and sysvars (counts) ==="
for d in "${PROGS[@]}"; do
  echo "$d: invoke=$(grep -rhE '\binvoke(_signed)?\(' "$d" --include='*.rs' 2>/dev/null | wc -l) cpi_ctx=$(grep -rhE 'CpiContext' "$d" --include='*.rs' 2>/dev/null | wc -l) remaining_accounts=$(grep -rhE 'remaining_accounts' "$d" --include='*.rs' 2>/dev/null | wc -l) unchecked_accounts=$(grep -rhE 'UncheckedAccount|AccountInfo<' "$d" --include='*.rs' 2>/dev/null | wc -l) token2022=$(grep -rhE 'token_2022|spl_token_2022|TokenInterface|InterfaceAccount' "$d" --include='*.rs' 2>/dev/null | wc -l) unsafe=$(grep -rhE '\bunsafe\b' "$d" --include='*.rs' 2>/dev/null | wc -l)"
done

echo "=== Tests and tooling (file-scan counts, always reliable) ==="
rs_unit=$(grep -rE '#\[test\]|#\[tokio::test\]' . --include='*.rs' 2>/dev/null | grep -v '/target/' | wc -l)
ts_tests=$(find . \( -name '*.ts' -o -name '*.js' \) -path '*/tests/*' "${EXCL[@]}" 2>/dev/null | wc -l)
echo "rust_test_fns: $rs_unit"
echo "ts_js_test_files: $ts_tests"
echo "litesvm: $(grep -rlE 'litesvm' . --include='*.rs' --include='Cargo.toml' --include='*.ts' --include='package.json' 2>/dev/null | grep -v node_modules | wc -l) files"
echo "mollusk: $(grep -rlE 'mollusk' . --include='*.rs' --include='Cargo.toml' 2>/dev/null | grep -v target | wc -l) files"
echo "solana_program_test_or_bankrun: $(grep -rlE 'solana_program_test|solana-bankrun|anchor-bankrun' . --include='*.rs' --include='Cargo.toml' --include='*.ts' --include='package.json' 2>/dev/null | grep -v node_modules | wc -l) files"
echo "proptest_or_quickcheck: $(grep -rlE 'proptest|quickcheck' . --include='*.rs' --include='Cargo.toml' 2>/dev/null | grep -v target | wc -l) files"
echo "trident: $(find . \( -name 'Trident.toml' -o -name 'trident-tests' \) "${EXCL[@]}" 2>/dev/null | wc -l) (Trident.toml / trident-tests)"
echo "cargo_fuzz_or_honggfuzz: $(find . \( -name 'fuzz_targets' -o -name 'hfuzz*' \) "${EXCL[@]}" 2>/dev/null | wc -l)"
echo "certora_cvlr: $(grep -rlE 'cvlr|certora' . --include='*.rs' --include='Cargo.toml' --include='*.conf' 2>/dev/null | grep -v target | wc -l) files"
echo "security_txt: $(grep -rlE 'security_txt|solana-security-txt' . --include='*.rs' --include='Cargo.toml' 2>/dev/null | grep -v target | wc -l) files"
echo "deny_toml: $([ -f deny.toml ] && echo yes || echo no)   cargo_lock: $([ -f Cargo.lock ] && echo yes || echo no)"
echo "ci_workflows: $(ls .github/workflows 2>/dev/null | tr '\n' ' ')"
echo "idl_files: $(find . -name '*.json' -path '*/idl/*' "${EXCL[@]}" 2>/dev/null | wc -l)"
echo "verified_build_hints: $(grep -rlE 'solana-verify|verifiable' . --include='*.md' --include='*.sh' --include='*.yml' --include='*.toml' 2>/dev/null | grep -v node_modules | wc -l) files"

echo "=== Docs and specs ==="
find . \( -iname 'README*' -o -iname '*spec*.md' -o -iname '*design*.md' -o -iname '*whitepaper*' -o -iname 'CLAUDE.md' -o -iname 'chain-facts*.md' -o -iname 'TOOLCHAIN.md' \) "${EXCL[@]}" -not -path '*/node_modules/*' 2>/dev/null | head -40
echo "natspec_style_doc_comments: $(grep -rhE '^\s*///' "${PROGS[@]}" --include='*.rs' 2>/dev/null | wc -l)"

echo "=== Git ==="
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "commit: $(git rev-parse --short HEAD)  branch: $(git rev-parse --abbrev-ref HEAD)"
  echo "total_commits: $(git rev-list --count HEAD)"
  echo "--- contributors (commits)"; git shortlog -sn HEAD 2>/dev/null | head -8
  echo "--- hotspots (most-changed program files)"
  for d in "${PROGS[@]}"; do git log --name-only --format= -- "$d" 2>/dev/null; done | grep -E '\.rs$' | sort | uniq -c | sort -rn | head -10
  echo "--- fix-like commits touching programs (subject matches fix|bug|vuln|exploit|audit|security|hotfix|overflow|rounding)"
  for d in "${PROGS[@]}"; do git log --format='%h %ad %s' --date=short -i -E --grep='fix|bug|vuln|exploit|audit|security|hotfix|overflow|rounding' -- "$d" 2>/dev/null; done | sort -u | head -20
  echo "--- most recent 15 commits touching programs"
  for d in "${PROGS[@]}"; do git log --format='%h %ad %an %s' --date=short -n 15 -- "$d" 2>/dev/null; done | sort -k2,2r -u | head -15
else
  echo "(not a git repository)"
fi
