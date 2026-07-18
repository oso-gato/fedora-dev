#!/usr/bin/env bash
# reconcile.sh — PROOF-GATED CLOSURE of backlog issues (apparatus reconciler, first slice; task #19).
#
# THE DEFECT IT REPLACES: dev-author used to put `Closes #N` in its PR body, so GitHub auto-closed the
# backlog issue THE INSTANT THE PR MERGED — before the change was built, published, or proven live. A
# merge whose CI never publishes, or whose deploy fails and rolls back, would still have closed the issue:
# "filed ≠ executed, merged ≠ live" (the audit's structural pattern #2). Arthur's decision (2026-07-18):
# *close each issue only after observing merge + GREEN verdict + live read-back, posting those proof links*.
#
# HOW: dev-author now stamps a NON-closing linkage `Backlog-ticket: #N` (GitHub does not auto-close on it).
# THIS actuator scans recently-merged PRs carrying that linkage and closes #N ONLY when the whole proof
# chain holds, posting the links as the closing comment. It is PLAIN SHELL, headless, bus-write-capable
# (unlike the interactive agent, which is classifier-walled from issue writes) — the sanctioned autonomous
# closer, exactly as the poller's retire_superseded is the sanctioned autonomous PR-closer.
#
# THE PROOF CHAIN (fail-closed at every link — a missing/unverifiable link WAITS or SKIPS, never closes):
#   1. MERGED       — the PR actually merged (mergedAt present).
#   2. HOST-GREEN    — the host live-gate posted VERDICT GREEN on it ($LG_HOST_LOGIN). A merged live-validate
#                      PR is definitionally GREEN (the poller requires it), but the reconciler VERIFIES it.
#   3. CI-PUBLISHED  — the merge commit's build.yml run CONCLUDED SUCCESS (the artifact exists). PENDING ⇒
#                      WAIT (re-scan); FAILED/absent ⇒ the artifact will never exist for this merge.
#   4. LIVE READ-BACK — the change is actually RUNNING. FIRST SLICE covers the LIVE-CLONE class (bin/**,
#                      policy/**, tests, docs — what the running box executes from its live clone): the
#                      merge sha is an ANCESTOR of the deployed clone's HEAD, i.e. the poller self-refresh
#                      (or a box rebuild) has advanced the box onto code that includes this merge. The
#                      IMAGE-BAKED class (Containerfile/install/entrypoint — only a rebuilt+redeployed
#                      image delivers it) needs the host redeploy-DONE signal, which is a DISCLOSED
#                      FOLLOW-UP: such merges WAIT here (never wrongly closed).
#
# NO LOCAL STATE (the host-refresh precedent): every decision input is GitHub- or clone-derived, and the
# dedup anchor is a `reconcile → closed:` comment posted on the PR (a wiped box re-derives + never
# double-closes; an already-CLOSED #N is a no-op). Idempotent + fail-safe: any fetch/close failure logs
# and degrades to the status quo — nothing here can stop a loop, and nothing closes an issue without proof.
#
#   reconcile.sh --once       one scan across the scoped repos, then exit
#   reconcile.sh --selftest   exercise the pure core (no gh / git / network)
#
# ENV: ORG (oso-gato) · RECONCILE_LOOKBACK (15 merged PRs/repo) · RECONCILE_MAX_AGE (172800s catch-up) ·
#      LG_HOST_LOGIN (oso-gato-erebus-claudebox) · RECONCILE_WORKFLOW (build.yml) · DEV_CLONE
#      (~/.local/share/fedora-dev — the deployed live clone, for the live read-back) · REPO_SCOPE
#      (bin/repo-scope.sh — R16) · BACKLOG_LABEL (backlog).
set -uo pipefail

ORG="${ORG:-oso-gato}"
LOOKBACK="${RECONCILE_LOOKBACK:-15}"
MAX_AGE="${RECONCILE_MAX_AGE:-172800}"
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
RECONCILE_WORKFLOW="${RECONCILE_WORKFLOW:-build.yml}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
DEV_CLONE="${DEV_CLONE:-$HOME/.local/share/fedora-dev}"

log(){ echo "reconcile: $*" >&2; }

# ---- PURE CORE (no I/O) — exercised by --selftest --------------------------------------------------

# IMAGE-BAKED paths (mirror of host-refresh.sh's IMAGE_RE): only a rebuilt+redeployed IMAGE delivers these
# to the running container, so the live-clone ancestor check is NOT a valid read-back for them (this slice
# WAITs on them). Everything else is LIVE-CLONE class — the box runs it straight from the live clone.
IMAGE_RE='^(Containerfile|install.*\.sh|entrypoint.*\.sh)$'
# change_class <newline-list-of-changed-paths> → IMAGE | CLONE. IMAGE iff ANY path is image-baked (the
# strong requirement: one image-baked file means the merge is not fully live until a redeploy).
change_class(){ if grep -qE "$IMAGE_RE"; then echo IMAGE; else echo CLONE; fi; }

