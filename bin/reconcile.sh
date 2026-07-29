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
#                      policy/**, tests, docs — what the running box executes from its live clone) OF THIS
#                      REPO: the merge sha is an ANCESTOR of the deployed clone's HEAD, i.e. the poller
#                      self-refresh (or a box rebuild) has advanced the box onto code that includes this
#                      merge. Everything else the apparatus DEPLOYS ($RECONCILE_DEPLOYED — the IMAGE-BAKED
#                      class here, plus fedora-desktop and fedora-bootstrap, all of which need the host
#                      redeploy/apply-DONE signal) is a DISCLOSED FOLLOW-UP: such merges WAIT here, never
#                      wrongly closed. A repo the apparatus merely DEVELOPS has no instance anywhere, so
#                      this link is N/A on it rather than a wait for an event that is never coming.
#
# NO LOCAL STATE (the host-refresh precedent): every decision input is GitHub- or clone-derived, and the
# dedup anchor is a `reconcile → closed:` comment posted on the ISSUE (a wiped box re-derives + never
# double-closes; an already-CLOSED #N is a no-op). It is PER-REF and lives on the issue because a
# PR-level mark cannot say WHICH of N declared tickets it attests to. The close is issued BEFORE the
# comment, as two separate calls, so an anchor can only ever exist on an issue that really closed.
# Idempotent + fail-safe: any fetch/close failure logs and degrades to the status quo — nothing here can
# stop a loop, and nothing closes an issue without proof.
#
#   reconcile.sh --once       one scan across the scoped repos, then exit
#   reconcile.sh --selftest   exercise the pure core (no gh / git / network)
#
# ENV: ORG (oso-gato) · RECONCILE_LOOKBACK (15 merged PRs/repo) · RECONCILE_MAX_AGE (172800s catch-up) ·
#      LG_HOST_LOGIN (oso-gato-erebus-claudebox) · RECONCILE_WORKFLOW (build.yml) · DEV_CLONE
#      (~/.local/share/fedora-dev — the deployed live clone, for the live read-back) · REPO_SCOPE
#      (bin/repo-scope.sh — R16) · BACKLOG_LABEL (backlog) · RECONCILE_DEPLOYED ("fedora-dev
#      fedora-desktop fedora-bootstrap" — the repos an instance of which the apparatus runs; see below).
set -uo pipefail

ORG="${ORG:-oso-gato}"
LOOKBACK="${RECONCILE_LOOKBACK:-15}"
MAX_AGE="${RECONCILE_MAX_AGE:-172800}"
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
RECONCILE_WORKFLOW="${RECONCILE_WORKFLOW:-build.yml}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
# THE REPOS THE APPARATUS RUNS A DEPLOYED INSTANCE OF — the discriminator between the live read-back's
# "not yet" (PENDING) and "never" (NA). Membership MIRRORS bin/host-refresh.sh's own deploy set: its
# WORKLOADS (`fedora-dev fedora-desktop` — itself a mirror of the host agent's KNOWN_WORKLOADS arg
# allowlist, the repos the apparatus files `redeploy <workload>` tickets for) plus its CONTROL_REPO
# (fedora-bootstrap — the host itself). Kept as a DEDICATED knob rather than read from
# $HOST_REFRESH_WORKLOADS because that variable answers a DIFFERENT question — "should I file redeploy
# tickets?" — and its documented empty-disables contract would then silently mean "nothing is deployed"
# here, re-arming the exact close-on-CI-alone defect this routing exists to prevent. `:-` (not `-`), so
# an empty value takes the default: an EMPTY deploy set is the unsafe direction here (every repo becomes
# NA and closes without a delivery link), the mirror-image of host-refresh, where empty is a safe no-op.
# reconcile.test.sh pins the two enumerations in lockstep so they cannot drift silently.
RECONCILE_DEPLOYED_DEFAULT='fedora-dev fedora-desktop fedora-bootstrap'
RECONCILE_DEPLOYED="${RECONCILE_DEPLOYED:-$RECONCILE_DEPLOYED_DEFAULT}"
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

