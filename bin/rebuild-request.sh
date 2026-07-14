#!/usr/bin/env bash
# rebuild-request.sh — the DEV-SIDE PRODUCER for R17 REBUILD CONTINUITY (fedora-dev#174).
#
# THE PAIR (pair-is-the-orchestrator): a purposeful rebuild KILLS the dev container and every process
# and session inside it, rebuilds it to the current spec, then RESTORES + RESUMES the sessions that were
# running (R17). Code running INSIDE the box cannot do that — it dies at the KILL step. So the HOST does
# the whole lifecycle from OUTSIDE via the already-merged `rebuild-devbox` verb
# (fedora-bootstrap host-agent-watch.sh): a container destroyed FROM THE HOST leaves no PID-namespace
# ghost, which an in-container `distrobox rm -f` cannot avoid.
#
# The host executor owns KILL → REBUILD → RESTORE → RESUME → VERIFY. The ONLY thing it cannot know is
# what was running on the dev box. THIS producer supplies exactly that: it enumerates the live tmux
# sessions into the executor's `session <name> <cwd>` MANIFEST grammar and composes the `rebuild-devbox`
# ticket. The executor recreates each session (`tmux new-session -d -s <name> -c <cwd>`) and resumes it
# (`claude --continue` typed in that cwd), then verifies alive-AND-active + the poller sweeping.
#
# WHY BASE-LEVEL: `tmux` lives in the fedora-dev BASE image, NOT the claudebox (it is not in
# distrobox.ini additional_packages). The tmux server runs at the fedora-dev container level. So this
# producer MUST run there (where `box-rebuild.sh` already runs), not inside the box.
#
# WHY IT DOES NOT FILE THE TICKET ITSELF: `rebuild-devbox` is a DESTRUCTIVE verb (it kills the whole
# box + all sessions). The executor deliberately AUTHOR-GATES it to a human admin|maintain and REFUSES
# an App/bot author (host-agent-watch.sh is_authorized_author) — a purposeful rebuild is a human,
# explicit action by design (R17). So this producer composes the ticket and presents it for a
# MAINTAINER to author (a prefilled new-issue URL + the raw body). It weakens no gate. A fully
# autonomous trigger would require relaxing that host author-gate — a separate maintainer decision, not
# taken here.
#
# USAGE:
#   rebuild-request.sh                 # enumerate → compose ticket body → present for a maintainer to file
#   rebuild-request.sh manifest        # print ONLY the manifest block (BEGIN…session…END) to stdout
#   rebuild-request.sh --selftest      # pure-helper self-checks (no tmux, no network)
#   rebuild-request.sh --help
set -uo pipefail
set -f   # session names + cwds become issue text AND (host-side) literal argv — never let a glob expand

# ── contract constants — MUST stay byte-identical to fedora-bootstrap host-agent-watch.sh ────────────
MANIFEST_BEGIN='%%DEVBOX-MANIFEST-BEGIN%%'
MANIFEST_END='%%DEVBOX-MANIFEST-END%%'
DEVBOX_MAX_SESSIONS="${DEVBOX_MAX_SESSIONS:-32}"        # executor rejects a manifest with > this many
REBUILD_WORKLOAD="${REBUILD_WORKLOAD:-fedora-dev}"     # executor REBUILD_WORKLOADS allowlist (exact match)
TICKET_ORG="${HOST_TICKET_ORG:-oso-gato}"
TICKET_REPO="${HOST_TICKET_REPO:-fedora-bootstrap}"
TICKET_LABEL="${HOST_TICKET_LABEL:-host-task}"
TMUX_BIN="${TMUX_BIN:-tmux}"                            # test seam: a stub tmux drives the real logic

log(){ echo "rebuild-request: $*" >&2; }
die(){ log "$*"; exit 1; }

