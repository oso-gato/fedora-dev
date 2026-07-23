#!/usr/bin/env bash
# doc-dry-audit.sh — cross-document DRY drift-audit (BP9 DOCUMENTATION-DRY; fedora-dev#206).
#
# WHAT / WHY. BP9 (00-BUILDPRINCIPLE.md) is "one authoritative home per concept; every other mention is
# a one-line pointer or deleted." `bin/fleet-guard-parity.sh` enforces the blocks that are meant to be
# IDENTICAL ACROSS repos (the fleet guard payload). THIS is the INTRA-repo inverse the issue asks for:
# it flags PROSE DUPLICATED ACROSS this repo's own governance docs (the Trinity + CLAUDE.md +
# policy/CLAUDE.md + FLEET.md) — a concept living in two homes instead of one, which is the *precondition*
# for the two copies silently drifting apart. Same philosophy, opposite direction: parity ENFORCES the
# intentional duplicates identical; this DISCOURAGES the unintentional ones.
#
# MECHANISM (deterministic, offline, low-false-positive by construction). Each doc is reduced to
# normalized CLAUSES — fenced ```code``` blocks and `inline code` spans stripped (code parity is
# fleet-guard-parity's job, not prose-DRY's), the remaining prose split on sentence/clause punctuation,
# then lowercased and alnum-collapsed. A clause of >= MIN_WORDS words that appears VERBATIM (after
# normalization) in >= 2 of the audited docs is a candidate DRY violation. Short shared phrases and
# terminology fall below the word floor and are never flagged — only a substantial shared CLAUSE trips
# it. A committed allowlist (doc-dry-allow.txt) is the REVIEWABLE LEDGER of duplications judged
# intentional (e.g. a principle restated as its per-repo instantiation); it is subtracted so the audit is
# GREEN on the current tree and RED only on NEW cross-doc duplication. RED => give the concept ONE
# authoritative home and make the other mention a one-line pointer, or — if the shared wording is truly
# intentional — add the printed clause to the ledger with a reason.
#
# HONEST SCOPE (anti-theater doctrine — do NOT overclaim). This detects normalized-IDENTICAL cross-doc
# clauses: the duplication that PRECEDES drift, the same signal fleet-guard-parity trusts. Once two copies
# have already been REWORDED (a semantic near-duplicate) their normalized forms differ and this goes
# SILENT on them — fuzzy near-duplicate detection is a documented follow-up, not claimed here. The value
# is preventing NEW duplication from taking root (so it can never later drift), not diffing prose that
# already diverged.
#
# Usage:
#   doc-dry-audit.sh                 # audit the default doc set; exit 1 (RED) on un-allowlisted dup, else 0
#   doc-dry-audit.sh --list          # print EVERY cross-doc duplicate clause (incl. allowlisted); exit 0
#   doc-dry-audit.sh --selftest      # exercise the pure helpers (no files / network)
# Overrides (flag | env):
#   --docs "a.md b.md …"  | DRY_DOCS       the audited doc set (default: Trinity + CLAUDE.md + policy/CLAUDE.md + FLEET.md)
#   --min-words N         | DRY_MIN_WORDS  clause length floor in words (default 8)
#   --allow FILE          | DRY_ALLOW      the allowlist ledger (default: <root>/doc-dry-allow.txt)
#   --root DIR            | DRY_ROOT       resolve docs + allowlist under DIR (default: the repo root)
set -uo pipefail

# The repo root: bin/ lives at the repo root, so root = the script's parent-of-parent. Robust to cwd
# (CI runs `bash bin/doc-dry-audit.sh` from the checkout root; a human may run it from anywhere).
_self_root(){ cd "$(dirname "$0")/.." 2>/dev/null && pwd; }
ROOT="${DRY_ROOT:-$(_self_root)}"
DOCS="${DRY_DOCS:-00-OBJECTIVES.md 00-REQUIREMENTS.md 00-BUILDPRINCIPLE.md 00-GOVERNANCE.md CLAUDE.md policy/CLAUDE.md FLEET.md}"
MIN_WORDS="${DRY_MIN_WORDS:-8}"
ALLOW="${DRY_ALLOW:-}"          # resolved against ROOT below once ROOT is final