# backlog_refs <pr-body> → EVERY ticket the body declares, one per line, in order, deduped.
# A superseding PR routinely delivers several tickets: e2e-beta#15 shipped the work of #2, #3 AND #6
# after #9/#10 were closed unmerged — but `backlog_ref`'s `head -1` reads only the first, so #2 and #3
# were delivered and PERMANENTLY unclaimable. Nothing could ever close them, so `drivable` could never
# reach 0 and the objective could never ship.
# GRAMMAR (deliberately strict — a loose match here closes the WRONG issue): a line that STARTS with the
# trailer, singular or plural, then #N optionally repeated, separated by a comma and/or spaces. The match
# STOPS at the first thing that is not another #N, so trailing prose cannot drag an unrelated number in:
#   "Backlog-ticket: #6 and also #99"  → 6      (prose stops it)
#   "Backlog-ticket: #6 (supersedes #99)" → 6   (paren stops it)
#   "Backlog-ticket: #6#2"             → 6      (glued is not a list)
# #0 and leading zeros are refused (no such issue). Every previously-inert form stays inert: indented,
# quoted, mid-prose, colon-less, and #-less all still yield nothing.
# strip_noncode <text> — remove ``` fenced blocks and <!-- HTML comments --> before trailer parsing.
# A trailer is a DECLARATION; text that merely SHOWS one is not. A PR body that documents the trailer
# form (```\nBacklog-ticket: #99\n```) puts a line-initial match in the body, and the parser cannot tell
# it from a real declaration — MEASURED: such a body yields `400 99`, so #99, never declared by anyone,
# would be closed as delivered. Line-start anchoring is not enough once bodies discuss their own format.
strip_noncode(){
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }        # drop the fence lines and everything between
    fence { next }
    { gsub(/<!--.*-->/, "") }                          # single-line HTML comments
    /<!--/ { htm = 1 } htm { if (/-->/) htm = 0; next } # multi-line HTML comments
    { print }'
}

backlog_refs(){
  strip_noncode "$1" \
  | grep -oiE '^Backlog-tickets?:[[:space:]]*#[1-9][0-9]*(([[:space:]]*,[[:space:]]*|[[:space:]]+)#[1-9][0-9]*)*' \
  | grep -oE '#[1-9][0-9]*' \
  | { seen=''; while IFS= read -r n; do n="${n#\#}"
        case " $seen " in *" $n "*) continue;; esac      # a repeat is one ticket, not two closes
        seen="$seen $n"; printf '%s\n' "$n"
      done; }
}

# ref_gate <issue-state> <prior-close:0|1> <labels-csv> → TAKE | SKIP:<why> (pure).
# PER-REF admission. The old whole-PR anchor cannot express "ref 1 done, ref 2 outstanding", so with N
# refs a single success would strand the rest forever. Each ref is now admitted on its OWN evidence.
#   * The `backlog` label is REQUIRED. It is the guard $BACKLOG_LABEL always documented but never
#     enforced, and it matters far more once N refs are in play: issues and PRs share one number space,
#     and `gh issue view <pr#>` happily resolves a PR and reports state OPEN — so a stray number in a
#     trailer could otherwise close a PULL REQUEST. A PR carries `live-validate`, never `backlog`.
#   * A prior close-comment on an issue that is OPEN again means a human REOPENED it. Never re-close.
#   * An unreadable read yields SKIP — never a close on absent evidence.
ref_gate(){
  local state="$1" prior="${2:-0}" labels="${3:-}"
  [ -n "$state" ] || { echo "SKIP:unreadable"; return; }
  case "$state" in
    OPEN) : ;;
    MERGED) echo "SKIP:already-MERGED"; return;;            # a PR number, not an issue
    *) echo "SKIP:already-$state"; return;;
  esac
  case ",$labels," in *",$BACKLOG_LABEL,"*) : ;; *) echo "SKIP:not-a-backlog-issue"; return;; esac
  [ "$prior" = 1 ] && { echo "SKIP:reopened-or-half-closed"; return; }
  echo TAKE
}

# close_decision <merged:0|1> <host_green:0|1> <publish:SUCCESS|PENDING|FAILED|NONE|NA> <live:LIVE|PENDING|NA>
#   → CLOSE | WAIT:<why> | SKIP:<why>. Fail-closed: closes ONLY when EVERY APPLICABLE link holds.
#
# NA means "this link cannot be taken on this change" — not "skip the check". It is only ever produced
# from POSITIVE evidence (a cleanly-read tree with no publish workflow; a repo the apparatus runs no
# instance of), never from a read that failed. The two links that CANNOT be NA are the two that carry the
# proof: the change MERGED, and the host live-gate posted GREEN on it. Every close still rests on those.
close_decision(){
  local merged="$1" green="$2" pub="$3" live="$4"
  [ "$merged" = 1 ] || { echo "SKIP:not-merged"; return; }
  [ "$green"  = 1 ] || { echo "WAIT:no-host-green"; return; }   # retryable: transient fetch, or gate lag
  case "$pub" in
    SUCCESS|NA) : ;;
    PENDING|NONE) echo "WAIT:ci-$( [ "$pub" = NONE ] && echo not-started || echo pending )"; return;;
    *)       echo "SKIP:ci-$pub"; return;;                      # FAILED/CANCELLED — artifact never exists
  esac
  case "$live" in
    LIVE|NA) echo "CLOSE";;
    *)       echo "WAIT:not-live-yet";;                         # PENDING — box has not yet run this merge
  esac
}

