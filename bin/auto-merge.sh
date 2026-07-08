#!/usr/bin/env bash
# auto-merge.sh — the DETERMINISTIC Tier-B/C merger (GOVERNANCE §4, Option 1).
#
# The ONLY thing besides Arthur that merges to main — and it is a DUMB, non-agent script, by design.
# It holds merge power precisely BECAUSE it has no agency: it merges iff three machine-checkable gates
# all say yes, and REFUSES (fail-closed) on anything else. An agent (which could be prompt-injected)
# never holds a merge credential; this script does, and it cannot be talked into merging a Tier-A
# change — it just reads the gates.
#
# THE THREE GATES (all required to merge; ANY missing/ambiguous/UNVERIFIABLE → REFUSE):
#   1. TIER = B or C   (bin/tier-classify.sh over the PR's changed files). Tier A → HUMAN (never auto).
#   2. HOST LIVE-GATE = GREEN   — a `Host live-gate (Gate B): VERDICT GREEN` comment AUTHORED BY THE
#      HOST BOT ($LG_HOST_LOGIN). Comments from anyone else (incl. the PR author) are ignored.
#   3. FITNESS = PASS  — a `Fitness review: VERDICT PASS` comment AUTHORED BY THE FITNESS-REVIEW BOT
#      ($FITNESS_LOGIN), NOT a self-appliable label. A verdict authored by the PR author is invalid.
# Both trust anchors MUST be configured and MUST differ from the PR author, else the gate is
# UNVERIFIABLE ⇒ REFUSE (fail-closed — a forgeable gate is treated as no gate). Only verified
# (B|C) AND GREEN AND PASS ⇒ merge. This is the ratified "Tier B/C auto-merges" — nothing else.
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

# UNFORGEABILITY (the gates are only as good as WHO posted them — the #92 review found both were
# forgeable). The verdicts are COMMENTS, and a PR author can post ANY comment / a collaborator can
# apply ANY label — so we IGNORE anyone but the trusted GitHub-App identities and REFUSE if those are
# unconfigured (fail-closed: no trust anchor ⇒ no auto-merge). Set these to the App bot logins:
#   LG_HOST_LOGIN   — the fedora-bootstrap host's GitHub-App identity that posts the live-gate verdict
#   FITNESS_LOGIN   — the independent fitness-review App identity that posts the fitness verdict
LG_HOST_LOGIN="${LG_HOST_LOGIN:-}"; FITNESS_LOGIN="${FITNESS_LOGIN:-}"
pr_author="$(gh pr view "$PR" --repo "$SLUG" --json author -q .author.login 2>/dev/null)"
# NORMALIZE: `--json author` prefixes an App-authored PR's login with `app/` (comment authors are
# bare) — proven empirically vs fedora-dev#110. Unstripped, the anchor != author guards below can
# NEVER match an App-authored PR (`x` != `app/x`) — fail-OPEN on the exact self-review case they
# exist to refuse. One canonical (bare) form for every identity comparison.
pr_author="${pr_author#app/}"

# Gate 1 — TIER from the changed files (fail-closed: no files → treat as A/HUMAN, never auto)
tier="$(gh pr view "$PR" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null \
        | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"

# Gate 2 — HOST LIVE-GATE verdict: newest verdict comment AUTHORED BY THE HOST BOT ONLY. A comment
# from anyone else (incl. the PR author) is ignored. No trust anchor ⇒ gate=NONE ⇒ REFUSE.
gate="NONE"
if [ -n "$LG_HOST_LOGIN" ] && [ "$LG_HOST_LOGIN" != "$pr_author" ]; then
  lgc="$(gh pr view "$PR" --repo "$SLUG" --json comments \
         -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body" 2>/dev/null \
         | grep -oE 'Host live-gate \(Gate B\): VERDICT (GREEN|RED)' | tail -1)"
  case "$lgc" in *GREEN) gate=GREEN;; *RED) gate=RED;; esac
else
  echo "[auto-merge] live-gate trust anchor unset or == PR author — gate unverifiable (fail-closed)"
fi

# Gate 3 — FITNESS verdict: a comment AUTHORED BY THE FITNESS-REVIEW BOT (NOT a self-appliable label).
# `Fitness review: VERDICT PASS|RETURN|ESCALATE`. A self-authored verdict (author == PR author) is
# invalid. No trust anchor ⇒ fit=NONE ⇒ REFUSE. (This is why the fitness harness POSTS such a comment.)
fit="NONE"
if [ -n "$FITNESS_LOGIN" ] && [ "$FITNESS_LOGIN" != "$pr_author" ]; then
  fvc="$(gh pr view "$PR" --repo "$SLUG" --json comments \
         -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body" 2>/dev/null \
         | grep -oE 'Fitness review: VERDICT (PASS|RETURN|ESCALATE)' | tail -1)"
  case "$fvc" in *PASS) fit=PASS;; *RETURN) fit=RETURN;; *ESCALATE) fit=ESCALATE;; esac
else
  echo "[auto-merge] fitness trust anchor unset or == PR author — fitness unverifiable (fail-closed)"
fi

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
