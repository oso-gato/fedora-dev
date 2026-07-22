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
# what was running on the dev box. THIS producer supplies exactly that: it enumerates the live claude
# tenant PROCESSES — each carries its ASSIGNED --session-id in its cmdline (bin/claude, D4) and its cwd
# in /proc — into the executor's `session <name> <cwd> [<sid>]` MANIFEST grammar and composes the
# `rebuild-devbox` ticket. The executor recreates each session (`tmux new-session -d -s <name> -c <cwd>`)
# and resumes it BY ID (`claude --resume <sid>`), so N tenants sharing one cwd all come back (the
# multi-tenant fix, 00-DESIGN D4/#191) — a tenant with no assigned id degrades to the v1 `claude
# --continue`. Then the executor verifies alive-AND-active + the poller sweeping.
#
# V2 ROLLOUT GATE (see manifest_v2_enabled): the 4-field by-id grammar is understood only by the
# fedora-bootstrap#143 executor (merged 2026-07-15). Because the RUNNING host executor's deploy LAGS
# that merge (a host-apply), v2 4-field emission is OPT-IN via DEVBOX_MANIFEST_V2 and DEFAULTS OFF —
# by default this producer emits v1 3-field lines, safe against ANY deployed executor. Flip it on in
# the fedora-dev deploy env once the host executor is confirmed to carry #143.
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
#   rebuild-request.sh file            # FILE the approval ticket as the apparatus (R17 approval flow —
#                                      #   the maintainer's whole act is ONE `approved`-label tap; invoked
#                                      #   by the poller's rebuild_request_tick, not the interactive agent)
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
# ── `file` mode (R17 approval flow, 2026-07-19 — pairs with fedora-bootstrap v1.2.69) ────────────────
APPROVAL_LABEL="${APPROVAL_LABEL:-rebuild-approval}"    # the maintainer's mobile-filter label on the filed ticket
APPROVE_LABEL="${APPROVE_LABEL:-approved}"             # the AUTHORIZATION tap: the executor's v1.2.69 gate fires when a maintainer applies THIS label. NOT applied at filing (that would self-authorize) — only CREATED so it exists in the repo's label set for the one-tap apply (mobile has no label-create UI; live 2026-07-19 the tap was impossible until this label was hand-created)
REBUILD_APPROVER_MENTION="${REBUILD_APPROVER_MENTION:-@oso-gato}"   # @mentioned in the ticket body → GitHub-app push; AUTHORIZATION is the role-checked `approved` label, never this string
HERE_RR="$(dirname "$(readlink -f "$0")")"
REPO_SCOPE="${REPO_SCOPE:-$HERE_RR/repo-scope.sh}"      # R16: filing targets the control repo — scope-checked

log(){ echo "rebuild-request: $*" >&2; }
die(){ log "$*"; exit 1; }