# deployed_p <slug> → 0 iff the apparatus RUNS A DEPLOYED INSTANCE of this repo ($RECONCILE_DEPLOYED).
# THIS IS THE WHOLE DISCRIMINATOR between "not yet" and "never", so it is a set membership rather than a
# slug literal: the question a live read-back asks is "does an instance of this exist to read back from?",
# and every repo the apparatus deploys answers yes — not just the one whose name someone remembered.
# The `:-` re-applies the default here too, not just at the assignment above: an EMPTY set is the unsafe
# state (every repo reads NA and closes with no delivery link), so it can never be reached — by an empty
# env at load, or by a caller emptying the variable at runtime. One literal, guarded at both levels.
deployed_p(){
  local slug="$1" w
  for w in ${RECONCILE_DEPLOYED:-$RECONCILE_DEPLOYED_DEFAULT}; do [ "$slug" = "$ORG/$w" ] && return 0; done
  return 1
}

# live_readback <slug> <class> <merge-oid> → LIVE | PENDING | NA
#   A REPO THE APPARATUS DEPLOYS (deployed_p — the workloads + the control repo): never NA. An instance
#   exists, so the link is takeable in principle and a real delivery event is still coming; only the READ
#   is missing here. Within that set:
#     · THIS repo (fedora-dev), CLONE class: LIVE iff the merge sha is an ancestor of the DEPLOYED clone
#       HEAD (the running box self-refreshed onto code that includes it) — the one read-back this slice
#       can actually take, because $DEV_CLONE is the one deployed checkout the dev box can read.
#     · THIS repo, IMAGE class: PENDING — delivery needs the host redeploy, a real pending event.
#     · EVERY OTHER DEPLOYED REPO (fedora-desktop, fedora-bootstrap): PENDING — their delivery signal
#       already exists on the bus (the host App's `**host-agent: DONE|FAILED**` on the redeploy /
#       apply ticket the merge files, which bin/host-refresh.sh ticket_outcome() already reads), it is
#       just not wired into this actuator yet. A DISCLOSED FOLLOW-UP; until then they wait.
#   ANY OTHER REPO: NA. For a repo the apparatus merely DEVELOPS there is no deployed instance of it
#   ANYWHERE in the apparatus to read back from, so the link can NEVER be satisfied and must not be
#   reported as "not yet" (that was the 147-permanent-wait bug). What proves such a change delivered is
#   the link that IS taken on it: the host live-gate, which builds the candidate on a real host + probes it.
#   NA is therefore about the ABSENCE OF ANY INSTANCE, never about this box's convenience — the dev box
#   cannot read erebus, but that is a missing READ, not a missing INSTANCE, and the two must not be folded
#   together: doing so closes a deployed workload's ticket the instant CI publishes, i.e. on merge alone,
#   which is the "merged ≠ live" pattern this whole actuator exists to kill.
# Lives with the decision functions, not the I/O helpers: the routing above is pure (and is what broke),
# and the one git probe is reached only for this repo's own clone, behind an existence guard.
live_readback(){
  local slug="$1" class="$2" oid="$3"
  # A DEPLOYED REPO IS NOT "NO READ-BACK AVAILABLE" — it is "read-back NOT WIRED HERE YET" (PENDING, not
  # NA). Two measured reasons this must hold for the whole deploy set, not just this repo:
  #   · fedora-bootstrap: MEASURED 2026-07-29, every one of the 27 apply-bootstrap tickets (#239…#317)
  #     reads FAILED and none DONE — so merged+host-GREEN is demonstrably NOT delivery there, and an NA
  #     would have closed #187's issue #133 as shipped for a feature that has never once run on the host.
  #   · fedora-desktop: the apparatus files `redeploy fedora-desktop` tickets for it
  #     (bin/host-refresh.sh WORKLOADS) and that signal demonstrably works (`redeploy fedora-dev` #255 →
  #     `host-agent: DONE`). An NA here closes its tickets the instant CI publishes — BEFORE, and
  #     regardless of, the host redeploy that actually delivers the image.
  # Today only the 48h age window stops either, and the window protects nothing for the NEXT such merge.
  # PENDING is the honest answer until the outcome read is wired (follow-up); it costs only that these
  # tickets keep waiting, which is what they should do while nothing has proven the change is running.
  deployed_p "$slug" || { echo NA; return; }
  [ "$slug" = "$ORG/fedora-dev" ] || { echo PENDING; return; }
  [ "$class" = CLONE ] || { echo PENDING; return; }
  [ -d "$DEV_CLONE/.git" ] || { echo PENDING; return; }
  if git -C "$DEV_CLONE" merge-base --is-ancestor "$oid" HEAD 2>/dev/null; then echo LIVE; else echo PENDING; fi
}

