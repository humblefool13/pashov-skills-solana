#!/usr/bin/env python3
"""Mechanical account map for Anchor and native Solana programs.

Read-only. Standard library only. No network. Writes Markdown to stdout.

Usage: python3 account_map.py <root-or-file> [<root-or-file> ...]

It lists, per instruction, every account with its type and the constraints
that bind it, plus line-level risk signals. It is built from regular
expressions: it misses macro-generated code and it over-flags. The auditor
must confirm every row in the source. It exists so agents start from the
same account graph instead of rebuilding it.
"""
import os
import re
import sys

SKIP_DIRS = {"target", "node_modules", ".git", "tests", "test", "migrations",
             ".anchor", "dist", "build", "out", ".solana-auditor", "fuzz", "trident-tests"}
AUTH_NAMES = re.compile(r"(authority|owner|admin|signer|payer|creator|delegate|depositor|"
                        r"user|trader|buyer|seller|governance|manager|operator|keeper)", re.I)

SIGNALS = [
    ("remaining_accounts", r"remaining_accounts"),
    ("raw-invoke", r"\binvoke(_signed)?\s*\("),
    ("cpi-context", r"CpiContext::new(_with_signer)?\s*\("),
    ("sysvar-unchecked-helper", r"load_(instruction_at|current_index)\s*\("),
    ("sysvar-from_account_info(id checked by trait)", r"::from_account_info\s*\("),
    ("sysvar-use", r"sysvar::"),
    ("create_program_address", r"create_program_address"),
    ("find_program_address", r"find_program_address"),
    ("manual-deserialize", r"try_from_slice(_unchecked)?\s*\(|unpack_unchecked|from_bytes\s*\(|try_deserialize\s*\("),
    ("unwrap/expect", r"\.unwrap\(\)|\.expect\("),
    ("narrowing-cast", r"\bas\s+(u8|u16|u32|u64|i8|i16|i32|i64|usize)\b"),
    ("bare-arith", r"[\w\)\]]\s*[-+*]\s*[\w\(]"),
    ("init_if_needed", r"init_if_needed"),
    ("lamports-direct", r"lamports\s*\.\s*borrow_mut|try_borrow_mut_lamports|\*\*.*lamports"),
    ("realloc", r"realloc"),
    ("close", r"\bclose\s*=|\.close\s*\("),
    ("emit", r"\bemit!|emit_cpi!|sol_log_data"),
    ("time", r"unix_timestamp|Clock::get|\.slot\b|\.epoch\b"),
    ("return-data", r"get_return_data"),
    ("authority-change", r"set_authority|SetAuthority|freeze_authority|mint_authority"),
    ("token2022", r"token_2022|spl_token_2022|TransferFee|TransferHook|get_extension"),
    ("unsafe", r"\bunsafe\b"),
    ("division", r"[^/]/[^/*=]"),
    ("pda-bump-arg", r"bump\s*=\s*[a-z_]+\b(?!\s*\.)"),
]
# bare-arith and division are noisy; they are reported as counts per file, not lines.
COUNT_ONLY = {"bare-arith", "division"}


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def strip_line_comments(src):
    """Blank out // comments (but keep /// doc lines intact for CHECK detection)."""
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("//") and not s.startswith("///"):
            out.append("")
        else:
            out.append(line)
    return "\n".join(out)


def lineno(src, pos):
    return src.count("\n", 0, pos) + 1


def read_balanced(s, i, open_c, close_c):
    depth = 0
    j = i
    in_str = False
    while j < len(s):
        c = s[j]
        if in_str:
            if c == "\\":
                j += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return len(s) - 1


def parse_struct_body(body):
    """Yield (name, type, attrs, doc) for each field of an Accounts struct."""
    i, n = 0, len(body)
    attrs, docs = [], []
    while i < n:
        if body[i].isspace():
            i += 1
        elif body.startswith("///", i):
            j = body.find("\n", i)
            j = n if j < 0 else j
            docs.append(body[i + 3:j].strip())
            i = j
        elif body.startswith("//", i):
            j = body.find("\n", i)
            i = n if j < 0 else j
        elif body.startswith("#[", i):
            j = read_balanced(body, i + 1, "[", "]")
            attrs.append(re.sub(r"\s+", " ", body[i + 2:j]).strip())
            i = j + 1
        else:
            j, depth = i, 0
            while j < n:
                c = body[j]
                if c in "<([":
                    depth += 1
                elif c in ">)]":
                    depth -= 1
                elif c == "," and depth <= 0:
                    break
                j += 1
            decl = re.sub(r"\s+", " ", body[i:j]).strip()
            m = re.match(r"(?:pub\s+)?(\w+)\s*:\s*(.+)$", decl)
            if m:
                yield m.group(1), m.group(2), attrs, docs
            attrs, docs = [], []
            i = j + 1