# ── pure helpers (no I/O; --selftest covers these) ──────────────────────────────────────────────────
# valid_session_name / valid_cwd: the executor's parse_manifest allowlists, byte-for-byte. The producer
# must NEVER emit a line the executor would reject — ONE bad line rejects the WHOLE ticket (rc=2), so a
# single un-restorable session would strand every other one. Non-conforming sessions are SKIPPED loudly.
valid_session_name(){ [ -n "${1:-}" ] && [ "${#1}" -le 64 ] && [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_cwd(){ [ -n "${1:-}" ] && [ "${#1}" -le 256 ] && [[ "$1" =~ ^/[A-Za-z0-9._/@%+-]*$ ]]; }
# ephemeral_session: the per-connection tmux CLIENT session `c<pid>` (install.sh: `tmux new-session -s
# c$$` joined into the `main` group, `destroy-unattached on`). It is a transient VIEW of `main` that
# self-destroys on disconnect — restoring it would resurrect a dead client, so it is excluded.
ephemeral_session(){ [[ "${1:-}" =~ ^c[0-9]+$ ]]; }

# emit_manifest_lines: read raw "name<TAB>cwd" candidates on stdin → emit validated `session <name>
# <cwd>` lines for the survivors. Skips (loudly) ephemeral sessions and any name/cwd the executor would
# reject; caps at DEVBOX_MAX_SESSIONS, logging the drop (never a silent cap).
emit_manifest_lines(){
  local n=0 name cwd
  while IFS=$'\t' read -r name cwd; do
    [ -n "$name" ] || continue
    if ephemeral_session "$name"; then log "skip ephemeral client session '$name'"; continue; fi
    if ! valid_session_name "$name"; then log "skip session '$name' — name outside the executor allowlist"; continue; fi
    if ! valid_cwd "$cwd"; then log "skip session '$name' — cwd '$cwd' is not a safe absolute path"; continue; fi
    if [ "$n" -ge "$DEVBOX_MAX_SESSIONS" ]; then log "cap $DEVBOX_MAX_SESSIONS reached — dropping '$name' and any further sessions"; break; fi
    printf 'session %s %s\n' "$name" "$cwd"
    n=$((n + 1))
  done
}

# compose_manifest_block: wrap emitted `session …` lines in the sentinels the executor scans for. An
# EMPTY block (no sessions) is well-formed to the executor (rc=0, restores nothing) — a valid degenerate
# rebuild; a MISSING block is refused (rc=3). So this always emits the sentinels.
compose_manifest_block(){
  local lines; lines="$(cat)"
  if [ -n "$lines" ]; then
    printf '%s\n%s\n%s\n' "$MANIFEST_BEGIN" "$lines" "$MANIFEST_END"
  else
    printf '%s\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END"
  fi
}

# enumerate_tmux: query the LIVE tmux server for each session's active-pane cwd → raw "name<TAB>cwd".
# Two calls (list-sessions, then display-message per session) so neither name nor path needs an
# in-band delimiter. Fail-soft: a tmux that is absent/empty yields nothing (→ an empty manifest).
enumerate_tmux(){
  local s cwd
  "$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
    [ -n "$s" ] || continue
    cwd="$("$TMUX_BIN" display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)"
    printf '%s\t%s\n' "$s" "$cwd"
  done
}

# manifest_block: the whole enumerate→validate→wrap pipeline (the testable core).
manifest_block(){ enumerate_tmux | emit_manifest_lines | compose_manifest_block; }

# compose_body: the full ticket body. LINE 1 is the machine op (exactly `host-op: rebuild-devbox
# <workload>`); the manifest block rides below, prose between is ignored by both parsers.
compose_body(){
  local manifest; manifest="$(cat)"
  cat <<EOF
host-op: rebuild-devbox $REBUILD_WORKLOAD

Purposeful **R17 rebuild** of the \`$REBUILD_WORKLOAD\` dev box — the host executes
KILL → REBUILD → RESTORE → RESUME → VERIFY (\`rebuild-devbox\` verb). The session manifest below was
captured on the dev box by \`bin/rebuild-request.sh\`. This ticket must be authored by a maintainer:
the executor author-gates this destructive verb to admin|maintain and refuses a bot author.

$manifest
EOF
}

# urlencode: RFC-3986 percent-encoding for the prefilled new-issue URL (ASCII manifest only).
urlencode(){
  local s="${1:-}" i c out=''
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

usage(){ sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# ── pure-helper self-test (no tmux, no network) ─────────────────────────────────────────────────────
run_selftest(){
  local fail=0
  ok(){ if eval "$2"; then :; else echo "SELFTEST FAIL: $1"; fail=1; fi; }
  # names
  ok "name main ok"            'valid_session_name main'
  ok "name dotted ok"          'valid_session_name feat.174_x-1'
  ok "name empty rejected"     '! valid_session_name ""'
  ok "name space rejected"     '! valid_session_name "a b"'
  ok "name slash rejected"     '! valid_session_name "a/b"'
  ok "name 64 ok"              "valid_session_name $(printf 'a%.0s' {1..64})"
  ok "name 65 rejected"        "! valid_session_name $(printf 'a%.0s' {1..65})"
  # cwds
  ok "cwd root ok"             'valid_cwd /'
  ok "cwd home ok"             'valid_cwd /home/core'
  ok "cwd allowed metach ok"   'valid_cwd /home/core/.cache/x@1%2+3-4'
  ok "cwd relative rejected"   '! valid_cwd home/core'
  ok "cwd space rejected"      '! valid_cwd "/home/my dir"'
  ok "cwd semicolon rejected"  '! valid_cwd "/home/x;rm"'
  ok "cwd empty rejected"      '! valid_cwd ""'
  # ephemeral
  ok "c12345 ephemeral"        'ephemeral_session c12345'
  ok "main not ephemeral"      '! ephemeral_session main'
  ok "cfoo not ephemeral"      '! ephemeral_session cfoo'
  # emit filters + shape
  local out
  out="$(printf 'main\t/home/core\nc999\t/home/core\nbad name\t/x\ngood\t/bad path\n' | emit_manifest_lines 2>/dev/null)"
  ok "emit keeps only valid"   '[ "$out" = "session main /home/core" ]'
  # compose_manifest_block wraps
  out="$(printf 'session main /home/core\n' | compose_manifest_block)"
  ok "block has begin"         "printf '%s' \"\$out\" | grep -qF '$MANIFEST_BEGIN'"
  ok "block has end"           "printf '%s' \"\$out\" | grep -qF '$MANIFEST_END'"
  # empty block is still well-formed (sentinels present)
  out="$(printf '' | compose_manifest_block)"
  ok "empty block sentinels"   "[ \"\$(printf '%s' \"\$out\" | grep -c '%%DEVBOX-MANIFEST')\" = 2 ]"
  # compose_body line 1 is the exact machine op the executor's parse_op reads
  out="$(echo x | compose_body | head -1)"
  ok "body line1 op"           '[ "$out" = "host-op: rebuild-devbox fedora-dev" ]'
  [ "$fail" = 0 ] && echo "rebuild-request --selftest: ALL PASS"
  return "$fail"
}

# ── dispatch ────────────────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  --help|-h)  usage; exit 0 ;;
  manifest)   manifest_block; exit 0 ;;
  ""|request) : ;;   # default → compose + present
  *)          die "unknown argument '$1' (use: manifest | request | --selftest | --help)" ;;
esac

mb="$(manifest_block)"
count="$(printf '%s\n' "$mb" | grep -c '^session ' || true)"
body="$(printf '%s\n' "$mb" | compose_body)"

OUT="${REBUILD_REQUEST_OUT:-$HOME/.local/state/rebuild-request/ticket-body.md}"
mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$body" > "$OUT"
log "captured $count session(s) → ticket body at $OUT"
[ "$count" -gt 0 ] || log "WARNING: zero sessions captured — is tmux running at the fedora-dev level? The rebuild will restore nothing."

title="host-task: rebuild-devbox $REBUILD_WORKLOAD"
url="https://github.com/$TICKET_ORG/$TICKET_REPO/issues/new?labels=$(urlencode "$TICKET_LABEL")&title=$(urlencode "$title")&body=$(urlencode "$body")"

cat <<EOF

  R17 rebuild-devbox request prepared ($count session(s) captured).

  A purposeful rebuild is destructive (it kills the box + all sessions), so the host executor requires
  a MAINTAINER to author the ticket. Two ways to file it:

  1. Open this prefilled issue and click "Submit" (authors it as you):
$(printf '     %s\n' "$url")

  2. Or file it from a shell where gh is authed as you:
       gh issue create --repo $TICKET_ORG/$TICKET_REPO --label $TICKET_LABEL \\
         --title "$title" --body-file $OUT

  Ticket body (also written to $OUT):
  ----------------------------------------------------------------------
$(printf '%s\n' "$body" | sed 's/^/  /')
  ----------------------------------------------------------------------
EOF