# proof_summary <pub> <live> <class> → the proof record the closing comment carries. EACH LINK REPORTS ITS
# OWN STATE: a link that was NOT TAKEN says "N/A" and why, instead of being folded into a blanket claim
# that everything was satisfied. That comment is this actuator's PERMANENT audit record AND its dedup
# anchor (never rewritten), for a component whose entire purpose is proof-gated closure — so a close that
# skipped a link while asserting it held would be a false proof on the one artifact that must not lie.
# merged + host-GREEN are unconditional here because close_decision can never reach CLOSE without them.
proof_summary(){
  local pub="$1" live="$2" class="$3" p l
  case "$pub" in
    SUCCESS) p="CI \`$RECONCILE_WORKFLOW\` published";;
    NA)      p="CI: N/A — this commit publishes no image (no \`$RECONCILE_WORKFLOW\` in the tree at it)";;
    *)       p="CI: $pub";;   # unreachable via close_decision; report the raw state rather than invent one
  esac
  case "$live" in
    LIVE) l="live read-back OK ($class class)";;
    NA)   l="live read-back: N/A — the apparatus deploys no instance of this repo, so there is nothing anywhere to read back from; the proof of delivery is the host live-gate";;
    *)    l="live read-back: $live";;
  esac
  echo "host live-gate GREEN, $p, $l"
}

