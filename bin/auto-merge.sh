#!/usr/bin/env bash
# auto-merge.sh — the DETERMINISTIC Tier-B/C merger (GOVERNANCE §4, Option 1).
#
# The ONLY thing besides Arthur that merges to main — and it is a DUMB, non-agent script, by design.
# It holds merge power precisely BECAUSE it has no agency: it merges iff three machine-checkable gates
# all say yes, and REFUSES (fail-closed) on anything else. An agent (which could be prompt-injected)
# never holds a merge credential; this script does, and it cannot be talked into merging a Tier-A
# change — it just reads the gates.
#
# THE THREE GATES (all required to merge; ANY missing/ambiguous → REFUSE):
#   1. TIER = B or C   (bin/tier-classify.sh over the PR's changed files). Tier A → HUMAN (never auto).
#   2. HOST LIVE-GATE = GREEN   (the host posted `VERDICT GREEN` — it ran, not just built).
#   3. FITNESS = PASS  (the independent fitness review posted `fitness-pass`; RETURN/ESCALATE/absent → no).
# Only (B|C) AND GREEN AND PASS ⇒ merge. This is the ratified "Tier B/C auto-merges" — nothing else.
#
# SAFE BY DEFAULT: --dry-run (the default) prints the DECISION and merges nothing. --commit actually
# merges. So wiring it up changes nothing until explicitly armed.
#
# Usage:
#   auto-merge.sh <repo> <pr>                 # dry-run: print decision
#   auto-merge.sh --commit <repo> <pr>        # actually merge if all three gates pass
#   auto-merge.sh --decide <tier> <gate> <fit>  # TEST the pure decision fn (no network)
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- the PURE decision function (no I/O — testable in isolation) -----------------------------------
# decide <tier:A|B|C> <livegate:GREEN|RED|NONE> <fitness:PASS|RETURN|ESCALATE|NONE> -> MERGE|HUMAN|REFUSE
decide(){
  local tier="$1" gate="$2" fit="$3"
  case "$tier" in
    A) echo HUMAN; return;;                     # Tier A NEVER auto-merges — Arthur's click
    B|C) : ;;
    *) echo REFUSE; return;;                     # unknown tier → fail closed
  esac
  [ "$gate" = GREEN ] || { echo REFUSE; return; }   # host must have live-gated GREEN
  [ "$fit"  = PASS  ] || { echo REFUSE; return; }   # independent fitness must PASS
  echo MERGE
}

# ---- --decide: exercise the pure function (used by the test) --------------------------------------
if [ "${1:-}" = "--decide" ]; then decide "${2:-}" "${3:-}" "${4:-}"; exit 0; fi

# ---- real path: gather the three gates from GitHub, then decide -----------------------------------
COMMIT=0; [ "${1:-}" = "--commit" ] && { COMMIT=1; shift; }
REPO="${1:?usage: auto-merge.sh [--commit] <repo> <pr>}"; PR="${2:?pr required}"
SLUG="oso-gato/$REPO"

# Gate 1 — TIER from the changed files (fail-closed: no files → treat as A/HUMAN, never auto)
tier="$(gh pr view "$PR" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null \
        | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"
# Gate 2 — HOST LIVE-GATE verdict: newest `Host live-gate (Gate B): VERDICT ...` comment
gate="NONE"
lgc="$(gh pr view "$PR" --repo "$SLUG" --json comments -q '.comments[].body' 2>/dev/null \
       | grep -oE 'Host live-gate \(Gate B\): VERDICT (GREEN|RED)' | tail -1)"
case "$lgc" in *GREEN) gate=GREEN;; *RED) gate=RED;; esac
# Gate 3 — FITNESS verdict from a label (fitness-pass / fitness-return / fitness-escalate)
fit="NONE"
labels="$(gh pr view "$PR" --repo "$SLUG" --json labels -q '.labels[].name' 2>/dev/null)"
printf '%s\n' "$labels" | grep -qx 'fitness-pass'     && fit=PASS
printf '%s\n' "$labels" | grep -qx 'fitness-return'   && fit=RETURN
printf '%s\n' "$labels" | grep -qx 'fitness-escalate' && fit=ESCALATE

decision="$(decide "$tier" "$gate" "$fit")"
echo "[auto-merge] $SLUG#$PR — tier=$tier live-gate=$gate fitness=$fit ⇒ $decision"

case "$decision" in
  MERGE)
    if [ "$COMMIT" = 1 ]; then
      gh pr merge "$PR" --repo "$SLUG" --squash --delete-branch \
        && echo "[auto-merge] MERGED $SLUG#$PR (Tier $tier, GREEN, fitness PASS)" \
        || { echo "[auto-merge] merge command failed"; exit 1; }
    else
      echo "[auto-merge] DRY-RUN — would merge (pass --commit to arm). Nothing merged."
    fi;;
  HUMAN)  echo "[auto-merge] Tier A — presenting to Arthur; NOT auto-merging.";;
  REFUSE) echo "[auto-merge] gates not all green — REFUSE (fail-closed). No merge.";;
esac
[ "$decision" = MERGE ] || [ "$decision" = HUMAN ]   # exit 0 for MERGE/HUMAN, 1 for REFUSE
