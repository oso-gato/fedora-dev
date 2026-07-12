#!/usr/bin/env bash
# dev-plan.sh — the AUTONOMOUS PLANNER (apparatus spec fedora-dev#135 R2).
#
# Turns a HUMAN-CONFIRMED objective/spec issue into a numbered set of `backlog`-labelled FEATURE issues,
# one per feature — the work-list the dev-loop driver (P3) then authors (R3) and the pipeline ships. It
# is the front of the loop: after this, the human is out until an ESCALATE question (R13).
#
# R1 discipline — it plans ONLY the human-confirmed spec: the spec issue must carry the `approved` label
# OR a MAINTAINER `CONFIRMED` comment; an unconfirmed spec is refused (the confirmed set is what fitness
# later grades against, so planning an unconfirmed one would ground the whole loop in unratified intent).
# The comment gate is bound like every fleet trust anchor (the auto-merge G2 discipline): the token must
# OPEN line 1 of the comment (machine-owned position — a quoted or mid-prose token never acts) AND the
# comment author must hold admin|maintain on the repo (permission-checked against the GitHub API, never
# text-trusted; the label path is already permission-gated by GitHub itself). Any check unfetchable →
# not confirmed (fail-closed).
#
# DETERMINISM split (design law): the JUDGMENT — "what features does this objective decompose into" — is
# ONE bounded `claude -p`, which WRITES each feature as a file (never creates issues itself). The ACTION
# — creating the `backlog` issues — is the plain-shell harness reading those files. So issue creation is
# deterministic + auditable, and the model touches no GitHub state.
#
#   dev-plan.sh <repo> <spec-issue#>   plan the confirmed objective into backlog feature issues
#   dev-plan.sh --selftest             exercise the pure helpers (no gh / claude / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); APPROVED_LABEL (default approved);
#      PLAN_CLAUDE (default "claude -p", overridable for the mock test); PLAN_TIMEOUT (default 1800);
#      MAX_FEATURES (cap the plan size, default 8); DEV_PLAN_STATE (marker dir).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
APPROVED_LABEL="${APPROVED_LABEL:-approved}"
PLAN_CLAUDE="${PLAN_CLAUDE:-claude -p}"
PLAN_TIMEOUT="${PLAN_TIMEOUT:-1800}"
MAX_FEATURES="${MAX_FEATURES:-8}"
STATE="${DEV_PLAN_STATE:-$HOME/.local/state/dev-plan}"

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
mkdir -p "$STATE"
marker="$STATE/${REPO}-${SPEC}.planned"

if [ -f "$marker" ]; then log "spec $SLUG#$SPEC already planned — skipping (idempotent)"; exit 0; fi

# 1) GUARD — read the spec + its confirmation state (R1). Refuse an unconfirmed spec, fail-closed.
title="$(gh issue view "$SPEC" --repo "$SLUG" --json title -q .title 2>/dev/null)" \
  || { log "cannot read spec $SLUG#$SPEC (fail-closed)"; exit 2; }
body="$(gh issue view "$SPEC" --repo "$SLUG" --json body -q .body 2>/dev/null)"
has_appr=0; gh issue view "$SPEC" --repo "$SLUG" --json labels -q '.labels[].name' 2>/dev/null | grep -qx "$APPROVED_LABEL" && has_appr=1
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
  done < <(gh issue view "$SPEC" --repo "$SLUG" --json comments \
             -q '.comments[] | [.author.login, (.body | split("\n")[0])] | @tsv' 2>/dev/null)
fi
if [ "$(is_confirmed "$has_appr" "$has_conf")" != CONFIRMED ]; then
  log "spec $SLUG#$SPEC is NOT confirmed (needs the '$APPROVED_LABEL' label or a maintainer line-1 CONFIRMED comment) — refusing"
  gh issue comment "$SPEC" --repo "$SLUG" --body "**dev-plan → refused:** this objective is not yet confirmed. Add the \`$APPROVED_LABEL\` label, or have a repo maintainer post a comment whose FIRST line starts with \`CONFIRMED\`, to authorize planning (R1)." >/dev/null 2>&1 || true
  exit 3
fi

# 2) PLAN — ONE bounded claude -p decomposes the confirmed objective, WRITING each feature to a file.
OUTDIR="$(mktemp -d)"; trap 'rm -rf "$OUTDIR"' EXIT
read -r -d '' prompt <<PLAN_EOF || true
You are the fedora-dev autonomous PLANNER. Decompose the CONFIRMED objective in issue $SLUG#$SPEC into a
small set of INDEPENDENT, buildable FEATURES — each one a self-contained change the feature-author can
implement in one PR. Aim for the SMALLEST set that faithfully covers the objective (do not pad); at most
$MAX_FEATURES.

OBJECTIVE (issue #$SPEC): $title

$body

For EACH feature, WRITE a file named '$OUTDIR/feat-NN.md' (NN = 01, 02, …), where:
  - line 1 is '# <concise imperative feature title>'
  - the rest is the feature spec: what to build, acceptance criteria, and which existing files it touches.
Make each feature genuinely actionable and independently shippable. Do NOT create GitHub issues yourself,
do NOT push or open PRs — only write the files. When done, end your reply with exactly:
    PLAN_DONE: <N features written>
If the objective is too vague or cannot be planned, write no files and end with:
    PLAN_BLOCKED: <one concise reason>
PLAN_EOF

log "planning $SLUG#$SPEC '$title' (bounded ${PLAN_TIMEOUT}s)…"
out="$(cd "$OUTDIR" && timeout "$PLAN_TIMEOUT" $PLAN_CLAUDE "$prompt" 2>&1)"
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
# ANY create failure → DEFER, marker NOT written (defers, never drops): the next run re-plans and the
# title dedup above re-files only what is missing. No comment — transient API failure needs no human.
if [ "$failed" -gt 0 ]; then
  log "$failed feature create(s) failed — DEFERRED, marker NOT written (${#created[@]} filed this run will be dedup-skipped on retry)"
  exit 6
fi

# 4) AUDIT — summarise on the spec issue (R5) + mark planned (idempotent) — only on a COMPLETE plan.
if [ "${#created[@]}" -gt 0 ]; then
  summary="**dev-plan → planned:** decomposed this objective into ${#created[@]} backlog feature issue(s):"$'\n'"$(printf '- %s\n' "${created[@]}")"$'\n\n<sub>autonomous planner (R2). The dev-loop authors each; the host live-gate → fitness → poller pipeline ships them. No merge taken.</sub>'
  gh issue comment "$SPEC" --repo "$SLUG" --body "$summary" >/dev/null 2>&1 || log "WARN: could not post the plan summary"
else
  log "every planned feature was already filed (recovered from an earlier deferred run)"
fi
: > "$marker"
log "PLANNED $SLUG#$SPEC → ${#created[@]} new backlog issue(s)"
if [ "${#created[@]}" -gt 0 ]; then printf '%s\n' "${created[@]}"; fi
exit 0