log(){ printf 'doc-dry-audit: %s\n' "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these) -----------------------------------------------

# dry_norm_clause <text> -> normalized clause: lowercase; every non-[a-z0-9] run -> a single space;
# trimmed. THE single normalization used everywhere — the doc clause stream AND every allowlist line
# pass through the identical tr|sed, so a match is exact-after-normalization and robust to the
# markdown / whitespace / case differences two homes inevitably carry.
dry_norm_clause(){
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/ /g; s/^ +//; s/ +$//'
}

# dry_nwords <text> -> word count of the NORMALIZED clause (0 for empty / all-punctuation).
dry_nwords(){
  local s; s="$(dry_norm_clause "$1")"
  [ -n "$s" ] || { printf 0; return; }
  printf '%s' "$s" | wc -w | tr -d ' '
}

# dry_significant <text> <min> -> rc 0 iff the clause carries >= <min> normalized words. The noise
# floor: shared TERMINOLOGY and short cross-references (below the floor) are expected and never flagged.
dry_significant(){ [ "$(dry_nwords "$1")" -ge "$2" ]; }

# dry_extract <file> -> the file's normalized, significant, de-duplicated clauses, one per line.
# Pipeline (each stage ONE process, not per-clause): strip fenced code blocks -> strip inline code spans
# -> join lines -> split on em-dash / spaced-hyphen / .;:!?| into one raw clause per line -> normalize
# (the SAME tr|sed as dry_norm_clause, stream-wide) -> keep >= MIN_WORDS words -> unique-within-doc.
dry_extract(){
  awk '
    /^[ \t]*```/ || /^[ \t]*~~~/ { fence = !fence; next }   # drop fenced code blocks whole (mawk-safe class)
    !fence { print }
  ' "$1" \
  | sed -E 's/`[^`]*`/ /g' \
  | tr '\n' ' ' \
  | sed -e 's/\xe2\x80\x94/\n/g' -e 's/ - /\n/g' \
  | tr '.;:!?|' '\n' \
  | tr 'A-Z' 'a-z' \
  | sed -E 's/[^a-z0-9]+/ /g; s/^ +//; s/ +$//' \
  | awk -v m="$MIN_WORDS" 'NF>=m' \
  | sort -u
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== dry_norm_clause (lowercase; non-alnum runs -> single space; trimmed) =="
  ck "case + punctuation"      "$(dry_norm_clause 'The Foo-Bar; BAZ.')"     "the foo bar baz"
  ck "collapse whitespace"     "$(dry_norm_clause '  a   b	c  ')"          "a b c"
  ck "markdown noise stripped" "$(dry_norm_clause '**one** _two_ `three`')" "one two three"
  ck "all-punctuation -> empty" "$(dry_norm_clause '—;:.|')"                ""
  echo "== dry_nwords =="
  ck "three words"             "$(dry_nwords 'one two three')"              "3"
  ck "hyphen is a separator"   "$(dry_nwords 'a-b c')"                      "3"
  ck "empty -> 0"             "$(dry_nwords '   ')"                        "0"
  echo "== dry_significant (word floor discriminates a clause from a phrase) =="
  dry_significant 'one two three four five six seven eight' 8 && r=YES || r=NO; ck "8 words >= 8" "$r" "YES"
  dry_significant 'one two three four five six seven' 8 && r=YES || r=NO;      ck "7 words <  8" "$r" "NO"
  echo; echo "doc-dry-audit selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]
  exit
fi

# ---- arg parse ------------------------------------------------------------------------------------
MODE=audit
while [ $# -gt 0 ]; do
  case "$1" in
    --list)      MODE=list; shift;;
    --docs)      DOCS="${2:?--docs needs a value}"; shift 2;;
    --min-words) MIN_WORDS="${2:?--min-words needs a value}"; shift 2;;
    --allow)     ALLOW="$2"; shift 2;;
    --root)      ROOT="$2"; shift 2;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0;;
    *) log "unknown argument: $1"; exit 2;;
  esac
