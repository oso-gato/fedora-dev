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
# WHAT ONE SCAN DOES (`--once`; bin/pr-poller.sh runs it every HOST_REFRESH_EVERY sweeps, R9-halt-gated
# by the tick that invokes it — filing a ticket is an ACTION):
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
#   has NO allowlisted apply verb: the host agent's fixed allowlist is exactly `redeploy <workload>`.
#   So SURFACE a question on the merged PR (`host-refresh → host-apply needed:`, once per PR, same
#   anchor-dedup discipline) instead of inventing an unbounded host op (req 2 — destructive/unbounded
#   host verbs are out of #163's scope). When a bounded apply verb ever lands in host-agent-watch.sh,
#   this arm is the seam that files it.
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
  hr "test only"                'fleet-halt.test.sh'                no
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
STATE="$HOME/.local/state/host-refresh"
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

scan_workload(){ # <workload == repo name>
  local repo="$1" slug="$ORG/$1" rows
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
  rows="$(merged_rows "$slug")" \
    || { log "$slug: merged-PR list failed — skipping this scan (retry next)"; return 0; }
  [ -n "$rows" ] || return 0
  local pr oid mergedat files cmts mark
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
    if printf '%s' "$cmts" | grep -qF 'host-refresh → host-apply needed:'; then
      : > "$mark"; continue
    fi
    # REQUIREMENT 2, THE HONEST HALF: the host agent's allowlist holds NO bounded apply verb (it is
    # exactly `redeploy <workload>`), and #163 forbids inventing an unbounded host op — so SURFACE.
    if gh pr comment "$pr" --repo "$slug" --body "**host-refresh → host-apply needed:** this merged \`$repo\` change touches host-executed paths, but the host agent's verb allowlist has no bounded apply verb (allowed today: \`redeploy <workload>\`) — the running host will NOT pick it up automatically. A human must apply it on erebus (ff-pull the host clone and re-stamp what it feeds), or a bounded apply verb must first land in \`host-agent-watch.sh\` (a fedora-bootstrap change — deliberately not invented here: destructive/unbounded host ops are out of #163's scope). When such a verb exists, bin/host-refresh.sh's control-repo arm is the seam that will file it."$'\n\n'"<sub>bin/host-refresh.sh (#163) — the host half of self-refresh; asked once per merged PR.</sub>" >/dev/null 2>&1; then
      log "$slug#$pr: merged control-repo change touches host-executed paths and no allowlisted apply verb exists — surfaced a question on the PR"
      : > "$mark"
    else
      log "$slug#$pr: host-apply question POST failed — retry next scan"
    fi
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
