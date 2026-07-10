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
# Both trust anchors MUST be configured, MUST differ from the PR author, AND MUST differ from EACH
# OTHER (G1 — one compromised token must never satisfy both gates). Verdict SELECTION and EXTRACTION
# both read ONLY line 1 of each anchor comment (G2 — embedded candidate logs and reviewer rationale
# are attacker-influenceable prose; neither a forged verdict nor a planted future-head anchor there
# can act), each bound to the FULL 40-hex head sha (a 7-hex prefix would be grindable), and the
# merge is --match-head-commit pinned. Same-identity fitness (FITNESS_SAME_IDENTITY=1) is DRY-RUN-ONLY:
# --commit under it is a hard REFUSE (#96 STEP 1 — arming requires a real, distinct fitness App).
# Else the gate is UNVERIFIABLE ⇒ REFUSE (fail-closed — a forgeable gate is treated as no gate).
# Only verified (B|C) AND GREEN AND PASS ⇒ merge. The ratified "Tier B/C auto-merges" — nothing else.
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
  # ZERO-GATE (2026-07-10, Arthur's decision): tier NO LONGER gates the merge. The old
  # `A → HUMAN` click was built on a misrepresented requirement (the real red line is throwaway
  # build-isolation for WORKLOAD dev, not "never touch the control plane" — building the apparatus
  # itself inherently edits policy/gate/quadlets). Recoverability is kept AUTOMATIC, not human:
  # the host post-deploy health-gate + digest auto-rollback, full git-revertability, and the fitness
  # reviewer's standing "preserve recoverability" requirement (a change that removes rollback or
  # exfiltrates the credential FAILS review). So the merge rests on the two INDEPENDENT gates only:
  # host live-gate GREEN + independent fitness PASS. `tier` is retained purely for the caller's
  # report/digest — it is not read here.
  local tier="$1" gate="$2" fit="$3"
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
# FAIL-CLOSED on an unreadable author: an empty pr_author would trivially pass every `!= pr_author`
# self-review guard below (fail-OPEN on exactly the anchor-authored-PR case they exist to refuse).
[ -n "$pr_author" ] || { echo "[auto-merge] cannot read PR author — REFUSE (fail-closed)"; exit 1; }
# MAKE-IT-WORK (DRY-RUN ONLY): FITNESS_SAME_IDENTITY=1 accepts a fitness verdict authored by the dev
# identity (the PR author) — no separate fitness App — so the loop can be OBSERVED end-to-end before
# SoD exists. That signal is forgeable by the author, so it may NEVER arm: --commit under
# same-identity is a hard REFUSE (#96 STEP 1). The host live-gate (Gate 2, erebus) is never relaxed.
if [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ]; then
  if [ "$COMMIT" = 1 ]; then
    echo "[auto-merge] REFUSE: FITNESS_SAME_IDENTITY=1 may never --commit — a same-identity fitness"
    echo "  verdict is forgeable by the PR author. Arm only with a distinct fitness App (#96 STEP 1)."
    exit 1
  fi
  FITNESS_LOGIN="$pr_author"
fi

# SEPARATION OF DUTIES (G1): the two trust anchors MUST be DISTINCT identities — if one bot answered
# both gates, a single compromised token would satisfy them together. Equal (non-empty) anchors
# disable both gates → every path below reads NONE → REFUSE (fail-closed).
if [ -n "$LG_HOST_LOGIN" ] && [ "$LG_HOST_LOGIN" = "$FITNESS_LOGIN" ]; then
  echo "[auto-merge] G1 REFUSE: LG_HOST_LOGIN == FITNESS_LOGIN — the live-gate and fitness identities"
  echo "  must be distinct bot logins (one token must not satisfy both gates)."
  LG_HOST_LOGIN=""; FITNESS_LOGIN=""
fi

# HEAD PIN — verdicts are per-head, so every gate below is bound to THIS sha (a new, ungated head
# must never inherit the previous head's GREEN/PASS), and the merge itself carries
# --match-head-commit so a commit racing in between the checks and the merge cannot land unverified.
head_sha="$(gh pr view "$PR" --repo "$SLUG" --json headRefOid -q .headRefOid 2>/dev/null)"
[ -n "$head_sha" ] || { echo "[auto-merge] cannot read head sha — REFUSE (fail-closed)"; exit 1; }

