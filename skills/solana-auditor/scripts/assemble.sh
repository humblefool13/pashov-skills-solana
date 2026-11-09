#!/usr/bin/env bash
# Assembler for solana-auditor. Builds full-report.md from finding block files.
# No model judgment runs here: it parses, sorts, counts and prints.
#
#   assemble.sh --dir .solana-auditor/runs/{stamp} [--copy-to PATH]
#
# Reads   {dir}/scope.tsv       key<TAB>value lines; last line per key wins
#                               keys: name mode files commit agents
#         {dir}/blocks/*.md     finding blocks (see references/finding-format.md)
# Writes  {dir}/full-report.md
# Prints  the full report, or (more than 20 findings) Scope + top 3 + the path.
# Local files only. No network. Deletes nothing outside its own mktemp directory.
set -euo pipefail

THRESHOLD=75   # judging.md sets it; named there and read here
TRIGGER=20     # more findings than this: terminal prints a counted slice

dir=""; copy_to=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --copy-to) copy_to=$2; shift 2 ;;
    *) echo "assemble.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -d "$dir" ] || { echo "assemble.sh: no such directory: $dir" >&2; exit 2; }
blocks="$dir/blocks"
[ -d "$blocks" ] || { echo "assemble.sh: no blocks directory: $blocks" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

scope() {  # last line per key wins
  [ -f "$dir/scope.tsv" ] || return 0
  awk -F'\t' -v k="$1" '$1==k { v=$2 } END { print v }' "$dir/scope.tsv"
}
hdr() {    # hdr FILE KEY: value of a header line, header ends at first blank line
  awk -v k="$2" '
    $0=="" { exit }
    { i=index($0,": "); if (i>0 && substr($0,1,i-1)==k) { print substr($0,i+2); exit } }' "$1"
}
body() {   # everything after the first blank line
  awk 'f{print} /^$/ && !f {f=1}' "$1"
}

name=$(scope name);   [ -n "$name" ]   || name='**name missing**'
mode=$(scope mode);   [ -n "$mode" ]   || mode='**mode missing**'
commit=$(scope commit); [ -n "$commit" ] || commit='none'
files=$(scope files)
agents=$(scope agents)

# ------------------------------------------------------------ index the blocks
: > "$work/findings.idx"; : > "$work/leads.idx"
nf=0; nl=0; bad=0; order=0
shopt -s nullglob
for f in "$blocks"/*.md; do
  order=$((order+1))
  kind=$(hdr "$f" kind); title=$(hdr "$f" title); loc=$(hdr "$f" loc); conf=$(hdr "$f" conf)
  if [ -z "$title" ] || [ -z "$loc" ]; then bad=$((bad+1)); continue; fi
  case "$kind" in
    FINDING)
      case "$conf" in ''|*[!0-9]*) bad=$((bad+1)); continue ;; esac
      if [ "$conf" -lt 1 ] || [ "$conf" -gt 100 ]; then bad=$((bad+1)); continue; fi
      nf=$((nf+1)); printf '%03d\t%06d\t%s\n' "$conf" "$order" "$f" >> "$work/findings.idx" ;;
    LEAD)
      nl=$((nl+1)); printf '%06d\t%s\n' "$order" "$f" >> "$work/leads.idx" ;;
    *) bad=$((bad+1)) ;;
  esac
done
# conf descending, then file order ascending
sort -t$'\t' -k1,1nr -k2,2n "$work/findings.idx" > "$work/findings.sorted"

# ------------------------------------------------------------ build the report
out="$dir/full-report.md"
rep="$work/report.md"
{
  echo "# Solana Security Review: $name"
  echo
  echo "---"
  echo
  echo "## Scope"
  echo
  echo "|  |  |"
  echo "| --- | --- |"
  echo "| **Mode** | $mode |"
  if [ -n "$files" ]; then
    echo -n "| **Files reviewed** | "
    i=0; line=""
    for p in $files; do
      i=$((i+1)); line+="\`$p\`"
      if [ $((i % 3)) -eq 0 ]; then line+="<br>"; else line+=" · "; fi
    done
    line="${line%<br>}"; line="${line% · }"
    echo "$line |"
  fi
  echo "| **Commit** | \`$commit\` |"
  echo "| **Confidence threshold (1-100)** | $THRESHOLD |"
  if [ -n "$agents" ]; then echo "| **Agents** | $agents |"; fi
  msg="$nf findings, $nl leads read"
  if [ "$bad" -gt 0 ]; then msg="⚠️ $msg; $bad block(s) could not be read and are NOT in this report"; fi
  echo "| **Blocks** | $msg |"
  echo
  echo "---"
  echo
  echo "## Findings"
  echo
  if [ "$nf" -eq 0 ]; then
    echo "_None. This scan raised no findings._"
    echo
  else
    n=0
    while IFS=$'\t' read -r conf ord f; do
      n=$((n+1))
      c=$((10#$conf))
      t=$(hdr "$f" title); l=$(hdr "$f" loc); a=$(hdr "$f" agents)
      meta="\`$l\` · Confidence: $c"
      [ -n "$a" ] && meta="$meta · agents: $a"
      echo "[$c] **$n. $t**"
      echo
      echo "$meta"
      echo
      if [ "$c" -ge "$THRESHOLD" ]; then
        body "$f"
      else
        # below threshold: description only (drop everything from the first Fix heading on)
        body "$f" | awk '/^\*\*Fix/ {exit} {print}'
      fi
      echo
      echo "---"
      echo
    done < "$work/findings.sorted"

    echo "Findings List"
    echo
    echo "| # | Confidence | Title |"
    echo "|---|---|---|"
    n=0; shown_sep=0
    while IFS=$'\t' read -r conf ord f; do
      n=$((n+1)); c=$((10#$conf))
      if [ "$c" -lt "$THRESHOLD" ] && [ "$shown_sep" -eq 0 ]; then
        echo "| | | **Below Confidence Threshold** |"; shown_sep=1
      fi
      echo "| $n | [$c] | $(hdr "$f" title) |"
    done < "$work/findings.sorted"
    echo
    echo "---"
    echo
  fi

  echo "## Leads"
  echo
  echo "_Vulnerability trails with concrete code smells where the full exploit path could not be completed. These are not false positives: they are high-signal leads for manual review. Not scored._"
  echo
  if [ "$nl" -eq 0 ]; then
    echo "_None._"
  else
    sort -n "$work/leads.idx" | while IFS=$'\t' read -r ord f; do
      t=$(hdr "$f" title); l=$(hdr "$f" loc); s=$(hdr "$f" smells)
      d=$(body "$f" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
      echo "- **$t** — \`$l\` — Code smells: ${s:-none recorded} — $d"
    done
  fi
  echo
  echo "---"
  echo
  echo "> ⚠️ This review was performed by an AI assistant. AI analysis cannot prove the absence of vulnerabilities and gives no guarantee of security. Use it together with a human audit, tests, fuzzing and monitoring."
} > "$rep"

mv "$rep" "$out.part" && mv "$out.part" "$out"
[ -n "$copy_to" ] && cp "$out" "$copy_to"

# ------------------------------------------------------------ print
if [ "$nf" -le "$TRIGGER" ]; then
  cat "$out"
else
  # Scope table, top 3 of N, path
  awk '/^## Scope/ {p=1} /^## Findings/ {p=0} p' "$out"
  echo
  echo "Findings List — top 3 of $nf"
  echo
  echo "| # | Confidence | Title | Location |"
  echo "|---|---|---|---|"
  n=0
  head -n 3 "$work/findings.sorted" | while IFS=$'\t' read -r conf ord f; do
    n=$((n+1)); echo "| $n | [$((10#$conf))] | $(hdr "$f" title) | \`$(hdr "$f" loc)\` |"
  done
  echo
  echo "**→ Full findings list, every description and every fix:** ${copy_to:-$out}"
  echo
  echo "---"
  echo
  grep '^> ⚠️' "$out"
fi
