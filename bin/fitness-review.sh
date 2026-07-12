#!/usr/bin/env bash
# fitness-review.sh — the INDEPENDENT FITNESS-REVIEW HARNESS (GOVERNANCE §5 / #93 Step 4b).
#
# The third gate auto-merge.sh reads. On a GREEN PR it spawns a HEADLESS `claude -p` INSIDE claudebox
# in a SEPARATE context from the PR author (separation of duties) that scores the change against
# GOVERNANCE.md + the doctrine — the three questions:
#   Q1  Is it what was asked for?                    (scope: no unrequested surface)
#   Q2  Does it contradict the constitution/law?     (GOVERNANCE.md, fleet-core.md, Build Principles)
#   Q3  Is it fit for purpose — incl. the 6 doctrine mandates? (solution-oriented, iterated-on-facts,
#       zero-based, objective-held, no-rabbit-hole, no-quiet-quit)
# …and posts exactly ONE comment `Fitness review: VERDICT PASS|RETURN|ESCALATE` AS THE FITNESS-REVIEW
# BOT ($FITNESS_LOGIN) — the exact unforgeable signal bin/auto-merge.sh greps (NOT a self-appliable
# label). RETURN → the developer reworks (never reaches Arthur); ESCALATE → surfaced to Arthur;
# PASS → hands to the merge decision.
#
# WHY THIS SCRIPT — NOT THE MODEL — OWNS THE VERDICT LINE: the canonical `Fitness review: VERDICT X`
# string is composed HERE by deterministic shell after extracting the model's judgment token; the
# model's prose is appended only as rationale. So a hallucinated/garbled model reply can never forge a
# PASS: no sanctioned verdict token → NO comment → gate stays NONE → auto-merge REFUSEs (fail-closed).
#
# UNFORGEABILITY / SEPARATION OF DUTIES (mirrors auto-merge.sh):
#   * The verdict MUST be posted as $FITNESS_LOGIN, an identity DISTINCT from the PR author — else
#     auto-merge.sh treats it as self-authored and invalid. So this script REFUSES when FITNESS_LOGIN
#     is unset, equals the PR author, or has no credential to post as that identity. Fail-closed: a
#     forgeable review is worse than none, so we post none.
#   * The reviewer is read-only BY CONSTRUCTION: it is handed a diff and asked for a judgment; it holds
#     no merge credential and this script never merges. Its ONLY output is the verdict comment.
#
# SAFE BY DEFAULT: --dry-run prints the composed verdict and posts nothing. Real posting needs --post.
#
# Usage:
#   fitness-review.sh <repo> <pr>              # dry-run: run the review, print the verdict, post nothing
#   fitness-review.sh --post <repo> <pr>       # run + post the verdict comment as $FITNESS_LOGIN
#   fitness-review.sh --selftest               # exercise the pure verdict extractor (no network/model)
#
# Config (env):
#   FITNESS_LOGIN      REQUIRED. The fitness-review App bot login (must differ from the PR author).
#   FITNESS_GH_TOKEN   REQUIRED to --post. Installation token for the fitness App — the comment is
#                      posted with THIS token so its author is $FITNESS_LOGIN, not the dev agent.
#   LG_HOST_LOGIN      The host bot login; used to confirm the PR is actually host-GREEN before review
#                      (default: oso-gato-erebus-claudebox[bot]). Set empty to skip the GREEN precheck.
#   FITNESS_CLAUDE     headless reviewer command (default: claude -p). Overridable for testing.
#   FITNESS_DIFF_CAP   max diff bytes fed to the reviewer (default 200000; larger → truncated + noted).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- the PURE verdict extractor (no I/O — testable in isolation) -----------------------------------
# The reviewer is instructed to end with a line `FITNESS_VERDICT: <verdict>`. We take the LAST such
# line (its final judgment) and NOTHING else. No sanctioned token ⇒ empty ⇒ fail-closed.
# ANCHORED AT BOTH ENDS: the line must be the verdict token and nothing more. Without the end anchor
# a reviewer that merely QUOTES the instruction/rubric at line start (e.g. `FITNESS_VERDICT: PASS
# (or RETURN…)`) yields a spurious PASS with no real judgment — fail-OPEN. Proven empirically: the
# prompt's own template line was extractable as PASS under the loose form (mock-stub dry-run).
extract_verdict(){
  # reads model output on stdin; echoes PASS|RETURN|ESCALATE or nothing
  grep -oE '^[[:space:]]*FITNESS_VERDICT:[[:space:]]*(PASS|RETURN|ESCALATE)[[:space:]]*$' \
    | grep -oE '(PASS|RETURN|ESCALATE)[[:space:]]*$' | grep -oE '(PASS|RETURN|ESCALATE)' | tail -1
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0; check(){ local got; got="$(printf '%s' "$2" | extract_verdict)"; \
    [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  check "plain pass"        $'reasoning...\nFITNESS_VERDICT: PASS'                 PASS
  check "return"            $'FITNESS_VERDICT: RETURN'                            RETURN
  check "escalate w/space"  $'   FITNESS_VERDICT:   ESCALATE  '                   ESCALATE
  check "last wins"         $'FITNESS_VERDICT: RETURN\nFITNESS_VERDICT: PASS'      PASS
  check "no verdict"        $'I think this looks fine, PASS probably'             ""
  check "inline not anchored" $'the verdict FITNESS_VERDICT: PASS inline'          ""
  check "garbage"           $'PASSED! LGTM'                                        ""
  check "empty"             ""                                                     ""
  check "trailing text"     $'FITNESS_VERDICT: PASS because it looks fine'          ""
  check "quoted rubric line" $'FITNESS_VERDICT: PASS   (or RETURN, or ESCALATE)'    ""
  check "prompt placeholder" $'FITNESS_VERDICT: <PASS|RETURN|ESCALATE>'             ""
  check "real after quote"  $'FITNESS_VERDICT: PASS (or RETURN)\nFITNESS_VERDICT: RETURN' RETURN
  [ "$fail" = 0 ] && echo "ALL FITNESS SELFTESTS PASS" || echo "FITNESS SELFTESTS FAILED"
  exit "$fail"
fi

POST=0; [ "${1:-}" = "--post" ] && { POST=1; shift; }
REPO="${1:?usage: fitness-review.sh [--post] <repo> <pr>}"; PR="${2:?pr required}"
SLUG="oso-gato/$REPO"
# TOKEN FERRY FALLBACK — the fitness App key never enters the box; the base entrypoint mints a
# <=1h installation token and ferries it (with the login) to this 0600 home-volume file on the
# 40-min tick. Explicit env ALWAYS wins (testing / CI); the ferry only fills what is unset. The
# file is root-written KEY=VALUE (trusted producer: the entrypoint), sourced only when readable.
if [ -z "${FITNESS_GH_TOKEN:-}" ] && [ -r "${FITNESS_ENV_FILE:-$HOME/.config/fitness/env}" ]; then
  _fl_pre="${FITNESS_LOGIN:-}"
  . "${FITNESS_ENV_FILE:-$HOME/.config/fitness/env}"
  [ -n "$_fl_pre" ] && FITNESS_LOGIN="$_fl_pre"   # explicit login wins over the ferried one
fi
# Fleet default: the org-wide independent fitness App (verdicts valid on ANY oso-gato repo as
# long as it differs from the PR author — enforced fail-closed below either way). The login is the
# App SLUG (= its name, already slug-form): the host-App precedent proves name == comment login.
FITNESS_LOGIN="${FITNESS_LOGIN:-oso-gato-fitness-claudebox}"
# NOTE: the login form MUST match what `gh pr view --json comments` (GraphQL) returns for the bot —
# that is the NON-`[bot]` form (REST's .user.login adds `[bot]`; GraphQL's .author.login does NOT).
# auto-merge.sh reads via the same GraphQL surface, so both must use the non-`[bot]` login. Use `-`
# (not `:-`) so an explicit empty value DISABLES the GREEN precheck (offline testing).
LG_HOST_LOGIN="${LG_HOST_LOGIN-oso-gato-erebus-claudebox}"
FITNESS_CLAUDE="${FITNESS_CLAUDE:-claude -p}"
FITNESS_DIFF_CAP="${FITNESS_DIFF_CAP:-200000}"

log(){ echo "[fitness] $*" >&2; }
die(){ log "$*"; exit 1; }

pr_author="$(gh pr view "$PR" --repo "$SLUG" --json author -q .author.login 2>/dev/null)"
[ -n "$pr_author" ] || die "cannot read PR author for $SLUG#$PR (fail-closed)"
# NORMALIZE: `--json author` prefixes an App-authored PR's login with `app/` (e.g.
# `app/oso-gato-nox-claudebox`) while comment authors carry the bare form — PROVEN empirically
# (dry-run vs fedora-dev#110). Without stripping it, the self-review comparison below could NEVER
# match an App-authored PR (`x` != `app/x`) — fail-OPEN on the exact
# case it guards. Strip the prefix so identities compare in one canonical form.
pr_author="${pr_author#app/}"

# SEPARATION OF DUTIES — fail-closed, identical rule to the one auto-merge.sh enforces on read.
# MAKE-IT-WORK: FITNESS_SAME_IDENTITY=1 drops the DISTINCT-App requirement. The review is STILL an
# independent AGENT-CONTEXT (a fresh `claude -p` with the rubric), but posts under the dev identity;
# cross-identity independence then rests on the host live-gate (erebus — a separate App on a separate
# box). Accepted make-it-work tradeoff: a same-identity verdict is forgeable by an injected author
# agent (Tier A still needs the human; host GREEN still independent). Tighten back with a real App later.
if [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ]; then
  FITNESS_LOGIN="$pr_author"                       # verdict is posted + verified under the dev identity
else
  [ -n "$FITNESS_LOGIN" ] || die "FITNESS_LOGIN unset — a fitness verdict must be posted by a DISTINCT bot; refusing (fail-closed)"
  [ "$FITNESS_LOGIN" != "$pr_author" ] || die "FITNESS_LOGIN == PR author ($pr_author) — self-review is invalid; refusing (fail-closed)"
fi

# GREEN PRECHECK — fitness only runs AFTER the host live-gate is GREEN (the poller enforces order, but
# be self-contained: an unGREEN PR under review means the caller is out of contract). Skippable (empty
# LG_HOST_LOGIN) for offline testing.
if [ -n "$LG_HOST_LOGIN" ]; then
  gate="$(gh pr view "$PR" --repo "$SLUG" --json comments \
          -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body | split(\"\n\")[0]" 2>/dev/null \
          | grep -oE '^\**Host live-gate \(Gate B\): VERDICT (GREEN|RED)' | grep -oE '(GREEN|RED)$' | tail -1)"
  case "$gate" in GREEN) : ;; *) die "PR is not host-GREEN (latest host verdict: ${gate:-NONE}) — fitness runs only on GREEN"; esac