# ── pure helpers (no I/O; --selftest covers these) ──────────────────────────────────────────────────
# valid_session_name / valid_cwd: the executor's parse_manifest allowlists, byte-for-byte. The producer
# must NEVER emit a line the executor would reject — ONE bad line rejects the WHOLE ticket (rc=2), so a
# single un-restorable session would strand every other one. Non-conforming sessions are SKIPPED loudly.
valid_session_name(){ [ -n "${1:-}" ] && [ "${#1}" -le 64 ] && [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_cwd(){ [ -n "${1:-}" ] && [ "${#1}" -le 256 ] && [[ "$1" =~ ^/[A-Za-z0-9._/@%+-]*$ ]]; }
# valid_sid: the executor's optional 4th-field grammar, byte-for-byte (fedora-bootstrap#143) — a real
# fixed-width UUID (8-4-4-4-12 hex; exactly what `claude --session-id` requires). A sid failing this is
# NOT emitted; the session degrades to a v1 3-field line rather than poisoning the whole ticket (the
# executor rejects a non-UUID 4th field, rc=2, which would strand EVERY session). Fixed-width, in lockstep
# with the executor's tightened regex — a length-36-but-not-8-4-4-4-12 sid rejects on both sides.
valid_sid(){ [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
# ephemeral_session: the per-connection tmux CLIENT session `c<pid>` (install.sh: `tmux new-session -s
# c$$` joined into the `main` group, `destroy-unattached on`). It is a transient VIEW of `main` that
# self-destroys on disconnect — restoring it would resurrect a dead client, so it is excluded.
ephemeral_session(){ [[ "${1:-}" =~ ^c[0-9]+$ ]]; }

# manifest_v2_enabled: emit v2 (4-field, resume-BY-ID) lines ONLY when explicitly enabled — DEFAULTS
# OFF (v1 3-field). This is the cross-repo grammar ROLLOUT GATE. The consumer is fedora-bootstrap#143
# (merged 2026-07-15); until the RUNNING host executor is confirmed to carry that 4-field parser (a
# host-apply that lags the merge), a 4-field line reaching a pre-#143 3-field executor is REFUSED —
# whole-ticket rc=2, but `parse_manifest` is validated BEFORE the kill (host-agent-watch.sh:400-408),
# so NO session is stranded, the rebuild simply does not fire. Default-off makes the producer safe
# against ANY deployed executor: every tenant restores by cwd (v1) exactly as before this change —
# multi-tenant collapse in a shared cwd is the pre-existing v1 behavior, NOT a regression this
# introduces. The CODE default stays OFF (safe for ANY deployment / a lagging host); fedora-dev's own
# deploy env (run.sh + fedora-dev.container, 2026-07-17) now sets DEVBOX_MANIFEST_V2=1 so THIS apparatus
# emits v2 by default — self-sustaining resume-by-id for N tenants sharing a cwd — with the fail-safe
# REFUSE above as the backstop should the host executor still lag #143. Set DEVBOX_MANIFEST_V2=0 to force v1.
manifest_v2_enabled(){ case "${DEVBOX_MANIFEST_V2:-}" in 1|true|yes|on) return 0;; *) return 1;; esac; }

# emit_manifest_lines: read raw "name<TAB>cwd[<TAB>sid]" candidates on stdin → emit validated
# `session <name> <cwd> [<sid>]` lines. With v2 ENABLED, a valid UUID sid ⇒ a v2 4-field line (resume
# THAT session by id — multi-tenant). Otherwise (v2 disabled, OR an empty/invalid sid) ⇒ a v1 3-field
# line (cwd-scoped `--continue`) — never emit a 4th field a pre-#143 executor would reject and thereby
# refuse the whole ticket. Skips (loudly) ephemeral sessions and any name/cwd the executor would reject;
# caps at DEVBOX_MAX_SESSIONS, logging the drop (never a silent cap).
emit_manifest_lines(){
  local n=0 name cwd sid
  while IFS=$'\t' read -r name cwd sid; do
    [ -n "$name" ] || continue
    if ephemeral_session "$name"; then log "skip ephemeral client session '$name'"; continue; fi
    if ! valid_session_name "$name"; then log "skip session '$name' — name outside the executor allowlist"; continue; fi
    if ! valid_cwd "$cwd"; then log "skip session '$name' — cwd '$cwd' is not a safe absolute path"; continue; fi
    if [ "$n" -ge "$DEVBOX_MAX_SESSIONS" ]; then log "cap $DEVBOX_MAX_SESSIONS reached — dropping '$name' and any further sessions"; break; fi
    if [ -n "$sid" ] && valid_sid "$sid" && manifest_v2_enabled; then
      printf 'session %s %s %s\n' "$name" "$cwd" "$sid"                     # v2: resume THIS session by id
    else
      if [ -n "$sid" ]; then
        if ! manifest_v2_enabled; then
          log "session '$name' — v2 emission disabled (DEVBOX_MANIFEST_V2 unset); emitting v1 cwd-scoped line"
        elif ! valid_sid "$sid"; then
          log "session '$name' — sid '$sid' not a valid UUID; emitting cwd-scoped v1 line"
        fi
      fi
      printf 'session %s %s\n' "$name" "$cwd"                               # v1: cwd-scoped --continue
    fi
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

# enumerate_claude_procs: the LIVE session source (D4/#191). Each interactive claude tenant is a live
# `claude` process whose ASSIGNED --session-id (bin/claude, D4) sits in its cmdline and whose cwd is in
# /proc — both readable at the base level (the box shares fedora-dev's PID namespace). Emits
# name<TAB>cwd<TAB>sid per tenant. Reads the live process table directly because a running process IS
# ground truth for "what is running" — and, decisively, the sid is ONLY knowable this way: it is NOT in
# /proc/<pid>/environ (claude sets it after launch) and the process holds no open <sid>.jsonl fd, so
# ASSIGNING it via --session-id and reading it back from the cmdline is the mechanism (00-DESIGN D4).
# EXCLUDES headless `claude -p` runs and subagents (CLAUDE_CODE_CHILD_SESSION=1) — neither is a
# restorable interactive tmux tenant. A tenant from an OLD bin/claude (no --session-id) yields an empty
# sid ⇒ emit_manifest_lines degrades it to a v1 cwd-scoped line. Fail-soft throughout.
# sid_from_cmd: extract a RESUMABLE session-id from a claude process cmdline. A FRESH launch carries the
# ASSIGNED `--session-id <uuid>` (bin/claude, D4); a RESTORED session carries `--resume <uuid>` / `-r <uuid>`
# — which is EXACTLY what the executor types to bring a session back (`claude --resume <sid>`, fedora-
# bootstrap#143). Both forms (space or `=`) hold the uuid in the cmdline, and a session has ONE or the
# other (bin/claude skips minting --session-id when a session is already named). Reading ONLY --session-id
# would miss every RESTORED session, so resume-by-id would survive just ONE rebuild then COLLAPSE on the
# next (rebuild #1 leaves every session as `--resume <sid>`, which the next scan would then read as empty).
# --continue/-c carry no id (cwd-scoped) and are correctly ignored. valid_sid re-validates the result.
sid_from_cmd(){ printf ' %s ' "${1:-}" | grep -oE -- ' (--session-id|--resume|-r)[= ][0-9a-fA-F-]{36}' | head -1 | grep -oE -- '[0-9a-fA-F-]{36}' | head -1; }

enumerate_claude_procs(){
  local pid cmd cwd sid child name
  for pid in $("${PGREP_BIN:-pgrep}" -x claude 2>/dev/null); do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    [ -n "$cmd" ] || continue
    case " $cmd " in *' -p '*|*' --print '*) continue ;; esac                       # headless, not a tenant
    child="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CODE_CHILD_SESSION=//p' | head -1)"
    [ "$child" = 1 ] && continue                                                     # subagent, not a tenant
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    sid="$(sid_from_cmd "$cmd")"                                                     # --session-id OR --resume/-r
    if [ -n "$sid" ]; then name="s-${sid%%-*}"; else name="s-p$pid"; fi             # collision-unlikely (first 8 hex of the sid), allowlist-safe
    printf '%s\t%s\t%s\n' "$name" "$cwd" "$sid"
  done
}

# dedup_by_sid: collapse the raw session source to ONE line per interactive session. A single tenant can
# have MULTIPLE live `claude` processes ALL carrying the SAME resumable id (observed 2026-07-19: TWO
# `/usr/bin/claude --resume <sid>` procs per tenant — a per-proc source therefore double-counts the SAME
# session). Left uncollapsed, the manifest lists N sessions for N/2 real tenants, and the executor's FINISH
# tally then reports "restored N/N" for N/2 real sessions — an UNTRUE count (and it redundantly recreates
# each tmux name: restore_session kills the same-name session first, so the duplicate just churns). A sid
# is UNIQUE per session (a session UUID), so two lines bearing the same non-empty sid ARE one tenant: the
# FIRST wins, later same-sid lines drop. A NO-SID (degraded/old-wrapper) line has no dedup key and always
# passes through — we cannot prove two keyless procs are one session, and each yields a distinct s-p<pid>
# name. Emits the input line VERBATIM (`print` = print $0, tabs intact — never re-split with OFS). Placed
# in the testable pipeline (not in enumerate_claude_procs) so the SESSION_SOURCE seam exercises it.
dedup_by_sid(){
  awk -F'\t' '{ if ($3=="") { print; next } if (!($3 in seen)) { seen[$3]=1; print } }'
}

# manifest_block: the whole enumerate→dedup→validate→wrap pipeline (the testable core). SESSION_SOURCE is
# the seam (default: the live-process scan; the test injects a fixture emitter). enumerate_tmux is kept as
# an alternative source but is no longer the default — it cannot carry a sid (tmux knows the pane, not
# the claude session-id), so it can only ever produce v1 lines.
SESSION_SOURCE="${SESSION_SOURCE:-enumerate_claude_procs}"
manifest_block(){ "$SESSION_SOURCE" | dedup_by_sid | emit_manifest_lines | compose_manifest_block; }

# ── manifest COMPLETENESS guard (fail-safe: never file a manifest that would silently WIPE sessions) ──
# enumerate_claude_procs captures a session ONLY if it can `readlink /proc/<pid>/cwd` — a PTRACE-gated
# read. Run in the WRONG context (root @ fedora-dev sits in the PARENT userns and reads NONE — an EMPTY
# manifest; a claude Bash-tool shell is bubblewrap-sandboxed and reads only its own lineage) it drops the
# rest SILENTLY. The executor treats an empty/partial manifest as "these are all the sessions" (rc=0,
# restores only what is listed), so a rebuild on it KILLS every un-captured session and never brings it
# back — with no error. So before a DESTRUCTIVE filing we cross-check: `/proc/<pid>/cmdline` is
# WORLD-readable (NOT ptrace-gated, unlike cwd/environ), so the live tenant session-ids are knowable in
# ANY context. `seen_sids` reads them with the SAME tenant filters enumerate uses (skip `-p` headless;
# skip CLAUDE_CODE_CHILD_SESSION subagents where environ is readable) MINUS the cwd read; `missing_sids`
# are the ones the composed manifest OMITS. `file_ticket` REFUSES when any is missing — turning a silent
# session-wiping rebuild into a LOUD refusal. The fix is always the CONTEXT (run as core at the base
# level — see the bin/rebuild-request.sh row in CLAUDE.md), never a weaker manifest. `SEEN_SIDS_SOURCE`
# is the test seam.
seen_sids(){
  local pid cmd sid child
  for pid in $("${PGREP_BIN:-pgrep}" -x claude 2>/dev/null); do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    [ -n "$cmd" ] || continue
    case " $cmd " in *' -p '*|*' --print '*) continue ;; esac                       # headless, not a tenant
    child="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CODE_CHILD_SESSION=//p' | head -1)"
    [ "$child" = 1 ] && continue                                                     # subagent (only excludable when environ readable)
    sid="$(sid_from_cmd "$cmd")"
    [ -n "$sid" ] && valid_sid "$sid" && printf '%s\n' "$sid"
  done | sort -u
}
SEEN_SIDS_SOURCE="${SEEN_SIDS_SOURCE:-seen_sids}"

# missing_sids <manifest-text>: the live tenant session-ids (from SEEN_SIDS_SOURCE) the manifest does NOT
# contain — sessions that EXIST but were dropped from capture. Sound ONLY when the manifest carries sids
# (v2); file_ticket forces DEVBOX_MANIFEST_V2=1, so the destructive path is always checked. A no-sid /
# invalid-sid tenant is never in seen_sids, so it can never raise a false positive.
missing_sids(){ # <manifest-text>
  local mb="${1:-}" s
  "$SEEN_SIDS_SOURCE" | while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s' "$mb" | grep -qF -- "$s" || printf '%s\n' "$s"
  done
}

# ── manifest AMBIGUITY guard (fail-safe: never file a manifest whose v1 line would MIS-RESTORE) ──
# A v1 (NO-SID, 3-field) line restores via `claude --continue <cwd>`, which resolves to the MOST-RECENT
# session in <cwd> — unambiguous ONLY when <cwd> hosts exactly one session. When ANOTHER manifest line
# (v1 OR v2) shares that cwd, `--continue` cannot target the v1 line's INTENDED session: it grabs whichever
# is most-recent, so N sessions on one cwd collapse to ONE restore — the OTHERS are killed and never brought
# back. Observed live 2026-07-21 (#226): a v2 line `s-ebcfa847 /home/core <sid>` + a NO-SID line
# `s-p2128 /home/core` → the rebuild resumed ONE session twice and DROPPED the other (this very session).
# `missing_sids` does NOT catch it: a no-sid line's session has no readable sid, so it is absent from
# seen_sids and can never be "missing" — a distinct blind spot. `ambiguous_v1_cwds` names the SHARED cwds
# of any no-sid line so file_ticket can REFUSE (turning a silent mis-restore into a loud refusal). The FIX
# is the CONTEXT (capture as CORE at the fedora-dev base level so EVERY live session carries its
# `--session-id` → a v2 by-id restore, never `--continue`; a session stuck on a cwd-scoped `--continue`
# launch is re-launched with its id) — never a weaker manifest. A LONE no-sid line on a UNIQUE cwd stays
# valid (the legitimate old-wrapper v1 fallback — `--continue` there is unambiguous). cwds carry no spaces
# (valid_cwd), so awk's whitespace fields are exact: a session line is NF≥3, cwd=$3, and NF==3 marks v1.
ambiguous_v1_cwds(){ # <manifest-text>
  printf '%s' "${1:-}" | awk '
    $1=="session"{ cwd=$3; count[cwd]++; if (NF==3) v1[cwd]=1 }
    END{ for (c in v1) if (count[c] > 1) print c }'
}

# ── shared ticket IDENTITY (the `file` path and the presented `request` command MUST agree) ───────────
# ticket_title: the ONE approval-ticket title. `file_ticket` files it; the `request`-mode presentation
# shows the SAME string in its prefilled URL + gh command — so a maintainer sees ONE consistent
# 🔴 APPROVAL REQUIRED ticket whichever way it is filed. WHY THIS EXISTS: the two paths had DRIFTED —
# `file` mode emitted this 🔴 title (as does the host's own increment-2 `file_recreate_ticket`), but
# `request` mode emitted a plain `host-task: rebuild-devbox <wl>`; a maintainer who hand-filed from the
# request command therefore got a DIFFERENT-looking, un-`rebuild-approval`-labelled ticket (incident
# 2026-07-22: #243, hand-filed from the request command, looked nothing like the apparatus's own #242).
# $1 = session count.
ticket_title(){ printf '🔴 APPROVAL REQUIRED: rebuild-devbox %s (%s session(s)) — tap the approved label' "$REBUILD_WORKLOAD" "${1:-0}"; }

# existing_open_ticket: the number of an already-OPEN rebuild-devbox ticket for this workload (a line-1
# op match on open host-task issues), or empty. BOTH paths consult it so neither FILES nor PRESENTS a
# DUPLICATE: the apparatus auto-files this ticket itself (the poller's rebuild_request_tick and the
# host's increment-2 `file_recreate_ticket`), so a second hand-filed one is redundant — incident
# 2026-07-22: #243 duplicated the apparatus's own #242, filed 65 min earlier. A closed/rejected ticket
# never blocks a re-file (only `--state open` is read).
existing_open_ticket(){
  gh issue list --repo "$TICKET_ORG/$TICKET_REPO" --state open --label "$TICKET_LABEL" --limit 50 \
    --json number,body -q '.[] | select(.body | startswith("host-op: rebuild-devbox '"$REBUILD_WORKLOAD"'")) | .number' 2>/dev/null | head -n1
}

# compose_body: the full ticket body. LINE 1 is the machine op (exactly `host-op: rebuild-devbox
# <workload>`); the manifest block rides below, prose between is ignored by both parsers. Mode `filed`
# writes the APPROVAL-FLOW prose (the apparatus filed it; the maintainer's one tap authorizes — the
# fedora-bootstrap v1.2.69 approval gate); default = the present-to-a-maintainer prose (authorship path).
compose_body(){ # [filed]
  local manifest mode="${1:-present}"; manifest="$(cat)"
  if [ "$mode" = filed ]; then
    cat <<EOF
host-op: rebuild-devbox $REBUILD_WORKLOAD

$REBUILD_APPROVER_MENTION — **ONE-TAP APPROVAL NEEDED**: apply the **\`approved\` label** to this issue to
authorize a purposeful **R17 rebuild** of the \`$REBUILD_WORKLOAD\` dev box (KILL → REBUILD → RESTORE →
RESUME → VERIFY; every session in the manifest below is restored + resumed + nudged back to work). Filed
by the apparatus (\`bin/rebuild-request.sh file\`); the host fires ONLY on a maintainer's act — the label
APPLIER is role-checked admin|maintain from the label's own timeline (an App-applied label is inert). The
host re-checks every ~10s and fires the moment the label lands. To REJECT: close this issue. The session
manifest was captured live at filing time.

$manifest
EOF
  else
    cat <<EOF
host-op: rebuild-devbox $REBUILD_WORKLOAD

Purposeful **R17 rebuild** of the \`$REBUILD_WORKLOAD\` dev box — the host executes
KILL → REBUILD → RESTORE → RESUME → VERIFY (\`rebuild-devbox\` verb). The session manifest below was
captured on the dev box by \`bin/rebuild-request.sh\`. Authorization is a MAINTAINER'S explicit act:
author this ticket yourself, OR (the one-tap path) any maintainer may apply the \`approved\` label.

$manifest
EOF
  fi
}

# file_ticket: FILE the approval ticket AS THE APPARATUS (the R17 approval flow — the executor half is
# fedora-bootstrap v1.2.69: a bot-filed ticket fires once a maintainer taps the `approved` label, so
# filing needs NO human; the maintainer's ENTIRE act is the one tap). Meant to be invoked by the POLLER's
# rebuild_request_tick (the sanctioned headless bus-writer — the host-refresh/host-ticket precedent),
# not the interactive agent. IDEMPOTENT: skips when an OPEN ticket for this workload already exists
# (line-1 op match on open host-task issues — a closed/rejected ticket never blocks a re-file). R16:
# refuses when the control repo is out of the operating scope (fail-closed; a missing reader is never a
# go). Labels: $TICKET_LABEL (host discovery) + $APPROVAL_LABEL (the maintainer's mobile notification
# filter), both create-on-use. The manifest is captured FRESH at filing time (it is a snapshot — a stale
# one strands sessions started since). rc 0 = filed (URL on stdout) or already-open; non-zero = not filed.
file_ticket(){
  local slug="$TICKET_ORG/$TICKET_REPO" existing mb count body tmp url
  # v2 BY-ID manifest is DEFAULT-ON for the FILING path (incident 2026-07-19: the running container's env
  # predated the deploy-env DEVBOX_MANIFEST_V2 flip, so the first live filing went out v1 cwd-scoped — a
  # MULTI-TENANT COLLAPSE for sessions sharing one cwd; caught in the poller log, the ticket body was
  # edit-corrected by hand). Depending on deploy env for CORRECTNESS was the bug; the code default for the
  # OTHER modes stays OFF (grammar safety for foreign deployments), but the filing path exists only in
  # THIS apparatus, whose deployed executor has understood v2 since fedora-bootstrap#143 (2026-07-15) —
  # and a pre-#143 executor fail-safe REFUSES a 4-field manifest BEFORE any kill. Explicit =0 forces v1.
  export DEVBOX_MANIFEST_V2="${DEVBOX_MANIFEST_V2:-1}"
  "$REPO_SCOPE" check "$TICKET_REPO" 2>/dev/null \
    || { log "R16: control repo '$TICKET_REPO' is not in the operating scope (or the reader is unavailable) — refusing to file"; return 1; }
  existing="$(existing_open_ticket)" || existing=''
  if [ -n "$existing" ]; then
    log "an OPEN rebuild ticket already exists (#$existing) — not filing a duplicate (idempotent)"
    return 0
  fi
  mb="$(manifest_block)"
  if manifest_v2_enabled; then                                   # sid-completeness is a v2 property (a v1 line carries no sid to cross-check)
    local missing; missing="$(missing_sids "$mb" | tr '\n' ' ')"
    if [ -n "${missing// /}" ]; then
      log "REFUSING to file rebuild-devbox: the captured manifest OMITS live session id(s) [ ${missing}] — a rebuild on it would KILL those sessions and NOT restore them. rebuild-request could not read all sessions' /proc: it MUST run as core at the fedora-dev BASE level (root is in the parent userns and reads NONE; a sandboxed shell reads only its own lineage). NOT filing; the flag is kept so the poller retries from the correct context."
      return 1
    fi
    local ambig; ambig="$(ambiguous_v1_cwds "$mb" | tr '\n' ' ')"
    if [ -n "${ambig// /}" ]; then
      log "REFUSING to file rebuild-devbox: the captured manifest has a NO-SID (v1) session sharing cwd(s) [ ${ambig}] with another session — the executor would restore that cwd via \`claude --continue\`, which resolves to the MOST-RECENT session there and so MIS-RESTORES (resumes one session twice, DROPS the other; observed 2026-07-21 #226). Capture as CORE at the fedora-dev BASE level so every session carries its --session-id (a v2 restore BY ID, never --continue); a session stuck on a cwd-scoped --continue launch must be re-launched with its id. NOT filing; the flag is kept so the poller retries from the correct context."
      return 1
    fi
  fi
  count="$(printf '%s\n' "$mb" | grep -c '^session ' || true)"
  [ "$count" -gt 0 ] || log "WARNING: zero sessions captured — the rebuild would restore nothing"
  body="$(printf '%s\n' "$mb" | compose_body filed)"
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$body" > "$tmp"
  gh label create "$TICKET_LABEL"   --repo "$slug" --color 5319e7 >/dev/null 2>&1 || true   # create-on-use
  gh label create "$APPROVAL_LABEL" --repo "$slug" --color d93f0b >/dev/null 2>&1 || true
  gh label create "$APPROVE_LABEL"  --repo "$slug" --color 0e8a16 >/dev/null 2>&1 || true   # the authorization tap must EXIST to be tappable; NOT applied here (self-authorize)
  if url="$(gh issue create --repo "$slug" \
        --title "$(ticket_title "$count")" \
        --label "$TICKET_LABEL" --label "$APPROVAL_LABEL" --body-file "$tmp" 2>&1)"; then
    rm -f "$tmp"
    log "FILED $url ($count session(s)) — awaiting the maintainer's one-tap \`approved\` label"
    printf '%s\n' "$url"
    return 0
  fi
  rm -f "$tmp"
  log "gh issue create FAILED (does the App hold Issues:write on $slug?): $url"
  return 1
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
  # valid_sid + the sid path (D4/#191): a real UUID → v2 4-field line; a bad/empty sid degrades to v1
  ok "sid valid uuid"          'valid_sid 0deceee8-34ab-4e41-be19-ba4210469eb6'
  ok "sid short rejected"      '! valid_sid aaaa-bbbb'
  ok "sid nonhex rejected"     '! valid_sid 0deceee8-34ab-4e41-be19-zzzzzzzzzzzz'
  ok "sid empty rejected"      '! valid_sid ""'
  ok "sid loose-36 rejected"   '! valid_sid 123456789-abc-4444-5555-123456789012'   # len-36 but not 8-4-4-4-12 (executor #143 parity)
  # sid_from_cmd: read the sid from a FRESH launch (--session-id) OR a RESTORED session (--resume/-r) — the
  # latter is what the executor produces, so missing it would collapse resume-by-id on the 2nd rebuild
  ok "sid_from --session-id"   '[ "$(sid_from_cmd "claude --session-id 0deceee8-34ab-4e41-be19-ba4210469eb6 --model x")" = 0deceee8-34ab-4e41-be19-ba4210469eb6 ]'
  ok "sid_from --resume"       '[ "$(sid_from_cmd "claude --resume 0deceee8-34ab-4e41-be19-ba4210469eb6 --model x")" = 0deceee8-34ab-4e41-be19-ba4210469eb6 ]'
  ok "sid_from --resume="      '[ "$(sid_from_cmd "claude --resume=0deceee8-34ab-4e41-be19-ba4210469eb6")" = 0deceee8-34ab-4e41-be19-ba4210469eb6 ]'
  ok "sid_from -r"             '[ "$(sid_from_cmd "claude -r 0deceee8-34ab-4e41-be19-ba4210469eb6")" = 0deceee8-34ab-4e41-be19-ba4210469eb6 ]'
  ok "sid_from --continue none" '[ -z "$(sid_from_cmd "claude --continue")" ]'
  ok "sid_from bare none"      '[ -z "$(sid_from_cmd "claude --model default --permission-mode auto")" ]'
  # v2 rollout gate (default OFF): a valid sid emits v2 ONLY when DEVBOX_MANIFEST_V2 is enabled
  ok "v2 gate default off"     '! manifest_v2_enabled'
  ok "v2 gate on for =1"       'DEVBOX_MANIFEST_V2=1 manifest_v2_enabled'
  out="$(printf 'main\t/home/core\t0deceee8-34ab-4e41-be19-ba4210469eb6\n' | DEVBOX_MANIFEST_V2=1 emit_manifest_lines 2>/dev/null)"
  ok "emit 4-field on valid sid (v2 on)" '[ "$out" = "session main /home/core 0deceee8-34ab-4e41-be19-ba4210469eb6" ]'
  out="$(printf 'main\t/home/core\t0deceee8-34ab-4e41-be19-ba4210469eb6\n' | emit_manifest_lines 2>/dev/null)"
  ok "emit v1 on valid sid (v2 OFF — safe default)" '[ "$out" = "session main /home/core" ]'
  out="$(printf 'main\t/home/core\tnot-a-uuid\n' | DEVBOX_MANIFEST_V2=1 emit_manifest_lines 2>/dev/null)"
  ok "emit degrades bad sid (v2 on)" '[ "$out" = "session main /home/core" ]'
  out="$(printf 'main\t/home/core\t\n' | DEVBOX_MANIFEST_V2=1 emit_manifest_lines 2>/dev/null)"
  ok "emit v1 when no sid"      '[ "$out" = "session main /home/core" ]'
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
  # ticket_title: the ONE 🔴 approval title shared by file-mode + the presented request command (no drift)
  ok "ticket_title 🔴 format"  '[ "$(ticket_title 2)" = "🔴 APPROVAL REQUIRED: rebuild-devbox fedora-dev (2 session(s)) — tap the approved label" ]'
  # missing_sids — the COMPLETENESS cross-check (fail-safe against a lossy manifest; file-mode REFUSE)
  _seen_present(){ printf '%s\n' aaaaaaaa-1111-2222-3333-444444444444; }
  _seen_extra(){   printf '%s\n' aaaaaaaa-1111-2222-3333-444444444444 bbbbbbbb-5555-6666-7777-888888888888; }
  local mf; mf="$(printf '%s\nsession s-aaa /home/core aaaaaaaa-1111-2222-3333-444444444444\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END")"
  ok "missing_sids none when captured" '[ -z "$(SEEN_SIDS_SOURCE=_seen_present missing_sids "$mf")" ]'
  ok "missing_sids flags the omitted"  '[ "$(SEEN_SIDS_SOURCE=_seen_extra missing_sids "$mf")" = bbbbbbbb-5555-6666-7777-888888888888 ]'
  # ambiguous_v1_cwds — the #226 mis-restore guard (a NO-SID line SHARING a cwd → flag; lone/all-sid → none)
  local amb
  amb="$(ambiguous_v1_cwds "$(printf '%s\nsession s-ebcfa847 /home/core aaaaaaaa-1111-2222-3333-444444444444\nsession s-p2128 /home/core\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END")")"
  ok "ambig flags a shared-cwd no-sid line" '[ "$amb" = /home/core ]'
  amb="$(ambiguous_v1_cwds "$(printf '%s\nsession s-a /home/core aaaaaaaa-1111-2222-3333-444444444444\nsession s-p9 /root\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END")")"
  ok "ambig none when no-sid cwd is unique"  '[ -z "$amb" ]'
  amb="$(ambiguous_v1_cwds "$(printf '%s\nsession s-a /home/core aaaaaaaa-1111-2222-3333-444444444444\nsession s-b /home/core bbbbbbbb-5555-6666-7777-888888888888\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END")")"
  ok "ambig none when both lines carry a sid" '[ -z "$amb" ]'
  amb="$(ambiguous_v1_cwds "$(printf '%s\nsession s-p1 /home/core\nsession s-p2 /home/core\n%s\n' "$MANIFEST_BEGIN" "$MANIFEST_END")")"
  ok "ambig flags two no-sid on one cwd"     '[ "$amb" = /home/core ]'
  [ "$fail" = 0 ] && echo "rebuild-request --selftest: ALL PASS"
  return "$fail"
}

# ── dispatch ────────────────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  --help|-h)  usage; exit 0 ;;
  manifest)   manifest_block; exit 0 ;;
  file)       file_ticket; exit $? ;;   # R17 approval flow: the apparatus files; the maintainer taps `approved`
  ""|request) : ;;   # default → compose + present
  *)          die "unknown argument '$1' (use: manifest | request | file | --selftest | --help)" ;;
esac

mb="$(manifest_block)"
if manifest_v2_enabled; then
  miss="$(missing_sids "$mb" | tr '\n' ' ')"
  [ -n "${miss// /}" ] && log "WARNING: manifest is INCOMPLETE — omits live session id(s) [ ${miss}]. A rebuild would not restore them. Run rebuild-request as core at the fedora-dev base level (not root / not a sandboxed shell)."
  amb="$(ambiguous_v1_cwds "$mb" | tr '\n' ' ')"
  [ -n "${amb// /}" ] && log "WARNING: manifest has a NO-SID session sharing cwd(s) [ ${amb}] — a rebuild would MIS-RESTORE via \`claude --continue\` (resume one twice, drop the other; #226). Capture as core at the fedora-dev base level so every session carries its --session-id."
fi
count="$(printf '%s\n' "$mb" | grep -c '^session ' || true)"
body="$(printf '%s\n' "$mb" | compose_body)"

OUT="${REBUILD_REQUEST_OUT:-$HOME/.local/state/rebuild-request/ticket-body.md}"
mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$body" > "$OUT"
log "captured $count session(s) → ticket body at $OUT"
[ "$count" -gt 0 ] || log "WARNING: zero sessions captured — is tmux running at the fedora-dev level? The rebuild will restore nothing."

# DEDUP: the apparatus auto-files this ticket itself (poller / host increment-2), so if an approval-ready
# one is already OPEN, point at THAT instead of presenting a new-issue URL — hand-filing a second is the
# #243/#242 duplicate. (The fresh manifest is still written to $OUT for reference; the host self-captures
# the live manifest at fire time anyway, so the existing ticket's body is never stale in practice.)
existing="$(existing_open_ticket)" || existing=''
if [ -n "$existing" ]; then
  cat <<EOF

  An approval-ready rebuild-devbox ticket for '$REBUILD_WORKLOAD' ALREADY EXISTS — do NOT file another:
     https://github.com/$TICKET_ORG/$TICKET_REPO/issues/$existing

  The apparatus files this ticket itself (the poller's rebuild-request tick / the host's increment-2
  recreate). To rebuild, apply the \`$APPROVE_LABEL\` label to #$existing. (A fresh manifest was still
  written to $OUT for reference; the host re-captures the live manifest at fire time regardless.)
EOF
  exit 0
fi

title="$(ticket_title "$count")"
url="https://github.com/$TICKET_ORG/$TICKET_REPO/issues/new?labels=$(urlencode "$TICKET_LABEL,$APPROVAL_LABEL")&title=$(urlencode "$title")&body=$(urlencode "$body")"

cat <<EOF

  R17 rebuild-devbox request prepared ($count session(s) captured).

  A purposeful rebuild is destructive (it kills the box + all sessions), so the host executor requires
  a MAINTAINER's explicit act. Two ways — BOTH produce the identical 🔴 \`rebuild-approval\`-labelled
  ticket the apparatus's own filer uses:

  1. Open this prefilled issue and click "Submit" (authors it as you — fires on your authorship):
$(printf '     %s\n' "$url")

  2. Or file it from a shell where gh is authed as you, then tap the \`$APPROVE_LABEL\` label:
       gh issue create --repo $TICKET_ORG/$TICKET_REPO \\
         --label $TICKET_LABEL --label $APPROVAL_LABEL \\
         --title "$title" --body-file $OUT

  Ticket body (also written to $OUT):
  ----------------------------------------------------------------------
$(printf '%s\n' "$body" | sed 's/^/  /')
  ----------------------------------------------------------------------
EOF