# hdr_verdict <login> <sha-anchor> <verdict-ERE> (G2): BOTH the sha-anchor SELECTION and the verdict
# EXTRACTION read ONLY THE FIRST LINE (the machine-owned header) of each comment authored by <login>,
# newest last, and the anchor is the FULL 40-hex head sha. WHY line-1-only: the host comment embeds
# a tail-N log of the candidate's OWN output and the fitness comment embeds the reviewer model's
# rationale — both are attacker-influenceable prose; a planted verdict string OR a planted
# future-head sha anchor in those regions must never select or decide (the STEP-2 forge-hunt showed
# whole-body contains() lets an old PASS donate itself to a never-reviewed head). WHY the FULL sha:
# a 7-hex prefix is 28 bits — a ground commit collision would inherit GREEN+PASS wholesale; 40 hex
# is not grindable. Verdict EREs are line-START anchored so trailing header text (e.g. the host's
# '(targets: …)') can never smuggle a second verdict token past the extraction.
hdr_verdict(){ # $1=login $2=full-sha-anchor $3=line-anchored verdict-ERE → newest verdict, or empty
  gh pr view "$PR" --repo "$SLUG" --json comments \
    -q ".comments[] | select(.author.login==\"$1\") | .body | split(\"\n\")[0] | select(contains(\"$2\"))" 2>/dev/null \
    | grep -oE "$3" | tail -1
}

# Gate 1 — TIER from the changed files (fail-closed: no files → treat as A/HUMAN, never auto)
tier="$(gh pr view "$PR" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null \
        | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"

# Gate 2 — HOST LIVE-GATE verdict: newest verdict comment AUTHORED BY THE HOST BOT ONLY. A comment
# from anyone else (incl. the PR author) is ignored. No trust anchor ⇒ gate=NONE ⇒ REFUSE.
gate="NONE"
if [ -n "$LG_HOST_LOGIN" ] && [ "$LG_HOST_LOGIN" != "$pr_author" ]; then
  lgc="$(hdr_verdict "$LG_HOST_LOGIN" "@ $head_sha" '^\**Host live-gate \(Gate B\): VERDICT (GREEN|RED)')"
  case "$lgc" in *GREEN) gate=GREEN;; *RED) gate=RED;; esac
else
  echo "[auto-merge] live-gate trust anchor unset or == PR author — gate unverifiable (fail-closed)"
fi

# Gate 3 — FITNESS verdict: a comment AUTHORED BY THE FITNESS-REVIEW BOT (NOT a self-appliable label).
# `Fitness review: VERDICT PASS|RETURN|ESCALATE`. A self-authored verdict (author == PR author) is
# invalid. No trust anchor ⇒ fit=NONE ⇒ REFUSE. (This is why the fitness harness POSTS such a comment.)
fit="NONE"
if [ -n "$FITNESS_LOGIN" ] && { [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ] || [ "$FITNESS_LOGIN" != "$pr_author" ]; }; then
  fvc="$(hdr_verdict "$FITNESS_LOGIN" "head $head_sha" '^Fitness review: VERDICT (PASS|RETURN|ESCALATE)')"
  case "$fvc" in *PASS) fit=PASS;; *RETURN) fit=RETURN;; *ESCALATE) fit=ESCALATE;; esac
else
  echo "[auto-merge] fitness trust anchor unset or == PR author — fitness unverifiable (fail-closed)"
fi

decision="$(decide "$tier" "$gate" "$fit")"
echo "[auto-merge] $SLUG#$PR — tier=$tier live-gate=$gate fitness=$fit ⇒ $decision"

case "$decision" in
  MERGE)
    if [ "$COMMIT" = 1 ]; then
      gh pr merge "$PR" --repo "$SLUG" --squash --delete-branch --match-head-commit "$head_sha" \
        && echo "[auto-merge] MERGED $SLUG#$PR (Tier $tier, GREEN, fitness PASS)" \
        || { echo "[auto-merge] merge command failed"; exit 1; }
    else
      echo "[auto-merge] DRY-RUN — would merge (pass --commit to arm). Nothing merged."
    fi;;
  REFUSE) echo "[auto-merge] gates not all green — REFUSE (fail-closed). No merge.";;
esac
[ "$decision" = MERGE ]   # exit 0 for MERGE, 1 for REFUSE (HUMAN is gone under zero-gate)