# proof_tag <pub> <live> <class> → the same record, compressed for the log line (which made the same claim).
proof_tag(){
  local pub="$1" live="$2" class="$3" p l
  if [ "$pub"  = NA ]; then p="ci-N/A";   else p="published";     fi
  if [ "$live" = NA ]; then l="live-N/A"; else l="live/$class";   fi
  echo "merged+green+$p+$l"
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
  echo "== backlog_refs — the SINGLE-ref grammar is unchanged (the four rows above, re-proved) =="
  ck "trailer → #"        "$(backlog_refs $'Autonomously authored.\nBacklog-ticket: #207\n')" "207"
  ck "case-insensitive"   "$(backlog_refs 'backlog-ticket:  #42')" "42"
  ck "quoted is inert"    "$(backlog_refs '> Backlog-ticket: #99')" ""
  ck "no trailer → empty" "$(backlog_refs 'Closes #5')" ""
  echo "== backlog_refs — MULTI: a PR that delivers N tickets must be able to claim all N =="
  # e2e-beta#15 shipped #2, #3 AND #6 (after #9/#10 were closed unmerged) but declared only #6, so #2
  # and #3 were delivered and permanently unclaimable — drivable could never reach 0.
  ck "two trailer lines"    "$(backlog_refs $'x\nBacklog-ticket: #6\nBacklog-ticket: #2\ny')" "$(printf '6\n2')"
  ck "the real #15 shape"   "$(backlog_refs $'Backlog-ticket: #6\nBacklog-ticket: #2\nBacklog-ticket: #3')" "$(printf '6\n2\n3')"
  ck "comma list"           "$(backlog_refs 'Backlog-ticket: #6, #2, #3')" "$(printf '6\n2\n3')"
  ck "comma, no space"      "$(backlog_refs 'Backlog-ticket: #6,#2')" "$(printf '6\n2')"
  ck "space-separated"      "$(backlog_refs 'Backlog-ticket: #6 #2')" "$(printf '6\n2')"
  ck "plural spelling"      "$(backlog_refs 'Backlog-tickets: #6, #2')" "$(printf '6\n2')"
  ck "repeat collapses"     "$(backlog_refs $'Backlog-ticket: #6\nBacklog-ticket: #6')" "6"
  echo "== backlog_refs — what MUST stay inert (each could otherwise close the WRONG issue) =="
  ck "prose after → stops"  "$(backlog_refs 'Backlog-ticket: #6 and also #99')" "6"
  ck "paren after → stops"  "$(backlog_refs 'Backlog-ticket: #6 (supersedes #99)')" "6"
  ck "glued #6#2 → stops"   "$(backlog_refs 'Backlog-ticket: #6#2')" "6"
  ck "mid-prose inert"      "$(backlog_refs 'See Backlog-ticket: #99')" ""
  ck "indented inert"       "$(backlog_refs '  Backlog-ticket: #99')" ""
  ck "no # inert"           "$(backlog_refs 'Backlog-ticket: 99')" ""
  ck "no colon inert"       "$(backlog_refs 'Backlog-ticket #6')" ""
  ck "#0 inert"             "$(backlog_refs 'Backlog-ticket: #0')" ""
  ck "leading zero inert"   "$(backlog_refs 'Backlog-ticket: #007')" ""
  echo "== backlog_refs — a trailer SHOWN is not a trailer DECLARED (adversarial review, 2026-07-29) =="
  # A PR body that documents the trailer form puts a line-initial match in the body. MEASURED before the
  # fix: this exact body yielded `400 99`, so #99 — declared by nobody — would have been CLOSED.
  ck "fenced block is inert"  "$(backlog_refs $'Autonomously authored.\n\nBacklog-ticket: #400\n\nRecognised form:\n\n```\nBacklog-ticket: #99\n```\n')" "400"
  ck "indented fence too"     "$(backlog_refs $'Backlog-ticket: #400\n  ```\n  Backlog-ticket: #99\n  ```\n')" "400"
  ck "html comment is inert"  "$(backlog_refs $'Backlog-ticket: #400\n<!-- Backlog-ticket: #99 -->\n')" "400"
  ck "multiline html comment" "$(backlog_refs $'Backlog-ticket: #400\n<!--\nBacklog-ticket: #99\n-->\n')" "400"
  ck "real trailers survive"  "$(backlog_refs $'```\nBacklog-ticket: #99\n```\nBacklog-ticket: #6\nBacklog-ticket: #2\n')" "$(printf '6\n2')"
  echo "== ref_gate — PER-REF admission (ref 2 must never be stranded by ref 1) =="
  ck "open backlog issue → TAKE"   "$(ref_gate OPEN 0 'backlog')" "TAKE"
  ck "extra labels → TAKE"         "$(ref_gate OPEN 0 'backlog,feature')" "TAKE"
  ck "already CLOSED → no-op"      "$(ref_gate CLOSED 0 'backlog')" "SKIP:already-CLOSED"
  ck "legacy PR-anchor case"       "$(ref_gate CLOSED 1 'backlog')" "SKIP:already-CLOSED"
  # Issues and PRs share ONE number space and `gh issue view <pr#>` resolves a PR as state OPEN. The
  # backlog label is what stops a stray trailer number from closing a PULL REQUEST.
  ck "a MERGED PR number → no-op"  "$(ref_gate MERGED 0 '')" "SKIP:already-MERGED"
  ck "an OPEN PR is NOT an issue"  "$(ref_gate OPEN 0 'live-validate')" "SKIP:not-a-backlog-issue"
  ck "unlabelled issue → no"       "$(ref_gate OPEN 0 '')" "SKIP:not-a-backlog-issue"
  ck "label substring is not it"   "$(ref_gate OPEN 0 'backlogged')" "SKIP:not-a-backlog-issue"
  ck "reopened → human decides"    "$(ref_gate OPEN 1 'backlog')" "SKIP:reopened-or-half-closed"
  ck "unreadable → never close"    "$(ref_gate '' 0 'backlog')" "SKIP:unreadable"
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
  echo "== close_decision — NA links (the observed permanent-WAIT bug: 147 logged waits that could never end) =="
  # fedora-bootstrap ships no build.yml at all, so it waited on a run that will never exist (124 times).
  ck "no publish workflow → CLOSE"     "$(close_decision 1 1 NA LIVE)" "CLOSE"
  # e2e-beta #11-13: merged, host-GREEN, image published — but the apparatus runs no instance to read back.
  ck "not-our-clone → CLOSE"           "$(close_decision 1 1 SUCCESS NA)" "CLOSE"
  # e2e-beta #14/#15: merged BEFORE build.yml landed, so no run was ever going to appear.
  ck "both links N/A → CLOSE"          "$(close_decision 1 1 NA NA)" "CLOSE"
  # NA must relax ONLY the two links that can be N/A. The proof links stay mandatory.
  ck "NA never bypasses host-green"    "$(close_decision 1 0 NA NA)" "WAIT:no-host-green"
  ck "NA never bypasses merged"        "$(close_decision 0 1 NA NA)" "SKIP:not-merged"
  ck "NA-live still SKIPs a failed CI" "$(close_decision 1 1 FAILED NA)" "SKIP:ci-FAILED"
  ck "workflow present, run pending"   "$(close_decision 1 1 PENDING NA)" "WAIT:ci-pending"
  echo "== live_readback — a link that can never be taken is NA, never a forever-PENDING =="
  ck "other repo → NA"        "$(live_readback oso-gato/e2e-beta CLONE deadbeef)" "NA"
  ck "other repo, IMAGE → NA" "$(live_readback oso-gato/e2e-beta IMAGE deadbeef)" "NA"
  # THE CONTROL REPO IS NOT NA. Measured 2026-07-29: all 27 apply-bootstrap tickets read FAILED, none
  # DONE — so merged+host-GREEN is demonstrably NOT delivery there, and an NA here would have closed
  # fedora-bootstrap#187's issue #133 as shipped. Only the 48h age window stood in the way, and it
  # protects nothing for the next such merge.
  ck "control repo → PENDING, not NA"  "$(live_readback oso-gato/fedora-bootstrap CLONE deadbeef)" "PENDING"
  ck "control repo, IMAGE → PENDING"   "$(live_readback oso-gato/fedora-bootstrap IMAGE deadbeef)" "PENDING"
  ck "…so the control repo cannot close" "$(close_decision 1 1 NA "$(live_readback oso-gato/fedora-bootstrap CLONE deadbeef)")" "WAIT:not-live-yet"
  # NEITHER IS A DEPLOYED WORKLOAD. fedora-desktop is in host-refresh.sh's WORKLOADS: the apparatus files
  # `redeploy fedora-desktop` tickets for it and that signal works (`redeploy fedora-dev` #255 → DONE), so
  # an NA here would close its tickets the instant CI publishes — before the redeploy that delivers them.
  # Keying the carve-out on the fedora-bootstrap SLUG missed exactly this; deployed_p keys on the set.
  ck "workload → PENDING, not NA"      "$(live_readback oso-gato/fedora-desktop CLONE deadbeef)" "PENDING"
  ck "workload, IMAGE → PENDING"       "$(live_readback oso-gato/fedora-desktop IMAGE deadbeef)" "PENDING"
  ck "…so a workload cannot close"     "$(close_decision 1 1 SUCCESS "$(live_readback oso-gato/fedora-desktop CLONE deadbeef)")" "WAIT:not-live-yet"
  ck "deployed_p: workload"            "$(deployed_p oso-gato/fedora-desktop   && echo y || echo n)" "y"
  ck "deployed_p: control repo"        "$(deployed_p oso-gato/fedora-bootstrap && echo y || echo n)" "y"
  ck "deployed_p: own repo"            "$(deployed_p oso-gato/fedora-dev       && echo y || echo n)" "y"
  ck "deployed_p: developed-only"      "$(deployed_p oso-gato/e2e-beta         && echo y || echo n)" "n"
  # Set membership is exact — a repo whose name merely CONTAINS a deployed one is not deployed.
  ck "deployed_p: no substring match"  "$(deployed_p oso-gato/fedora-desktop-x && echo y || echo n)" "n"
  ck "deployed_p: org-bound"           "$(deployed_p other-org/fedora-desktop  && echo y || echo n)" "n"
  # An EMPTY deploy set is the unsafe direction (everything NA ⇒ everything closes), so it takes the
  # default rather than emptying — the mirror-image of host-refresh.sh, where empty is a safe no-op.
  ck "empty deploy set → default"      "$(RECONCILE_DEPLOYED= live_readback oso-gato/fedora-desktop CLONE deadbeef)" "PENDING"
  # …while the repos that genuinely have no instance still do close (the unblock this PR exists for).
  ck "developed repo still closes"     "$(close_decision 1 1 NA "$(live_readback oso-gato/e2e-beta CLONE deadbeef)")" "CLOSE"
  # On fedora-dev itself the read-back IS takeable, so it stays mandatory — an image-baked change there is
  # live only once the host redeploys, which is a real event that actually arrives.
  ck "own repo, IMAGE → PENDING" "$(DEV_CLONE=/nonexistent live_readback oso-gato/fedora-dev IMAGE deadbeef)" "PENDING"
  ck "own repo, no clone → PENDING" "$(DEV_CLONE=/nonexistent live_readback oso-gato/fedora-dev CLONE deadbeef)" "PENDING"
  echo "== proof_summary / proof_tag — the record must state each link's REAL state, never a blanket claim =="
  # A close that skipped a link while asserting it held is a false proof on the actuator's own audit record.
  has(){ case "$2" in *"$3"*) ck "$1" yes yes;; *) ck "$1" "$2" "…$3…";; esac; }
  hasnt(){ case "$2" in *"$3"*) ck "$1" "$2" "NOT …$3…";; *) ck "$1" yes yes;; esac; }
  has   "taken CI link says published"  "$(proof_summary SUCCESS LIVE CLONE)" "CI \`$RECONCILE_WORKFLOW\` published"
  has   "taken live link says OK"       "$(proof_summary SUCCESS LIVE CLONE)" "live read-back OK (CLONE class)"
  has   "NA publish reported as N/A"    "$(proof_summary NA LIVE CLONE)" "CI: N/A"
  hasnt "NA publish never says published" "$(proof_summary NA LIVE CLONE)" "published"
  has   "NA live reported as N/A"       "$(proof_summary SUCCESS NA CLONE)" "live read-back: N/A"
  hasnt "NA live never says read-back OK" "$(proof_summary SUCCESS NA CLONE)" "read-back OK"
  has   "both N/A: neither is claimed"  "$(proof_summary NA NA CLONE)" "CI: N/A"
  hasnt "both N/A: no 'published'"      "$(proof_summary NA NA CLONE)" "published"
  has   "host-GREEN stays unconditional" "$(proof_summary NA NA CLONE)" "host live-gate GREEN"
  ck "tag: all links taken"  "$(proof_tag SUCCESS LIVE CLONE)" "merged+green+published+live/CLONE"
  ck "tag: publish N/A"      "$(proof_tag NA LIVE CLONE)"      "merged+green+ci-N/A+live/CLONE"
  ck "tag: live N/A"         "$(proof_tag SUCCESS NA CLONE)"   "merged+green+published+live-N/A"
  ck "tag: both N/A"         "$(proof_tag NA NA CLONE)"        "merged+green+ci-N/A+live-N/A"
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