fi

# DEDUP — one review per head SHA. If $FITNESS_LOGIN already commented a verdict since the current head,
# don't re-review (idempotent; avoids duplicate/contradictory verdicts on the same code).
head_sha="$(gh pr view "$PR" --repo "$SLUG" --json headRefOid -q .headRefOid 2>/dev/null)"
state_dir="$HOME/.local/state/fitness-review"; mkdir -p "$state_dir"
marker="$state_dir/${REPO}-${PR}-${head_sha}.done"
if [ -f "$marker" ]; then log "already reviewed $SLUG#$PR @ ${head_sha:0:7} — skipping"; exit 0; fi

# ---- build the review prompt: PR metadata + diff + the doctrine questions --------------------------
title="$(gh pr view "$PR" --repo "$SLUG" --json title -q .title 2>/dev/null)"
body="$(gh pr view "$PR" --repo "$SLUG" --json body -q .body 2>/dev/null)"
diff="$(gh pr diff "$PR" --repo "$SLUG" 2>/dev/null)"
[ -n "$diff" ] || die "empty/unreadable diff for $SLUG#$PR (fail-closed)"
diff_note=""
if [ "${#diff}" -gt "$FITNESS_DIFF_CAP" ]; then
  diff="${diff:0:$FITNESS_DIFF_CAP}"; diff_note=$'\n\n[diff truncated at '"$FITNESS_DIFF_CAP"$' bytes — judge on what is shown; if truncation hides the answer, ESCALATE]'
