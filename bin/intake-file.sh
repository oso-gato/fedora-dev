#!/usr/bin/env bash
# intake-file.sh — THE ORDER DESK'S FILING CLERK: validate a drafted objective and file it as a GitHub
# issue the autonomous loop can actually act on.
#
# WHY THIS EXISTS (STEP 2 of the standing work plan, oso-gato/fedora-dev#274).
# The apparatus had ~11,000 lines of delivery and guard machinery and NO FRONT DOOR. R31 specifies a
# conversational intake and had ZERO lines implemented; `dev-plan.sh` — the first machine in the chain —
# refuses anything without a hand-written issue carrying a hand-applied maintainer approval. So 4,400
# lines of brakes were built around an entrance nobody built, and the maintainer (a non-programmer) had
# no way in except to write specs himself.
#
# THE DIVISION OF LABOUR, and it is the whole point:
#   * THE AGENT interviews the maintainer, DRAFTS the specification INCLUDING the acceptance criteria,
#     and shows it to him. He JUDGES it; he never AUTHORS it. Judging a criterion is easy for a
#     non-programmer; authoring one is the skill he does not have and should not need.
#   * THIS SCRIPT is the deterministic half: it refuses to file a spec the loop cannot act on, then
#     files it. No model, no judgement — a checklist with an exit code.
#   * THE MAINTAINER confirms with ONE tap. He must: `dev-plan.sh` resolves WHO applied the approval
#     and binds that actor to a maintainer role, so the agent cannot self-authorise an objective. That
#     is the correct trust boundary (R1: confirming the spec is a human act) and this script does not
#     try to route around it — it files the issue ASSIGNED to him so it lands in his GitHub app.
#
# THE LABEL IS THE GATE, AND IT MUST NOT BE `backlog` (fitness RETURN on d339476 — the defect this
# script shipped with). `backlog` is not "a ticket to look at": it is the label `dev-loop.sh` sweeps and
# hands STRAIGHT to `dev-author.sh`, which implements it, opens a PR, labels it `live-validate` and lets
# the poller auto-merge it. Filing an un-confirmed objective under it therefore routes PAST R1 entirely —
# the maintainer's `approved` tap is never consulted, because the only component that checks it
# (`dev-plan.sh`) is not in that path at all. So an intake objective is filed under its OWN label
# ($INTAKE_LABEL, default `objective`), which the feature author deliberately does not sweep, and
# `dev-loop.sh`'s PLAN ARM is what carries an `approved`-labelled objective to `dev-plan.sh`. Nothing is
# built from this issue until a MAINTAINER taps `approved`; the label is the gate, and that is the point.
#
# R16 SCOPE (a disclosed deferral, not an oversight): every other actuator calls `bin/repo-scope.sh`
# first. This one deliberately does not YET — with no `policy/scope.conf` present the reader fails
# closed to the apparatus's OWN two repos, which would refuse the front door for exactly the tenant
# repos it exists to serve. The boundary still holds structurally: the App credential cannot reach a
# repo it is not installed on, so a `gh issue create` there simply fails. Wiring the belt (once the
# session-scope path is the norm) is a follow-up, tracked as a NOTE rather than done blind here.
#
# THE LOAD-BEARING VALIDATION IS THE ACCEPTANCE COMMAND. An issue without one leaves "looks done" as the
# only completion signal, which puts a human at the end of every iteration. Measured across ~9,900 agent
# runs: 45-48% of ALL failures were false claims of completion where nothing independent could check;
# where an independent process COULD check, that fell to 3%. So: no runnable check, no ticket.
#
#   intake-file.sh --check <spec.md>            validate only; rc 0 = fileable, rc 1 = incomplete (says why)
#   intake-file.sh --file <spec.md> --repo <r>  validate, then file the issue (assigned, labelled)
#   intake-file.sh --selftest                   exercise the pure core; no network
#
# SPEC FORMAT (what the agent drafts — see the skill for how it is elicited):
#   # <title: one verb, one deliverable>
#   ## Objective        — what and why, in the maintainer's own words
#   ## Scope            — what is IN
#   ## Out of scope     — what is deliberately NOT in (bounds the agent)
#   ## Acceptance       — at least one line starting `$ ` : an exact command a machine can run
#   ## Notes            — optional
#
# FAIL DIRECTION: this REFUSES rather than files a weak ticket. A vague ticket does not fail loudly — it
# produces confident wrong work and a stalled loop, which is far more expensive than a refusal here.
set -uo pipefail