def bound_by(ty, attr_text):
    out = []
    base = re.match(r"(?:Box<)?\s*(\w+)", ty)
    base = base.group(1) if base else ""
    if base in ("Account", "InterfaceAccount", "AccountLoader", "LazyAccount"):
        out.append("typed(owner+disc)" if base != "InterfaceAccount" else "typed(interface)")
    if base == "Signer":
        out.append("Signer")
    if base in ("Program", "Interface"):
        out.append("program-id")
    if base == "Sysvar":
        out.append("sysvar-id")
    for key in ("seeds", "bump", "has_one", "address", "constraint", "owner",
                "token::mint", "token::authority", "token::token_program",
                "associated_token::mint", "associated_token::authority",
                "mint::authority", "mint::freeze_authority", "mint::decimals",
                "close", "realloc", "signer", "dup"):
        # keys that take a value are only matched in `key =` form, so a field named `owner`
        # inside a constraint expression is not mistaken for the `owner = ...` constraint
        if key in ("signer", "dup"):
            pat = r"(^|[\s,(])" + re.escape(key) + r"(\s*,|\s*\)|\s*$)"
        elif key == "bump":
            pat = r"(^|[\s,(])bump(\s*=|\s*,|\s*\)|\s*$)"
        else:
            pat = r"(^|[\s,(])" + re.escape(key) + r"\s*="
        if re.search(pat, attr_text):
            if key in ("signer",) and "Signer" in ty:
                continue
            out.append(key)
    # normalise
    seen, res = set(), []
    for x in out:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res


def analyze_accounts_structs(src, path):
    structs = {}
    for m in re.finditer(r"#\[derive\([^\]]*\bAccounts\b[^\]]*\)\]", src):
        rest = src[m.end():]
        sm = re.match(r"\s*(?:#\[[^\]]*\]\s*)*(?:pub\s+)?struct\s+(\w+)\s*(?:<[^>]*>)?\s*\{", rest)
        if not sm:
            continue
        open_pos = m.end() + sm.end() - 1
        close_pos = read_balanced(src, open_pos, "{", "}")
        body = src[open_pos + 1:close_pos]
        fields = []
        for name, ty, attrs, docs in parse_struct_body(body):
            atext = " ; ".join(attrs)
            flags = bound_by(ty, atext)
            is_mut = bool(re.search(r"(^|[\s,(])mut(\s|,|\)|$)", atext)) or "init" in atext
            has_init = bool(re.search(r"(^|[\s,(])init(_if_needed)?(\s|,|\)|$)", atext))
            is_signer = "Signer" in ty or "signer" in flags
            base = re.match(r"(?:Box<)?\s*(\w+)", ty)
            base = base.group(1) if base else ""
            notes = []
            if base in ("AccountInfo", "UncheckedAccount"):
                bound = [f for f in flags if f in ("address", "constraint", "owner", "seeds", "has_one")]
                if not bound:
                    notes.append("UNCHECKED-TYPE")
            if AUTH_NAMES.search(name) and not is_signer and base in ("AccountInfo", "UncheckedAccount", "SystemAccount") \
                    and not re.search(r"(mint|vault|account|ata|token|pool|config|state|info|program)$", name, re.I):
                notes.append("authority-like-not-signer?")
            if "init_if_needed" in atext:
                notes.append("init_if_needed")
            if has_init:
                notes.append("init")
            if docs and any("CHECK" in d for d in docs):
                notes.append("CHECK-doc: " + " ".join(docs)[:90])
            fields.append(dict(name=name, ty=ty, mut=is_mut, signer=is_signer,
                               flags=flags, notes=notes, attrs=atext))
        # duplicate-mutable risk
        by_type = {}
        for f in fields:
            if not f["signer"] and not re.match(r"(Program|Interface|Sysvar|SystemAccount)", f["ty"]):
                by_type.setdefault(re.sub(r"\s+", "", f["ty"]), []).append(f)
        for ty, fs in by_type.items():
            if len(fs) > 1 and not any("dup" in x["flags"] for x in fs):
                for f in fs:
                    f["notes"].append("same-type-as-another-field(dup risk" + (", mut" if f["mut"] else "") + ")")
        structs[(path, sm.group(1))] = dict(fields=fields, line=lineno(src, m.start()), path=path)
    return structs


def analyze_handlers(src, path):
    """Anchor handlers: pub fn x(ctx: Context<S>, ...) inside #[program]."""
    handlers = []
    for m in re.finditer(r"pub\s+fn\s+(\w+)\s*(?:<[^>]*>)?\s*\(\s*(?:mut\s+)?ctx\s*:\s*Context\s*<\s*(?:'[^,>]+,\s*)*(\w+)", src):
        handlers.append((m.group(1), m.group(2), lineno(src, m.start())))
    return handlers


def analyze_native(src, path):
    """Native handlers: fn taking &[AccountInfo]."""
    out = []
    for m in re.finditer(r"fn\s+(\w+)\s*(?:<[^>]*>)?\s*\(([^)]*&\s*\[\s*AccountInfo[^)]*)\)", src, re.S):
        start = m.end()
        bm = re.search(r"\{", src[start:])
        if not bm:
            continue
        open_pos = start + bm.start()
        close_pos = read_balanced(src, open_pos, "{", "}")
        body = src[open_pos:close_pos]
        out.append(dict(
            name=m.group(1), line=lineno(src, m.start()),
            is_signer=len(re.findall(r"\.is_signer", body)),
            owner=len(re.findall(r"\.owner\b", body)),
            key_cmp=len(re.findall(r"\.key\b", body)),
            next_account=len(re.findall(r"next_account_info", body)),
            invoke=len(re.findall(r"\binvoke", body)),
            writable=len(re.findall(r"is_writable", body)),
        ))
    return out


