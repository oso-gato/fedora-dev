#!/usr/bin/env bash
# host-ticket.sh — DEV-SIDE PRODUCER for the dev→host ticket bus (apparatus fedora-dev#131 R5).
#
# The dev box (fedora-dev / nox) is WALLED OFF from host operations. To get a host op done it FILES a
# TICKET — a `host-task`-labelled issue in the CONTROL REPO (oso-gato/fedora-bootstrap) whose FIRST
# body line is the machine instruction `host-op: <verb> [args]`. The host agent
# (fedora-bootstrap:host-agent-watch.sh — the symmetric CONSUMER) reads line 1, performs the
# allowlisted op, and posts a `host-agent: DONE|FAILED` comment + closes the issue.
#
# This is the counterpart producer to that consumer. Deterministic, PLAIN SHELL — like the poller, NO
# Claude in the loop. Uses the standing App `gh` credential (needs Issues:write on the control repo).
#
# USAGE:
#   host-ticket.sh redeploy fedora-dev          # file the ticket, print its URL, exit 0
#   host-ticket.sh --wait redeploy fedora-dev   # file, then BLOCK until the host agent responds:
#                                               #   exit 0 on host-agent DONE, 1 on FAILED, 2 on timeout
#   host-ticket.sh --selftest                   # pure-helper self-checks (no network)
#
# ENV (mirror the consumer): HOST_TICKET_ORG=oso-gato, HOST_TICKET_REPO=fedora-bootstrap,
#   HOST_TICKET_LABEL=host-task, HOST_TICKET_TIMEOUT=600, HOST_TICKET_POLL=10.
set -uo pipefail
set -f   # the verb+args become issue text; no globbing wanted

ORG="${HOST_TICKET_ORG:-oso-gato}"
REPO="${HOST_TICKET_REPO:-fedora-bootstrap}"
LABEL="${HOST_TICKET_LABEL:-host-task}"
SLUG="$ORG/$REPO"
WAIT_TIMEOUT="${HOST_TICKET_TIMEOUT:-600}"   # seconds to wait for a host-agent response (--wait)
POLL_INTERVAL="${HOST_TICKET_POLL:-10}"      # matches the host agent's 10s cadence

# MULTI-SESSION TICKET ISOLATION (R3): every ticket is STAMPED with the filing session's name, and a
# session can read back ONLY its own tickets' results. The name comes from bin/session-id.sh's
# session_id() — the SAME minter every actuator in the session shares — so all of one session's
# host-ticket.sh calls stamp identically. SESSION_ID_LIB is a test seam (default the sibling) so a
# neutralized copy of this file can still source the real minter.
HT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_ID_LIB="${SESSION_ID_LIB:-$HT_DIR/session-id.sh}"
# shellcheck source=session-id.sh
. "$SESSION_ID_LIB"

die(){ echo "host-ticket: $*" >&2; exit 1; }
log(){ echo "host-ticket: $*" >&2; }

# ---- pure helpers (no I/O) -------------------------------------------------------------------------
# op_line: the FIRST body line the consumer parses — MUST stay byte-compatible with host-agent-watch's
# `host-op: <verb> [args]` line-1 grammar.
op_line(){ printf 'host-op: %s' "$*"; }
# outcome_of: given all comment bodies on stdin, echo done|failed|"" — anchored to the
# `host-agent: DONE|FAILED` STATUS marker the consumer posts (never free-text detail). DONE is checked
# first so a DEFERRED-but-DONE verdict (or detail prose mentioning "fail") never misreads as failed.
outcome_of(){
  local b; b="$(cat)"
  printf '%s\n' "$b" | grep -qiE 'host-agent:[*[:space:]]*done'   && { echo done;   return 0; }
  printf '%s\n' "$b" | grep -qiE 'host-agent:[*[:space:]]*failed' && { echo failed; return 0; }
  echo ""; return 0
}
# session_of: given an issue body on stdin, echo the SID on its FIRST `host-session: <SID>` line, or ""
# if none. Anchored to the WHOLE line at column 0 (the stamp's byte position) so the same string quoted
# in prose can never be read as the stamp — the ownership fact the isolation enforcement rests on.
session_of(){
  local s; s="$(grep -m1 '^host-session: ' 2>/dev/null || true)"
  s="${s#host-session: }"; s="${s%$'\r'}"
  printf '%s' "$s"
}