ORG="${ORG:-oso-gato}"
# The intake label — see THE LABEL IS THE GATE above. It MUST NOT be the author loop's $BACKLOG_LABEL
# (`backlog`): that one is swept straight into autonomous implementation, and this issue has not been
# confirmed by anybody yet.
INTAKE_LABEL="${INTAKE_LABEL:-objective}"
APPROVED_LABEL="${APPROVED_LABEL:-approved}"
MAINTAINER="${MAINTAINER:-oso-gato}"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# spec_verdict <has_title> <n_accept_cmds> <n_clarify_markers> <has_scope> <has_outofscope> → READY | the reason
# Order matters: report the FIRST missing thing so the agent gets one clear instruction, not a list.
spec_verdict(){
  local title="${1-}" cmds="${2-}" clar="${3-}" scope="${4-}" oos="${5-}"
  case "$cmds" in ''|*[!0-9]*) printf 'INCOMPLETE: acceptance-command count unreadable\n'; return 1 ;; esac
  case "$clar" in ''|*[!0-9]*) printf 'INCOMPLETE: clarification-marker count unreadable\n'; return 1 ;; esac
  [ "$title" = 1 ] || { printf 'INCOMPLETE: no title line (# <one verb, one deliverable>)\n'; return 1; }
  [ "$clar" -eq 0 ] || { printf 'INCOMPLETE: %s unresolved [NEEDS CLARIFICATION] marker(s) — the interview is not finished\n' "$clar"; return 1; }
  [ "$cmds" -ge 1 ] || { printf 'INCOMPLETE: no acceptance command — add at least one line starting "$ " that a machine can run to prove the work is done\n'; return 1; }
  [ "$scope" = 1 ] || { printf 'INCOMPLETE: no ## Scope section\n'; return 1; }
  [ "$oos" = 1 ] || { printf 'INCOMPLETE: no ## Out of scope section — an unbounded ticket invites scope creep the agent cannot detect\n'; return 1; }
  printf 'READY\n'; return 0
}

# count_accept_cmds <file> → number of `$ ` command lines inside the ## Acceptance section only.
# Scoped to the section ON PURPOSE: a `$ ` example elsewhere in the prose is illustration, not a check.
# UNREADABLE IS NOT ZERO. Both counters emit the literal `unreadable` when they cannot actually count,
# which spec_verdict rejects — the header's "never file on missing evidence" and the selftest's refusal
# rows are then true of the I/O layer too, not just of the pure core. (Emitting 0 was fail-OPEN: an
# unreadable spec would have read as "no clarification markers", i.e. as a clean interview.)
count_accept_cmds(){
  local f="${1-}" in=0 n=0 line
  [ -r "$f" ] || { printf 'unreadable'; return; }
  while IFS= read -r line; do
    case "$line" in
      '## Acceptance'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    case "$line" in
      '$ '*) n=$((n+1)) ;;
      '    $ '*|'  $ '*) n=$((n+1)) ;;
    esac
  done < "$f"
  printf '%s' "$n"
}

has_section(){ grep -qiE "^##[[:space:]]+$2([[:space:]]|$)" "$1" 2>/dev/null && printf 1 || printf 0; }
has_title(){   grep -qE '^#[[:space:]]+\S' "$1" 2>/dev/null && printf 1 || printf 0; }
# NB: `grep -c` PRINTS 0 and EXITS 1 when there is no match, so a naive `|| printf 0` emits "0\n0" —
# non-numeric, which the pure core correctly rejects as unreadable and which refused every clean spec.
# Caught only by running a real file through it; the selftest passed because it hand-fed the counts.
count_clarify(){
  local n rc
  n="$(grep -c 'NEEDS CLARIFICATION' "$1" 2>/dev/null)"; rc=$?
  # rc 0 = matched, 1 = no match (a real count of 0), anything else = grep could not read the file.
  [ "$rc" -le 1 ] || { printf 'unreadable'; return; }
  case "$n" in ''|*[!0-9]*) printf 'unreadable'; return ;; esac
  printf '%s' "$n"
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s\n       want=[%s]\n       got =[%s]\n' "$1" "$3" "$2"; fi; }
  v(){ spec_verdict "$@" 2>/dev/null | head -1; }
  echo "== a complete spec files =="
  ck "all sections + one command" "$(v 1 1 0 1 1)" "READY"
  ck "several commands"           "$(v 1 3 0 1 1)" "READY"
  echo "== THE LOAD-BEARING RULE: no runnable check, no ticket =="
  ck "zero acceptance commands is refused" \
     "$(v 1 0 0 1 1 | cut -c1-30)" "INCOMPLETE: no acceptance comm"
  echo "== an unfinished interview cannot be filed =="
  ck "one unresolved marker blocks"  "$(v 1 1 1 1 1 | cut -c1-24)" "INCOMPLETE: 1 unresolved"
  ck "markers outrank a missing cmd" "$(v 1 0 2 1 1 | cut -c1-24)" "INCOMPLETE: 2 unresolved"
  echo "== structural requirements =="
  ck "no title"        "$(v 0 1 0 1 1 | cut -c1-22)" "INCOMPLETE: no title l"
  ck "no scope"        "$(v 1 1 0 0 1 | cut -c1-25)" "INCOMPLETE: no ## Scope s"
  ck "no out-of-scope" "$(v 1 1 0 1 0 | cut -c1-26)" "INCOMPLETE: no ## Out of s"
  echo "== fail-safe: unreadable counts REFUSE (never file on missing evidence) =="
  ck "unreadable cmd count"     "$(v 1 x 0 1 1 | cut -c1-24)" "INCOMPLETE: acceptance-c"
  ck "unreadable marker count"  "$(v 1 1 x 1 1 | cut -c1-26)" "INCOMPLETE: clarification-"
  # …and the I/O layer actually EMITS that unreadable token, so the rows above are reachable in real
  # life rather than only from hand-fed arguments. (They were not: both counters used to answer 0.)
  ck "count_clarify on an unreadable file"     "$(count_clarify /nonexistent/spec.md)" "unreadable"
  ck "count_accept_cmds on an unreadable file" "$(count_accept_cmds /nonexistent/spec.md)" "unreadable"
  echo "== the intake label is NOT the label the feature author sweeps (fitness RETURN, d339476) =="
  ck "INTAKE_LABEL default is not 'backlog'" "$INTAKE_LABEL" "objective"
  echo; echo "intake-file selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