# issue_facts <slug> <issue#> → "<state>\t<prior-close:0|1>\t<labels-csv>"; EMPTY when unreadable (the
# gate then SKIPs). ONE call carries all three ref_gate inputs. `prior` IS the per-ref dedup anchor and it
# lives on the ISSUE — the object the decision is about — not on the PR, which cannot say which of N refs
# it attests to. Still no local state (the header's invariant): every input stays GitHub-derived. Labels
# come LAST so a comma inside a label name can only ever corrupt the field that already tolerates commas.
issue_facts(){
  gh issue view "$2" --repo "$1" --json state,labels,comments \
    -q '[.state,
         (if ([.comments[]?|select(.body|contains("reconcile → closed:"))]|length) > 0 then "1" else "0" end),
         ([.labels[]?.name]|join(","))] | @tsv' 2>/dev/null
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

# publish_applicable_p <slug> <merge-oid> — rc 0 iff $RECONCILE_WORKFLOW EXISTS in the repo tree AT that
# merge commit, i.e. publishing an image is part of THIS commit's delivery. Separates the two cases that
# an absent run cannot tell apart on its own:
#   present + no run  → the run is genuinely still coming        (PENDING/NONE → WAIT, retryable)
#   absent            → nothing will ever publish this commit    (NA, so it stops gating the close)
# Absence is only ever concluded from a tree we READ CLEANLY. Unreadable or truncated ⇒ rc 0 (applicable)
# ⇒ keep waiting: never manufacture "not applicable" out of a read that failed.
publish_applicable_p(){
  local tree
  tree="$(gh api "repos/$1/git/trees/$2?recursive=1" \
          -q '"\(.truncated)", (.tree[]?.path)' 2>/dev/null)" || return 0
  [ -n "$tree" ] || return 0
  printf '%s\n' "$tree" | head -1 | grep -qx false || return 0
  printf '%s\n' "$tree" | grep -qxF ".github/workflows/$RECONCILE_WORKFLOW"
}

