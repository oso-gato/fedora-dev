#!/usr/bin/env bash
# dev-plan.sh — the AUTONOMOUS PLANNER (apparatus spec fedora-dev#135 R2).
#
# Turns a HUMAN-CONFIRMED objective/spec issue into a numbered set of `backlog`-labelled FEATURE issues,
# one per feature — the work-list the dev-loop driver (P3) then authors (R3) and the pipeline ships. It
# is the front of the loop: after this, the human is out until an ESCALATE question (R13).
#
# R1 discipline — it plans ONLY the human-confirmed spec: the spec issue must carry a MAINTAINER-APPLIED
# `approved` label OR a MAINTAINER `CONFIRMED` comment; an unconfirmed spec is refused (the confirmed set
# is what fitness later grades against, so planning an unconfirmed one would ground the whole loop in
# unratified intent). This confirmation is the loop's ONLY remaining human anchor, so BOTH paths are
# MAINTAINER-BOUND exactly like every other fleet trust anchor (the auto-merge G2 discipline) — the
# acting identity is resolved from the GitHub permission API and must hold admin|maintain; nothing is
# text-trusted or mere-presence-trusted:
#   * LABEL  — the label's PRESENCE proves nothing: applying one needs only triage/write, which every
#     fleet App identity holds (dev-author adds `live-validate`, dev-plan itself adds `backlog`), so a
#     presence-only check would let the autonomous side self-authorize an unratified objective with one
#     `gh issue edit --add-label approved`. We resolve WHO applied it (the last `labeled` timeline event
#     for that label) and bind THAT actor to a maintainer role.
#   * COMMENT — the token must OPEN line 1 (machine-owned position: a quoted or mid-prose token never
#     acts) AND the comment's author must be a maintainer.
# Anything unfetchable (labels, timeline, role) ⇒ NOT confirmed (fail-closed).
#
# DETERMINISM split (design law): the JUDGMENT — "what features does this objective decompose into" — is
# ONE bounded `claude -p`, which WRITES each feature as a file (never creates issues itself). The ACTION
# — creating the `backlog` issues — is the plain-shell harness reading those files. So issue creation is
# deterministic + auditable, and the model touches no GitHub state.
#
#   dev-plan.sh <repo> <spec-issue#>   plan the confirmed objective into backlog feature issues
#   dev-plan.sh --selftest             exercise the pure helpers (no gh / claude / network)
#
# NO LOCAL STATE — THE PLANNER HOLDS NONE (spec #135's design law: *no local state anywhere — every
# component resumes by re-reading GitHub*; R5: issues/PRs are the sole IPC, WAL and audit log; R14's
# E2E-KILL: a box killed and wiped mid-work resumes FROM THE BUS ALONE). Every fact this planner acts on
# is re-derived from the spec issue's own COMMENT STREAM each run — there is nothing on disk to lose:
#   * ALREADY PLANNED  ⟺  this box's own line-1-anchored `planned:` SUMMARY is on the issue (planned_
#     already). That comment is not decoration — it IS the tombstone the old `.planned` file used to be.
#     It has to be, because the title dedup that would otherwise catch a re-plan is an EXACT-title match
#     against a NON-DETERMINISTIC model: a wiped box re-running the planner would re-word half the
#     features and file a fresh set of near-duplicate backlog issues, which dev-loop would then author
#     into duplicate PRs. Fail-CLOSED: an unreadable comment stream means we cannot prove the spec is not
#     already planned, so we refuse rather than risk that duplicate plan.
#   * ALREADY ASKED    ⟺  the question itself is the NEWEST comment (asked_already) — so a re-run stays
#     quiet, and a reply un-mutes it.
# Both are IDENTITY- + LINE-1-bound (the auto-merge G2 discipline): a stranger pasting an anchor cannot
# forge either fact.
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); APPROVED_LABEL (default approved);
#      PLAN_CLAUDE (default "claude -p", overridable for the mock test); PLAN_TIMEOUT (default 1800);
#      MAX_FEATURES (cap the plan size, default 8 — a CAP THAT DEFERS: the overflow is reported on the
#      bus and the spec is left unplanned, never silently dropped);
#      DEV_LOGIN (this box's App identity, whose own comments it recognises on the bus — default
#      oso-gato-nox-claudebox; empty ⇒ it can recognise neither, so it re-asks and refuses to claim a
#      spec is planned: fail-safe toward telling a human, fail-closed against a duplicate plan).
#
# EXIT: 0 planned (or already planned) · 2 spec/bus unreadable · 3 unconfirmed · 4 planner BLOCKED
#       5 no features · 6 create failed (total or partial → deferred) · 7 no PLAN_DONE sentinel
#       8 plan exceeded MAX_FEATURES (the surplus is deferred, reported on the bus, spec left unplanned)
#       9 filed, but the `planned:` summary could not be posted → deferred (the bus is the only record).
#       12 repo outside the R16 operating scope (#167) — refused before anything was read or filed.
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
APPROVED_LABEL="${APPROVED_LABEL:-approved}"
PLAN_CLAUDE="${PLAN_CLAUDE:-claude -p}"
PLAN_TIMEOUT="${PLAN_TIMEOUT:-1800}"
MAX_FEATURES="${MAX_FEATURES:-8}"
DEV_LOGIN="${DEV_LOGIN-oso-gato-nox-claudebox}"