def scan_files(roots):
    files = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue
        for dp, dn, fn in os.walk(root):
            dn[:] = [d for d in dn if d not in SKIP_DIRS]
            for f in fn:
                if f.endswith(".rs") or f == "Cargo.toml" or f == "Anchor.toml":
                    files.append(os.path.join(dp, f))
    return sorted(files)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    files = scan_files(argv[1:])
    rs = [f for f in files if f.endswith(".rs")]
    tomls = [f for f in files if f.endswith(".toml")]
    print("# Account Map (mechanical; confirm every row in the source)\n")
    # Cargo / Anchor facts
    print("## Build facts\n")
    for t in tomls:
        txt = read(t)
        facts = []
        for key in ("anchor-lang", "anchor-spl", "solana-program", "spl-token", "spl-token-2022", "pinocchio"):
            mm = re.search(r"^\s*" + re.escape(key) + r"\s*=\s*(\"[^\"]+\"|\{[^}]*\})", txt, re.M)
            if mm:
                facts.append(f"{key} = {mm.group(1)}")
        if re.search(r"\[profile\.release\]", txt):
            oc = re.search(r"overflow-checks\s*=\s*(true|false)", txt)
            facts.append("release overflow-checks = " + (oc.group(1) if oc else "NOT SET (defaults to false)"))
        elif "[workspace]" in txt or "[package]" in txt:
            if "anchor-lang" in txt or "solana-program" in txt:
                facts.append("no [profile.release] in this file")
        if facts:
            print(f"- `{t}`: " + "; ".join(facts))
    print()
    all_structs, all_handlers, native, signals, counts = {}, [], [], [], {}
    for p in rs:
        raw = read(p)
        src = strip_line_comments(raw)
        all_structs.update({k: v for k, v in analyze_accounts_structs(raw, p).items()})
        for h in analyze_handlers(src, p):
            all_handlers.append((p,) + h)
        for nh in analyze_native(src, p):
            nh["path"] = p
            native.append(nh)
        for i, line in enumerate(src.split("\n"), 1):
            l = line.strip()
            if not l or l.startswith("//") or l.startswith("use ") or l.startswith("#["):
                continue
            if "msg!" in l and "ctx" not in l:
                pass
            for label, pat in SIGNALS:
                if re.search(pat, l):
                    if label in COUNT_ONLY:
                        counts[(p, label)] = counts.get((p, label), 0) + 1
                    else:
                        signals.append((p, i, label, l[:110]))
    # --- instructions
    print("## Anchor instructions\n")
    if not all_handlers:
        print("_No `ctx: Context<..>` handlers found._\n")
    for p, name, sname, line in all_handlers:
        st = all_structs.get((p, sname)) or next((v for (pp, nn), v in all_structs.items() if nn == sname), None)
        print(f"### `{name}` ({p}:{line}) accounts: `{sname}`\n")
        if not st:
            print("_Accounts struct not found in scanned files._\n")
            continue
        print("| account | type | mut | signer | bound by | notes |")
        print("|---|---|---|---|---|---|")
        for f in st["fields"]:
            ty = f["ty"].replace("|", "\\|")
            print(f"| {f['name']} | `{ty}` | {'mut' if f['mut'] else ''} | {'S' if f['signer'] else ''} | "
                  f"{', '.join(f['flags'])} | {'; '.join(f['notes'])} |")
        print()
    orphan = [k for k in all_structs if k not in {h[2] for h in all_handlers}]
    if orphan:
        print("Accounts structs not referenced by a handler (nested or cpi): " + ", ".join(f"`{o}`" for o in orphan) + "\n")
    # --- native
    if native:
        print("## Native-style handlers (functions taking `&[AccountInfo]`)\n")
        print("| function | location | is_signer | .owner | .key | next_account_info | invoke | is_writable |")
        print("|---|---|---|---|---|---|---|---|")
        for n in native:
            print(f"| `{n['name']}` | {n['path']}:{n['line']} | {n['is_signer']} | {n['owner']} | {n['key_cmp']} | "
                  f"{n['next_account']} | {n['invoke']} | {n['writable']} |")
        print("\nA handler with 0 `is_signer` or 0 `.owner` mentions is a prompt to read it, not a verdict.\n")
    # --- signals
    print("## Risk signals (line-level, regex-based)\n")
    if not signals:
        print("_None._\n")
    else:
        print("| file:line | signal | code |")
        print("|---|---|---|")
        for p, i, label, code in signals[:400]:
            print(f"| {p}:{i} | {label} | `{code.replace('|', '\\|')}` |")
        if len(signals) > 400:
            print(f"\n_{len(signals) - 400} more signals truncated._")
        print()
    if counts:
        print("Noisy counts (lines matching): " + "; ".join(f"{os.path.basename(p)} {l}={c}" for (p, l), c in sorted(counts.items())) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