# backlog_ref <pr-body> → the "#N" a `Backlog-ticket:` trailer names (first match), else empty. Anchored
# to a line that STARTS with the trailer (a quoted/mid-prose mention is inert), digits only.
backlog_ref(){
  printf '%s\n' "$1" | grep -oiE '^Backlog-ticket:[[:space:]]*#[0-9]+' | head -1 | grep -oE '[0-9]+'
}

# close_decision <merged:0|1> <host_green:0|1> <publish:SUCCESS|PENDING|FAILED|NONE> <live:LIVE|PENDING|NA>
#   → CLOSE | WAIT:<why> | SKIP:<why>. Fail-closed: closes ONLY when EVERY link holds.
close_decision(){
  local merged="$1" green="$2" pub="$3" live="$4"
  [ "$merged" = 1 ] || { echo "SKIP:not-merged"; return; }
  [ "$green"  = 1 ] || { echo "WAIT:no-host-green"; return; }   # retryable: transient fetch, or gate lag
  case "$pub" in
    SUCCESS) : ;;
    PENDING|NONE) echo "WAIT:ci-$( [ "$pub" = NONE ] && echo not-started || echo pending )"; return;;
    *)       echo "SKIP:ci-$pub"; return;;                      # FAILED/CANCELLED — artifact never exists
  esac
  case "$live" in
    LIVE|NA) echo "CLOSE";;
    *)       echo "WAIT:not-live-yet";;                         # PENDING — box has not yet run this merge
  esac
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== backlog_ref (line-anchored trailer, digits only) =="
  ck "trailer → #"        "$(backlog_ref $'Autonomously authored.\nBacklog-ticket: #207\n')" "207"
  ck "case-insensitive"   "$(backlog_ref 'backlog-ticket:  #42')" "42"
  ck "quoted is inert"    "$(backlog_ref '> Backlog-ticket: #99')" ""
  ck "no trailer → empty" "$(backlog_ref 'Closes #5')" ""
  echo "== change_class (IMAGE iff any image-baked path; reads the path list on STDIN, as the scan pipes it) =="
  ck "bin only → CLONE"      "$(printf '%s\n' bin/x.sh policy/CLAUDE.md | change_class)" "CLONE"
  ck "Containerfile → IMAGE" "$(printf '%s\n' bin/x.sh Containerfile | change_class)" "IMAGE"
  ck "entrypoint → IMAGE"    "$(printf '%s\n' entrypoint.sh | change_class)" "IMAGE"
  ck "docs/tests → CLONE"    "$(printf '%s\n' README.md foo.test.sh | change_class)" "CLONE"
  echo "== close_decision — fail-closed proof chain =="
  ck "all links hold → CLOSE"          "$(close_decision 1 1 SUCCESS LIVE)" "CLOSE"
  ck "image-baked NA-live also CLOSE"  "$(close_decision 1 1 SUCCESS NA)" "CLOSE"
  ck "not merged → SKIP"               "$(close_decision 0 1 SUCCESS LIVE)" "SKIP:not-merged"
  ck "no host green → WAIT"            "$(close_decision 1 0 SUCCESS LIVE)" "WAIT:no-host-green"
  ck "ci pending → WAIT"               "$(close_decision 1 1 PENDING LIVE)" "WAIT:ci-pending"
  ck "ci not-started → WAIT"           "$(close_decision 1 1 NONE LIVE)" "WAIT:ci-not-started"
  ck "ci failed → SKIP"                "$(close_decision 1 1 FAILED LIVE)" "SKIP:ci-FAILED"
  ck "published but not live → WAIT"   "$(close_decision 1 1 SUCCESS PENDING)" "WAIT:not-live-yet"
  echo; echo "reconcile selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- I/O helpers (real gh / git) -------------------------------------------------------------------

# too_old <mergedAt-iso> — rc 0 when older than the catch-up window (bounds a wiped box's back-scan). An
# unparsable/empty date is treated as too old (fail-safe: never resurrect ancient merges). No Date.now in
# scripts is a workflow-runtime rule, not a shell one — `date` is fine here.
too_old(){
  local iso="$1" now m
  now="$(date -u +%s 2>/dev/null)" || return 0
  m="$(date -u -d "$iso" +%s 2>/dev/null)" || return 0
  [ -n "$m" ] || return 0
  [ $(( now - m )) -gt "$MAX_AGE" ]
}

# host_green_p <slug> <pr> — rc 0 iff the host live-gate ($LG_HOST_LOGIN) posted a VERDICT GREEN comment.
host_green_p(){
  gh pr view "$2" --repo "$1" --json comments \
    -q "[.comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | select(.body|test(\"VERDICT GREEN\"))] | length" \
    2>/dev/null | grep -qvE '^(0|)$'
}

# publish_state <slug> <merge-oid> → SUCCESS | PENDING | FAILED | NONE (the merge commit's build.yml run).
publish_state(){
  local st
  st="$(gh run list --repo "$1" --workflow "$RECONCILE_WORKFLOW" --commit "$2" \
        --json status,conclusion -q '.[0] | (.conclusion // .status // "")' 2>/dev/null)"
  case "$st" in
    success)                 echo SUCCESS;;
    ''|null)                 echo NONE;;
    failure|cancelled|timed_out|action_required|startup_failure) echo FAILED;;
    *)                       echo PENDING;;   # queued/in_progress/requested/waiting/pending
  esac
}

