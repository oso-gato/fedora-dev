#!/usr/bin/env bash
# host-refresh.sh — SELF-REFRESH, the HOST HALF (#163): a merged change that only the RUNNING HOST can
# apply reaches erebus PROMPTLY and AUTONOMOUSLY — not up to a month later on the workload-refresh
# timer, and not by a runbook a human executes. #162 is the DEV half (the running poller redeploys its
# own merged live-clone code, in-box); THIS is the symmetric HOST half, and it WIRES THE PROVEN SEAM —
# it builds NO new host machinery:
#
#   this scan ──▶ bin/host-ticket.sh ──▶ `host-task` issue ──▶ host-agent-watch.sh (erebus consumer,
#   (dev side)     (the R5 ticket bus)     (control repo)       proven live by host-task #120)
#                                                                 └─ redeploy <workload>
#                                                                    └─ workload-refresh@ → container-refresh.sh
#                                                                       (busy-probe deferral · digest-compare ·
#                                                                        health-gate · digest AUTO-ROLLBACK —
#                                                                        R10 recovery-before-power lives THERE;
#                                                                        this script never bypasses or
#                                                                        duplicates it)
#
# WHAT ONE SCAN DOES (`--once`; bin/pr-poller.sh runs it every HOST_REFRESH_EVERY sweeps, at the END of
# the tick that invokes it):
#
#   WORKLOAD repos (HOST_REFRESH_WORKLOADS — mirrors the host agent's KNOWN_WORKLOADS arg allowlist; a
#   repo without a real workload-refresh@<name> unit on the host must NOT be listed, the agent would
#   refuse its ticket): for each recently-merged PR,
#     1. CLASSIFY from the PR's own changed files (GitHub-derived, req 4): REDEPLOY-RELEVANT iff the
#        diff touches an IMAGE-BAKED path — HOST_REFRESH_IMAGE_RE, default Containerfile* /
#        install*.sh / entrypoint*.sh at the repo root: what ONLY a rebuilt image delivers to the
#        running container (the pattern covers the fedora-desktop lineage variants Containerfile.grd /
#        install-grd.sh / entrypoint-grd.sh). NOT the live-clone half (bin/ + policy/ + distrobox.ini
#        + the box scripts — #162 and the daily box rebuild deliver those in-box, and the baked seed
#        copy is shadowed by the live clone), NOT the deploy-contract files (run.sh* / spin-up.sh /
#        *.container — the host reads those from its own setup-managed clone; container-refresh.sh
#        does not git-pull, verified), NOT docs/tests/CI. FAIL DIRECTION: not-relevant — a missed
#        redeploy degrades to the monthly timer (the accepted status quo, logged where detectable); a
#        spurious one bounces a live box for nothing.
#     2. GATE ON THE PUBLISH (req 1: file AFTER publish, so the host pulls the NEW digest and never
#        redeploys a stale :latest): the merge commit's CI build run (gh run list --commit, workflow
#        HOST_REFRESH_WORKFLOW) must have CONCLUDED SUCCESS. PENDING → no ticket, NO marker — the
#        absence of a marker IS the retry (next scan re-checks). FAILED/CANCELLED → this merge's
#        image will NEVER publish: no ticket ever (a stale-digest redeploy is the one forbidden
#        outcome), the MISS is logged, the merge is parked — the next image-baked merge or the
#        monthly --no-cache rebuild carries its paths.
#     3. FILE exactly one `redeploy <workload>` ticket via bin/host-ticket.sh (plain shell, the
#        standing App credential — never the classifier-gated interactive agent), then stamp the
#        merged PR with a `host-refresh → filed:` comment: the audit trail AND the wiped-state dedup
#        anchor (the PR's own comment stream is the durable record — a box that lost its local
#        markers re-derives everything from GitHub and still files nothing twice). Belt behind the
#        anchor: the host side is idempotent anyway (the agent's per-ticket claim/outcome markers +
#        container-refresh's digest-compare make a duplicate redeploy a harmless no-op) — req 4
#        RESTS on that; the anchor just keeps the bus quiet.
#
#   CONTROL repo (HOST_REFRESH_CONTROL_REPO, default fedora-bootstrap — the erebus host's own repo):
#   a merged change touching host-executed paths (anything but docs/tests/CI — HOST_REFRESH_INERT_RE)
#   FILES exactly one `apply-bootstrap` ticket via bin/host-ticket.sh — the bounded host verb has landed
#   (#133/#187): the host FF-pulls the control clone to merged `main` + re-runs setup.sh AS ROOT,
#   health-gated with rollback + a fail-closed live readback, idempotent (same-sha ⇒ no-op). apply-boot-
#   strap takes NO arg (it applies pinned, merge-gated `main`, injecting nothing — the merge gate is the
#   content-authorization). CONFIG-CONVERGE ONLY: it re-installs the Quadlet FILE + daemon-reload but
#   does NOT recreate a running container, so a changed Quadlet `Environment=`/`Secret=` takes effect on
#   the next recreate (the approved-gated Tier-2 recreate is a disclosed follow-on). Same anchor-dedup
#   discipline as the workload arm: a `host-refresh → apply-filed:` comment is the audit trail + the
#   wiped-state dedup anchor; a duplicate filing is a harmless no-op (host idempotency + the agent's
#   per-ticket claim/outcome markers). TRANSITION: a PR already carrying the pre-#187 `host-refresh →
#   host-apply needed:` question is left alone — it was surfaced for a human to apply when no verb
#   existed; only FRESH merges (neither anchor) are filed.
#
# FAIL-SAFE (req 5): every failure path — list/files/run/comments fetch, ticket create, comment post —
# LOGS and DEGRADES TO THE STATUS QUO (skip now, retry next scan, the monthly timer as backstop).
# Nothing here can stop the merge loop (the poller swallows this script's rc) and nothing can redeploy
# an unpublished digest (step 2 is the gate).
#
# BOUNDS: HOST_REFRESH_LOOKBACK most-recently-updated merged PRs per repo (the retire_superseded
# window precedent); merges older than HOST_REFRESH_MAX_AGE are parked to the monthly timer (bounds a
# long-dead poller's catch-up and a wiped box's re-derivation; logged). Terminal decisions park under
# a scan-once marker in ~/.local/state/host-refresh — the retire-scan precedent, pure COST bounding
# against the 5k/h REST budget; every DECISION input is GitHub-derived, so state loss only costs
# re-reads, never a wrong action. Steady state ≈ 1 list call per repo per scan (~36/h at the poller's
# default 30-sweep cadence).
#
# RESIDUAL (disclosed): fedora-dev bakes three bin/ wrappers into /usr/local/bin (Containerfile COPY of
# bin/claude, bin/claudebox-rebuild, bin/gh-app-auth.sh). A merge touching ONLY those misses the prompt
# redeploy — #163's own rule keeps bin/ wholesale on the live-clone side ("NOT the live-clone
# bin/+policy/ paths"), and a per-file carve-out here would drift from the Containerfile silently.
# They ride the next image-baked merge or the monthly rebuild.
#
# USAGE:
#   host-refresh.sh --once       # one scan of all enrolled repos (what the poller runs)
#   host-refresh.sh --selftest   # pure-helper self-checks (no network)
#
# ENV: HOST_REFRESH_ORG=oso-gato · HOST_REFRESH_WORKLOADS="fedora-dev fedora-desktop" ("" disables
#   the workload arm) · HOST_REFRESH_CONTROL_REPO=fedora-bootstrap ("" disables the control arm) ·
#   HOST_REFRESH_LOOKBACK=15 · HOST_REFRESH_MAX_AGE=172800 (s) · HOST_REFRESH_WORKFLOW=build.yml ·
#   HOST_REFRESH_IMAGE_RE / HOST_REFRESH_INERT_RE (the two classifiers) ·
#   HOST_TICKET=bin/host-ticket.sh (the producer this fires). Covered by host-refresh.test.sh.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- pure core (no I/O) — the two path classifiers + the publish fold; exercised by --selftest ------
# IMAGE-BAKED = what only a rebuilt image delivers to the RUNNING container (repo-root files). Kept in
# lockstep with what the enrolled repos' Containerfiles COPY (minus the live-clone-shadowed seed).
IMAGE_RE="${HOST_REFRESH_IMAGE_RE:-^(Containerfile[^/]*|install[^/]*\.sh|entrypoint[^/]*\.sh)$}"
# INERT for a HOST APPLY = paths the running host never executes or consumes (docs, tests, CI).
# Only ROOT-level .md is a doc — a nested one (policy/CLAUDE.md) is stamped law the host's box
# rebuild consumes from its clone, so it stays host-relevant.
INERT_RE="${HOST_REFRESH_INERT_RE:-^\.github/|^[^/]*\.md$|\.test\.sh$}"