if [ "${1:-}" = "--selftest" ]; then
  f=0
  [ "$(op_line redeploy fedora-dev)" = "host-op: redeploy fedora-dev" ] && echo "ok: op_line" || { echo "FAIL op_line"; f=1; }
  [ "$(printf '%s' '**host-agent: DONE** — redeploy done'          | outcome_of)" = done   ] && echo "ok: done"   || { echo "FAIL done"; f=1; }
  [ "$(printf '%s' '**host-agent: FAILED** — nope'                 | outcome_of)" = failed ] && echo "ok: failed" || { echo "FAIL failed"; f=1; }
  [ "$(printf '%s' 'just a human comment'                          | outcome_of)" = ""     ] && echo "ok: none"   || { echo "FAIL none"; f=1; }
  # a DONE verdict whose DETAIL prose mentions "fail" must still read as done (DONE checked first, anchored):
  [ "$(printf '%s' '**host-agent: DONE** — deploy ok, no health-failure' | outcome_of)" = done ] && echo "ok: done-not-failed" || { echo "FAIL done-not-failed"; f=1; }
  # a DEFERRED redeploy is reported by the consumer as DONE → producer reads done:
  [ "$(printf '%s' "**host-agent: DONE** — redeploy 'x' DEFERRED — workload busy" | outcome_of)" = done ] && echo "ok: deferred=done" || { echo "FAIL deferred"; f=1; }
  [ "$f" = 0 ] && echo "ALL HOST-TICKET SELFTESTS PASS" || echo "HOST-TICKET SELFTESTS FAILED"; exit "$f"
fi

# The filing session's STABLE name — the same for every host-ticket.sh call this session makes (that is
# the whole property isolation rests on: see bin/session-id.sh). HOST_SESSION_ID is a direct test
# override; production leaves it unset and drives the SID through CLAUDE_CODE_SESSION_ID → session_id().
SID="${HOST_SESSION_ID:-$(session_id)}"
[ -n "$SID" ] || die "session_id() yielded an EMPTY SID — refusing to file or read an unstamped ticket"

# ---- --mine: list only THIS session's OPEN host-task tickets (<number>\t<title>) -------------------
if [ "${1:-}" = "--mine" ]; then
  # gh returns EVERY open host-task issue as `<number>\t<title>\t<its host-session stamp>`: jq splits each
  # body on newlines and lifts the FIRST `host-session: ` line's value (a single token — no tabs, no
  # newlines — so one issue = exactly one @tsv line). The SID FILTER lives HERE in shell, never in gh: a
  # ticket is mine iff its lifted stamp EQUALS my SID. That this equality — not gh — is what selects is
  # exactly what the isolation proof mutation-checks (neutralize the compare and another session leaks in).
  gh issue list --repo "$SLUG" --label "$LABEL" --state open --json number,title,body \
       --jq '.[] | [.number, .title, (.body / "\n" | map(select(startswith("host-session: "))) | (.[0] // "") | ltrimstr("host-session: ") | rtrimstr("\r"))] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r num title stamp; do
        [ -n "$num" ] || continue
        [ "$stamp" = "$SID" ] && printf '%s\t%s\n' "$num" "$title"
      done
  exit 0
fi

# ---- --outcome <num>: read a ticket's outcome, but ONLY if THIS session filed it (the ENFORCEMENT) --
if [ "${1:-}" = "--outcome" ]; then
  num="${2:-}"
  case "$num" in ''|*[!0-9]*) die "usage: host-ticket.sh --outcome <issue-number>";; esac
  body="$(gh issue view "$num" --repo "$SLUG" --json body -q .body 2>/dev/null)" \
    || die "could not read $SLUG#$num (does it exist? does the App have Issues:read on $SLUG?)"
  owner="$(printf '%s' "$body" | session_of)"
  if [ -z "$owner" ]; then
    echo "host-ticket: issue #$num carries NO host-session stamp — refusing to read a ticket whose owning session is unknown (mine is $SID)" >&2
    exit 3
  fi
  if [ "$owner" != "$SID" ]; then
    echo "host-ticket: issue #$num belongs to session $owner, not $SID — refusing to read another session's ticket" >&2
    exit 3
  fi
  # mine → report the host agent's verdict, matching --wait's exit contract (0 done / 1 failed / 2 none).
  oc="$(gh issue view "$num" --repo "$SLUG" --json comments -q '.comments[].body | split("\n")[0]' 2>/dev/null | outcome_of)"
  [ -n "$oc" ] && echo "$oc"
  case "$oc" in
    done)   exit 0;;
    failed) exit 1;;
    *)      exit 2;;
  esac