fi

read -r -d '' PROMPT <<PROMPT_EOF || true
You are an INDEPENDENT fitness reviewer for the oso-gato fleet. You did NOT write this change; you have
no stake in it merging. Judge it against the fleet's stamped law and PROBLEM-SOLVING DOCTRINE, then give
ONE verdict. You have NO merge power — your only job is the judgment.

Answer these three questions about the PR below, briefly, then emit the verdict line.
  Q1 ASKED-FOR: does the change do what its title/body says was asked, with NO unrequested extra surface?
  Q2 CONTRADICTS: does it violate the constitution/law — GOVERNANCE.md, fleet-core.md, the Build
     Principles (provenance/minimalism/no-secrets/deploy-contract/validate), or the control-plane/Tier
     boundary?
  Q3 FIT-FOR-PURPOSE incl. the 6 doctrine mandates: solution-oriented; iterated-on-facts (proven, not
     asserted); zero-based; objective-held; no rabbit-hole; no quiet-quit/partial-done presented as done.

SEVERITY — the single most important judgment you make. MVP-FIRST (Arthur's standing instruction):
"get it to work first; where fitness finds something that could be better or improved but is NOT
blocking, we continue to build and you make a note of it — later, when we ship a finished feature, we
revisit and close those loops." Prove the feature first; polish is a follow-up, not a gate.

A finding BLOCKS only if it makes the change INCORRECT, UNSAFE, or UNTRUE:
  (a) INCORRECT — it does not actually do what it claims; the stated feature is broken or does not work.
  (b) UNSAFE    — it weakens or deletes a guard, exposes a credential, enables an unsafe or unreviewed
                  merge, breaks the fail-closed posture or the merge-trust boundary (G1/G2, author≠judge),
                  or removes recoverability/rollback.
  (c) UNTRUE    — it ships a claim that is false: a doc row, code comment, log line or test that asserts
                  behaviour the code does not have. (This fleet's dominant defect. A test that passes
                  against the pre-fix code is untrue. Hold this line hard.)
EVERYTHING ELSE IS A NOTE, NOT A BLOCKER — and a NOTE is compatible with PASS. Non-blocking includes:
missing coverage that is not load-bearing for (a)-(c); design/idiom/DRY improvements; a cleaner
architecture you would have preferred; stale numbers in the PR body; secondary spec gaps that do not
stop the feature working correctly and safely; anything you would phrase as "should also", "could be
better", or "a cleaner way would be".

Ask yourself literally: does this make the change incorrect, unsafe, or untrue? If NO — it is a NOTE.
Do NOT RETURN a working, safe, honest change because it is imperfect. An endless RETURN loop over
non-blocking polish burns the maintainer's budget and is itself a doctrine failure (rabbit-hole).

Decide:
  PASS     — works, safe, honest. Route to the merge decision. Record any non-blocking findings under a
             "## NOTES (non-blocking — follow-ups)" heading; they are logged and revisited after ship.
  RETURN   — at least ONE finding is INCORRECT, UNSAFE or UNTRUE per (a)-(c). Name it explicitly and say
             which of (a)/(b)/(c) it is. Send back to the developer (do NOT bother Arthur).
  ESCALATE — a judgment only Arthur should make (genuine policy ambiguity, control-plane trade-off,
             or the diff is unreadable/truncated past the point of judgment).
When unsure whether a finding BLOCKS, apply the (a)/(b)/(c) test — not your taste. If it is not
incorrect, unsafe, or untrue, PASS and NOTE it.

End your reply with EXACTLY one line, nothing after it — the token alone, no brackets, no trailing text:
FITNESS_VERDICT: <PASS|RETURN|ESCALATE>

=== PR $SLUG#$PR ===
TITLE: $title

BODY:
$body

DIFF:
$diff$diff_note
PROMPT_EOF

log "reviewing $SLUG#$PR @ ${head_sha:0:7} (author=$pr_author, reviewer=$FITNESS_LOGIN)…"
review="$($FITNESS_CLAUDE "$PROMPT" 2>/dev/null)"
verdict="$(printf '%s' "$review" | extract_verdict)"

if [ -z "$verdict" ]; then
  # Infra/format failure — NOT a governance judgment. Post nothing (gate stays NONE ⇒ REFUSE). A human
  # can look; we never manufacture a PASS or a misleading ESCALATE from a broken reviewer run.
  die "reviewer produced no sanctioned FITNESS_VERDICT line — posting nothing (fail-closed). Merge stays blocked."
fi

# ---- compose the CANONICAL verdict comment (shell-owned) + the model's rationale -------------------
rationale="$(printf '%s' "$review" | grep -vE '^[[:space:]]*FITNESS_VERDICT:' | sed -e 's/[[:space:]]*$//')"
comment="Fitness review: VERDICT $verdict — head $head_sha

<sub>Independent fitness review (Step 4b) — reviewer \`$FITNESS_LOGIN\`, head \`${head_sha:0:7}\`. Machine-read by \`bin/auto-merge.sh\` from LINE 1 ONLY (verdict + FULL head sha — prose/rationale below this line is never machine-trusted); the verdict token above is authoritative.</sub>

<details><summary>rationale</summary>

$rationale
</details>"

echo "[fitness] $SLUG#$PR — VERDICT $verdict"
if [ "$POST" != 1 ]; then
  echo "----- DRY-RUN (would post as $FITNESS_LOGIN; pass --post to post) -----"
  printf '%s\n' "$comment"
  exit 0
fi

if [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ]; then
  # MAKE-IT-WORK: post under the ambient dev credential (same identity as the PR author).
  if gh pr comment "$PR" --repo "$SLUG" --body "$comment" >/dev/null 2>&1; then
    : > "$marker"
    echo "[fitness] posted VERDICT $verdict on $SLUG#$PR as $FITNESS_LOGIN (same-identity)"
  else
    die "failed to post fitness comment (fail-closed — no marker written; will retry next cycle)"
  fi
  exit 0
fi

[ -n "${FITNESS_GH_TOKEN:-}" ] || die "--post needs FITNESS_GH_TOKEN (the fitness App's token) to post AS $FITNESS_LOGIN; refusing to post the unforgeable line under the wrong identity (fail-closed)"

# Post with the FITNESS App token so the comment's author is $FITNESS_LOGIN (the unforgeable signal).
if GH_TOKEN="$FITNESS_GH_TOKEN" gh pr comment "$PR" --repo "$SLUG" --body "$comment" >/dev/null 2>&1; then
  : > "$marker"
  echo "[fitness] posted VERDICT $verdict on $SLUG#$PR as $FITNESS_LOGIN"
else
  die "failed to post fitness comment (fail-closed — no marker written; will retry next cycle)"
fi