# live_readback <slug> <class> <merge-oid> → LIVE | PENDING | NA
#   CLONE class on THIS repo (fedora-dev): LIVE iff the merge sha is an ancestor of the DEPLOYED clone HEAD
#   (the running box self-refreshed onto code that includes it). Other repos / IMAGE class: PENDING here
#   (the host-redeploy read-back is the disclosed follow-up), so they are never wrongly closed.
live_readback(){
  local slug="$1" class="$2" oid="$3"
  [ "$class" = CLONE ] || { echo PENDING; return; }
  [ "$slug" = "$ORG/fedora-dev" ] || { echo PENDING; return; }
  [ -d "$DEV_CLONE/.git" ] || { echo PENDING; return; }
  if git -C "$DEV_CLONE" merge-base --is-ancestor "$oid" HEAD 2>/dev/null; then echo LIVE; else echo PENDING; fi
}

# ---- ONE SCAN over a repo --------------------------------------------------------------------------
scan_repo(){ # <repo bare name>
  local repo="$1" slug="$ORG/$1"
  "$REPO_SCOPE" check "$repo" >/dev/null 2>&1 || { log "R16: '$repo' out of scope — skipping"; return 0; }
  local rows; rows="$(gh pr list --repo "$slug" --state merged --search 'sort:updated-desc' --limit "$LOOKBACK" \
                      --json number,mergeCommit,mergedAt,body -q '.[] | "\(.number)\t\(.mergeCommit.oid)\t\(.mergedAt)\t\(.body|gsub("\n";"\\n"))"' 2>/dev/null)" \
    || { log "$slug: merged-PR list failed — skipping this scan"; return 0; }
  [ -n "$rows" ] || return 0
  local pr oid mergedAt bodyenc body ref issue_state class pub live comments
  while IFS=$'\t' read -r pr oid mergedAt bodyenc; do
    [ -n "$pr" ] || continue
    body="$(printf '%b' "$bodyenc")"
    ref="$(backlog_ref "$body")"; [ -n "$ref" ] || continue      # only PRs that claim a backlog ticket
    too_old "$mergedAt" && { log "$slug#$pr → #$ref: merge outside the catch-up window — leaving to a human"; continue; }
    # dedup anchor (no local state): a prior 'reconcile → closed:' comment on the PR means done.
    comments="$(gh pr view "$pr" --repo "$slug" --json comments -q '.comments[].body' 2>/dev/null)"
    printf '%s' "$comments" | grep -qF 'reconcile → closed:' && { log "$slug#$pr → #$ref: already reconciled (anchor present)"; continue; }
    issue_state="$(gh issue view "$ref" --repo "$slug" --json state -q .state 2>/dev/null)"
    [ "$issue_state" = OPEN ] || { log "$slug#$pr → #$ref: issue already $issue_state (nothing to close)"; continue; }
    class="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null | change_class)"
    pub="$(publish_state "$slug" "$oid")"
    live="$(live_readback "$slug" "$class" "$oid")"
    local verdict; verdict="$(close_decision 1 "$(host_green_p "$slug" "$pr" && echo 1 || echo 0)" "$pub" "$live")"
    case "$verdict" in
      CLOSE)
        gh issue close "$ref" --repo "$slug" \
          --comment "**reconcile → closed:** proof-gated closure of #$ref — authored PR #$pr merged (\`${oid:0:7}\`), host live-gate GREEN, CI \`$RECONCILE_WORKFLOW\` published, live read-back OK ($class class). $slug#$pr"$'\n\n<sub>bin/reconcile.sh (task #19) — closed on OBSERVED proof, not on merge. This comment is the wiped-state dedup anchor.</sub>' \
          >/dev/null 2>&1 \
          && log "$slug#$pr → CLOSED #$ref (proof: merged+green+published+live/$class)" \
          || log "$slug#$pr → #$ref: close FAILED (will retry next scan)"
        # stamp the PR too, so the dedup anchor exists even if the issue-close comment is unreadable later.
        gh pr comment "$pr" --repo "$slug" --body "**reconcile → closed:** #$ref closed on observed proof (merged \`${oid:0:7}\` · host GREEN · CI published · live/$class)." >/dev/null 2>&1 || true
        ;;
      WAIT:*) log "$slug#$pr → #$ref: ${verdict#WAIT:} — not closing yet (re-scan)";;
      SKIP:*) log "$slug#$pr → #$ref: ${verdict#SKIP:} — not a proof-gated close";;
    esac
  done <<<"$rows"
}

case "${1:-}" in
  --once)
    while IFS= read -r r <&3; do [ -n "$r" ] && scan_repo "$r"; done 3< <("$REPO_SCOPE" list 2>/dev/null)
    ;;
  *) echo "usage: reconcile.sh --once | --selftest" >&2; exit 2;;
esac