fi

WAIT=0; [ "${1:-}" = "--wait" ] && { WAIT=1; shift; }
verb="${1:-}"; [ -n "$verb" ] || die "usage: host-ticket.sh [--wait] <verb> [args...]  (e.g. redeploy fedora-dev)"; shift || true
args="$*"
opline="$(op_line "$verb${args:+ $args}")"

# R16 OPERATING SCOPE (#167): filing a ticket is an action against the target control repo — refuse
# an out-of-scope one before the label/issue writes. (The verb's WORKLOAD argument is gated by its
# producers — bin/host-refresh.sh scope-checks each workload it scans — and by the host agent's own
# KNOWN_WORKLOADS allowlist on the consuming side; verb args are opaque here by design.) Any
# non-zero reader rc (127 included) refuses (fail-closed).
HERE="$(dirname "$(readlink -f "$0")")"
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
"$REPO_SCOPE" check "$REPO" 2>/dev/null \
  || die "R16 SCOPE: control repo '$SLUG' is outside the maintainer-confirmed operating scope — no ticket filed"

# ensure the ticket label exists — creating an issue with an unknown label fails (create-on-use).
gh label create "$LABEL" --repo "$SLUG" --color 5319e7 \
   --description "dev→host op ticket — host-agent-watch consumes line 1 (host-op:)" --force >/dev/null 2>&1 || true

tmp="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT   # Principle-10 teardown: no temp leak on any exit path (incl. SIGINT mid-create)
# LINE 1 stays byte-identical to the consumer's grammar (`host-op: <verb> [args]`); LINE 2 is the
# multi-session STAMP (`host-session: <SID>`) that --mine/--outcome key on. The host consumer parses
# only line 1, so the stamp is invisible to it — the isolation is entirely dev-side (R3).
{ printf '%s\n' "$opline"
  printf 'host-session: %s\n\n' "$SID"
  printf '%s\n' "_Filed by host-ticket.sh — the dev→host ticket bus (apparatus R5). The host agent reads line 1 (\`host-op:\`), performs the allowlisted op, and posts the outcome below + closes this issue._"
} > "$tmp"

url="$(gh issue create --repo "$SLUG" --title "host-task: $verb${args:+ $args}" --label "$LABEL" --body-file "$tmp" 2>&1)" \
   || die "gh issue create failed (does the App have Issues:write on $SLUG?): $url"
echo "$url"
num="${url##*/}"
case "$num" in ''|*[!0-9]*) [ "$WAIT" = 1 ] && die "created, but could not parse an issue number from '$url' to --wait"; exit 0;; esac

[ "$WAIT" = 1 ] || exit 0

# ROBUSTNESS (isolation): --wait blocks on the issue we JUST created — verify it actually carries OUR
# stamp before trusting it. A mismatch means we parsed the wrong number or another actor raced the
# create; either way waiting on a ticket that is not provably ours is exactly what isolation forbids.
created_sid="$(gh issue view "$num" --repo "$SLUG" --json body -q .body 2>/dev/null | session_of)"
[ "$created_sid" = "$SID" ] || die "created $SLUG#$num but its host-session stamp '${created_sid:-<none>}' != mine '$SID' — refusing to --wait on a ticket that is not provably ours"

log "waiting up to ${WAIT_TIMEOUT}s for the host agent to respond to $SLUG#$num (poll ${POLL_INTERVAL}s)…"
waited=0
while :; do
  # anchor to each comment's FIRST line — the consumer puts its `**host-agent: DONE|FAILED** — …` marker
  # on line 1, so the same marker merely quoted in another comment's prose can never false-positive.
  oc="$(gh issue view "$num" --repo "$SLUG" --json comments -q '.comments[].body | split("\n")[0]' 2>/dev/null | outcome_of)"
  case "$oc" in
    done)   log "host-agent DONE — $SLUG#$num"; exit 0;;
    failed) log "host-agent FAILED — $SLUG#$num"; exit 1;;
  esac
  # timeout is exit 2 (NOT die's 1) so a caller can tell a retryable "no response yet" from a FAILED op.
  [ "$waited" -ge "$WAIT_TIMEOUT" ] && { log "timeout after ${WAIT_TIMEOUT}s — no host-agent response on $SLUG#$num (is the host agent running on erebus?)"; exit 2; }
  sleep "$POLL_INTERVAL"; waited=$((waited+POLL_INTERVAL))
done