# image_relevant: changed paths on stdin → rc 0 iff ANY path is image-baked.
image_relevant(){ grep -qE "$IMAGE_RE"; }
# host_relevant: changed paths on stdin → rc 0 iff ANY non-empty path is NOT inert (control repo).
# The `grep .` strips empty lines first — without it a zero-file PR's single empty line would count
# as "not inert" and surface a question for nothing.
host_relevant(){ grep . | grep -qvE "$INERT_RE"; }
# publish_state <status> <conclusion> → PUBLISHED | FAILED | PENDING. Empty status = no CI run seen
# yet (a fresh merge, or the run row not yet indexed) = PENDING; only completed+success is a publish;
# every other completion (failure, cancelled, skipped…) means this merge's image will NEVER exist.
publish_state(){
  case "${1:-}:${2:-}" in
    completed:success) printf 'PUBLISHED';;
    completed:*)       printf 'FAILED';;
    *)                 printf 'PENDING';;
  esac
}

if [ "${1:-}" = "--selftest" ]; then
  f=0
  ir(){ local got; printf '%s\n' "$2" | image_relevant && got=yes || got=no; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — image_relevant($2)=$got want $3"; f=1; }; }
  ir "Containerfile"            'Containerfile'                     yes
  ir "desktop lineage"          'Containerfile.grd'                 yes
  ir "install"                  'install.sh'                        yes
  ir "install variant"          'install-grd.sh'                    yes
  ir "entrypoint"               'entrypoint.sh'                     yes
  ir "entrypoint variant"       'entrypoint-grd.sh'                 yes
  ir "mixed live+image"         $'bin/pr-poller.sh\nContainerfile'  yes
  ir "live-clone bin"           'bin/pr-poller.sh'                  no
  ir "live-clone policy"        'policy/CLAUDE.md'                  no
  ir "docs"                     'README.md'                         no
  ir "deploy contract run.sh"   'run.sh'                            no
  ir "deploy contract quadlet"  'fedora-dev.container'              no
  ir "box manifest"             'distrobox.ini'                     no
  ir "box script"               'claudebox-init.sh'                 no
  ir "nested Containerfile"     'docs/Containerfile.example'        no
  ir "empty"                    ''                                  no
  hr(){ local got; printf '%s\n' "$2" | host_relevant && got=yes || got=no; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — host_relevant($2)=$got want $3"; f=1; }; }
  hr "host script"              'container-refresh.sh'              yes
  hr "systemd unit"             'systemd-units/x.service'           yes
  hr "policy needs a pull too"  'policy/CLAUDE.md'                  yes
  hr "docs only"                'README.md'                         no
  hr "ci only"                  '.github/workflows/build.yml'       no
  hr "test only"                'repo-labels.test.sh'                no
  hr "mixed doc+script"         $'README.md\nverify.sh'             yes
  hr "empty"                    ''                                  no
  ps_(){ local got; got="$(publish_state "$2" "$3")"; [ "$got" = "$4" ] && echo "ok: $1" || { echo "FAIL: $1 — publish_state($2,$3)=$got want $4"; f=1; }; }
  ps_ "published"               completed   success   PUBLISHED
  ps_ "build failed"            completed   failure   FAILED
  ps_ "cancelled"               completed   cancelled FAILED
  ps_ "still running"           in_progress ''        PENDING
  ps_ "queued"                  queued      ''        PENDING
  ps_ "no run yet"              ''          ''        PENDING
  [ "$f" = 0 ] && echo "ALL HOST-REFRESH SELFTESTS PASS" || echo "HOST-REFRESH SELFTESTS FAILED"; exit "$f"
fi

# ---- I/O layer -------------------------------------------------------------------------------------
ORG="${HOST_REFRESH_ORG:-oso-gato}"
# `-` (not `:-`) expansions: an EXPLICITLY EMPTY value disables that arm (the documented contract);
# only an unset one takes the fleet default.
WORKLOADS="${HOST_REFRESH_WORKLOADS-fedora-dev fedora-desktop}"
CONTROL_REPO="${HOST_REFRESH_CONTROL_REPO-fedora-bootstrap}"
LOOKBACK="${HOST_REFRESH_LOOKBACK:-15}"
MAX_AGE="${HOST_REFRESH_MAX_AGE:-172800}"
WORKFLOW="${HOST_REFRESH_WORKFLOW:-build.yml}"
HOST_TICKET="${HOST_TICKET:-$HERE/host-ticket.sh}"
# the R16 operating-scope reader (#167) — every scanned repo is checked before ANY read/ticket/
# comment against it; rc≠0 (127 included) is never a go (fail-closed).
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
STATE="$HOME/.local/state/host-refresh"
# apply-bootstrap retry bound: after a merged control change's apply FAILS this many times (each a fresh
# ticket the host rolled back), stop auto-retrying and surface a loud BLOCKED alarm (the host is on prior
# code and needs a human). BLOCKED_LABEL tags the alarm issue (created on first use).
MAX_APPLY_RETRIES="${HOST_REFRESH_MAX_APPLY_RETRIES:-3}"
BLOCKED_LABEL="${HOST_REFRESH_BLOCKED_LABEL:-apparatus-blocked}"
# @mention the maintainer in the alarm-issue BODY → opening the issue push-notifies that user, so the
# GitHub MOBILE APP (with "Direct Mentions" push on) rings the phone (same mechanism as
# rebuild-request.sh). Empty disables it. Notification only, never authorization.
APPARATUS_ALERT_MENTION="${APPARATUS_ALERT_MENTION:-@oso-gato}"
log(){ echo "host-refresh: $*" >&2; }

# merged_rows <slug> — ONE batched list call (number/merge-oid/mergedAt as TSV; the sweep's TSV
# precedent), sorted by UPDATE recency so a long-parked PR that merges late still enters the window.
merged_rows(){
  gh pr list --repo "$1" --state merged --search 'sort:updated-desc' --limit "$LOOKBACK" \
     --json number,mergeCommit,mergedAt -q '.[] | "\(.number)\t\(.mergeCommit.oid)\t\(.mergedAt)"' 2>/dev/null
}

# too_old <mergedAt-iso> — rc 0 when the merge is outside the catch-up window. An unparsable date
# fails toward FRESH (scan it) — never a silent park on a formatting quirk.
too_old(){
  local m; m="$(date -d "$1" +%s 2>/dev/null)" || m="$NOW"
  [ -n "$m" ] || m="$NOW"
  [ $(( NOW - m )) -gt "$MAX_AGE" ]
}

# ticket_outcome <issue-num> — echo done|failed|pending for a filed apply-bootstrap ticket, read DIRECTLY
# from the control-repo issue (NEVER via host-ticket.sh --outcome, which is SID-scoped and refuses a ticket
# after a rebuild changes the poller SID). The host's respond() posts `**host-agent: DONE|FAILED** — …` and
# closes the issue. Mapping: a DONE verdict ⇒ done; a FAILED verdict ⇒ failed; CLOSED with NO host-agent
# verdict ⇒ pending (a human manually cancelled it — NEVER retry that, it fights the maintainer; it ages
# out via too_old). Anything else (open, unreadable) ⇒ pending (fail-safe: wait, never a false terminal).
ticket_outcome(){
  local n="$1" state cmts
  state="$(gh issue view "$n" --repo "$ORG/$CONTROL_REPO" --json state -q .state 2>/dev/null)"
  cmts="$(gh issue view "$n" --repo "$ORG/$CONTROL_REPO" --json comments -q '.comments[].body' 2>/dev/null)"
  if printf '%s' "$cmts" | grep -qiE 'host-agent:[*[:space:]]*done'; then echo done; return; fi
  if printf '%s' "$cmts" | grep -qiE 'host-agent:[*[:space:]]*failed'; then echo failed; return; fi
  echo pending   # OPEN (in-flight), CLOSED-without-verdict (human cancel), or unreadable → wait, never terminal
}

# surface_blocked <slug> <pr> <oid> <attempts> <last-ticket-num> — retries exhausted: post ONE loud terminal
# PR comment AND find-or-create a single deduped alarm issue in the control repo (the host is on PRIOR code).
surface_blocked(){
  local slug="$1" pr="$2" oid="$3" attempts="$4" tnum="$5"
  local mention="${APPARATUS_ALERT_MENTION:+$APPARATUS_ALERT_MENTION — }"   # @mention → GitHub mobile-app push
  gh pr comment "$pr" --repo "$slug" --body "**host-refresh → apply-blocked:** apply-bootstrap FAILED ${attempts}× for merge \`${oid:0:7}\` (last ticket #${tnum}) — the host is on PRIOR code and auto-retry is EXHAUSTED. A human is needed. (Auto-retry resumes only if a later merge re-arms the apply.)"$'\n\n'"<sub>bin/host-refresh.sh — bounded apply-bootstrap retry (HOST_REFRESH_MAX_APPLY_RETRIES=${MAX_APPLY_RETRIES}).</sub>" >/dev/null 2>&1 \
    || log "$slug#$pr: apply-blocked PR comment FAILED (surfacing continues via the alarm issue)"
  local title="BLOCKED: host apply-bootstrap keeps failing (${slug}#${pr})" existing
  existing="$(gh api -X GET "search/issues" -f q="repo:$ORG/$CONTROL_REPO in:title \"$title\" state:open" -q '.items[0].number' 2>/dev/null)"
  if [ -n "$existing" ] && [ "$existing" != null ]; then
    log "$slug#$pr: apply-blocked alarm already open (#$existing) — not duplicating"
    return 0
  fi
  gh issue create --repo "$ORG/$CONTROL_REPO" --title "$title" \
      --body "${mention}apply-bootstrap for merge \`${oid:0:7}\` (${slug}#${pr}) FAILED and rolled back ${attempts}× (last ticket #${tnum}). The host is running PRIOR code; bounded auto-retry (${MAX_APPLY_RETRIES}) is exhausted. A human must investigate the failing apply. See ${slug}#${pr} for the apply-filed history." \
      --label "$BLOCKED_LABEL" >/dev/null 2>&1 \
    || gh issue create --repo "$ORG/$CONTROL_REPO" --title "$title" \
      --body "${mention}apply-bootstrap for merge \`${oid:0:7}\` (${slug}#${pr}) FAILED and rolled back ${attempts}× (last ticket #${tnum}). The host is running PRIOR code; bounded auto-retry is exhausted. A human must investigate." >/dev/null 2>&1 \
    || log "$slug#$pr: apply-blocked alarm issue create FAILED (PR comment carries the signal)"
}

scan_workload(){ # <workload == repo name>
  local repo="$1" slug="$ORG/$1" rows
  # R16 (#167): an out-of-scope workload gets NO scan and NO redeploy ticket — one loud line.
  if ! "$REPO_SCOPE" check "$repo" 2>/dev/null; then
    log "R16 SCOPE: workload '$repo' is outside the maintainer-confirmed operating scope — skipped (no scan, no ticket)"
    return 0
  fi
  rows="$(merged_rows "$slug")" \
    || { log "$slug: merged-PR list failed — skipping this scan (retry next; the monthly timer is the backstop)"; return 0; }
  [ -n "$rows" ] || return 0
  # rows ride FD 3, not stdin (the sweep_repo idiom): loop-body children must never eat the list.
  local pr oid mergedat files runrow status concl pub cmts url mark
  while IFS=$'\t' read -r -u 3 pr oid mergedat; do
    [ -n "$pr" ] || continue
    mark="$STATE/redeploy-${repo}-${pr}.done"
    [ -f "$mark" ] && continue
    if too_old "$mergedat"; then
      log "$slug#$pr: merged outside the catch-up window (>${MAX_AGE}s ago) — the monthly workload-refresh timer owns it (no ticket)"
      : > "$mark"; continue
    fi
    files="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null)" \
      || { log "$slug#$pr: files fetch failed — retry next scan"; continue; }
    if ! printf '%s\n' "$files" | image_relevant; then
      : > "$mark"; continue      # live-clone/docs/deploy-contract only — #162 + the daily box rebuild own it
    fi
    # THE PUBLISH GATE (req 1): the host must pull the NEW digest, never re-pull a stale :latest.
    runrow="$(gh run list --repo "$slug" --commit "$oid" --workflow "$WORKFLOW" --limit 1 \
              --json status,conclusion -q 'first(.[]) | "\(.status)\t\(.conclusion // "")"' 2>/dev/null)" \
      || { log "$slug#$pr: CI run lookup failed — retry next scan"; continue; }
    IFS=$'\t' read -r status concl <<< "$runrow"
    pub="$(publish_state "${status:-}" "${concl:-}")"
    case "$pub" in
      PENDING)
        log "$slug#$pr (merge ${oid:0:7}): image publish PENDING ($WORKFLOW ${status:-not started yet}) — no ticket yet, re-checked next scan"
        continue;;
      FAILED)
        log "$slug#$pr (merge ${oid:0:7}): $WORKFLOW concluded '${concl:-?}' — this merge's image will NEVER publish, so NO redeploy is filed (a stale digest must never redeploy). MISS — the next image-baked merge or the monthly rebuild carries these paths"
        : > "$mark"; continue;;
    esac
    # wiped-state dedup (req 4): the merged PR's own comment stream is the durable record — a prior
    # filed-anchor means the ticket exists; local-state loss must never file twice.
    cmts="$(gh pr view "$pr" --repo "$slug" --json comments -q '.comments[].body' 2>/dev/null)" \
      || { log "$slug#$pr: comments fetch failed — retry next scan"; continue; }
    if printf '%s' "$cmts" | grep -qF 'host-refresh → filed:'; then
      log "$slug#$pr: a 'host-refresh → filed:' anchor already exists (state was wiped?) — not filing twice"
      : > "$mark"; continue
    fi
    url="$("$HOST_TICKET" redeploy "$repo")" \
      || { log "$slug#$pr: host-ticket.sh FAILED — no ticket filed; retry next scan"; continue; }
    log "$slug#$pr (merge ${oid:0:7}): image PUBLISHED → redeploy ticket filed: $url"
    gh pr comment "$pr" --repo "$slug" --body "**host-refresh → filed:** $url — merge \`${oid:0:7}\` touches image-baked paths and CI published the image; the host agent's \`redeploy $repo\` rides workload-refresh@ → container-refresh.sh (busy-probe deferral · digest-compare · health-gate · digest auto-rollback)."$'\n\n'"<sub>bin/host-refresh.sh (#163) — the host half of self-refresh; this comment is also the wiped-state dedup anchor.</sub>" >/dev/null 2>&1 \
      || log "$slug#$pr: audit comment FAILED (the ticket IS filed: $url); dedup rests on the local marker until a comment lands"
    : > "$mark"
  done 3<<< "$rows"
}