done
[ -n "$ROOT" ] || { log "cannot resolve repo root (pass --root DIR)"; exit 2; }
ALLOW="${ALLOW:-$ROOT/doc-dry-allow.txt}"

# ---- gather the audited docs' clause streams ------------------------------------------------------
tmp="$(mktemp)"; allowtmp="$(mktemp)"; trap 'rm -f "$tmp" "$allowtmp"' EXIT
present=""
for d in $DOCS; do
  path="$ROOT/$d"
  if [ -f "$path" ]; then
    present="$present $d"
    while IFS= read -r c; do [ -n "$c" ] && printf '%s\t%s\n' "$d" "$c"; done < <(dry_extract "$path")
  else
    log "skip $d — not found under $ROOT"
  fi
done > "$tmp"
set -- $present
[ "$#" -ge 2 ] || { log "fewer than 2 audited docs present ($present) — nothing to compare"; exit 0; }

# ---- normalize the allowlist ledger (the SAME normalization, so entries match doc clauses) --------
if [ -f "$ALLOW" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue;; esac
    printf '%s\n' "$(dry_norm_clause "$line")"   # \n-terminate: dry_norm_clause emits no trailing newline
  done < "$ALLOW" | sort -u > "$allowtmp"
fi

# ---- fold: a clause in >= 2 distinct docs (and not allowlisted) is a cross-document duplication ----
# tmp rows are unique (doc,clause) pairs (dry_extract sort -u's per doc), so a per-clause row count IS
# the distinct-doc count. First input = the normalized allowlist; second = the (doc \t clause) stream.
# The allowlist file is matched by FILENAME (NOT the NR==FNR idiom, which silently misroutes the WHOLE
# second file into the allowlist when the first file is EMPTY — the no-allowlist case — a false GREEN).
fold(){
  awk -F'\t' -v want_allowed="$1" -v af="$allowtmp" '
    FILENAME==af { allow[$0]=1; next }
    { c=$2; if (!(c in docs)) docs[c]=$1; else docs[c]=docs[c] ", " $1; n[c]++ }
    END {
      for (c in n) {
        if (n[c] < 2) continue
        a = (c in allow) ? 1 : 0
        if (want_allowed == "only-new"  && a) continue
        if (want_allowed == "only-allow" && !a) continue
        printf "%d\t%s\t%s\t%s\n", n[c], (a?"allow":"new"), docs[c], c
      }
    }
  ' "$allowtmp" "$tmp" | sort -t"$(printf '\t')" -k1,1nr -k4,4
}

if [ "$MODE" = list ]; then
  echo "== cross-document duplicate clauses (>= $MIN_WORDS words) across:$present =="
  any=0
  while IFS="$(printf '\t')" read -r ndocs kind docs clause; do
    any=1
    mark=$([ "$kind" = allow ] && echo "· (allowlisted)" || echo "✗ NEW")
    printf '  %s  [%s docs: %s]\n      "%s"\n' "$mark" "$ndocs" "$docs" "$clause"
  done < <(fold all)
  [ "$any" = 1 ] || echo "  (none)"
  exit 0
fi

# audit mode: only un-allowlisted duplications gate.
new="$(fold only-new)"
if [ -z "$new" ]; then
  echo "GREEN — no un-allowlisted cross-document duplication across:$present"
  exit 0
fi
echo "RED — cross-document DRY drift: a concept is stated verbatim in >= 2 docs (BP9: one authoritative"
echo "home per concept; every other mention a one-line pointer). Give it ONE home + a pointer, OR add the"
echo "clause to $ALLOW with a reason if the shared wording is intentional."
echo
while IFS="$(printf '\t')" read -r ndocs kind docs clause; do
  printf '  ✗ duplicated across %s docs (%s):\n      "%s"\n' "$ndocs" "$docs" "$clause"
done <<<"$new"
exit 1