# ---- ONE SCAN over a repo --------------------------------------------------------------------------
scan_repo(){ # <repo bare name>
  local repo="$1" slug="$ORG/$1"
  "$REPO_SCOPE" check "$repo" >/dev/null 2>&1 || { log "R16: '$repo' out of scope — skipping"; return 0; }
  local rows; rows="$(gh pr list --repo "$slug" --state merged --search 'sort:updated-desc' --limit "$LOOKBACK" \
                      --json number,mergeCommit,mergedAt,body -q '.[] | "\(.number)\t\(.mergeCommit.oid)\t\(.mergedAt)\t\(.body|gsub("\n";"\\n"))"' 2>/dev/null)" \
    || { log "$slug: merged-PR list failed — skipping this scan"; return 0; }
  [ -n "$rows" ] || return 0
  local pr oid mergedAt bodyenc body refs reflist ref todo closed_now st prior labels gate class pub live
  while IFS=$'\t' read -r pr oid mergedAt bodyenc; do
    [ -n "$pr" ] || continue
    body="$(printf '%b' "$bodyenc")"
    refs="$(backlog_refs "$body")"; [ -n "$refs" ] || continue   # only PRs that claim a backlog ticket
    # A malformed element TRUNCATES the rest of a list — "#6, #007, #2" yields 6 alone, because the match
    # stops at the first non-#N and #007 is refused. That strictness is right (it stops prose dragging in
    # an unrelated number), but silently dropping a declared ticket is the strand this feature exists to
    # end. Count the #N-shaped tokens on trailer lines and say so when the parse kept fewer.
    _decl="$(strip_noncode "$body" | grep -ciE '^Backlog-tickets?:.*#[0-9]' 2>/dev/null || echo 0)"
    _seen="$(strip_noncode "$body" | grep -oiE '^Backlog-tickets?:.*' 2>/dev/null | grep -oE '#[0-9]+' | wc -l)"
    _got="$(printf '%s\n' "$refs" | grep -c . )"
    [ "${_seen:-0}" -gt "${_got:-0}" ] 2>/dev/null && log "$slug#$pr: body shows $_seen #N token(s) on $_decl trailer line(s) but only $_got parsed — a malformed element truncates the rest; check the trailer"
    # shellcheck disable=SC2086
    reflist="$(printf '#%s ' $refs)"
    too_old "$mergedAt" && { log "$slug#$pr → $reflist: merge outside the catch-up window — leaving to a human"; continue; }
    # PER-REF ADMISSION, each from its OWN evidence. The dedup anchor MOVED from the PR to the ISSUE:
    # a PR-level "reconcile → closed:" comment cannot say WHICH of N refs it attests to, so under the old
    # check a PR whose first ref closed would skip its remaining refs forever. Backward compatible by
    # construction — every PR that ever received the legacy PR-level anchor has refs that are already
    # CLOSED, and ref_gate independently answers SKIP:already-CLOSED for those.
    todo=""
    for ref in $refs; do
      IFS=$'\t' read -r st prior labels <<<"$(issue_facts "$slug" "$ref")"
      gate="$(ref_gate "$st" "${prior:-0}" "$labels")"
      case "$gate" in
        TAKE) todo="$todo $ref";;
        *)    log "$slug#$pr → #$ref: ${gate#SKIP:} — no action on this ref";;
      esac
    done
    [ -n "$todo" ] || continue      # every ref settled — none of the proof calls below are worth making
    class="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null | change_class)"
    pub="$(publish_state "$slug" "$oid")"
    # No run found: is one still coming, or does this commit ship no image at all? Only ask when there is
    # no run (a run of any state proves the workflow applies), so this costs one API call in the rare case.
    if [ "$pub" = NONE ] && ! publish_applicable_p "$slug" "$oid"; then
      pub=NA; log "$slug#$pr: no \`$RECONCILE_WORKFLOW\` at ${oid:0:7} — this commit publishes no image (link N/A)"
    fi
    live="$(live_readback "$slug" "$class" "$oid")"
    local verdict; verdict="$(close_decision 1 "$(host_green_p "$slug" "$pr" && echo 1 || echo 0)" "$pub" "$live")"
    case "$verdict" in
      CLOSE)
        local proof tag
        proof="$(proof_summary "$pub" "$live" "$class")"   # each link's REAL state — an N/A says so
        tag="$(proof_tag "$pub" "$live" "$class")"
        # ONE verdict, N closes. Every proof input (merge, host GREEN, CI, read-back) is a property of the
        # CHANGE, not of any one ticket, so refs on a single PR share one chain and cannot disagree about
        # it. Each close is INDEPENDENT: a failure on one ref is logged and the loop continues, so it can
        # never swallow its siblings, and the next scan retries exactly the ones still open (their anchor
        # was never written — the anchor is the close-comment on the ISSUE).
        # CLOSE FIRST, COMMENT SECOND — two separate calls, never `--comment`.
        # `gh issue close --comment` posts the comment and THEN closes. If the close fails (500, 403,
        # secondary rate limit — and this loop now issues N mutations per PR), the issue is left OPEN
        # CARRYING ITS OWN ANCHOR, so the next scan reads prior=1 on an OPEN issue and answers
        # SKIP:reopened-or-half-closed. PERMANENTLY. That is the exact strand this feature exists to
        # remove, recreated by the mechanism meant to remove it, and unrecoverable without a human.
        # Ordering it this way is safe whichever way `gh` sequences internally: a failed close writes
        # nothing, so the ref simply retries; a failed COMMENT leaves the issue CLOSED, which the state
        # check already treats as a no-op. The anchor can now only exist on an issue that really closed.
        closed_now=""
        for ref in $todo; do
          if gh issue close "$ref" --repo "$slug" >/dev/null 2>&1; then
            closed_now="$closed_now $ref"
            log "$slug#$pr → CLOSED #$ref (proof: $tag)"
            gh issue comment "$ref" --repo "$slug" \
              --body "**reconcile → closed:** proof-gated closure of #$ref — authored PR #$pr merged (\`${oid:0:7}\`), $proof. $slug#$pr"$'\n\n<sub>bin/reconcile.sh (task #19) — closed on OBSERVED proof, not on merge. Each link above reports its own state; an N/A link was not taken and says why. This comment is the per-ref dedup anchor.</sub>' \
              >/dev/null 2>&1 || log "$slug#$pr → #$ref: CLOSED, but the proof comment did not post (the issue is closed; the state check makes this a no-op)"
          else
            log "$slug#$pr → #$ref: close FAILED (will retry next scan — no anchor written)"
          fi
        done
        # Stamp the PR with the refs that ACTUALLY closed, never the ones merely attempted. Posting the
        # full list unconditionally would assert closures that did not happen, on the PR's own record.
        # shellcheck disable=SC2086
        [ -n "$closed_now" ] && gh pr comment "$pr" --repo "$slug" --body "**reconcile → closed:** $(printf '#%s ' $closed_now)closed on observed proof — merged \`${oid:0:7}\`, $proof." >/dev/null 2>&1 || true
        ;;
      # $todo, not $reflist: a ref the gate already settled (already-CLOSED, not-a-backlog-issue)
      # is NOT waiting on this proof chain, and listing it here asserts a state it is not in.
      # shellcheck disable=SC2086
      WAIT:*) log "$slug#$pr → $(printf '#%s ' $todo): ${verdict#WAIT:} — not closing yet (re-scan)";;
      # shellcheck disable=SC2086
      SKIP:*) log "$slug#$pr → $(printf '#%s ' $todo): ${verdict#SKIP:} — not a proof-gated close";;
    esac
  done <<<"$rows"
}

case "${1:-}" in
  --once)
    while IFS= read -r r <&3; do [ -n "$r" ] && scan_repo "$r"; done 3< <("$REPO_SCOPE" list 2>/dev/null)
    ;;
  *) echo "usage: reconcile.sh --once | --selftest" >&2; exit 2;;
esac
