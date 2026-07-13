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
{ printf '%s\n\n' "$opline"
  printf '%s\n' "_Filed by host-ticket.sh — the dev→host ticket bus (apparatus R5). The host agent reads line 1 (\`host-op:\`), performs the allowlisted op, and posts the outcome below + closes this issue._"
} > "$tmp"

url="$(gh issue create --repo "$SLUG" --title "host-task: $verb${args:+ $args}" --label "$LABEL" --body-file "$tmp" 2>&1)" \
   || die "gh issue create failed (does the App have Issues:write on $SLUG?): $url"
echo "$url"
num="${url##*/}"
case "$num" in ''|*[!0-9]*) [ "$WAIT" = 1 ] && die "created, but could not parse an issue number from '$url' to --wait"; exit 0;; esac

[ "$WAIT" = 1 ] || exit 0

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