# The machine-owned line-1 anchors. Each question gets its OWN anchor rather than sharing the generic
# `**dev-plan → needs a decision (BLOCKED):**` prefix of the early-exit questions (planner-blocked,
# no-sentinel, no-features): those are posted on paths that exit BEFORE the create step, so a shared
# prefix would let a STALE one of them suppress a LATER, different question — the run's only way to tell
# a human that nothing can be filed at all, or that part of the plan did not fit under the cap.
PLANNED_ANCHOR='^\*\*dev-plan → planned:\*\*'
CREATE_FAIL_ANCHOR='^\*\*dev-plan → needs a decision \(BLOCKED, issue-create failed\):\*\*'
CAPPED_ANCHOR='^\*\*dev-plan → needs a decision \(BLOCKED, plan exceeded MAX_FEATURES\):\*\*'

log(){ printf '[%s] dev-plan: %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo --:--:--)" "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these) ------------------------------------------------

# is_confirmed <has-approved-label:0|1> <has-maintainer-CONFIRMED-comment:0|1> → CONFIRMED | UNCONFIRMED.
# Either signal suffices; both absent → refuse (R1 fail-closed).
is_confirmed(){
  { [ "$1" = 1 ] || [ "$2" = 1 ]; } && printf 'CONFIRMED' || printf 'UNCONFIRMED'
}

# confirm_line1 <comment-line-1> → 1 iff the CONFIRMED token OPENS the line (G2 position discipline:
# only LINE 1 of a comment is ever passed in, so a quoted/mid-prose/multi-line-embedded token is inert).
confirm_line1(){
  printf '%s' "$1" | grep -qE '^CONFIRMED\b' && printf 1 || printf 0
}

# role_can_confirm <role_name> → 1 only for a repo maintainer (admin|maintain); write/triage/read/bot/
# empty/unknown → 0. The fleet App identities hold write, so they can never confirm a spec.
role_can_confirm(){
  case "$1" in admin|maintain) printf 1;; *) printf 0;; esac
}

# asked_already <dev-login> <newest-comment-author> <newest-comment-line-1> <anchor> → 1 iff the spec
# issue's NEWEST comment is the question THIS box already posted under <anchor> — the ask-once gate,
# DERIVED from the bus instead of a local marker (no local state: a wiped box must not re-ask, and a box
# that never asked must). Identity-bound + line-1-anchored (the auto-merge G2 discipline used by the gate
# above): a stranger pasting the anchor cannot mute the question, and a quoted marker is inert. Anything
# else — a later reply, a later `planned:` summary from a run whose creates worked, an unreadable comment
# — reads as NOT-asked, so we ask: fail-safe toward telling a human, never toward silence.
asked_already(){
  local me="$1" who="$2" line1="$3" anchor="$4"
  [ -n "$me" ] && [ "$who" = "$me" ] || { printf 0; return; }
  printf '%s' "$line1" | grep -qE "$anchor" && printf 1 || printf 0
}

# planned_already <dev-login> <bus-tsv> → 1 iff THIS box's line-1-anchored `planned:` summary is ANYWHERE
# in the spec issue's comment stream. This is the idempotency tombstone (it replaces the `.planned` file):
# the summary comment is the sole, GitHub-resident record that this objective was decomposed.
# WHY ANYWHERE, not newest-only (unlike asked_already): later comments legitimately land on a planned spec
# (a maintainer's reply, a dev-author question), and a newest-only read would then see "not planned" and
# re-plan — the exact duplicate-filing hazard this exists to stop. Identity-bound by an EXACT login match
# (no regex, so no injection) + line-1-anchored. An empty $DEV_LOGIN can prove nothing ⇒ 0, and the caller
# refuses to plan rather than risk a duplicate (fail-closed — the opposite direction from asked_already,
# because here the unsafe outcome is a duplicate plan, not an extra question).
planned_already(){
  local me="$1" who line1
  [ -n "$me" ] || { printf 0; return; }
  while IFS=$'\t' read -r who line1; do
    [ "$who" = "$me" ] || continue
    printf '%s' "$line1" | grep -qE "$PLANNED_ANCHOR" && { printf 1; return; }
  done <<<"$2"
  printf 0
}

# drop_report <dropped-title…> → the bus-visible list of features the cap did NOT file. The titles go ON
# THE BUS precisely because the planner's $OUTDIR is a mktemp the EXIT trap deletes: without this, the
# dropped features exist nowhere at all once the run ends.
drop_report(){ printf -- '- %s\n' "$@"; }