scan_control(){ # <control repo>
  local repo="$1" slug="$ORG/$1" rows
  # R16 (#167): same gate as the workload arm — no scan, no question, on an out-of-scope repo.
  if ! "$REPO_SCOPE" check "$repo" 2>/dev/null; then
    log "R16 SCOPE: control repo '$repo' is outside the maintainer-confirmed operating scope — skipped (no scan, no question)"
    return 0
  fi
  rows="$(merged_rows "$slug")" \
    || { log "$slug: merged-PR list failed — skipping this scan (retry next)"; return 0; }
  [ -n "$rows" ] || return 0
  local pr oid mergedat files cmts mark attempts tnum
  while IFS=$'\t' read -r -u 3 pr oid mergedat; do
    [ -n "$pr" ] || continue
    mark="$STATE/apply-${repo}-${pr}.done"
    [ -f "$mark" ] && continue
    if too_old "$mergedat"; then
      log "$slug#$pr: merged outside the catch-up window (>${MAX_AGE}s ago) — an old host change is a human's catch-up, not a fresh question"
      : > "$mark"; continue
    fi
    files="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null)" \
      || { log "$slug#$pr: files fetch failed — retry next scan"; continue; }
    if ! printf '%s\n' "$files" | host_relevant; then
      : > "$mark"; continue      # docs/tests/CI only — nothing for the running host to apply
    fi
    cmts="$(gh pr view "$pr" --repo "$slug" --json comments -q '.comments[].body' 2>/dev/null)" \
      || { log "$slug#$pr: comments fetch failed — retry next scan"; continue; }
    # TERMINAL skips (the PR's own comment stream is the durable record): the pre-#187 `host-apply needed:`
    # question asked a human to apply back when no verb existed — never re-file it; and a prior
    # `apply-blocked:` surface means bounded auto-retry is exhausted (a human owns it) — also terminal.
    if printf '%s' "$cmts" | grep -qF 'host-refresh → host-apply needed:' \
       || printf '%s' "$cmts" | grep -qF 'host-refresh → apply-blocked:'; then
      : > "$mark"; continue
    fi
    # OUTCOME-KEYED dedup (audit #7 fix): the old dedup skipped whenever a ticket had been FILED
    # (`apply-filed:`), so a FAILED+rolled-back apply NEVER retried and the host sat on prior code SILENTLY
    # (stranded fedora-bootstrap #239/#240/#241). Instead read the LAST filed ticket's host-agent verdict
    # and branch on the OUTCOME: DONE ⇒ terminal skip; PENDING ⇒ wait (no re-file, no marker → re-check
    # next scan); FAILED ⇒ bounded retry up to MAX_APPLY_RETRIES, then surface BLOCKED and stop.
    attempts="$(printf '%s' "$cmts" | grep -cF 'host-refresh → apply-filed:')"
    if [ "$attempts" -gt 0 ]; then
      tnum="$(printf '%s' "$cmts" | grep -F 'host-refresh → apply-filed:' | tail -1 | grep -oE 'issues/[0-9]+' | tail -1)"
      tnum="${tnum##*/}"
      case "$(ticket_outcome "$tnum")" in
        done)
          : > "$mark"; continue ;;                       # terminal success — the host reached merged main
        pending)
          log "$slug#$pr: apply ticket #${tnum:-?} in-flight or human-cancelled (no verdict yet) — waiting, no re-file"
          continue ;;                                    # NO marker → re-check the outcome next scan
        failed)
          if [ "$attempts" -ge "$MAX_APPLY_RETRIES" ]; then
            log "$slug#$pr: apply FAILED ${attempts}× (>= MAX_APPLY_RETRIES=$MAX_APPLY_RETRIES) — surfacing BLOCKED, stopping auto-retry"
            surface_blocked "$slug" "$pr" "$oid" "$attempts" "$tnum"
            : > "$mark"; continue                        # terminal: a human owns it now
          fi
          log "$slug#$pr: apply ticket #$tnum FAILED, host rolled back — bounded retry $((attempts+1))/$MAX_APPLY_RETRIES" ;;
      esac                                               # (falls through to re-file, NO marker)
    fi
    # FILE (first attempt, or a bounded FAILED retry). apply-bootstrap applies pinned, merge-gated `main`
    # (health-gated with rollback + a fail-closed readback; idempotent, same-sha ⇒ no-op). CONFIG-CONVERGE
    # ON DISK — a changed Quadlet env takes effect on the next recreate (disclosed).
    url="$("$HOST_TICKET" apply-bootstrap)" \
      || { log "$slug#$pr: host-ticket.sh (apply-bootstrap) FAILED — no ticket filed; retry next scan"; continue; }
    log "$slug#$pr (merge ${oid:0:7}): merged control-repo change touches host-executed paths → apply-bootstrap ticket filed: $url (attempt $((attempts+1)))"
    gh pr comment "$pr" --repo "$slug" --body "**host-refresh → apply-filed:** $url — merge \`${oid:0:7}\` touches host-executed paths; the host agent's \`apply-bootstrap\` FF-pulls the control clone to merged \`main\` + re-runs setup.sh as root (health-gated with rollback + a fail-closed live readback; idempotent, same-sha ⇒ no-op). This is config-converge ON DISK — a changed Quadlet \`Environment=\`/\`Secret=\` takes effect on the next container recreate (the approved-gated Tier-2 recreate is the disclosed follow-on). Attempt $((attempts+1))/${MAX_APPLY_RETRIES}${tnum:+; prior ticket #$tnum FAILED, host rolled back to prior code}."$'\n\n'"<sub>bin/host-refresh.sh (#163) — the host half of self-refresh; this comment is the OUTCOME-keyed apply-bootstrap dedup anchor (retries count these).</sub>" >/dev/null 2>&1 \
      || log "$slug#$pr: apply-filed audit comment FAILED (the ticket IS filed: $url); next scan may re-file — apply-bootstrap is idempotent (same-sha no-op)"
    # NO marker written here — it is set ONLY on terminal states (done / blocked / transition / too-old /
    # not-host-relevant), so an in-flight or failed apply is always re-evaluated on the next scan.
  done 3<<< "$rows"
}

case "${1:-}" in
  --once)
    mkdir -p "$STATE"
    NOW="$(date +%s)"
    for _w in $WORKLOADS; do scan_workload "$_w"; done
    [ -z "$CONTROL_REPO" ] || scan_control "$CONTROL_REPO"
    exit 0;;
  *) echo "usage: host-refresh.sh --once | --selftest" >&2; exit 2;;
esac