log(){ echo "intake: $*" >&2; }

MODE=""; SPEC=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; SPEC="${2:-}"; shift 2 ;;
    --file)  MODE=file;  SPEC="${2:-}"; shift 2 ;;
    --repo)  REPO="${2:-}"; shift 2 ;;
    *) echo "usage: intake-file.sh {--check <spec.md> | --file <spec.md> --repo <repo>} | --selftest" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] && [ -r "$SPEC" ] || { echo "usage: intake-file.sh {--check <spec.md> | --file <spec.md> --repo <repo>} | --selftest" >&2; exit 2; }

verdict="$(spec_verdict "$(has_title "$SPEC")" "$(count_accept_cmds "$SPEC")" "$(count_clarify "$SPEC")" \
                        "$(has_section "$SPEC" Scope)" "$(has_section "$SPEC" 'Out of scope')")"
rc=$?
if [ "$rc" -ne 0 ]; then
  log "REFUSED — $verdict"
  log "the spec is not yet something the loop can act on; finish the interview and re-check"
  exit 1
fi
log "spec is READY ($(count_accept_cmds "$SPEC") acceptance command(s))"
[ "$MODE" = check ] && exit 0

[ -n "$REPO" ] || { log "--file needs --repo"; exit 2; }
title="$(grep -m1 -E '^#[[:space:]]+' "$SPEC" | sed -E 's/^#[[:space:]]+//')"
body="$(cat "$SPEC")"
bodyfile="$(mktemp)"
{
  printf '%s\n\n---\n\n' "$body"
  printf '<sub>Drafted conversationally with the maintainer and filed by `intake-file.sh` (R31). '
  printf 'Validated: has a title, a bounded scope, and at least one **runnable acceptance command**; '
  printf 'no unresolved clarification markers.</sub>\n\n'
  printf '**@%s — this is waiting on you.** Nothing is built from this issue until you apply the `%s` label.\n' \
         "$MAINTAINER" "$APPROVED_LABEL"
  printf 'It is filed as `%s`, which the feature author does not sweep; the one tap is what hands it to the planner\n' "$INTAKE_LABEL"
  printf '(`dev-plan.sh` decomposes it into feature tickets, which the loop then implements, gates and ships).\n'
  printf 'The agent deliberately cannot self-approve: `dev-plan.sh` resolves WHO applied the label and binds that actor to a maintainer role.\n'
} > "$bodyfile"

# CREATE-ON-USE the intake label (the dev-plan.sh / host-ticket.sh precedent): `gh issue create --label`
# HARD-FAILS on a label the repo does not carry, and `$INTAKE_LABEL` is deliberately NOT one of the
# labels the fleet already uses — so without this, the very first intake into any repo fails outright.
gh label create "$INTAKE_LABEL" --repo "$ORG/$REPO" --color 5319e7 \
   --description "a drafted objective awaiting the maintainer's '$APPROVED_LABEL' tap (R31 intake)" \
   --force >/dev/null 2>&1 || true

url="$(gh issue create --repo "$ORG/$REPO" --title "$title" --body-file "$bodyfile" \
        --label "$INTAKE_LABEL" --assignee "$MAINTAINER" 2>&1)" || {
  log "FAILED to file the issue: $url"; rm -f "$bodyfile"; exit 1; }
rm -f "$bodyfile"
log "FILED: $url"
log "next: the maintainer applies the '$APPROVED_LABEL' label — dev-loop's plan arm then hands it to dev-plan.sh, which decomposes it into backlog feature issues. Until that tap, nothing acts on it."
printf '%s\n' "$url"