# feature_title <feature-file> → line 1 with a leading '# ' stripped (the issue title).
feature_title(){ head -1 "$1" | sed -E 's/^#[[:space:]]*//'; }
# feature_body <feature-file> → everything after line 1 (the issue body).
feature_body(){ tail -n +2 "$1"; }

# extract_plan_sentinel <text> → the LAST anchored PLAN_DONE:/PLAN_BLOCKED: line (both-end rigor).
extract_plan_sentinel(){
  printf '%s' "$1" | grep -aoE '^PLAN_(DONE|BLOCKED):.*$' | tail -1 \
    | sed -E 's/^PLAN_(DONE|BLOCKED): */\1 /'
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0; td="$(mktemp -d)"; trap 'rm -rf "$td"' EXIT
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  printf '# Add a WebP probe\nThe body line one.\nAnd two.\n' > "$td/feat-01.md"
  echo "== is_confirmed (R1: approved label OR CONFIRMED comment; else refuse) =="
  ck "approved label → CONFIRMED"   "$(is_confirmed 1 0)" "CONFIRMED"
  ck "CONFIRMED comment → CONFIRMED" "$(is_confirmed 0 1)" "CONFIRMED"
  ck "neither → UNCONFIRMED"        "$(is_confirmed 0 0)" "UNCONFIRMED"
  echo "== confirm_line1 (token must OPEN line 1 — G2 position discipline) =="
  ck "line-1 token acts"            "$(confirm_line1 'CONFIRMED — ship it')" "1"
  ck "bare token acts"              "$(confirm_line1 'CONFIRMED')" "1"
  ck "mid-prose token inert"        "$(confirm_line1 'I would say CONFIRMED')" "0"
  ck "prefix-glued token inert"     "$(confirm_line1 'CONFIRMEDx')" "0"
  echo "== role_can_confirm (maintainer-bound: admin|maintain only) =="
  ck "admin confirms"               "$(role_can_confirm admin)" "1"
  ck "maintain confirms"            "$(role_can_confirm maintain)" "1"
  ck "write cannot (fleet Apps)"    "$(role_can_confirm write)" "0"
  ck "empty/unknown cannot"         "$(role_can_confirm '')" "0"
  echo "== asked_already (ask-once, DERIVED from the bus — no local marker) =="
  CFQ='**dev-plan → needs a decision (BLOCKED, issue-create failed):** every create failed.'
  CAP='**dev-plan → needs a decision (BLOCKED, plan exceeded MAX_FEATURES):** 5 features, cap 3.'
  ck "our own create-failure question is newest → already asked" "$(asked_already me me "$CFQ" "$CREATE_FAIL_ANCHOR")" "1"
  ck "a reply came after it → ask again"        "$(asked_already me arthur 'fixed the label' "$CREATE_FAIL_ANCHOR")" "0"
  ck "no comments at all → ask"                 "$(asked_already me '' '' "$CREATE_FAIL_ANCHOR")" "0"
  ck "a stranger forging the anchor cannot mute us" "$(asked_already me randomer "$CFQ" "$CREATE_FAIL_ANCHOR")" "0"
  ck "an OLD planner-BLOCKED question is a DIFFERENT anchor → still ask" \
     "$(asked_already me me '**dev-plan → needs a decision (BLOCKED):** the spec is too vague.' "$CREATE_FAIL_ANCHOR")" "0"
  ck "the anchor QUOTED is inert → ask"         "$(asked_already me me "> $CFQ" "$CREATE_FAIL_ANCHOR")" "0"
  ck "the cap question has its OWN anchor"      "$(asked_already me me "$CAP" "$CAPPED_ANCHOR")" "1"
  ck "a create-fail question does not mute the cap question" "$(asked_already me me "$CFQ" "$CAPPED_ANCHOR")" "0"
  echo "== planned_already (the idempotency tombstone, DERIVED from the bus — no .planned file) =="
  SUM=$'**dev-plan → planned:** decomposed this objective into 2 backlog feature issue(s):'
  ck "our own summary anywhere in the stream → planned" \
     "$(planned_already me "$(printf 'arthur\tCONFIRMED\nme\t%s' "$SUM")")" "1"
  ck "…even when later comments buried it (NOT newest-only)" \
     "$(planned_already me "$(printf 'me\t%s\narthur\tthanks\nme\tsomething else\n' "$SUM")")" "1"
  ck "an empty stream → not planned"            "$(planned_already me '')" "0"
  ck "a stranger forging the summary cannot mark it planned" \
     "$(planned_already me "$(printf 'randomer\t%s' "$SUM")")" "0"
  ck "the summary QUOTED is inert"              "$(planned_already me "$(printf 'me\t> %s' "$SUM")")" "0"
  ck "an unknown identity can prove nothing → not planned" "$(planned_already '' "$(printf 'me\t%s' "$SUM")")" "0"
  echo "== drop_report (the dropped titles reach the BUS — \$OUTDIR is deleted on exit) =="
  ck "lists every dropped title" "$(drop_report 'Feature four' 'Feature five')" "$(printf -- '- Feature four\n- Feature five')"
  echo "== feature file parsing =="
  ck "title strips '# '"            "$(feature_title "$td/feat-01.md")" "Add a WebP probe"
  ck "body is lines 2+"             "$(feature_body "$td/feat-01.md")" "$(printf 'The body line one.\nAnd two.')"
  echo "== extract_plan_sentinel (both-end anchored; last wins) =="
  ck "done token"                   "$(extract_plan_sentinel $'x\nPLAN_DONE: 3 features written')" "DONE 3 features written"
  ck "blocked token"                "$(extract_plan_sentinel $'PLAN_BLOCKED: spec too vague')" "BLOCKED spec too vague"
  ck "mid-line quote inert"         "$(extract_plan_sentinel 'end with PLAN_DONE: <n>')" ""
  echo; echo "dev-plan selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- LIVE PATH -------------------------------------------------------------------------------------
REPO="${1:?usage: dev-plan.sh <repo> <spec-issue#> | --selftest}"
SPEC="${2:?usage: dev-plan.sh <repo> <spec-issue#>}"
SLUG="$ORG/$REPO"

# R16 OPERATING SCOPE (#167): planning files issues AGAINST a repo — an out-of-scope repo gets NO
# action of any kind (nothing read, nothing filed, no comment on the foreign repo) and one loud log
# line. Any non-zero rc from the reader (127 included) refuses (fail-closed).
REPO_SCOPE="${REPO_SCOPE:-$(dirname "$(readlink -f "$0")")/repo-scope.sh}"
# R16 per-session scope (2026-07-16): inside a REAL agent session narrow to THIS session's objective-BACKED
# scope; headless (no real session env) leaves SCOPE_SESSION unset → ceiling only, byte-identical (never
# the pid-token session_id fallback, which would fail-close every repo). Detached-timer binding = a NOTE.
if [ -z "${SCOPE_SESSION:-}" ] && [ -n "${CLAUDE_SESSION_ID:-}${CLAUDE_CODE_SESSION_ID:-}" ]; then
  export SCOPE_SESSION="$(. "$(dirname "$REPO_SCOPE")/session-id.sh" >/dev/null 2>&1; session_id 2>/dev/null || true)"
fi
"$REPO_SCOPE" check "$REPO" 2>/dev/null \
  || { log "R16 SCOPE: repo '$REPO' is outside the maintainer-confirmed operating scope — refusing to plan (nothing read, nothing filed)"; exit 12; }

# bus_comments → the spec issue's COMPLETE comment stream, one "<login>\t<line-1>" per line, oldest→newest.
# The REST endpoint with `--paginate`, NOT `gh issue view --json comments`, whose GraphQL page carries only
# the newest 100: planned_already must find a summary however long the thread grew, and its failure to see
# one re-plans the spec — a DUPLICATE backlog, the one outcome that must not be reachable by a paging quirk.
# App identities are suffixed REST-side (`<app>[bot]`); strip it so the comparison matches the bare
# $DEV_LOGIN form the rest of the fleet uses (dev-loop's park gate, the poller's FITNESS_LOGIN).
bus_comments(){
  gh api "repos/$SLUG/issues/$SPEC/comments" --paginate \
     -q '.[] | [((.user.login // "") | rtrimstr("[bot]")), ((.body // "") | split("\n")[0])] | @tsv' 2>/dev/null
}

# 1) GUARD — read the spec + its confirmation state (R1). Refuse an unconfirmed spec, fail-closed.
title="$(gh issue view "$SPEC" --repo "$SLUG" --json title -q .title 2>/dev/null)" \
  || { log "cannot read spec $SLUG#$SPEC (fail-closed)"; exit 2; }
body="$(gh issue view "$SPEC" --repo "$SLUG" --json body -q .body 2>/dev/null)"
# The BUS — read ONCE, and it carries every fact the old local markers used to: whether this spec is
# already planned, and who confirmed it. Unreadable ⇒ we cannot prove the spec is not already planned,
# so we refuse (fail-closed against a duplicate plan) rather than re-spend a model run and re-file.
bus="$(bus_comments)" \
  || { log "cannot read the comment stream of $SLUG#$SPEC — refusing (cannot prove it is not already planned)"; exit 2; }
if [ "$(planned_already "$DEV_LOGIN" "$bus")" = 1 ]; then
  log "spec $SLUG#$SPEC already planned (its 'planned:' summary is on the issue) — skipping (idempotent)"; exit 0
fi
# LABEL gate, APPLIER-BOUND: presence alone is forgeable by any write/triage identity (incl. the fleet
# Apps), so resolve WHO applied it — the LAST `labeled` timeline event for this label — and bind that
# actor to admin|maintain. Unfetchable timeline / non-maintainer applier ⇒ inert (fail-closed).
has_appr=0
if gh issue view "$SPEC" --repo "$SLUG" --json labels -q '.labels[].name' 2>/dev/null | grep -qx "$APPROVED_LABEL"; then
  appr_by="$(gh api "repos/$SLUG/issues/$SPEC/timeline" --paginate \
               -q '.[] | select(.event == "labeled" and .label.name == "'"$APPROVED_LABEL"'") | .actor.login' 2>/dev/null | tail -1)"
  if [ -z "$appr_by" ]; then
    log "'$APPROVED_LABEL' is present but WHO applied it is unfetchable — inert (fail-closed)"
  else
    role="$(gh api "repos/$SLUG/collaborators/$appr_by/permission" -q .role_name 2>/dev/null)"
    if [ "$(role_can_confirm "$role")" = 1 ]; then
      has_appr=1; log "CONFIRMED by maintainer @$appr_by ('$APPROVED_LABEL' label; role: $role)"
    else
      log "ignoring '$APPROVED_LABEL' applied by @$appr_by (role: ${role:-unfetchable} — not a maintainer)"
    fi
  fi
fi
# Comment gate, anchor-bound (auto-merge G2 discipline): only LINE 1 of each comment is read (machine-
# owned position), and it acts only when its author holds admin|maintain on the repo — verified against
# the GitHub permission API per author, fail-closed (unfetchable role ⇒ not a maintainer ⇒ inert).
has_conf=0
if [ "$has_appr" != 1 ]; then
  while IFS=$'\t' read -r c_login c_line1; do
    [ -n "$c_login" ] || continue
    [ "$(confirm_line1 "$c_line1")" = 1 ] || continue
    role="$(gh api "repos/$SLUG/collaborators/$c_login/permission" -q .role_name 2>/dev/null)"
    if [ "$(role_can_confirm "$role")" = 1 ]; then
      has_conf=1; log "CONFIRMED by maintainer @$c_login (role: $role)"; break
    fi
    log "ignoring line-1 CONFIRMED from @$c_login (role: ${role:-unfetchable} — not a maintainer)"
  done <<<"$bus"
fi
if [ "$(is_confirmed "$has_appr" "$has_conf")" != CONFIRMED ]; then
  log "spec $SLUG#$SPEC is NOT confirmed (needs a MAINTAINER-applied '$APPROVED_LABEL' label or a maintainer line-1 CONFIRMED comment) — refusing"
  gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → refused:** this objective is not yet confirmed. A repo MAINTAINER (admin|maintain) must either apply the \`$APPROVED_LABEL\` label or post a comment whose FIRST line starts with \`CONFIRMED\`, to authorize planning (R1). A label applied by a non-maintainer identity does not authorize anything." >/dev/null 2>&1 || true
  exit 3
fi

# 2) PLAN — ONE bounded claude -p decomposes the confirmed objective, WRITING each feature to a file.
OUTDIR="$(mktemp -d)"; trap 'rm -rf "$OUTDIR"' EXIT

# THE ALREADY-FILED TITLES RIDE INTO THE PROMPT — this is what makes the DEFER paths recoverable rather
# than duplicative. Every deferred exit (cap overflow 8, partial create 6, un-postable summary 9) leaves
# the spec UNPLANNED with some of its features ALREADY FILED, so the recovery run RE-PLANS — and the only
# dedup the harness has is an EXACT-title match (`grep -qxF`, below). A fresh model run is
# non-deterministic: left BLIND to the bus it re-words the features it already filed, the exact-title
# dedup sails straight past them, and it files near-duplicates of live backlog issues that dev-loop then
# authors into duplicate PRs. So the planner is TOLD what is already filed and told to reuse those titles
# verbatim. The harness still owns the dedup, and this is an INSTRUCTION to a model, not a guarantee — a
# re-worded title can still slip through, which is exactly what the cap-overflow comment now says out
# loud instead of implying the dedup is airtight. Best-effort read: unreadable ⇒ no block in the prompt
# (the FAIL-CLOSED dedup fetch after the plan is the actual gate on filing).
prior="$(gh issue list --repo "$SLUG" --label "$BACKLOG_LABEL" --state all --limit 200 \
           --json title -q '.[].title' 2>/dev/null)"
prior_block=""
[ -n "$prior" ] && prior_block="ALREADY FILED — these features are already \`$BACKLOG_LABEL\` issues in $SLUG:
$(printf '%s\n' "$prior" | sed 's/^/  - /')
If a feature you plan is one of those, REUSE ITS TITLE VERBATIM — the harness dedups by EXACT title and
will skip it. NEVER re-word an already-filed feature into a near-duplicate.
"

read -r -d '' prompt <<PLAN_EOF || true
You are the fedora-dev autonomous PLANNER. Decompose the CONFIRMED objective in issue $SLUG#$SPEC into a
small set of INDEPENDENT, buildable FEATURES — each one a self-contained change the feature-author can
implement in one PR. Aim for the SMALLEST set that faithfully covers the objective (do not pad); at most
$MAX_FEATURES.

OBJECTIVE (issue #$SPEC): $title

$body

$prior_block
For EACH feature, WRITE a file named '$OUTDIR/feat-NN.md' (NN = 01, 02, …), where:
  - line 1 is '# <concise imperative feature title>'
  - the rest is the feature spec: what to build, acceptance criteria, and which existing files it touches.
Make each feature genuinely actionable and independently shippable. Do NOT create GitHub issues yourself,
do NOT push or open PRs — only write the files. When done, end your reply with exactly:
    PLAN_DONE: <N features written>
If the objective is too vague or cannot be planned, write no files and end with:
    PLAN_BLOCKED: <one concise reason>
PLAN_EOF

log "planning $SLUG#$SPEC '$title' (bounded ${PLAN_TIMEOUT}s, prompt ${#prompt} bytes)…"
# THE PROMPT RIDES STDIN, NEVER ARGV (#155) — same law as dev-author's run (see there for the why). This
# prompt embeds a SPEC ISSUE BODY plus the already-filed titles, so it grows without bound; as an argv
# argument it would fail to EXEC with E2BIG past MAX_ARG_STRLEN (131072 bytes) and the planner would
# never run. Feeding it on stdin has no ceiling AND subsumes the old `</dev/null`: the model's stdin is
# the prompt pipe, so it can drain nothing else (a caller's list can never be swallowed by this run).
#
# THE `cd` IS A FAIL-CLOSED GUARD, SO BIND THE BODY TO IT. `cd "$OUTDIR" && set +o pipefail; <pipe>` does
# NOT: `&&` binds to `set` alone and the `;` ends the list, so the pipeline runs ANYWAY — in the CALLER'S
# cwd (a git clone), where a planner told to WRITE FILES would scatter them. The brace group binds the
# whole body to the cd; a cd that fails runs NOTHING and says so, rather than reaching the no-sentinel
# branch below and blaming a timeout for a planner that never STARTED. File nothing, leave the spec
# UNPLANNED (so a re-run re-plans cleanly). `( cd )` tests what the real cd does.
if ! ( cd "$OUTDIR" ) 2>/dev/null; then
  log "cannot enter the planner's output dir '$OUTDIR' (fail-closed) — the planner was NOT run; filing nothing"
  gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → needs a decision (BLOCKED):** the planner's output directory (\`$OUTDIR\`) could not be entered, so the planner was **never run** — no backlog issues were filed and this spec stays unplanned. An infrastructure failure on the dev box (disk / tmp), not a problem with the spec; fix it and re-run \`dev-plan\`."$'\n\n<sub>autonomous planner (R2). A dev-task question, not an approval request.</sub>' >/dev/null 2>&1 || true
  exit 10
fi
out="$(cd "$OUTDIR" && { set +o pipefail; printf '%s' "$prompt" | timeout "$PLAN_TIMEOUT" $PLAN_CLAUDE 2>&1; })"
sentinel="$(extract_plan_sentinel "$out")"
case "$sentinel" in
  BLOCKED*)
    log "planner reported BLOCKED"
    gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → needs a decision (BLOCKED):** ${sentinel#BLOCKED }"$'\n\n<sub>autonomous planner (R2). No backlog issues filed — a dev-task question, not an approval request.</sub>' >/dev/null 2>&1 || true
    exit 4 ;;
  DONE*) : ;;
  *)
    # No sentinel at all — a timed-out/killed planner may have written a PARTIAL feature set; filing it
    # would silently ship a truncated backlog behind the idempotency marker. Fail-closed: file NOTHING,
    # surface, leave the marker unwritten so a re-run can re-plan (the both-end rigor the DONE end needs).
    log "planner ended WITHOUT a PLAN_DONE/PLAN_BLOCKED sentinel (timeout/interrupted?) — refusing to file a possibly-partial plan"
    gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → needs a decision (BLOCKED):** the planner did not complete (no \`PLAN_DONE\` sentinel — likely a timeout). No backlog issues were filed; re-run \`dev-plan\` (or raise \`PLAN_TIMEOUT\`)."$'\n\n<sub>autonomous planner (R2). A dev-task question, not an approval request.</sub>' >/dev/null 2>&1 || true
    exit 7 ;;
esac

# 3) FILE — deterministic harness: one backlog issue per feature file (the model created none).
shopt -s nullglob
files=("$OUTDIR"/feat-*.md)
# ENFORCE the cap HERE, not in the prompt. MAX_FEATURES is documented as a cap, and a prompt line is a
# request, not a bound — the model can write any number of feat-*.md files. The harness owns every write
# to GitHub, so it owns the cap too.
#
# A CAP MUST DEFER, NEVER DROP — the same principle the partial-create path already obeys, and the reason
# this is not simply a truncation: $OUTDIR is a mktemp the EXIT trap deletes, so a feature we merely skip
# is GONE — deleted work from a maintainer's confirmed objective, with the run still reporting a complete
# plan. So the overflow is (a) carried to the bus BY TITLE below, where a human (or a re-run) can still
# reach it, and (b) treated as an INCOMPLETE plan: no `planned:` summary, so the spec is never marked
# done and a re-run under a raised cap re-plans and files the rest (the title dedup skips what is filed).
dropped=()
if [ "${#files[@]}" -gt "$MAX_FEATURES" ]; then
  for fpath in "${files[@]:$MAX_FEATURES}"; do dropped+=("$(feature_title "$fpath")"); done
  log "planner wrote ${#files[@]} feature file(s) > MAX_FEATURES=$MAX_FEATURES — filing the first $MAX_FEATURES; the other ${#dropped[@]} are DEFERRED (reported on the spec issue, spec left UNPLANNED)"
  files=("${files[@]:0:$MAX_FEATURES}")
fi
if [ "${#files[@]}" -eq 0 ]; then
  log "planner claimed PLAN_DONE but wrote no feature files — surfacing as no-progress"
  gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → needs a decision (BLOCKED):** the planner produced no features (unable to decompose). A maintainer should sharpen the objective." >/dev/null 2>&1 || true
  exit 5
fi
# Existing-title dedup: a re-run after a DEFERRED partial failure files ONLY the still-missing features,
# never duplicates. Fail-closed: if the existing set is unreadable, dedup is impossible → file nothing.
existing="$(gh issue list --repo "$SLUG" --label "$BACKLOG_LABEL" --state all --limit 200 \
              --json title -q '.[].title' 2>/dev/null)" \
  || { log "cannot list existing '$BACKLOG_LABEL' issues (fail-closed — filing nothing, marker not written)"; exit 6; }
# CREATE-ON-USE the backlog label (the host-ticket.sh precedent): dev-plan is repo-agnostic, and a fleet
# repo need not already carry '$BACKLOG_LABEL' (fedora-bootstrap does not). `gh issue create --label` HARD-
# FAILS on an unknown label, so without this every create fails in such a repo and the run defers forever,
# silently. Best-effort: if the label already exists (or we lack label-write), the creates below decide.
gh label create "$BACKLOG_LABEL" --repo "$SLUG" --color 0e8a16 \
   --description "actionable feature ticket — dev-plan (R2) files it, dev-loop authors it" --force >/dev/null 2>&1 || true

created=(); failed=0
for fpath in "${files[@]}"; do
  ftitle="$(feature_title "$fpath")"; [ -n "$ftitle" ] || continue
  if [ -n "$existing" ] && printf '%s\n' "$existing" | grep -qxF -- "$ftitle"; then
    log "  already filed (dedup): $ftitle"; continue
  fi
  fbody="$(feature_body "$fpath")"$'\n\n---\nPart of the objective #'"$SPEC"' — filed autonomously by dev-plan (R2). The dev-loop will author this.'
  bf="$(mktemp)"; printf '%s' "$fbody" > "$bf"
  url="$(gh issue create --repo "$SLUG" --title "$ftitle" --label "$BACKLOG_LABEL" --body-file "$bf" 2>/dev/null)"
  rm -f "$bf"
  [ -n "$url" ] && { created+=("$url"); log "  filed backlog: $url"; } \
    || { failed=$((failed+1)); log "  WARN: failed to file '$ftitle'"; }
done
# TOTAL failure (nothing filed at all) → NOT a transient blip: a missing/unwritable label, lost issue-write
# access, or an issues-disabled repo fails EVERY create identically, and a silent defer would spin that
# forever with no human ever told. Surface it as a dev-task QUESTION — ONCE, so a timer does not re-ask
# every pass — and post no `planned:` summary, so a fixed repo re-plans cleanly. ASK-ONCE IS DERIVED FROM
# THE BUS, NOT CACHED: the question already sitting on the spec issue IS the record that we asked (a local
# marker would be the sole record of that fact, and losing it — a wiped box, a different box — would
# re-ask; spec #135 forbids exactly that). Once a later comment lands (a maintainer's reply, or the
# `planned:` summary of a run whose creates worked), the question is no longer newest and a fresh failure
# asks afresh — the same semantics a marker would have had, with nothing on disk to lose.

# ask_once <anchor> <body> — post a question UNLESS it is already the newest comment on the spec issue
# (the bus IS the record that we asked; see asked_already). The stream is RE-READ here, not taken from the
# opening $bus: a bounded planner run sits in between, and a human may have replied inside that window.
ask_once(){
  local anchor="$1" body="$2" last who line1
  last="$(bus_comments | tail -1)"
  IFS=$'\t' read -r who line1 <<<"$last"
  if [ "$(asked_already "$DEV_LOGIN" "${who:-}" "${line1:-}" "$anchor")" = 1 ]; then
    log "that question is already the newest comment on $SLUG#$SPEC — not re-asking"; return 0
  fi
  gh issue comment "$SPEC" --repo "$SLUG" --body "$body" >/dev/null 2>&1 || log "WARN: could not post the question"
}

if [ "$failed" -gt 0 ] && [ "${#created[@]}" -eq 0 ]; then
  log "every feature create FAILED ($failed) — surfacing a question, spec NOT marked planned"
  ask_once "$CREATE_FAIL_ANCHOR" "**dev-plan → needs a decision (BLOCKED, issue-create failed):** the objective decomposed into $failed feature(s), but EVERY \`gh issue create\` failed — so no backlog issues were filed. Likely the \`$BACKLOG_LABEL\` label cannot be created, or issue-write access to this repo was lost. A maintainer should check the repo's issue permissions; planning re-runs cleanly once fixed."$'\n\n<sub>autonomous planner (R2). A dev-task question, not an approval request.</sub>'
  exit 6
fi
# PARTIAL failure → DEFER, spec NOT marked planned (defers, never drops): the next run re-plans and the
# title dedup above re-files only what is missing. No comment — a partial blip is transient, needs no human.
if [ "$failed" -gt 0 ]; then
  log "$failed feature create(s) failed — DEFERRED, spec NOT marked planned (the ${#created[@]} filed this run are handed to the retry's planner by title and dedup-skipped on an exact match)"
  exit 6
fi

# 4a) CAP OVERFLOW → DEFER, and say so ON THE BUS. The plan is INCOMPLETE, so it must not claim success:
# no `planned:` summary is posted, which leaves the spec re-plannable (that summary IS the tombstone now).
# The dropped TITLES ride the comment, so the work survives $OUTDIR's teardown even if nobody re-runs.
if [ "${#dropped[@]}" -gt 0 ]; then
  log "cap overflow: ${#dropped[@]} feature(s) deferred — reporting on $SLUG#$SPEC, spec left UNPLANNED"
  ask_once "$CAPPED_ANCHOR" "**dev-plan → needs a decision (BLOCKED, plan exceeded MAX_FEATURES):** this objective decomposed into $(( ${#created[@]} + ${#dropped[@]} )) features, but \`MAX_FEATURES=$MAX_FEATURES\` caps one plan. The first $MAX_FEATURES were filed as \`$BACKLOG_LABEL\` issues; the remaining ${#dropped[@]} were **not** filed and are listed here so none is lost:"$'\n'"$(drop_report "${dropped[@]}")"$'\n'"A maintainer should either raise \`MAX_FEATURES\` and re-run \`dev-plan\`, or split this objective into smaller specs. On a re-run the planner is handed the titles already filed above and told to reuse them verbatim, so they dedup-skip on an exact-title match — but that is an instruction to a non-deterministic model, not a guarantee: **if it re-words one, the re-run can file a near-duplicate of an already-filed feature** (and it may word the deferred ones differently too). Skim the backlog after re-running. **This spec is deliberately NOT marked planned** — the cap defers, it never drops."$'\n\n<sub>autonomous planner (R2). A dev-task question, not an approval request.</sub>'
  if [ "${#created[@]}" -gt 0 ]; then printf '%s\n' "${created[@]}"; fi
  exit 8
fi

# 4b) AUDIT — the `planned:` summary on the spec issue (R5). This comment is NOT decoration: it is the
# idempotency TOMBSTONE (planned_already reads it back), so it is posted on EVERY complete plan — the
# all-deduped recovery run included, which would otherwise leave a fully-planned spec with no record and
# re-plan forever. If it cannot be posted we have no record, so the run DEFERS rather than claim success.
if [ "${#created[@]}" -gt 0 ]; then
  summary="**dev-plan → planned:** decomposed this objective into ${#created[@]} backlog feature issue(s):"$'\n'"$(printf -- '- %s\n' "${created[@]}")"
else
  summary="**dev-plan → planned:** every feature of this objective was already filed as a \`$BACKLOG_LABEL\` issue (recovered from an earlier deferred run) — nothing new to file."
fi
summary="$summary"$'\n\n<sub>autonomous planner (R2). The dev-loop authors each; the host live-gate → fitness → poller pipeline ships them. No merge taken.</sub>'
gh issue comment "$SPEC" --repo "$SLUG" --body "$summary" >/dev/null 2>&1 \
  || { log "could not post the plan summary — it is the ONLY record that $SLUG#$SPEC is planned, so this run DEFERS (the ${#created[@]} filed issue(s) dedup-skip on retry)"; exit 9; }
log "PLANNED $SLUG#$SPEC → ${#created[@]} new backlog issue(s)"
if [ "${#created[@]}" -gt 0 ]; then printf '%s\n' "${created[@]}"; fi
exit 0
