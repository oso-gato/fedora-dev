#!/usr/bin/env bash
# pr-poller.sh — the DEV-SIDE POLLER / wake-up mechanism (R6/R7 / #93 Step 5).
#
# The host is already autonomous: it live-gates a labelled PR and posts a GREEN/RED verdict on its own
# timer. This closes the DEV-side gap — a supervised, PLAIN-SHELL (NO Claude in the loop) watcher on
# fedora-dev that reacts to each new host verdict:
#
#   RED   → spawn a BOUNDED headless `claude -p` fixer in an ISOLATED WORKTREE checked out on the PR's
#           own gated head; the model COMMITS, the HARNESS pushes the FEATURE branch and VERIFIES the
#           landing at ORIGIN (the new head SHA re-triggers the host gate). The dev pushes fixes —
#           NEVER the host, NEVER main; the fixer holds NO merge step. NO FIXED ITERATION CAP: it loops
#           until GREEN or until it stops making progress (same failure signature twice / the fixer
#           reports BLOCKED), which is SURFACED as a decision — never a quiet quit (doctrine mandate 6).
#   GREEN → run the independent fitness harness (bin/fitness-review.sh); then the merge decision:
#           Tier A → present to Arthur (never auto); Tier B/C + fitness PASS → bin/auto-merge.sh.
#
#   RETIRE → each sweep FIRST retires SUPERSEDED PRs: a MERGED PR whose body carries a WHOLE LINE that
#           is exactly `Supersedes #N[, #M…]` (same-repo, case-insensitive, nothing else on the line)
#           closes a still-OPEN #N with an explanatory comment. The authorizing event is the
#           SUPERSEDER'S MERGE — already human-clicked (or, armed, three-gate-checked) — so
#           retirement runs even while DISARMED: a close is reversible (reopen button) and never
#           touches main; arming (#96) gates the MERGE boundary only. Fail-closed to NO-OP: an issue
#           number, a cross-repo ref, prose, a backticked/blockquoted/fenced/code-indented example,
#           a malformed list, or an already-closed target never acts; a transient API failure degrades to the
#           status quo (the PR stays open for a human) — never to a wrong close; a human REOPEN is
#           durable (a PR carrying a prior retire comment is never re-closed, even after local state
#           loss). WHY THE POLLER: the interactive agent is classifier-DENIED `gh pr close` on PRs
#           it didn't create (run-003 lesson b), so this deterministic verb is the sanctioned
#           retirement path.
#
# ARMED BY DEFAULT (gate-free objective): the GREEN→merge path calls auto-merge.sh with --commit so the loop
# merges autonomously (no human approves the shipment — 00-OBJECTIVES.md). POLLER_ARMED=0 is a deliberate
# dry-run SOAK (prints the DECISION, merges nothing — the design-doc use). The #96 Tier-A "arm on Arthur's
# click" is RETIRED (pre-ZERO-GATE). The MERGE boundary is NOT this flag: auto-merge.sh re-checks the two
# DISTINCT App-identity gates fail-closed (host-GREEN + a distinct fitness-PASS) and HARD-REFUSES --commit
# under same-identity fitness, so a stale plan can never mis-merge and a default-armed poller cannot merge
# without the real independent fitness App.
#
# The poller has NO merge credential of its own: it OBSERVES, spawns a feature-branch fixer, retires
# superseded PRs (a reversible close — see RETIRE above; the one non-merge write it performs even
# disarmed, alongside its surface/fitness comments), and delegates the merge to the dumb, gate-checked
# auto-merge.sh. It cannot be prompt-injected — it runs no model; the only model it spawns is the
# disposable fixer, whose prompt forbids merge/main.
#
# Usage:
#   pr-poller.sh --once                # one sweep of all open PRs, then exit (cron / manual / testing)
#   pr-poller.sh --watch               # supervised loop (singleton via flock), sweeps every $POLL_INTERVAL
#   pr-poller.sh --selftest            # exercise the pure plan()/verdict extractors (no network/model)
#
# Config (env):
#   POLLER_REPOS      the repos one tick sweeps. DEFAULT: derived from the R16 operating scope
#                     (bin/repo-scope.sh list → policy/scope.conf — #167), never a hardcoded list.
#                     An explicit value can narrow/reorder but NOT expand: every repo is re-checked
#                     against the scope each tick (out of scope ⇒ skipped, one loud line).
#   REPO_SCOPE        the R16 scope reader (default: bin/repo-scope.sh — see its header; #167).
#                     Any non-zero rc — a missing reader included — is "not in scope": fail-closed.
#   POLLER_REPO       repo to watch (default: fedora-dev — the poller watches its OWN repo's PRs)
#   LG_HOST_LOGIN     host bot login whose verdict is trusted (default: oso-gato-erebus-claudebox[bot])
#   FITNESS_LOGIN     fitness bot login (passed through to fitness-review.sh + auto-merge.sh)
#   POLLER_ARMED      1 → GREEN+B/C+PASS actually merges (auto-merge --commit). Default 0 (dry-run).
#   POLL_INTERVAL     seconds between --watch sweeps (default 30 — a simple fixed cadence).
#                     Cost at 30s (fetch-BATCHED sweep): steady state ≈ 120×(2+N)/h — the open-PR
#                     list (TSV: number+ref+sha in ONE call), the retire merged-list, and ONE
#                     sha-bound comments call per open PR. A PARKED GREEN PR (already acted:
#                     PRESENT posted / dry-run decided / merge attempted) is terminal-state-skipped
#                     on its acted marker, so it too costs exactly 1 comments call/sweep; only a
#                     GREEN PR whose routing is PENDING (fitness verdict not yet posted, or
#                     fitness-RETURN driving the fixer) costs +2 (files + fitness comments) per
#                     sweep until it parks — short-lived, and bounded by the fitness/fixer
#                     turnaround. A REVIEW-PARKED head (#156: the reviewer failed its bounded
#                     retries and a question is asked) keeps costing that +2 by DESIGN: it is not
#                     acted-marker-parked, precisely so a hand-posted verdict is still seen — no
#                     model run is spent on it, only the reads. Against the dev App's 5k/h REST budget (SHARED with the fixer,
#                     fitness reviewer and auto-merge): N=10 open PRs ≈ 4.3k/h — the ceiling is
#                     ~10 sustained open PRs (was 2-3 unbatched). The R9 fleet-halt read (#151)
#                     adds 2 calls per TICK, not per repo (1 title-search + 1 timeline ≈ +720/h;
#                     the search API has its own 30/min budget, of which this uses 6/min).
#                     On exhaustion gh calls fail and
#                     sweeps degrade to NOOP until the window resets — fail-closed,
#                     self-recovering; GREEN-moment fetch failures skip that PR for that sweep
#                     (retry next), never a misroute. Escalation if ever needed: one GraphQL
#                     sweep query for ALL open PRs (N-independent) — designed, not built.
#   POLLER_FIXER      headless fixer command (default: claude -p). Overridable for testing.
#   FIXER_TIMEOUT     max seconds for ONE fixer run (default 1800). Bounds a single iteration, not the
#                     count of iterations.
#   FRESH_TREE        the isolator (default: bin/fresh-tree.sh). Every fix runs in a throwaway worktree
#                     off the PR's own head — NEVER the shared clone (#152). Overridable for testing.
#   FLEET_HALT        the R9 fleet HALT reader (default: bin/fleet-halt.sh — see its header; #151).
#                     Read at the TOP of every tick, BEFORE any model run / merge / retire / comment.
#                     rc 0 alone means GO; ANY other outcome (maintainer HALT, unreadable-signal PAUSE,
#                     a missing/crashed checker) makes the whole tick OBSERVE-ONLY — fail-closed toward
#                     stopping BY CONSTRUCTION. Overridable for testing.
#   FITNESS_REVIEW    the independent fitness harness the REVIEW arm runs (default: bin/fitness-review.sh).
#                     Overridable for testing. Its exit code is a CONTRACT: 0 = verdict posted; 3 = the
#                     reviewer could not be RUN / produced no verdict for this head; anything else = a
#                     retryable precondition (try again next sweep).
#   FITNESS_REVIEW_TRIES / FITNESS_RETRY_BACKOFF
#                     how the REVIEW arm answers an rc 3 (default 3 attempts, ≥300s apart — see
#                     review_due). rc 3 CANNOT distinguish a permanent cause (E2BIG, missing binary) from
#                     a transient one (model API 5xx, rate limit, timeout), so the arm retries a BOUNDED
#                     number of spaced times and only then SURFACES the real cause and stops reviewing
#                     that head. Re-spinning every sweep is the silent spin R4 forbids (#155); parking on
#                     the FIRST rc 3 would strand a host-GREEN PR forever on one blip (#156). The parked
#                     head is NOT written to the acted marker, so a verdict posted by hand (the
#                     remediation the question prints) is still picked up and acted on.
#   RETIRE_LOOKBACK   how many of the most recently UPDATED merged PRs each sweep scans for
#                     `Supersedes #N` declarations (default 15; sorted by update recency so a
#                     long-parked PR that merges late still enters the window; each merged PR is
#                     scanned only once — state marker). Residual: if the poller is DOWN while more
#                     than this many merged PRs receive updates, older declarations fall out of the
#                     window unscanned — degrades to status quo (the PR stays open for a human).
#   SELF_REFRESH*     the SELF-REFRESH mechanism (#162 — the running poller deploys its OWN merged code).
#                     SELF_REFRESH=1 (on) · SELF_REFRESH_CLONE (the clone we execute; default one level
#                     up from bin/) · SELF_REFRESH_REMOTE/BRANCH (origin/main) · SELF_REFRESH_EVERY
#                     (fetch once per N sweeps; default 30) · SELF_REFRESH_FETCH_TIMEOUT (60s) ·
#                     POLLER_RELOAD_RC (the exit code that asks poller-service.sh to ff-pull + relaunch;
#                     default 90 — a SHARED default with bin/poller-service.sh). The staleness baseline
#                     is the LAUNCH HEAD (#170) — captured ONCE at process start (injectable via
#                     POLLER_LAUNCH_HEAD, a test seam), NEVER the clone's momentary HEAD, which anything
#                     may pull while we run. See refresh_decision().
#   HOST_REFRESH*     the HOST half of self-refresh (#163 — a merged IMAGE-BAKED change auto-redeploys
#                     the running host, and a merged control-repo change surfaces its host apply):
#                     HOST_REFRESH_SCAN (the scanner, default bin/host-refresh.sh — its header carries
#                     the whole design) · HOST_REFRESH_EVERY (scan once per N sweeps; default 30;
#                     0 disables). Runs at the END of a sweep tick, gated by THAT tick's R9 halt read.
#   POLLER_DEFER_RC / LOCK_DEFER_MAX / LOCK_DEFER_WINDOW / POLLER_BOX_GEN_FILE / POLLER_BOX_GEN
#                     the LOCK-LIVENESS contract (#173 — the flock singleton must survive a box
#                     recreate). The --watch lock lives on the HOME VOLUME, which OUTLIVES the poller
#                     process: a claudebox-rebuild can orphan a running poller (the box shares
#                     fedora-dev's PID namespace, so `distrobox rm` does not reap what it spawned)
#                     whose lingering process/FD keeps the flock held while sweeping NOTHING — and the
#                     fresh poller then deferred rc=0 every 30 s, forever (observed live 2026-07-13,
#                     08:27→12:23: FOUR HOURS of zero sweeps that every log read as healthy). So the
#                     holder RECORDS `pid boot-id starttime box-generation` in the lock file and a
#                     would-be starter ADJUDICATES the record (lock_verdict, pure): DEFER only to a
#                     POSITIVELY-confirmed live, same-generation holder; everything else — no/garbled
#                     record (the bare-flock era wrote none), dead pid, recycled pid (starttime is the
#                     anti-masquerade token), previous kernel boot, previous box generation — is a
#                     TAKEOVER: rotate the lock file (unlink + re-flock a FRESH inode, so a lingering
#                     FD gates nothing) and TERM only a provably-live previous-generation orphan.
#                     FAIL DIRECTION: liveness in doubt ⇒ START (a brief double-sweep is idempotent,
#                     sha-bound and gate-checked; a silently dead poller is unrecoverable). A DEFER is
#                     never silent and NEVER rc=0 (req 2): it exits POLLER_DEFER_RC (91 — shared with
#                     poller-service.sh, distinct from the reload rc 90), and LOCK_DEFER_MAX (10 ≈
#                     5 min at the supervisor's 30 s restart cadence) CONSECUTIVE deferrals (within
#                     LOCK_DEFER_WINDOW, 3600 s — a stray manual defer from hours ago never
#                     pre-charges the streak) surface ONE gh-issue question naming the holder. Box
#                     generation = inode.mtime of POLLER_BOX_GEN_FILE (default the claudebox
#                     `.assembled` marker, `touch`ed by every assemble); POLLER_BOX_GEN injects the
#                     token directly (test seam).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ===================================================================================================
# PURE decision core — no I/O, exercised by --selftest.
# ===================================================================================================

# extract the newest host live-gate verdict (GREEN|RED) from header lines on stdin. LINE-START
# anchored: a verdict string quoted mid-line (embedded candidate log, prose) never matches — the
# same G2 discipline as bin/auto-merge.sh, applied to ROUTING so forged strings can't even misroute.
# SKIPPED is a REAL verdict, not the absence of one (2026-07-28, MOVE 1b of #274). The host answers
# GREEN / RED / SKIPPED, and SKIPPED means "there is nothing here for me to build or probe against this
# base" — its own comment says "Neutral skip, not a failure". But it was matched by NOTHING here, so it
# read as NONE ⇒ plan() returned NOOP ⇒ the PR froze SILENTLY AND FOREVER. Four of the six PRs in the
# e2e-beta acceptance run (#11 run.sh, #12 Quadlet, #13 CI, #14 README) sat exactly there for 24h+.
# A gate is allowed to say "not applicable"; it is NOT allowed to say nothing.
host_verdict(){ grep -oE '^\**Host live-gate \(Gate B\): (VERDICT (GREEN|RED)|SKIPPED)' | grep -oE '(GREEN|RED|SKIPPED)$' | tail -1; }

# gate_relevant <changed-files-newline-list> → 1 if this PR touches anything that DEFINES the runtime
# the host gate exists to validate, else 0. PURE + selftested.
#
# This is the safety hinge of MOVE 1b. Treating SKIPPED as merge-eligible is correct for a PR the gate
# genuinely cannot judge (a README, a CI workflow) — the host has no objection because there is nothing
# to object to. It would be UNSAFE for a PR that changes the image, the run contract or the gate
# contract itself: there, a SKIP means the gate could not evaluate a change it SHOULD have evaluated,
# and merging on "no objection" would let a change dodge the gate by removing what the gate reads.
gate_relevant(){
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      Containerfile*|*/Containerfile*) printf 1; return 0 ;;
      .live-gate|*/.live-gate)         printf 1; return 0 ;;
      run.sh|*/run.sh)                 printf 1; return 0 ;;
      spin-up.sh|*/spin-up.sh)         printf 1; return 0 ;;
      entrypoint.sh|*/entrypoint.sh)   printf 1; return 0 ;;
      *.container)                     printf 1; return 0 ;;
      install.sh|*/install.sh)         printf 1; return 0 ;;
    esac
  done
  printf 0
}
# extract the newest fitness verdict (PASS|RETURN|ESCALATE) from header lines on stdin (line-start
# anchored, same rationale).
fitness_verdict(){ grep -oE '^Fitness review: VERDICT (PASS|RETURN|ESCALATE)' | grep -oE '(PASS|RETURN|ESCALATE)$' | tail -1; }
# extract same-repo supersession targets (PR numbers, one per line, deduped) from a PR body on stdin.
# STRICT WHOLE-LINE grammar — a line that is EXACTLY `Supersedes #N[, #M…]` (case-insensitive, up to
# 3 leading spaces, trailing whitespace ok, CRLF stripped) and NOTHING else. ALL-OR-NOTHING: a line
# with any other text — backticks, a blockquote `>`, mid-sentence prose, trailing words, a
# space-separated list — matches NOTHING (never a partial list), so quoted examples with a live
# number, negations, cross-repo refs and unrelated `#N` can never act. MARKDOWN-AWARE: fenced code
# blocks (``` / ~~~ toggles) are stripped before matching and a ≥4-space/tab indent is markdown code
# — so DOCUMENTING the grammar in a fence or code-indent can never act either (belt: still write
# `#N` — letters — in prose examples). The superseding PR carries the declaration as its own line.
supersede_targets(){ tr -d '\r' | awk '/^ {0,3}(```|~~~)/{f=!f; next} !f' | grep -ioE '^ {0,3}supersedes:?[[:space:]]+#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*[[:space:]]*$' | grep -oE '#[0-9]+' | tr -d '#' | sort -un; }

# plan <host:GREEN|RED|NONE> <tier:A|B|C|""> <fitness:PASS|RETURN|ESCALATE|NONE> <armed:0|1>
#   -> NOOP | FIX | REVIEW | MERGE | MERGE_DRYRUN | PRESENT
# The single source of truth for "given the gates, what does the poller DO". Fail-closed toward the
# human: any ambiguity (unknown tier, no host verdict) resolves to NOOP or PRESENT, never to a merge.
plan(){
  local host="$1" tier="$2" fit="$3" armed="$4" gaterel="${5:-0}"
  case "$host" in
    RED)  echo FIX; return;;                          # host says broken → iterate a fix
    GREEN) : ;;                                        # fall through to the merge decision
    SKIPPED)
      # MOVE 1b (#274). The host had nothing to build or probe. EVERY outcome a gate can return must map
      # to an action — merge, fix, or escalate once. Silence froze four acceptance-run PRs for 24h+.
      #   * touches NOTHING the gate validates (docs, CI) ⇒ a genuine NOT-APPLICABLE. The host has no
      #     objection because there is nothing to object to, so this is a NEUTRAL PASS: fall through and
      #     let the INDEPENDENT fitness review decide. The merge still needs two identities to agree —
      #     one of them simply has nothing to say, which is an honest answer.
      #   * touches the image / run contract / gate contract ⇒ the gate could not evaluate a change it
      #     SHOULD have. Merging on "no objection" would let a change dodge the gate by deleting what
      #     the gate reads. Wait instead — the existing IDLE-WITH-WORK-PENDING surfacer alarms on it,
      #     and an R25 base advance re-gates it (which is the real cure: these SKIP because their base
      #     has no Containerfile YET, and gain one the moment the image PR lands).
      [ "$gaterel" = 1 ] && { echo NOOP; return; }
      : ;;
    *)    echo NOOP; return;;                          # no host verdict yet (NONE) → wait
  esac
  # ZERO-GATE (2026-07-10, Arthur's decision): tier NO LONGER routes to a human PRESENT. Every GREEN
  # PR flows by its fitness verdict alone (host-GREEN + fitness-PASS auto-merges ANY tier, control-
  # plane included). The old Tier-A→click was misrepresented-requirement harness; recoverability is
  # kept automatic (host rollback + git revert + fitness's standing "preserve recoverability" rule),
  # not a tier gate. `tier` is retained for the log line only. ESCALATE still surfaces (below) — that
  # is the REVIEWER deferring on genuine ambiguity, not a tier gate.
  case "$fit" in
    NONE)     echo REVIEW;   return;;                  # GREEN but not yet fitness-reviewed → review it
    PASS)     [ "$armed" = 1 ] && echo MERGE || echo MERGE_DRYRUN; return;;
    RETURN)   echo FIX;      return;;                  # fitness wants rework → back to the developer
    ESCALATE) echo PRESENT;  return;;                  # fitness defers to Arthur
    *)        echo PRESENT;  return;;                  # unknown fitness token → human (fail-closed)
  esac
}

# R18 IDLE-WITH-WORK-PENDING (audit 2026-07-18, CAT-42/01; the kd#23 six-hour silent stall). The poller's
# process-liveness is watched (the apparatus-deadman: is it sweeping?) but its WORK progress is NOT: a
# poller that NOOPs on `host=NONE` every sweep is "healthy" by construction while the workstream is dead.
# stall_verdict is the missing WORK-level clock: a live-validate-LABELLED open head that has sat at
# host=NONE (no host verdict produced) past a bound is a STALL to SURFACE, not a NOOP to repeat forever.
# The age is derived from GitHub truth (the head commit's committer date), never a local first-seen marker
# a restart would reset (R24 no-proxy). NOT a merge decision — surfacing only; pure + selftested.
POLLER_STALL_MAX="${POLLER_STALL_MAX:-1800}"   # s a labelled head may sit at host=NONE before it surfaces (30m; the host gate normally verdicts in ~10m)
# stall_verdict <host> <labelled:0|1> <age_seconds> <bound> -> OK | STALL
stall_verdict(){
  local host="$1" lbl="$2" age="$3" bound="$4"
  case "$age"   in ''|*[!0-9]*) age=0;;   esac
  case "$bound" in ''|*[!0-9]*) bound=0;; esac
  if [ "$host" = NONE ] && [ "$lbl" = 1 ] && [ "$age" -ge "$bound" ]; then echo STALL; else echo OK; fi
}

# CAT-17 (audit 2026-07-18, rank #2): a GREEN+PASS PR merely BEHIND main must not park TERMINALLY on its
# acted marker — with nobody owning the rebase, every sibling merge strands the remaining backlog (O(N^2)).
# The poller now OWNS the mechanical rebase: `gh pr update-branch` server-side-merges main into the PR
# branch (NO local clone touched, unlike the fixer) — a CLEAN behind succeeds, minting a NEW head that
# re-gates (progress, NOT parked); a genuine CONFLICT fails → surface + park for a human. Bounded so a
# pathological "advances but never merges" head cannot churn forever. rebase_due is the pure bound.
POLLER_REBASE_MAX="${POLLER_REBASE_MAX:-6}"   # auto-rebases attempted on ONE PR before surfacing for a human
# rebase_due <attempts-so-far> <max> -> TRY | GIVEUP
rebase_due(){
  local n="$1" max="$2"
  case "$n"   in ''|*[!0-9]*) n=0;;   esac
  case "$max" in ''|*[!0-9]*) max=6;; esac
  [ "$n" -lt "$max" ] && echo TRY || echo GIVEUP
}

# fix_outcome <blocked:0|1> <gated-sha> <worktree-head> <push-rc> <origin-head>
#   -> BLOCKED | NO_COMMIT | PUSH_FAILED | NOT_LANDED | LANDED
# The fixer's TRUTHFUL outcome — this retires the old `new head (if pushed) will re-gate` shrug, which
# never checked anything: a fixer that pushed NOTHING was indistinguishable from one that succeeded, so
# the next sweep's no-progress stop parked the PR on a FALSE 'blocked' (and, on 2026-07-12, cost a human
# an hour concluding the fixer had landed nothing when it had landed correctly twice).
# A push rc of 0 is NOT proof of landing (a no-op push, a swallowed rejection, a hook that ate it) — a
# local commit that never reached origin is not progress. So LANDED requires ORIGIN's ref to actually
# hold the commit we made: origin-head == worktree-head, and the worktree-head moved past the gated sha.
fix_outcome(){
  local blocked="$1" base="$2" head="$3" prc="$4" remote="$5"
  [ "$blocked" = 1 ] && { printf 'BLOCKED'; return; }                     # model declared it cannot fix
  [ -n "$head" ] && [ "$head" != "$base" ] || { printf 'NO_COMMIT'; return; }  # nothing to push
  [ "$prc" = 0 ] || { printf 'PUSH_FAILED'; return; }                     # push itself errored
  [ "$remote" = "$head" ] || { printf 'NOT_LANDED'; return; }             # rc 0 but origin never moved
  printf 'LANDED'
}

# fix_cause <host> <fitness> -> HOST | FITNESS | UNKNOWN
# WHICH gate sent this PR to the fixer. plan() returns FIX from TWO different routes — host RED and
# fitness RETURN — and the fixer is a bounded `claude -p` that can only fix what it is TOLD. Feeding a
# fitness RETURN the canned "host live-gate RED" line made it chase a build failure that never happened
# (the build is GREEN on a RETURN), so it could never make progress and the PR parked on a FALSE
# "blocked — host live-gate RED" surface. This is R6: "findings are generative — RETURN reasons feed
# the fixer's next iteration". PURE + selftested, so a future plan() route cannot silently inherit the
# wrong prompt: an unrecognised pairing is UNKNOWN, and the caller then refuses to guess.
fix_cause(){
  case "$1:$2" in
    RED:*)    printf 'HOST';;                          # host verdict RED (fitness is not even read yet)
    *:RETURN) printf 'FITNESS';;                       # host GREEN, reviewer wants rework
    *)        printf 'UNKNOWN';;                       # not a FIX route → never guess a reason
  esac
}

# review_due <attempts-so-far> <seconds-since-last-attempt> <max-tries> <backoff-secs>
#   -> RUN | WAIT | PARKED
# THE BOUNDED RETRY THE rc-3 CONTRACT REQUIRES (#156). fitness-review.sh returns 3 for "the reviewer
# produced no verdict for THIS head" — and it CANNOT tell a PERMANENT cause (E2BIG, missing binary, bad
# auth) from a TRANSIENT one (model API 5xx, rate limit, timeout, a killed run). So NEITHER extreme is
# correct, and each is a real failure mode:
#   * re-running every sweep is the SILENT SPIN R4 forbids — a bounded model run burned per 10s, forever,
#     signalling nothing;
#   * parking on the FIRST rc 3 STRANDS a host-GREEN PR on a single API blip — nothing re-reviews it (the
#     fixer only runs on RED / fitness-RETURN), so it can never merge on that head. Before the rc contract
#     existed, that same blip simply self-healed on the next sweep; a fix for the permanent class must not
#     buy a new permanent failure for the transient one.
# So: retry a BOUNDED number of times, SPACED by a backoff (a 10s re-poke does not outlast a 529 burst),
# and surface only when the failure SURVIVES them. A blip then costs nothing and a real breakage still
# reaches a human — exactly once.
review_due(){
  local n="$1" since="$2" max="$3" backoff="$4"
  [ "$n" -ge "$max" ] && { printf 'PARKED'; return; }   # tries exhausted → the question is asked; never re-run
  [ "$n" -le 0 ] && { printf 'RUN'; return; }           # no failure on this head yet → run
  [ "$since" -ge "$backoff" ] && printf 'RUN' || printf 'WAIT'
}

# infra_healthy <rc> <probe-output> → 0 (UP) iff the probe GENUINELY SUCCEEDED: exit 0 AND the reply
# carries the requested token. NON-EMPTY OUTPUT IS NOT ENOUGH — a real `claude -p` AUTH failure (the
# common fitness-credential / login-expiry outage) prints "Not logged in · Please run /login" to STDOUT
# and exits 1; a bare non-empty check would misread THAT global outage as UP and re-open the parking
# incident this gate exists to prevent. So the probe is trusted only when it exits 0 AND actually followed
# the trivial instruction (echoed the token). PURE + selftested.
infra_healthy(){
  [ "$1" = 0 ] || return 1
  printf '%s' "$2" | grep -qi "${FITNESS_INFRA_TOKEN:-OK}"   # :-default: --selftest runs before the env block
}
# review_infra_ok — is the reviewer infrastructure (`claude -p`) working RIGHT NOW? A CHEAP liveness probe,
# run AT MOST ONCE per sweep (cached in $REVIEW_INFRA) and only ON A REVIEW FAILURE (a success needs no
# probe — it IS the health signal), so a healthy sweep pays nothing. 0 = up (⇒ a per-head failure), 1 =
# down (⇒ a GLOBAL outage — pause the arm). FAIL DIRECTION: the probe mirrors the real review's own
# `claude -p`, so a probe that does not return a valid reply IS the "it does not work" signal; disabled
# (FITNESS_INFRA_CHECK=0) ⇒ always "up" (the pre-2026-07-20 behaviour). Overridable ($FITNESS_INFRA_PROBE).
review_infra_ok(){
  case "$REVIEW_INFRA" in up) return 0;; down) return 1;; esac
  [ "$FITNESS_INFRA_CHECK" = 1 ] || { REVIEW_INFRA=up; return 0; }
  local out rc
  out="$(printf '%s' "$FITNESS_INFRA_PROMPT" | timeout "$FITNESS_INFRA_TIMEOUT" $FITNESS_INFRA_PROBE 2>/dev/null)"; rc=$?
  if infra_healthy "$rc" "$out"; then REVIEW_INFRA=up; return 0; fi
  REVIEW_INFRA=down
  log "REVIEW INFRA DOWN: the cheap \`claude -p\` liveness probe did not return a valid reply (rc=$rc) — the reviewer infrastructure is unavailable (an API outage, or an expired credential). PAUSING all fitness reviews this sweep (NO per-head strikes, NO questions); they resume automatically the moment it recovers."
  return 1
}
# infra_recovered — a review SUCCEEDED (or a probe passed): the reviewer infra is up. Clear any
# down-streak so a later real outage starts its "persistent?" clock fresh (no sticky state).
infra_recovered(){ rm -f "$STATE/review-infra-down.since" "$STATE/review-infra-down.asked" 2>/dev/null; }
# infra_down_note — record/observe the GLOBAL-outage down-streak and, ONLY once it PERSISTS past
# FITNESS_INFRA_PAUSE_SURFACE seconds, surface exactly ONE question (marker-gated) so a never-recovering
# break is never a SILENT stall. The arm keeps auto-resuming regardless — no human action is required.
infra_down_note(){ # <pr> <sha>
  local f="$STATE/review-infra-down.since" now since
  now="$(date +%s)"; since="$now"                          # ALWAYS set (an unwritable $STATE must not set -u abort)
  [ -f "$f" ] || printf '%s\n' "$now" > "$f"
  read -r since < "$f" 2>/dev/null || since="$now"; case "$since" in ''|*[!0-9]*) since="$now";; esac
  if [ $(( now - since )) -ge "$FITNESS_INFRA_PAUSE_SURFACE" ] && [ ! -f "$STATE/review-infra-down.asked" ]; then
    # Mark "asked" ONLY if the post SUCCEEDED (surface returns non-zero on a failed gh post) — else a
    # throttled comment during a broad outage would permanently swallow the escalation (retry next sweep).
    surface "$1" "$2" "review-infra-down" "the independent fitness reviewer's infrastructure (\`claude -p\`) has been unavailable for ~$(( (now-since)/60 )) min, so ALL fitness reviews are PAUSED (fail-closed: no verdict ⇒ no merge). The poller keeps probing cheaply and SELF-HEALS the instant \`claude -p\` recovers — no action is required unless it stays down, in which case investigate the reviewer model availability / credential." \
      && : > "$STATE/review-infra-down.asked"
  fi
}

# refresh_decision <clean:0|1> <running-sha> <origin-sha> <origin-is-descendant-of-running:0|1>
#   -> NOFETCH | UPTODATE | DIRTY | DIVERGED | RELOAD
# THE SELF-REFRESH DECISION (#162). The dev loop merges improvements to THIS machinery — the poller, the
# fitness harness, dev-{plan,author,loop}, tier-classify, auto-merge — and nothing used to pull the live
# clone, so the RUNNING poller kept executing the OLD code until a human ran `git pull` + bounced --watch.
# This pure core decides, given what origin holds vs. what we run, whether the poller should STEP ASIDE
# so poller-service.sh can fast-forward the clone + relaunch us on the new code. FAIL-SAFE TOWARD PROGRESS
# is baked in: every verdict but RELOAD means "leave the poller running unchanged" (req 3 — a refresh
# that cannot happen must never stop the loop). Only a CLEAN clone that origin strictly FAST-FORWARDS
# reloads — never a rebase/merge that could rewrite a human's clone; a dirty or diverged clone is left
# untouched (req 1). PURE + selftested.
# THE <running-sha> INPUT IS THE LAUNCH HEAD (#170) — the commit THIS process was started on, captured
# ONCE at process start — NEVER the clone's momentary HEAD. The clone is a shared artifact anything may
# pull while the poller runs (observed live 2026-07-13: an orchestrator pulled it to origin minutes
# after a merge, clone==origin then read UPTODATE forever while the process executed the launch-time
# build — the reload silently self-disabled in exactly the condition it exists for). Cleanliness and
# divergence are still read from the CLONE, FRESH at every check, so a dirty clone that is later
# cleaned resumes reloading (no sticky state).
#   NOFETCH  — origin sha unknown (the fetch failed / branch unresolvable) → never reload.
#   UPTODATE — origin == running → nothing merged since LAUNCH → silent no-op (req 5).
#   DIRTY    — the clone carries local edits → a human touched it → never clobber, leave it.
#   DIVERGED — origin is NOT a fast-forward of what we run (rewritten history / local commits) → leave.
#   RELOAD   — clean, and origin strictly fast-forwards past what we run → step aside for a reload.
refresh_decision(){
  local clean="$1" run="$2" org="$3" desc="$4"
  [ -n "$org" ] || { printf 'NOFETCH'; return; }        # no resolvable origin tip → can't reload
  [ "$run" = "$org" ] && { printf 'UPTODATE'; return; } # current already (regardless of a dirty tree)
  [ "$clean" = 1 ] || { printf 'DIRTY'; return; }       # human edits present → never clobber
  [ "$desc" = 1 ] && printf 'RELOAD' || printf 'DIVERGED'
}

# lock_verdict <record-line> <current-boot-id> <holder-starttime-now|""> <current-box-generation>
#   -> DEFER | TAKEOVER_NORECORD | TAKEOVER_BOOT | TAKEOVER_DEAD | TAKEOVER_RECYCLED | TAKEOVER_GENERATION
# THE LOCK-LIVENESS ADJUDICATION (#173). A held flock proves only that SOME process/FD is alive
# somewhere on this kernel — NOT that a poller is sweeping: the lock file sits on the home volume,
# which outlives every box recreate, and the 2026-07-13 incident's holder was an orphan of a torn-down
# claudebox that held the lock for four hours while sweeping nothing (the fresh poller deferred rc=0
# every 30 s and no log said the loop was down). So the record the HOLDER wrote is adjudicated:
#   * DEFER — the ONLY verdict that yields: the recorded process is POSITIVELY confirmed live (same
#     kernel boot, pid exists, starttime matches — pid+starttime+boot uniquely name a process, so a
#     recycled pid cannot masquerade) AND not provably from a previous box generation. Two pollers
#     must never both run; a proven-live peer wins.
#   * TAKEOVER_NORECORD — no/garbled record (the bare-flock era wrote none; a truncated write). A
#     record that cannot CONFIRM a live holder confirms nothing → START (req 3's fail direction: a
#     brief double-sweep is idempotent + sha-bound + gate-checked; a silently dead poller is not
#     recoverable).
#   * TAKEOVER_BOOT — recorded before a different kernel boot: pid+starttime are per-boot coordinates;
#     nothing written under another boot can name a live process now.
#   * TAKEOVER_DEAD / TAKEOVER_RECYCLED — the recorded process is gone (pid missing, or the pid now
#     wears a DIFFERENT starttime: a stranger reused it). The flock lingers on an inherited FD only.
#   * TAKEOVER_GENERATION — alive, but recorded under a previous BOX generation: an orphan of a
#     torn-down box (THE incident class — the box shares fedora-dev's PID namespace, so the orphan
#     stays visible and signalable), never the singleton's healthy peer. The caller may TERM exactly
#     this class: it is the one takeover whose target provably IS the recorded poller.
# Generation ambiguity (either side unrecorded/unreadable, written as '-') is NEUTRAL — by that point
# liveness is already POSITIVELY confirmed, so deferring is the safe direction for a proven-live
# holder; a persistent wrong defer still surfaces via the deferral streak (req 2). PURE + selftested.
lock_verdict(){
  local rec="$1" boot="$2" nowstart="$3" gen="$4"
  local rpid rboot rstart rgen _rest
  read -r rpid rboot rstart rgen _rest <<<"$rec"
  # '-' is the writer's explicit empty-field placeholder (the record is whitespace-framed, so a truly
  # empty field would silently shift its neighbours into the wrong columns)
  [ "${rboot:-}" = "-" ] && rboot=""; [ "${rstart:-}" = "-" ] && rstart=""; [ "${rgen:-}" = "-" ] && rgen=""
  case "${rpid:-}" in ''|*[!0-9]*) printf 'TAKEOVER_NORECORD'; return;; esac
  case "${rstart:-}" in ''|*[!0-9]*) printf 'TAKEOVER_NORECORD'; return;; esac
  [ -n "${rboot:-}" ] || { printf 'TAKEOVER_NORECORD'; return; }
  [ "$rboot" = "$boot" ] || { printf 'TAKEOVER_BOOT'; return; }
  [ -n "$nowstart" ] || { printf 'TAKEOVER_DEAD'; return; }
  case "$nowstart" in *[!0-9]*) printf 'TAKEOVER_DEAD'; return;; esac   # garbled read confirms nothing
  # /proc starttime FLUTTERS ±1 clock tick between reads of the SAME process (measured on this kernel:
  # the boottime→clock_t conversion rounds differently read-to-read), so an EXACT match would misjudge
  # a genuinely live holder as a recycled pid sporadically. Compare with a ±2-tick tolerance: a truly
  # recycled pid differs by the whole gap between the dead poller's start and the stranger's —
  # seconds-to-months, never ticks.
  local d=$(( nowstart - rstart )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 2 ] || { printf 'TAKEOVER_RECYCLED'; return; }
  if [ -n "$rgen" ] && [ -n "$gen" ] && [ "$rgen" != "$gen" ]; then printf 'TAKEOVER_GENERATION'; return; fi
  printf 'DEFER'
}

# fitness_login_default — the reviewer login the identity MODE requires (PURE; --selftest covers it).
# An explicit non-empty FITNESS_LOGIN (env) ALWAYS wins; otherwise the default MUST match the mode, or a
# half-configured strict-SoD arm SELF-REVIEWS: SAME_IDENTITY=0 (strict) → the DISTINCT fitness App;
# SAME_IDENTITY=1 (make-it-work / dry-run) → the dev identity. (The prior unconditional `:-nox` default
# filled the dev login even under SAME_IDENTITY=0, shadowing the ferried fitness App inside
# fitness-review.sh, so the author≠judge guard refused EVERY review and NO PR could auto-merge.)
fitness_login_default(){ # <same_identity> <current_login>
  if [ -n "${2:-}" ]; then printf '%s' "$2"
  elif [ "${1:-}" = 1 ]; then printf 'oso-gato-nox-claudebox'
  else printf 'oso-gato-fitness-claudebox'; fi
}

# GENERAL ANOMALY REPAIR (R39 / #278) ------------------------------------------------------------------
# WHY: seven distinct stalls in one session (2026-07-27/28), none predicted, each hand-patched after the
# fact. The pattern was never the individual bugs. It was the DEFAULT: the pipeline's answer to "a state
# I have no rule for" was its answer to every surprise — log it, mark it blocked, wait for a human.
# Enumerating every way the world can surprise a machine does not converge; the tail is unbounded.
#
# THE CURE WAS ALREADY BUILT AND WIRED SHUT. run_fixer summons a model to diagnose and repair, and could
# only be reached from TWO anticipated states (host RED, fitness RETURN). Every other surprise took the
# road to the maintainer. The machine was never lacking the ability to unstick itself; it was only
# PERMITTED to for two problems somebody thought of in advance.
#
# anomaly_route <kind> <attempts> <max> -> INFRA | ESCALATE | REPAIR   (pure; --selftest covers it)
#   INFRA    - the anomaly IS the repair machinery, or a budget we cannot read. Fixing a broken tool with
#              itself loops, so these go STRAIGHT to the maintainer. Anything unparseable lands here.
#   ESCALATE - the bounded attempts are spent. The human is the LAST resort, never the first.
#   REPAIR   - hand it to the fixer.
# THE DEFAULT IS REPAIR, so a future call site that surfaces some new anomaly inherits self-repair
# without anyone remembering to wire it up. That inversion is the entire point.
#
# THE INFRA LIST IS MATCHED BY PATTERN, NOT BY EXACT NAME. An exact-match list is the wrong shape for a
# default-REPAIR router: every kind it fails to recognise falls through to the model, so a MISS here is a
# miss toward handing the fixer a tool that is itself broken. The live `review-infra-down` kind (a GLOBAL
# `claude -p` outage) proved it — under exact matching it missed `infra` and routed to REPAIR, i.e. the
# poller's answer to "the model is unreachable" would have been to summon the model, once per PR. Every
# review-* kind is the FITNESS GATE's own machinery and every *infra*/*trust* kind is the pipeline's, so
# both are matched as families. Fail direction is deliberately inverted HERE and only here: for the
# infra question a false INFRA costs one human ping, a false REPAIR loops a broken tool on itself.
anomaly_route(){
  local kind="${1-}" att="${2-}" max="${3-}"
  case "$kind" in
    *infra*|*trust*|refused|escalate|review|review-*) printf 'INFRA\n'; return 0 ;;
  esac
  case "$att" in ''|*[!0-9]*) printf 'INFRA\n'; return 0 ;; esac
  case "$max" in ''|*[!0-9]*) printf 'INFRA\n'; return 0 ;; esac
  [ "$max" -le 0 ] && { printf 'INFRA\n'; return 0; }
  [ "$att" -ge "$max" ] && { printf 'ESCALATE\n'; return 0; }
  printf 'REPAIR\n'
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  ck(){ local got; got="$(plan "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — plan($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  ck "no verdict"         NONE  B   NONE 0 NOOP
  ck "red"                RED   B   NONE 0 FIX
  ck "red ignores tier"   RED   A   PASS 1 FIX
  ck "green tierA merges" GREEN A   PASS 1 MERGE          # ZERO-GATE: A now merges like B/C
  ck "green tierA disarm" GREEN A   PASS 0 MERGE_DRYRUN   # ZERO-GATE: A routes by fitness, not tier
  ck "green B unreviewed" GREEN B   NONE 0 REVIEW
  ck "green C unreviewed" GREEN C   NONE 0 REVIEW
  ck "green B pass armed" GREEN B   PASS 1 MERGE
  ck "green B pass disarm" GREEN B  PASS 0 MERGE_DRYRUN
  ck "green C pass armed" GREEN C   PASS 1 MERGE
  ck "green B return"     GREEN B   RETURN 1 FIX
  ck "green B escalate"   GREEN B   ESCALATE 1 PRESENT
  ck "green unknown tier" GREEN ""  PASS 1 MERGE          # ZERO-GATE: unknown tier no longer gates
  ck "green unknown fit"  GREEN B   WAT  1 PRESENT
  # R18 idle-with-work-pending (audit CAT-42): a live-validate-labelled head at host=NONE past the bound STALLs.
  sv(){ local got; got="$(stall_verdict "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — stall_verdict($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  sv "labelled NONE aged → STALL"  NONE  1 2000 1800 STALL
  sv "labelled NONE fresh → OK"    NONE  1  600 1800 OK
  sv "unlabelled NONE aged → OK"   NONE  0 9999 1800 OK
  sv "GREEN never stalls"          GREEN 1 9999 1800 OK
  sv "RED never stalls"            RED   1 9999 1800 OK
  sv "non-numeric age → OK"        NONE  1 abc  1800 OK
  # CAT-17 bounded auto-rebase of GREEN+PASS-behind-main.
  rb(){ local got; got="$(rebase_due "$2" "$3")"; [ "$got" = "$4" ] && echo "ok: $1" || { echo "FAIL: $1 — rebase_due($2,$3)=$got want $4"; fail=1; }; }
  rb "0 attempts → TRY"    0 6 TRY
  rb "at bound → GIVEUP"   6 6 GIVEUP
  rb "over bound → GIVEUP" 9 6 GIVEUP
  rb "garbage n → TRY"     x 6 TRY
  # R6 — the fixer must be told WHICH gate failed. plan() returns FIX from two routes; fix_cause pins
  # the mapping so a fitness RETURN can never again be handed a canned "host live-gate RED" prompt.
  fc(){ local got; got="$(fix_cause "$2" "$3")"; [ "$got" = "$4" ] && echo "ok: $1" || { echo "FAIL: $1 — fix_cause($2,$3)=$got want $4"; fail=1; }; }
  fc "RED → HOST"                  RED   NONE     HOST
  fc "RED before fitness is read"  RED   ""       HOST
  fc "GREEN+RETURN → FITNESS"      GREEN RETURN   FITNESS
  fc "GREEN+PASS → never a FIX"    GREEN PASS     UNKNOWN
  fc "GREEN+NONE → never a FIX"    GREEN NONE     UNKNOWN
  # every plan()=FIX route must map to a KNOWN cause — the guard against a future route silently
  # inheriting the wrong prompt (the exact defect this fixes). The host axis spans the UNKNOWN/absent
  # tokens too (NONE = no verdict yet, WAT = an unrecognised one), so the claim the loop prints is the
  # claim it actually tests: no host token whatsoever can reach the fixer without a truthful cause.
  for h in RED GREEN NONE WAT ""; do for f in NONE PASS RETURN ESCALATE WAT ""; do
    if [ "$(plan "$h" B "$f" 1)" = FIX ] && [ "$(fix_cause "$h" "$f")" = UNKNOWN ]; then
      echo "FAIL: plan($h,$f)=FIX but fix_cause=UNKNOWN — the fixer would get no truthful reason"; fail=1
    fi
  done; done
  echo "ok: every FIX route has a known cause"
  # FITNESS_LOGIN default must MATCH the identity mode (this fix): an explicit login wins; else strict
  # SoD (0) → the fitness App, make-it-work (1) → the dev identity. The pre-fix bug was an unconditional
  # nox default that shadowed the fitness App under SAME_IDENTITY=0 and blocked ALL auto-merges.
  fld(){ local got; got="$(fitness_login_default "$2" "$3")"; [ "$got" = "$4" ] && echo "ok: $1" || { echo "FAIL: $1 — fitness_login_default($2,$3)=$got want $4"; fail=1; }; }
  fld "strict SoD → fitness App"     0 ""                         oso-gato-fitness-claudebox
  fld "make-it-work → dev identity"  1 ""                         oso-gato-nox-claudebox
  fld "explicit login wins (SoD)"    0 oso-gato-fitness-claudebox oso-gato-fitness-claudebox
  fld "explicit login wins (miw)"    1 someone-else               someone-else
  # #152 — the fixer's outcome is DETERMINED, never assumed. The landing is verified against ORIGIN, so
  # rc-0-but-nothing-landed ("push lied") and origin-unreadable are FAILURES, not silent successes.
  fo(){ local got; got="$(fix_outcome "$2" "$3" "$4" "$5" "$6")"; [ "$got" = "$7" ] && echo "ok: $1" || { echo "FAIL: $1 — fix_outcome($2,$3,$4,$5,$6)=$got want $7"; fail=1; }; }
  fo "blocked beats everything"  1 aaa bbb 0 bbb  BLOCKED
  fo "no commit (head unmoved)"  0 aaa aaa 0 aaa  NO_COMMIT
  fo "no commit (no head)"       0 aaa ""  0 ""   NO_COMMIT
  fo "push errored"              0 aaa bbb 1 aaa  PUSH_FAILED
  fo "push rc0 but origin stale" 0 aaa bbb 0 aaa  NOT_LANDED
  fo "origin unreadable"         0 aaa bbb 0 ""   NOT_LANDED
  fo "landed (origin holds it)"  0 aaa bbb 0 bbb  LANDED
  # #156 — the rc-3 retry is BOUNDED, not absent (silent spin) and not zero (a blip strands a GREEN PR).
  rd(){ local got; got="$(review_due "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — review_due($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  rd "first attempt runs"           0 0     3 300 RUN
  rd "a blip retries after backoff" 1 300   3 300 RUN
  rd "…but not inside the backoff"  1 299   3 300 WAIT
  rd "the LAST try still runs"      2 300   3 300 RUN
  rd "exhausted → parked"           3 99999 3 300 PARKED
  rd "parked stays parked"          9 99999 3 300 PARKED
  rd "tries=1 parks after one"      1 99999 1 0   PARKED
  # REVIEW-INFRA health classifier (2026-07-20) — NON-EMPTY OUTPUT IS NOT ENOUGH: a claude -p auth failure
  # prints its error to STDOUT and exits 1, and must classify DOWN (else the global outage re-opens the
  # parking incident). Trusted only on exit 0 AND the reply token.
  ih(){ local got=up; infra_healthy "$2" "$3" || got=down; [ "$got" = "$4" ] && echo "ok: $1" || { echo "FAIL: $1 — infra_healthy($2,<$3>)=$got want $4"; fail=1; }; }
  ih "rc0 + OK token → up"                  0 "OK"                                up
  ih "rc0 + OK mid-sentence → up"           0 "Sure — OK."                        up
  ih "auth error (rc1 + stdout msg) → down" 1 "Not logged in · Please run /login" down
  ih "rc0 but empty → down"                 0 ""                                  down
  ih "rc0 but no token (garbage) → down"    0 "unexpected model output"           down
  ih "timeout/killed (rc124, empty) → down" 124 ""                                down
  # #162 — the self-refresh decision. Only a CLEAN, strictly-fast-forward clone reloads; every other
  # verdict leaves the poller running unchanged (fail-safe toward progress). Removing the reload path
  # (restoring the no-refresh behaviour) makes the RELOAD row fail. The <run> input is the LAUNCH head
  # (#170) — the caller-level clone-HEAD-proxy rows (an external pull must not mask a stale process)
  # live in poller-selfrefresh.test.sh, where the mutation is restored mechanically.
  rf(){ local got; got="$(refresh_decision "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — refresh_decision($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  rf "no fetch (empty origin)"      1 aaa ""  0 NOFETCH
  rf "up to date"                   1 aaa aaa 1 UPTODATE
  rf "clean + ff ahead → reload"    1 aaa bbb 1 RELOAD
  rf "dirty blocks the reload"      0 aaa bbb 1 DIRTY
  rf "diverged (not a ff) → leave"  1 aaa bbb 0 DIVERGED
  rf "dirty even when diverged"     0 aaa bbb 0 DIRTY
  rf "uptodate beats dirty"         0 aaa aaa 1 UPTODATE
  # #173 — the lock-liveness adjudication. ONLY a positively-confirmed live, same-generation holder
  # defers a start; every doubt resolves toward STARTING (a silently dead poller is unrecoverable).
  lk(){ local got; got="$(lock_verdict "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — lock_verdict('$2','$3','$4','$5')=$got want $6"; fail=1; }; }
  lk "live same-gen holder → defer"          '123 b1 777 g1' b1 777 g1 DEFER
  lk "dead holder (pid gone) → take"         '123 b1 777 g1' b1 ''  g1 TAKEOVER_DEAD
  lk "recycled pid (starttime moved) → take" '123 b1 777 g1' b1 999 g1 TAKEOVER_RECYCLED
  lk "starttime read-flutter +1 → still live" '123 b1 777 g1' b1 778 g1 DEFER
  lk "starttime read-flutter -2 → still live" '123 b1 777 g1' b1 775 g1 DEFER
  lk "past the flutter tolerance → take"     '123 b1 777 g1' b1 780 g1 TAKEOVER_RECYCLED
  lk "previous kernel boot → take"           '123 b0 777 g1' b1 777 g1 TAKEOVER_BOOT
  lk "previous box generation → take"        '123 b1 777 g0' b1 777 g1 TAKEOVER_GENERATION
  lk "gen unrecorded THERE → liveness rules" '123 b1 777 -'  b1 777 g1 DEFER
  lk "gen unreadable HERE → liveness rules"  '123 b1 777 g1' b1 777 '' DEFER
  lk "empty record (bare-flock era) → take"  ''              b1 ''  g1 TAKEOVER_NORECORD
  lk "garbage record → take"                 'not a record'  b1 ''  g1 TAKEOVER_NORECORD
  lk "placeholder starttime → take"          '123 b1 - g1'   b1 777 g1 TAKEOVER_NORECORD
  lk "dead beats generation in the verdict"  '123 b1 777 g0' b1 ''  g1 TAKEOVER_DEAD
  vg(){ local got; got="$(printf '%s' "$2" | host_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  vg "host green"  'Host live-gate (Gate B): VERDICT GREEN'                                 GREEN
  vg "host latest" $'…VERDICT RED\nHost live-gate (Gate B): VERDICT GREEN'                   GREEN
  vg "host none"   'some unrelated comment'                                                 ""
  fv(){ local got; got="$(printf '%s' "$2" | fitness_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  fv "fit pass"    'Fitness review: VERDICT PASS'                                           PASS
  fv "fit latest"  $'Fitness review: VERDICT RETURN\nFitness review: VERDICT PASS'          PASS
  st(){ local got; got="$(printf '%s' "$2" | supersede_targets | tr '\n' ' ')"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  st "retire one"        'Supersedes #97'                                                   '97 '
  st "retire colon list" $'Body text.\nsupersedes: #12, #13\nMore.'                         '12 13 '
  st "retire crlf+indent" $'  Supersedes #42\r\nother\r\n'                                  '42 '
  st "retire dedup"      $'Supersedes #7\nSupersedes #7'                                    '7 '
  st "retire cross-repo" 'Supersedes oso-gato/fedora-desktop#97'                            ''
  st "retire prose only" 'this supersedes the old approach entirely'                        ''
  st "retire unrelated"  'relates to #4; fixes #5'                                          ''
  st "retire mid-line"   'note: this PR supersedes #12 in spirit'                           ''
  st "retire backticked" '`Supersedes #97`'                                                 ''
  st "retire blockquote" '> Supersedes #97'                                                 ''
  st "retire trailing"   'Supersedes #12 — replaced by the new approach'                    ''
  st "retire space list" 'Supersedes #12 #13'                                               ''
  st "retire fenced"     $'```\nSupersedes #55\n```'                                        ''
  st "retire tilde fence" $'~~~\nSupersedes #56\n~~~'                                       ''
  st "retire code indent" '    Supersedes #55'                                              ''
  st "retire post-fence" $'```\ndoc example\n```\nSupersedes #57'                           '57 '
  # tier-classify --stdin regression harness (the sibling script IS a dependency of sweep routing):
  # the gather loop must keep a FINAL UNTERMINATED line — a command-substituted variable loses its
  # trailing newline, and dropping that line classified a one-file PR from ZERO paths (round-2
  # review blocker). Empty stdin must stay "no files" — asserted here as EMPTY OUTPUT (the property
  # the sweep's ${tier:-A} consumes; the script also exits 2, not asserted).
  tc(){ local got; got="$(printf '%s' "$2" | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; got="${got:-NONE}"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  tc "tier unterminated one"  'README.md'                    'C'
  tc "tier unterminated last" $'README.md\npolicy/CLAUDE.md' 'A'
  tc "tier terminated parity" $'README.md\n'                 'C'
  tc "tier empty stdin"       ''                             'NONE'
  # ── MOVE 1b (#274): SKIPPED is a verdict, and every verdict maps to an action ──────────────────────
  hv(){ printf '%s\n' "$2" | host_verdict; }
  ck2(){ if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; fail=1; fi; }
  ck2 "host_verdict reads GREEN"   "$(hv _ '**Host live-gate (Gate B): VERDICT GREEN** - repo @ abc')" "GREEN"
  ck2 "host_verdict reads RED"     "$(hv _ '**Host live-gate (Gate B): VERDICT RED** - repo @ abc')" "RED"
  ck2 "THE 1b BUG: SKIPPED was invisible, now read" "$(hv _ '**Host live-gate (Gate B): SKIPPED** - `e2e-beta` @ `a5ee7f7` carries no top-level Containerfile')" "SKIPPED"
  ck2 "prose mentioning skipped is not a verdict"   "$(hv _ 'the gate skipped it earlier')" ""

  gr(){ printf '%s\n' "$2" | gate_relevant; }
  ck2 "README is not gate-relevant"      "$(gr _ 'README.md')" "0"
  ck2 "CI workflow is not gate-relevant" "$(gr _ '.github/workflows/build.yml')" "0"
  ck2 "Containerfile IS gate-relevant"   "$(gr _ 'Containerfile')" "1"
  ck2 ".live-gate IS gate-relevant"      "$(gr _ '.live-gate')" "1"
  ck2 "run.sh IS gate-relevant"          "$(gr _ 'run.sh')" "1"
  ck2 "Quadlet IS gate-relevant"         "$(gr _ 'e2e-beta.container')" "1"
  ck2 "any gate-relevant file in a set taints it" "$(printf 'README.md\nrun.sh\n' | gate_relevant)" "1"
  ck2 "empty file list is not gate-relevant"      "$(printf '' | gate_relevant)" "0"

  pl(){ plan "$2" "$3" "$4" "$5" "$6"; }
  ck2 "SKIPPED + docs-only + unreviewed -> REVIEW (unfrozen)" "$(pl _ SKIPPED A NONE 1 0)" "REVIEW"
  ck2 "SKIPPED + docs-only + PASS -> MERGE (the freeze is over)" "$(pl _ SKIPPED A PASS 1 0)" "MERGE"
  ck2 "SKIPPED + docs-only + RETURN -> FIX"                  "$(pl _ SKIPPED A RETURN 1 0)" "FIX"
  ck2 "SKIPPED + GATE-RELEVANT -> NOOP (must NOT dodge the gate)" "$(pl _ SKIPPED A PASS 1 1)" "NOOP"
  ck2 "GREEN unaffected by the new arg"   "$(pl _ GREEN A PASS 1 1)" "MERGE"
  ck2 "RED still fixes"                   "$(pl _ RED A NONE 1 0)" "FIX"
  ck2 "NONE still waits"                  "$(pl _ NONE A NONE 1 0)" "NOOP"
  ck2 "back-compat: 4-arg call still works" "$(plan GREEN A PASS 1)" "MERGE"
  ar(){ local got; got="$(anomaly_route "$2" "$3" "$4")"; [ "$got" = "$5" ] && echo "ok: $1" || { echo "FAIL: $1 anomaly_route($2,$3,$4)=$got want=$5"; fail=1; }; }
  # The KINDS below are the ones the poller ACTUALLY emits (grep surface_or_repair/surface): asserting a
  # route for a kind nothing can produce is a green row naming a feature that is not there.
  ar "a brand-new anomaly repairs by DEFAULT"   stalled        0 3 REPAIR
  ar "the wired 'cannot tell which gate' repairs" blocked      0 3 REPAIR
  ar "the wired rebase-conflict repairs"        rebase         0 3 REPAIR
  ar "an unknown FUTURE kind repairs"           some-new-thing 0 3 REPAIR
  ar "mid-budget still repairs"                 stalled        2 3 REPAIR
  ar "budget spent escalates to the human"      stalled        3 3 ESCALATE
  ar "infra failure goes straight to human"     infra          0 3 INFRA
  ar "a refusal is not repairable"              refused        0 3 INFRA
  ar "a trust-boundary event is not repairable" trust          0 3 INFRA
  # The review-* family IS the fitness gate's own machinery: summoning the model to fix "the model is
  # unreachable" loops a broken tool on itself. These fell through to REPAIR under exact-match.
  ar "a GLOBAL reviewer outage is NOT repairable"  review-infra-down 0 3 INFRA
  ar "a per-head reviewer failure is NOT repairable" review-failed   0 3 INFRA
  ar "a deliberate fitness ESCALATE is not repairable" review        0 3 INFRA
  # enroll_pr names its kind `enroll-infra` SO THAT the existing *infra* family catches it — a missing
  # label-write is a credential fact no code change repairs. That naming is load-bearing, so pin it here:
  # rename the kind without the -infra suffix and the poller answers "I cannot label" by summoning a model
  # that cannot label either. Charged at att=0, i.e. it never depends on the budget to reach the human.
  ar "an un-addable label is NOT repairable"    enroll-infra   0 3 INFRA
  ar "unreadable attempts -> human"             stalled        x 3 INFRA
  ar "unreadable budget -> human"               stalled        0 x INFRA
  ar "repair disabled (0) -> human"             stalled        0 0 INFRA
  [ "$fail" = 0 ] && echo "ALL POLLER SELFTESTS PASS" || echo "POLLER SELFTESTS FAILED"
  exit "$fail"
fi

# ===================================================================================================
# I/O layer — the real sweep.
# ===================================================================================================
POLLER_REPO="${POLLER_REPO:-fedora-dev}"
SLUG="oso-gato/$POLLER_REPO"
# R16 OPERATING SCOPE (#167): the sweep list DERIVES from the maintainer-confirmed scope config
# (policy/scope.conf via bin/repo-scope.sh — config-as-code), NEVER a hardcoded list buried here:
# the 2026-07-13 incident was exactly a one-line PR editing this default to enroll a repo the
# maintainer had scoped away, and no layer noticed. An explicit POLLER_REPOS env can still narrow
# or reorder (testing), but can never EXPAND: sweep() re-checks EVERY repo against the scope each
# tick, so an env var, a stale process, or a mutated default cannot reach a foreign repo. The
# reader is fail-closed (its header): unreadable config ⇒ only the apparatus's own two repos;
# missing reader ⇒ check rc 127 ⇒ nothing swept at all. Zero API calls — a local file read.
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
if [ -z "${POLLER_REPOS:-}" ]; then
  POLLER_REPOS="$("$REPO_SCOPE" list)" || POLLER_REPOS=""
fi
# login MUST be the GraphQL form (no `[bot]` suffix) — that is what `gh pr view --json comments`
# returns and what auto-merge.sh matches against. REST's `.user.login` adds `[bot]`; do NOT use it.
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
# IDENTITY MODE: FITNESS_SAME_IDENTITY=1 (make-it-work / DRY-RUN) posts the verdict — and auto-merge.sh
# accepts it — under the DEV identity (oso-gato-nox-claudebox); the review is still an independent
# agent-context (fresh `claude -p`), cross-identity independence resting on the host live-gate (erebus).
# FITNESS_SAME_IDENTITY=0 is STRICT separation-of-duties (the arm that actually auto-merges): the verdict
# is posted by, and verified against, the DISTINCT fitness App (oso-gato-fitness-claudebox). The reviewer
# login default MUST match that mode (fitness_login_default, above): an unconditional `:-nox` default
# would fill the DEV login even under SAME_IDENTITY=0, shadowing the ferried fitness App inside
# fitness-review.sh, so the author≠judge guard refuses EVERY review — blocking all auto-merges (observed
# live 2026-07-14: a strict arm with FITNESS_LOGIN unset self-reviewed forever). An explicit FITNESS_LOGIN
# still wins. EXPORTED so fitness-review.sh + auto-merge.sh (which BOTH need the non-empty login) see it.
export FITNESS_SAME_IDENTITY="${FITNESS_SAME_IDENTITY:-1}"
FITNESS_LOGIN="$(fitness_login_default "$FITNESS_SAME_IDENTITY" "${FITNESS_LOGIN:-}")"; export FITNESS_LOGIN
POLLER_ARMED="${POLLER_ARMED:-1}"   # ARMED BY DEFAULT (gate-free objective; #96 explicit-arm retired) — the merge-trust boundary is the distinct-App gates + auto-merge's fail-closed re-check, not this flag; POLLER_ARMED=0 is a deliberate dry-run soak
POLL_INTERVAL="${POLL_INTERVAL:-30}"   # fixed sweep cadence (a gentler 30s; no adaptive machinery)
POLLER_FIXER="${POLLER_FIXER:-claude -p}"
POLLER_REPAIR_MAX="${POLLER_REPAIR_MAX:-3}"   # R39/#278: bounded repair attempts before the maintainer
# R39/#278 UNENROLLED-PR SELF-HEAL. DEV_LOGIN is the author identity whose PRs the loop owns and may
# therefore enrol; ENROLL_LABEL is the host live-gate's ONLY discovery signal and must stay in lockstep
# with bin/dev-author.sh's AUTHOR_LABEL (the two are the same enrolment, at author-time and after).
DEV_LOGIN="${DEV_LOGIN:-oso-gato-nox-claudebox}"
ENROLL_LABEL="${ENROLL_LABEL:-live-validate}"
POLLER_ENROLL_MAX="${POLLER_ENROLL_MAX:-3}"   # consecutive failed enrolments before the maintainer hears about it
# GENERATION FENCE (2026-07-28) — SHARED CONTRACT with bin/poller-service.sh: rc 92 means "I am running
# in a container that no longer exists", and the supervisor must EXIT on it rather than relaunch.
POLLER_ORPHAN_RC="${POLLER_ORPHAN_RC:-92}"
BOX_GENERATION="${BOX_GENERATION:-$HERE/box-generation.sh}"
FIXER_TIMEOUT="${FIXER_TIMEOUT:-1800}"
RETIRE_LOOKBACK="${RETIRE_LOOKBACK:-15}"
# the isolator the fixer runs in (#152). Overridable so poller-fixer.test.sh can drive the REAL sweep.
FRESH_TREE="${FRESH_TREE:-$HERE/fresh-tree.sh}"
# the R9 fleet HALT reader (#151). Overridable so the mock suites can pin both directions
# (poller-fixer.test.sh drives a halted sweep with FLEET_HALT=false, a normal one with FLEET_HALT=true).
FLEET_HALT="${FLEET_HALT:-$HERE/fleet-halt.sh}"
POLLER_HALTED=0
# the independent fitness harness the REVIEW arm runs. Overridable (same reason as FRESH_TREE) so
# fitness-review.test.sh can drive the REAL sweep against a scripted reviewer outcome.
FITNESS_REVIEW="${FITNESS_REVIEW:-$HERE/fitness-review.sh}"
# THE BOUNDED RETRY BEHIND rc 3 (#156 — see review_due). A no-verdict review is retried at most
# FITNESS_REVIEW_TRIES times per head, spaced by FITNESS_RETRY_BACKOFF seconds; only a failure that
# SURVIVES them becomes a question. This is now the PER-HEAD path — CORRECT only because a GLOBAL reviewer
# outage is caught first by the infra health gate below (2026-07-20). A per-head rc-3 (infra confirmed UP)
# is a genuinely-broken PR, so bounded-retry-then-surface is right; a new commit or a fix recovers it.
FITNESS_REVIEW_TRIES="${FITNESS_REVIEW_TRIES:-3}"
FITNESS_RETRY_BACKOFF="${FITNESS_RETRY_BACKOFF:-300}"
# ── REVIEW-INFRA HEALTH GATE (2026-07-20): the MISSING GLOBAL SIGNAL. ────────────────────────────────
# rc 3 alone cannot say whether the whole reviewer infra (`claude -p`) is DOWN (a global outage — out for
# EVERY PR) or THIS one head is broken. Without the distinction, a >15-min claude -p outage on 2026-07-20
# was absorbed as N per-head failures and PARKED EVERY PR permanently (the incident). The gate adds the
# distinction the cheapest way: when a review FAILS (rc 3), a tiny `claude -p` liveness PROBE disambiguates
# — DOWN ⇒ this is global, so DON'T strike the head; PAUSE the arm for the sweep (no strikes, no questions)
# and skip the remaining reviews; it SELF-HEALS the next sweep once the probe passes (the fleet-halt PAUSE
# pattern). UP ⇒ genuinely per-head ⇒ the bounded retry above. Probe-ON-FAILURE, so a sweep whose reviews
# all SUCCEED pays NOTHING (a success IS the health signal). Disable with FITNESS_INFRA_CHECK=0 (⇒ the old
# behaviour). A persistent outage past FITNESS_INFRA_PAUSE_SURFACE seconds surfaces ONE question (so a
# never-recovering break is never a SILENT stall) — but the arm keeps auto-resuming, no human required.
FITNESS_INFRA_CHECK="${FITNESS_INFRA_CHECK:-1}"
FITNESS_INFRA_PROBE="${FITNESS_INFRA_PROBE:-claude -p}"
FITNESS_INFRA_TIMEOUT="${FITNESS_INFRA_TIMEOUT:-45}"
FITNESS_INFRA_PROMPT="${FITNESS_INFRA_PROMPT:-Reply with the single word: OK}"
FITNESS_INFRA_TOKEN="${FITNESS_INFRA_TOKEN:-OK}"   # the probe reply must carry this to count as healthy (rc 0 alone is not enough)
FITNESS_INFRA_PAUSE_SURFACE="${FITNESS_INFRA_PAUSE_SURFACE:-3600}"
REVIEW_INFRA=""   # per-SWEEP cache (reset at the top of sweep()): ''=unknown, up, down
# ── SELF-REFRESH (#162): the running poller deploys its OWN merged code, no human pull + bounce ──────
# At a SAFE POINT (the top of a sweep cycle — no fixer/review/merge in flight; they ALL run synchronously
# INSIDE sweep()), the poller fetches and, if origin/<branch> has fast-forwarded past the code it runs on
# a CLEAN clone, STEPS ASIDE (exits POLLER_RELOAD_RC). poller-service.sh then ff-pulls the clone +
# relaunches --watch on the new code (the flock singleton survives: the old poller fully exits, freeing
# its lock, before the new one starts). The poller NEVER writes the clone — detection only (req 4).
SELF_REFRESH="${SELF_REFRESH:-1}"                          # 1 = on; 0 disables the whole mechanism
# the clone whose code we execute: bin/ sits inside it, so its root is one level up from $HERE. In
# production this is fedora-dev's LIVE spec clone ($HOME/.local/share/fedora-dev). Overridable for tests.
SELF_REFRESH_CLONE="${SELF_REFRESH_CLONE:-$(dirname "$HERE")}"
SELF_REFRESH_REMOTE="${SELF_REFRESH_REMOTE:-origin}"
SELF_REFRESH_BRANCH="${SELF_REFRESH_BRANCH:-main}"
SELF_REFRESH_EVERY="${SELF_REFRESH_EVERY:-30}"            # fetch once per N sweeps (cheap, rate-limited; req 5)
SELF_REFRESH_FETCH_TIMEOUT="${SELF_REFRESH_FETCH_TIMEOUT:-60}"
# the exit code the poller uses to ask poller-service.sh to ff-pull + relaunch. SHARED CONTRACT: the same
# default lives in bin/poller-service.sh; override via env in BOTH (the service passes its env through).
POLLER_RELOAD_RC="${POLLER_RELOAD_RC:-90}"
# #170 — the code THIS PROCESS runs, captured ONCE at process start (before --watch's loop). The clone's
# momentary HEAD is a FALSE PROXY for it: the proxy held only while nothing but poller-service.sh ever
# pulled the clone, and that invariant is unenforced (observed live 2026-07-13: an orchestrator pulled
# the live clone to origin right after a merge, so every later check read clone==origin ⇒ UPTODATE while
# the process still executed the launch-time build — no merge could ever trigger a reload again). Every
# refresh decision compares origin against THIS. POLLER_LAUNCH_HEAD is a test seam (the suite injects a
# stale launch head to prove an external pull cannot mask a stale process).
LAUNCH_HEAD="${POLLER_LAUNCH_HEAD:-$(git -C "$SELF_REFRESH_CLONE" rev-parse HEAD 2>/dev/null)}"
# ── HOST-REFRESH (#163): the HOST half of self-refresh — a merged IMAGE-BAKED change redeploys the ───
# running host through the PROVEN dev→host seam (bin/host-refresh.sh → host-ticket.sh → the host
# agent's `redeploy <workload>` → container-refresh.sh's health-gate + digest auto-rollback — R10 stays
# where it already lives). The scan runs at the END of a sweep tick: a safe point (all sweep_repo work
# is synchronous and done) with THIS tick's R9 halt read in hand — filing a ticket is an ACTION, so a
# halted tick skips it. Rate-limited to once per HOST_REFRESH_EVERY sweeps (0 disables; a `--once`
# fires it only under HOST_REFRESH_EVERY=1 — the manual catch-up / test seam, since each --once is a
# fresh process whose counter starts at 0). FAIL-SAFE: a scan failure logs and never stops the loop —
# a missed redeploy degrades to the status quo (the monthly workload-refresh timer).
HOST_REFRESH_SCAN="${HOST_REFRESH_SCAN:-$HERE/host-refresh.sh}"
HOST_REFRESH_EVERY="${HOST_REFRESH_EVERY:-30}"
HOST_REFRESH_TICKS=0
# RECONCILE (task #19) — proof-gated closure of backlog issues (design in bin/reconcile.sh's header).
# Same wiring shape as host-refresh: once per RECONCILE_EVERY sweeps, at the END of a tick, gated by THAT
# tick's R9 halt read (closing an issue is an ACTION). FAIL-SAFE: a scan failure logs and never stops the loop.
RECONCILE_SCAN="${RECONCILE_SCAN:-$HERE/reconcile.sh}"
RECONCILE_EVERY="${RECONCILE_EVERY:-30}"
RECONCILE_TICKS=0
# SHIP ACTUATOR (R40) — the loop closes its own objective: run the R34 gate when it is the last missing
# piece, then announce the ship. Rarer cadence than the other ticks because a gate run costs a model
# call; 0 disables. See ship_actuator_tick() for the fail-safe contract.
SHIP_ACTUATOR="${SHIP_ACTUATOR:-$HERE/ship-actuator.sh}"
SHIP_ACTUATOR_EVERY="${SHIP_ACTUATOR_EVERY:-60}"
SHIP_ACTUATOR_TICKS=0
# ── DEV-LOOP LAUNCH (self-arm the authoring loop, 2026-07-19) ────────────────────────────────────────
# The authoring loop (dev-loop-service.sh) is launched by entrypoint.sh — but entrypoint.sh is
# IMAGE-BAKED, so on a box whose RUNNING image predates the loop, NOTHING launches it until a rebuild.
# A rebuild kills+restores every live session (R17) and its trigger is human-gated, so an image-only
# launch could NEVER self-arm on a busy multi-tenant box (the "box idle" contradiction). THIS tick closes
# the gap: the poller is CLONE-side and SELF-REFRESHES its own code (#162), so a poller carrying this tick
# reaches a running box with NO rebuild, and it kick-starts the authoring loop the same way — arming it
# CLONE-side instead of image-side. dev-loop-service.sh's liveness-adjudicated singleton dedups against
# the entrypoint's own launch on a rebuilt box (both may run; the singleton keeps one). Gated
# DEV_LOOP_ENABLED default-ON (the #220 self-arm default — a pre-loop container may not even carry the
# var, so default-on IS the self-arm; explicit =0 disables) + R9 halt (launching a service is an ACTION).
# Rate-limited to once per DEV_LOOP_LAUNCH_EVERY sweeps (0 disables; a lone `--once` fires it only under
# =1 — the test/catch-up seam, since each --once is a fresh process whose counter starts at 0).
DEV_LOOP_SERVICE="${DEV_LOOP_SERVICE:-$HERE/dev-loop-service.sh}"
DEV_LOOP_SERVICE_LOG="${DEV_LOOP_SERVICE_LOG:-$HOME/.local/state/dev-loop/service.log}"
DEV_LOOP_LAUNCH_EVERY="${DEV_LOOP_LAUNCH_EVERY:-6}"   # ~3 min at the 30s cadence — arm authoring promptly after a self-refresh
DEV_LOOP_LAUNCH_TICKS=0
# ── REBUILD-REQUEST (R17 approval flow, 2026-07-19) — flag-fired ONE-SHOT filing of the rebuild-devbox
# APPROVAL ticket. Anything in-box may request a purposeful rebuild by touching the FLAG file (a LOCAL
# write, not a bus write); THIS tick — the sanctioned headless bus-writer, the host-refresh/host-ticket
# precedent — then runs `rebuild-request.sh file`, which captures a FRESH session manifest and files the
# ticket AS the App (🔴 APPROVAL REQUIRED title + `rebuild-approval` label + @mention → the maintainer's
# phone). The maintainer's ENTIRE act is one `approved`-label tap; the host executor (fedora-bootstrap
# v1.2.69 approval gate) fires on it. ONE-SHOT: the flag is consumed on rc 0 (filed OR already-open —
# file_ticket is idempotent); a failure KEEPS the flag for a retry next firing. 0 disables.
REBUILD_REQUEST_SCRIPT="${REBUILD_REQUEST_SCRIPT:-$HERE/rebuild-request.sh}"
REBUILD_REQUEST_FLAG="${REBUILD_REQUEST_FLAG:-$HOME/.local/state/rebuild-request/requested}"
REBUILD_REQUEST_EVERY="${REBUILD_REQUEST_EVERY:-6}"
REBUILD_REQUEST_TICKS=0
STATE="$HOME/.local/state/pr-poller"; mkdir -p "$STATE"
LOG="$STATE/poller.log"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }

# ── LOCK LIVENESS (#173): the flock singleton must survive a box recreate ───────────────────────────
# The --watch lock lives on the HOME VOLUME, which outlives the poller process. A claudebox-rebuild
# can orphan a running poller (the box shares fedora-dev's PID namespace, so `distrobox rm` does not
# reap what it spawned): the orphan's process/FD keeps the flock held while sweeping NOTHING, and the
# fresh box's poller then found the lock held and politely exited 0 — every 30 s, forever. Observed
# live 2026-07-13 (08:27→12:23): FOUR HOURS of `exited (rc=0) — restarting in 30s`, zero sweeps, zero
# merges, and nothing anywhere said "the poller is down". The singleton exists to prevent TWO pollers;
# it produced ZERO and reported success. So the holder now RECORDS its identity in the lock file and a
# contender ADJUDICATES the record (lock_verdict, pure) instead of trusting the flock alone.
LOCKFILE="$STATE/poller.lock"
POLLER_DEFER_RC="${POLLER_DEFER_RC:-91}"        # the deferral exit code — NEVER 0 (#173 req 2: rc=0
                                                # must not mean "I did nothing and will keep doing
                                                # nothing"). SHARED CONTRACT with bin/poller-service.sh;
                                                # distinct from POLLER_RELOAD_RC (90).
LOCK_DEFER_MAX="${LOCK_DEFER_MAX:-10}"          # consecutive deferrals before ONE question is surfaced
                                                # (~5 min at the supervisor's 30 s restart cadence)
LOCK_DEFER_WINDOW="${LOCK_DEFER_WINDOW:-3600}"  # seconds two deferrals may sit apart and still count as
                                                # CONSECUTIVE: a real dead-lock streak arrives every
                                                # ~30 s; a stray manual defer from hours ago must not
                                                # pre-charge the streak toward a false alarm.
# the box-GENERATION token: every claudebox assemble `touch`es the .assembled marker, so its
# inode.mtime names the box incarnation this process belongs to. A holder recorded under a PREVIOUS
# generation is an orphan of a torn-down box — taken over even while alive. Missing/unreadable (tests,
# running outside the box) degrades to liveness-only adjudication (neutral, never a takeover cause).
POLLER_BOX_GEN_FILE="${POLLER_BOX_GEN_FILE:-$HOME/.local/state/claudebox/.assembled}"
boot_id(){ cat /proc/sys/kernel/random/boot_id 2>/dev/null || :; }
box_gen(){
  if [ -n "${POLLER_BOX_GEN:-}" ]; then printf '%s' "$POLLER_BOX_GEN"; return 0; fi   # test seam
  stat -c '%i.%Y' "$POLLER_BOX_GEN_FILE" 2>/dev/null || :
}
# starttime (field 22 of /proc/<pid>/stat) of a live pid; EMPTY when no such process. Parsed AFTER the
# last ')' — comm may contain spaces/parens, so counting whitespace fields from the front is wrong.
proc_start(){ # <pid>
  local s
  s="$(cat "/proc/${1:-0}/stat" 2>/dev/null)" || return 0
  s="${s##*) }"; set -- $s
  printf '%s' "${20:-}"
}

# lock_won <fresh|takeover> — we hold fd 9: record our identity + reset the deferral streak.
lock_won(){
  local b s g
  b="$(boot_id)"; s="$(proc_start "$$")"; g="$(box_gen)"
  # '-' placeholders keep the whitespace-framed record parseable when a field is unreadable
  printf '%s %s %s %s\n' "$$" "${b:--}" "${s:--}" "${g:--}" > "$LOCKFILE"
  local n=0 cf="$STATE/lock-defer.count"
  if [ -f "$cf" ]; then
    n="$(cat "$cf" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0;; esac
    [ "$n" -gt 0 ] && log "lock: ACQUIRED ($1) after $n deferral(s) — the deferral streak resets"
  fi
  rm -f "$STATE/lock-defer.count" "$STATE/lock-defer.surfaced"
  return 0
}

# lock_defer <why> <holder-record> — count the CONSECUTIVE streak, surface at the bound, exit
# POLLER_DEFER_RC. Deferring is fine ONCE (a healthy peer holds the lock); what must never happen
# again is a silent, rc=0, unbounded deferral loop (#173 req 2) — so every defer logs the holder
# adjudication, exits non-zero, and a streak of LOCK_DEFER_MAX surfaces ONE question.
lock_defer(){
  local why="$1" rec="${2:-}" cf="$STATE/lock-defer.count" mk="$STATE/lock-defer.surfaced" n=0 last=0 now
  now="$(date +%s)"
  if [ -f "$cf" ]; then
    n="$(cat "$cf" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0;; esac
    last="$(stat -c %Y "$cf" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0;; esac
    # the streak the question claims is CONSECUTIVE — make that claim true: a defer older than the
    # window is a different event, not part of this incident.
    [ $(( now - last )) -gt "$LOCK_DEFER_WINDOW" ] && { n=0; rm -f "$mk"; }
  fi
  n=$((n+1)); printf '%s' "$n" > "$cf"
  log "lock DEFER #$n: $why — exiting rc=$POLLER_DEFER_RC, not starting (a dead or previous-generation holder would have been TAKEN OVER; this one adjudicated LIVE)"
  if [ "$n" -ge "$LOCK_DEFER_MAX" ] && [ ! -f "$mk" ]; then
    # asked ONCE per incident (marker), but RE-ATTEMPTED until a post succeeds — a throttled create
    # must not become a lost question (the review_question discipline).
    if gh issue create --repo "$SLUG" \
         --title "poller: --watch has deferred $n consecutive starts — the lock is held and the singleton may be DOWN" \
         --body "**Poller → operator [lock-deferral streak]:** \`pr-poller --watch\` has deferred **$n consecutive** start attempts because \`$LOCKFILE\` is flock-held by a holder it adjudicates as LIVE and same-generation: \`${rec:-no record}\` (pid boot-id starttime generation). While this stands the supervisor's restart loop starts NOTHING. If no healthy poller is actually sweeping (check \`$LOG\`), the holder is wedged or the adjudication is wrong: \`kill <pid>\` frees the flock within one 30 s restart (proven 2026-07-13), or remove \`$LOCKFILE\` to force a rotation. A dead or previous-box-generation holder is taken over automatically — this question exists because a LIVE one cannot be (two pollers must never both run)."$'\n\n<sub>dev-side poller lock liveness (#173); no start taken — needs an operator look.</sub>' >/dev/null 2>&1; then
      : > "$mk"
      log "lock DEFER: surfaced the $n-deferral streak as an issue on $SLUG"
    else
      log "lock DEFER: could NOT surface the deferral streak (gh issue create failed) — will re-attempt on the next deferral"
    fi
  fi
  exit "$POLLER_DEFER_RC"
}

# lock_acquire — the --watch entry: adjudicated flock (#173). Returns holding fd 9, or exits
# POLLER_DEFER_RC via lock_defer. TAKEOVER mechanics: the stale flock rides a lingering FD we cannot
# make its owner drop, but flock binds to the INODE — unlink the path and re-flock a fresh file, and
# the lingering lock gates nothing (the orphaned inode dies with its holder). Only a provably-live
# previous-generation orphan is first sent SIGTERM (the poller traps TERM and exits cleanly, freeing
# its own flock); dead/recycled/no-record holders get NO signal — a recycled pid is an innocent
# stranger.
lock_acquire(){
  # APPEND-mode open: a contender must NEVER truncate a live holder's record (the old `exec 9>` did
  # exactly that, which is one reason no record could have lived in the bare-flock lock file).
  exec 9>>"$LOCKFILE"
  if flock -n 9; then lock_won fresh; return 0; fi
  local rec rpid verdict
  rec="$(head -n1 "$LOCKFILE" 2>/dev/null)"
  rpid="${rec%% *}"
  verdict="$(lock_verdict "$rec" "$(boot_id)" "$(proc_start "$rpid")" "$(box_gen)")"
  if [ "$verdict" = DEFER ]; then
    lock_defer "the lock is held by a LIVE same-generation pr-poller (pid=$rpid)" "$rec"   # exits
  fi
  log "lock TAKEOVER ($verdict): the flock is held but the recorded holder (${rec:-no record}) is not a live same-generation poller — rotating the lock file (fail-safe toward STARTING: a brief double-sweep is idempotent + gate-checked; a silently dead poller cost 4 h of rc=0 on 2026-07-13)"
  if [ "$verdict" = TAKEOVER_GENERATION ]; then
    kill -TERM "$rpid" 2>/dev/null && log "lock TAKEOVER: sent SIGTERM to the previous-generation orphan pid=$rpid (it traps TERM and exits cleanly)"
  fi
  exec 9>&-
  rm -f "$LOCKFILE"
  exec 9>>"$LOCKFILE"
  flock -n 9 || lock_defer "lost the takeover race — another starter flocked the rotated lock first (live by construction)" "$(head -n1 "$LOCKFILE" 2>/dev/null)"
  # unlink-rotation race guard: if a SECOND rotator unlinked the inode we just flocked and created its
  # own, the path no longer names our file — two "winners" would both sweep. The path's inode must be
  # the one our fd holds.
  local ino_fd ino_path
  ino_fd="$(stat -Lc %i /proc/self/fd/9 2>/dev/null)"; ino_path="$(stat -c %i "$LOCKFILE" 2>/dev/null)"
  if [ -z "$ino_fd" ] || [ "$ino_fd" != "$ino_path" ]; then
    lock_defer "lost the takeover race — the rotated lock was re-rotated by another starter" "$(head -n1 "$LOCKFILE" 2>/dev/null)"
  fi
  lock_won takeover
}

# Surface a decision to Arthur WITHOUT merging: a single idempotent comment per (pr,sha,kind). The
# poller never clicks — it makes the human touchpoint visible and stops churning.
surface(){ # <pr> <sha> <kind> <message>
  # NB: two `local` statements ON PURPOSE. Bash expands ALL words of a declaration builtin BEFORE
  # executing it, so `${kind}` inside a `m=…` word on the SAME line would be expanded before
  # kind="$3" is assigned → `set -u` abort. Proven live: the first real sweep died here (#116).
  local pr="$1" sha="$2" kind="$3" msg="$4"
  local m="$STATE/surfaced-${pr}-${sha}-${kind}.done"
  [ -f "$m" ] && return 0
  log "SURFACE $SLUG#$pr @ ${sha:0:7} [$kind]: $msg"
  gh pr comment "$pr" --repo "$SLUG" --body "**Poller → Arthur [$kind]:** $msg"$'\n\n<sub>dev-side poller (Step 5); no merge taken — needs your decision.</sub>' >/dev/null 2>&1 && : > "$m"
}

# surface_or_repair <pr> <ref> <sha> <kind> <reason> — THE NEW DEFAULT for an unexpected state.
# Bounded self-repair FIRST; the maintainer only when repair is inapplicable (INFRA) or spent (ESCALATE).
# A repair needs a real branch to commit to, so an empty ref degrades to surface() — honest, never silent.
#
# CONTRACT WITH THE CALLER (two channels, both load-bearing):
#   rc        - passed through from whatever it did, so a caller that parks on a SUCCESSFUL POST keeps
#               doing exactly that (a throttled comment must never silence a human touchpoint).
#   SOR_ROUTE - the road actually taken (REPAIR|ESCALATE|INFRA). A caller that parks its head must NOT
#               park a REPAIR: a repair mints a NEW head that re-gates on its own, which is PROGRESS,
#               and parking it would strand the very PR the repair just unstuck.
SOR_ROUTE=""
surface_or_repair(){
  local pr="$1" ref="$2" sha="$3" kind="$4" reason="$5"
  local budget="$STATE/repair-${pr}-${kind}.n" att=0
  [ -f "$budget" ] && att="$(cat "$budget" 2>/dev/null || echo 0)"
  case "$att" in ''|*[!0-9]*) att=0 ;; esac
  local route; route="$(anomaly_route "$kind" "$att" "$POLLER_REPAIR_MAX")"
  [ -n "$ref" ] || route=INFRA
  # A repair that cannot be ISOLATED is not a repair. Without a local clone to bolt a throwaway worktree
  # off, run_fixer refuses (fail-closed, correctly) and surfaces its OWN "check the repo clone" message —
  # which would REPLACE this anomaly's diagnosis with a note about the repair machinery, leaving the
  # maintainer told nothing about WHY the PR is stuck. The poller sweeps repos it may hold no clone of,
  # so this is a live state, not a hypothetical. Degrade to surface() with the REAL reason, and charge
  # NO budget: an attempt that could never happen must not consume one of the attempts.
  [ "$route" != REPAIR ] || clone_for "$POLLER_REPO" >/dev/null 2>&1 || route=INFRA
  SOR_ROUTE="$route"
  case "$route" in
    REPAIR)
      att=$((att+1)); printf '%s' "$att" > "$budget" 2>/dev/null
      log "ANOMALY $SLUG#$pr @ ${sha:0:7} [$kind] repair attempt $att/$POLLER_REPAIR_MAX: $reason"
      run_fixer "$pr" "$ref" "$sha" "ANOMALY" "$reason" ;;
    ESCALATE)
      log "ANOMALY $SLUG#$pr @ ${sha:0:7} [$kind] — $att/$POLLER_REPAIR_MAX attempts spent; escalating"
      surface "$pr" "$sha" "$kind" "$reason - the loop attempted bounded self-repair $att time(s) and could not clear it; this is now a maintainer decision." ;;
    *)
      surface "$pr" "$sha" "$kind" "$reason" ;;
  esac
}

# WHICH surface() CALL SITES STAY surface() — a boundary, not an oversight. The default is REPAIR, so
# every site left alone below is left alone for a REASON, recorded here because "nobody wired it up" is
# exactly how the first cut of this feature shipped as unreachable code:
#   * anything INSIDE run_fixer/fix_in_tree (no-progress, no clone, unenterable worktree, FIXER_BLOCKED,
#     no-commit, push-failed, did-not-land) — surface_or_repair CALLS run_fixer, so wiring these would
#     re-enter the fixer from within itself. They are also, every one of them, the fixer reporting that
#     the fixer could not run: the broken tool cannot be the repair for its own breakage.
#   * review-failed / review-infra-down — the FITNESS GATE's own machinery. anomaly_route classifies the
#     review-* family INFRA for the same reason; the call sites match, so neither layer stands alone.
#   * refused — the MERGE-TRUST boundary disagreeing with the poller. A model must never be summoned to
#     make a trust refusal go away. INFRA in anomaly_route, and it stays surface() here.
#   * merge-failed (rc 3) — NOT stuck. It deliberately does not park and the poller re-attempts the merge
#     every sweep until it lands; spending a model run on a state that is already self-healing is churn.
#   * review (PRESENT) — a fitness ESCALATE is the reviewer DEFERRING a judgment call to the maintainer
#     BY DESIGN. That is the one human path zero-gate keeps on purpose; repairing around it would route
#     a deliberate escalation back into the machine.

# UNENROLLED-PR SELF-HEAL (R39 / #278) -----------------------------------------------------------------
# The host live-gate discovers work ORG-WIDE by the `live-validate` label and by NOTHING ELSE. So a PR the
# loop authored but never labelled can never receive a verdict: host stays NONE, plan() stays NOOP, and the
# poller sweeps past it in silence for as long as it stays open. Not hypothetical — the maintainer-facing
# agent forgot the label on THREE PRs in one session (#271, #277, bootstrap#283). Enrolment must therefore
# not depend on anyone remembering, which is exactly the #278 thesis applied to its own front door.
#
# DETERMINISTIC, NOT A MODEL RUN. The repair here is one idempotent label add, and the no-offload doctrine
# cuts both ways: we do not hand the maintainer a command we can run ourselves, and we do not summon a
# model for one either. run_fixer commits code in a worktree — it could not add a label if we asked it to.
#
# CREATE-ON-USE. `gh pr edit --add-label` HARD-FAILS on a label the repo does not carry, and a brand-new
# repo carries none — that exact miss is one of the seven stalls behind #278 (it cost 12 SILENT hours). So
# a failed add is retried ONCE behind a `gh label create`, the dev-plan.sh / host-ticket.sh precedent.
#
# ONE SHOT PER PR, and that is a boundary, not a bound. We heal an OMISSION; we do not fight a DECISION. If
# the label is gone after we enrolled it, somebody removed it on purpose, and re-adding it every 30s would
# be the loop arguing with a human. The marker is per-PR (enrolment is a PR property, not a head one); a
# wiped box re-enrols once, which is harmless and idempotent.
#
# FAILURE IS BOUNDED, NOT SILENT (R4). A transient API blip must not ping the maintainer, and a permanent
# one (no label-write on this repo) must not re-spin at sweep cadence forever telling nobody. Consecutive
# failures are counted; at POLLER_ENROLL_MAX the state goes to surface_or_repair under the kind
# `enroll-infra`, which anomaly_route's existing `*infra*` family already routes straight to the human —
# correctly, because the missing capability is a credential fact no code change repairs.
enroll_pr(){ # <pr> <ref> <sha> — rc 0 = enrolled (or already handled); rc 1 = could not
  local pr="$1" ref="$2" sha="$3"
  local mark="$STATE/enrolled-${pr}.done" budget="$STATE/enroll-${pr}.n" n=0
  [ -f "$mark" ] && return 0
  if gh pr edit "$pr" --repo "$SLUG" --add-label "$ENROLL_LABEL" >/dev/null 2>&1 \
     || { gh label create "$ENROLL_LABEL" --repo "$SLUG" --color 1d76db \
            --description "enrols a PR in the host live-gate — the gate discovers work by this label" \
            --force >/dev/null 2>&1
          gh pr edit "$pr" --repo "$SLUG" --add-label "$ENROLL_LABEL" >/dev/null 2>&1; }; then
    : > "$mark"; rm -f "$budget"
    log "SELF-HEAL $SLUG#$pr @ ${sha:0:7}: enrolled in the host live-gate ($ENROLL_LABEL) — a dev-authored PR that was never labelled can NEVER be verdicted, so it would have sat at host=NONE in silence"
    return 0
  fi
  [ -f "$budget" ] && n="$(cat "$budget" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1)); printf '%s' "$n" > "$budget" 2>/dev/null
  log "SELF-HEAL $SLUG#$pr: could not add '$ENROLL_LABEL' (attempt $n/$POLLER_ENROLL_MAX; label create+retry also failed)"
  if [ "$n" -ge "$POLLER_ENROLL_MAX" ]; then
    surface_or_repair "$pr" "$ref" "$sha" "enroll-infra" "this dev-authored PR carries no \`$ENROLL_LABEL\` label, so the host live-gate will never discover it and the PR can never reach a verdict — and the poller could not add the label itself after $n attempts (a \`gh label create\` + retry included). That is a CREDENTIAL/permission fact, not a code defect: the App identity appears to lack label-write on \`$SLUG\`. REMEDIATION: grant it Issues:write on this repo, or add the \`$ENROLL_LABEL\` label to the PR by hand — either one re-enters the normal gate → fitness → merge path with no further action."
  fi
  return 1
}

# The rc-3 question — asked ONCE per head, and ONLY once the bounded retries are exhausted (review_due).
# It carries the reviewer harness's REAL stderr: a question that shrugs is not a question. Re-callable on
# every later sweep at zero cost — surface() early-exits on its own marker, and RE-POSTS if a previous
# post failed (a throttled comment must not become a lost question).
#
# THE REMEDIATION IT PRINTS IS ONE THE HARNESS HONOURS. This deliberately does NOT write the sweep's
# `acted` marker: that marker is the TERMINAL-state skip the MERGE arm also short-circuits on, so parking
# the head with it would make the operator's fix — re-run `fitness-review.sh --post` — post a verdict the
# poller then refuses to read. What is parked is the REVIEW (review_due returns PARKED for this head, so
# no further model run is spent); the PR itself stays live, and a verdict posted by hand routes to MERGE
# on the very next sweep.
review_question(){ # <pr> <sha> <attempts> <reviewer-stderr>
  surface "$1" "$2" "review-failed" \
    "the independent fitness reviewer could not produce a verdict on head \`${2:0:7}\` — it failed $3 spaced attempt(s), so this is an INFRASTRUCTURE failure, not a judgment (and not a transient blip: a blip is retried silently). No verdict was posted, so the merge stays blocked (fail-closed). The reviewer harness reported:"$'\n\n```\n'"$(printf '%s' "${4:-(no stderr captured)}" | tail -c 900)"$'\n```\n\n'"The poller will not re-run the review on this head (that would re-spin every sweep with no signal). Push a new commit — or fix the cause and re-run \`bin/fitness-review.sh --post $POLLER_REPO $1\`: this head is NOT parked on the poller's acted marker, so the verdict that run posts IS picked up and acted on by the next sweep."
}

# Resolve the PERSISTENT clone a throwaway worktree bolts off. `~/repos/<repo>` is the fleet convention
# (what fresh-tree.sh + dev-author.sh use); `~/.local/share/<repo>` is fedora-dev's LIVE spec clone, kept
# as a fallback so a box carrying only that clone still fixes. FAIL-CLOSED (rc 1) when neither exists —
# never a cwd guess. NB the pre-#152 code hard-coded `cd $HOME/.local/share/$POLLER_REPO`, which exists
# ONLY for fedora-dev: on the other two swept repos the cd failed, the `&&` short-circuited, the fixer
# NEVER RAN — and the poller still logged its cheerful "new head (if pushed)".
clone_for(){ # <repo> → clone path on stdout, or rc 1
  local c
  for c in "$HOME/repos/$1" "$HOME/.local/share/$1"; do
    [ -d "$c/.git" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Reap a throwaway fixer worktree — Principle 10: the tree is DISPOSABLE and EVERY path reaps it.
# A kill -9 can still leak one; fresh-tree.sh force-removes a stale same-named worktree before
# recreating it (its path is deterministic per repo+branch), so the next fix on that branch self-heals.
reap_tree(){ # <clone> <worktree>
  [ -n "${2:-}" ] || return 0
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || rm -rf "$2"
  git -C "$1" worktree prune >/dev/null 2>&1 || true
}

# Spawn ONE bounded fixer iteration on a RED (or fitness-RETURN) PR. Feature-branch only, no merge.
# <cause> is HOST|FITNESS (from fix_cause) and <reason> is that gate's OWN text — the fixer is told the
# truth about which gate failed and is given the findings it must actually address (R6).
#
# #152 — ISOLATION IS GUARANTEED, NOT HOPED FOR, AND THE HARNESS OWNS GIT. The model gets a FRESH
# WORKTREE checked out on the PR's own gated head; it COMMITS and does nothing else. The SHELL pushes
# (scoped explicitly to the feature ref) and VERIFIES the landing against ORIGIN. Previously the model
# was handed the SHARED LIVE CLONE (checked out on main — the very tree the poller executes from) and
# was told to push: `policy/CLAUDE.md` forbids exactly that ("MUST NOT run PR git in a working tree
# another box or process may be mutating concurrently… use a dedicated git worktree/clone" — the
# 2026-06-28 incident, where a commit in the shared clone landed on a parallel box's branch and merged
# to main). Two live fixers happened to make their own scratch worktrees, but that was the MODEL'S
# discretion; a run that instead did `git checkout -b` in the shared clone would move the live clone's
# HEAD off main underneath the running poller. Now the harness guarantees it — mirroring dev-author.sh,
# the proven pattern (isolate via fresh-tree.sh → model commits, never pushes → harness owns git).
run_fixer(){ # <pr> <headref> <sha> <cause:HOST|FITNESS> <reason>
  local pr="$1" ref="$2" sha="$3" cause="$4" reason="$5"
  # R16 belt (#167): sweep() already scope-gates every swept repo; re-check HERE, before a worktree
  # is cut, so no future caller/route can walk a fixer into a foreign repo (the incident's exact
  # blast: a bot commit pushed onto a foreign feature branch). Normally unreachable — belt, not path.
  if ! "$REPO_SCOPE" check "$POLLER_REPO" >/dev/null 2>&1; then
    log "FIX $SLUG#$pr @ ${sha:0:7} REFUSED — '$POLLER_REPO' is outside the operating scope (R16); no worktree cut, no fix attempted"
    return 0
  fi
  # Signature spans BOTH cause and reason: a host RED and a fitness RETURN on the same head are
  # DIFFERENT failures and must not collide onto one no-progress signature.
  local sig; sig="$(printf '%s%s' "$cause" "$reason" | tr -cd '[:alnum:]' | tail -c 40)"
  local sigfile="$STATE/fixsig-${pr}.last" prev=""; [ -f "$sigfile" ] && prev="$(cat "$sigfile")"
  # PROGRESS-BASED STOP (not a count cap): if we already ran a fixer for THIS exact failure signature
  # and the head has NOT advanced past what we fixed, we are not making progress → surface, don't churn.
  local lastfixed="$STATE/fixed-${pr}.sha"; local lf=""; [ -f "$lastfixed" ] && lf="$(cat "$lastfixed")"
  if [ "$sig" = "$prev" ] && [ "$sha" = "$lf" ]; then
    surface "$pr" "$sha" "blocked" "the same failure persists after a fix attempt (no progress) — a human decision is needed. Failing gate: ${cause}. Detail: ${reason:0:400}"
    return 0
  fi

  # 1) ISOLATE — FAIL-CLOSED. No clone / no worktree ⇒ NO fix is attempted. There is deliberately NO
  # shared-clone fallback: running the model in a tree the poller itself executes from is the hazard
  # this exists to remove, so "could not isolate" must surface, never degrade into it.
  local clone wt
  clone="$(clone_for "$POLLER_REPO")" || {
    log "FIX $SLUG#$pr @ ${sha:0:7} — NO CLONE of $POLLER_REPO to isolate from (fail-closed: no fix attempted)"
    surface "$pr" "$sha" "blocked" "the fixer cannot run: no local clone of \`$POLLER_REPO\` to bolt an isolated worktree off. No fix was attempted — the fixer never runs in a shared tree."
    return 0
  }
  # the worktree is checked out on the PR's OWN head (FD_BASE_REF=origin/<ref>), not origin/main:
  # a fix iterates the PR's branch, so its base is that branch as ORIGIN currently holds it.
  wt="$(FD_BASE_REF="origin/$ref" "$FRESH_TREE" "$clone" "$ref" 2>>"$LOG")"
  # A worktree we cannot ENTER is not isolation. Prove it HERE — the one place the refusal can name its
  # real cause — because the branch-moved check below reads the tree with `git -C` and would fail on an
  # unenterable one too, parking the PR on a bogus "the branch moved" instead of the truth. `( cd )`
  # tests exactly what the model's own `cd` does: a directory can exist, pass -d, and still be unenterable.
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! ( cd "$wt" ) 2>/dev/null; then
    log "FIX $SLUG#$pr @ ${sha:0:7} — FRESH-TREE FAILED (no usable isolated worktree) for origin/$ref (fail-closed: no fix attempted)"
    surface "$pr" "$sha" "blocked" "could not create a usable isolated worktree on \`$ref\` — no fix was attempted (the fixer must never run in the shared clone). A maintainer should check the repo clone."
    # EVERY path reaps (Principle 10) — this one INCLUDED. A tree that exists but cannot be entered is
    # still a tree on the home volume; refusing to use it is not a licence to leave it behind. reap_tree
    # no-ops on an empty $wt (the fresh-tree-failed case), so one call covers both refusals.
    reap_tree "$clone" "$wt"
    return 0
  fi

  # 2) DO NOT FIX AN UN-GATED HEAD. fresh-tree.sh just fetched origin; if the branch moved between the
  # sweep reading $sha and this checkout, the findings we hold describe a head that no longer exists.
  # Skip — the new head carries no verdict yet and re-gates on its own.
  local base; base="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  if [ "$base" != "$sha" ]; then
    log "FIX $SLUG#$pr — BRANCH MOVED (gated ${sha:0:7} ≠ origin/$ref ${base:0:7}) — skipping; the new head re-gates itself"
    reap_tree "$clone" "$wt"
    return 0
  fi

  # markers are written only HERE — once a fix is genuinely being ATTEMPTED on this head. Writing them
  # before the isolation would park a NEVER-ATTEMPTED fix on a false "no progress" on the next sweep.
  printf '%s' "$sig" > "$sigfile"; printf '%s' "$sha" > "$lastfixed"
  log "FIX $SLUG#$pr @ ${sha:0:7} ref=$ref cause=$cause — isolated worktree $wt; spawning bounded fixer (timeout ${FIXER_TIMEOUT}s)"
  fix_in_tree "$pr" "$ref" "$sha" "$cause" "$reason" "$wt"
  # 6) THROWAWAY DISCIPLINE — every path through fix_in_tree returns here, so the tree is always reaped.
  reap_tree "$clone" "$wt"
}

# The bounded fix ITSELF, inside the isolated worktree: model commits → harness pushes → harness verifies
# the landing at ORIGIN → reports the TRUTH. Split out so run_fixer's single reap_tree covers every exit.
fix_in_tree(){ # <pr> <ref> <sha> <cause> <reason> <worktree>
  local pr="$1" ref="$2" sha="$3" cause="$4" reason="$5" wt="$6"
  # The prompt must be TRUTHFUL about which gate failed. Telling a fitness-RETURNed PR that "the host
  # live-gate returned a problem" sent the fixer hunting a build failure that does not exist (the build
  # is GREEN on a RETURN) — it could not progress, and the PR parked on a false 'blocked'.
  local what
  if [ "$cause" = FITNESS ]; then
    what="The build is GREEN. The INDEPENDENT FITNESS REVIEWER returned this head for rework — do NOT go
looking for a build or live-gate failure; there isn't one. Address the reviewer's findings below. They are
the reviewer's PROSE (advisory, not a machine signal): treat them as the requirements to satisfy, use your
own judgment on HOW, and if you believe a finding is wrong, say so via FIXER_BLOCKED rather than
half-fixing it."
  elif [ "$cause" = ANOMALY ]; then
    what="Neither gate failed. The PIPELINE ITSELF reached a state it has no rule for and is STUCK — this
PR cannot progress until that state is resolved. The stuck-state is described below. DIAGNOSE the real
cause from the repository as it actually is, then make the MINIMAL change that lets this PR move again.
If the right repair is NOT a change to this branch — it needs a maintainer decision, access you do not
have, or a change to the pipeline's own rules — do NOT improvise one: end with FIXER_BLOCKED and state
precisely what is needed."
  else
    what="The HOST LIVE-GATE returned RED — the candidate failed to build or failed its live probes.
Address the failure below."
  fi
  local prompt
  read -r -d '' prompt <<FIX_EOF || true
You are the fedora-dev fix iteration for PR $SLUG#$pr. You are working ONLY in the current directory: an
ISOLATED git worktree, already checked out on the PR's own branch '$ref' at exactly the head the gate
judged. $what

Your ONE job: make a MINIMAL, correct fix and COMMIT it here, so the gates re-run on the new head.
HARD RULES: the HARNESS owns git — you COMMIT (one or more commits, clear messages) and nothing more.
Do NOT 'git push': the harness pushes '$ref' for you and verifies it landed at origin. Do NOT open a PR,
do NOT merge, NEVER touch main or the merge gate, and never work outside this worktree. If you cannot fix
it (need a decision, missing access, or the approach is wrong), do NOT guess or commit half-work — end
your reply with a line 'FIXER_BLOCKED: <one-line reason>' and commit nothing.

The findings you must address (from the ${cause} gate):

$reason
FIX_EOF
  # TRANSPORT — THE PROMPT RIDES STDIN, NEVER ARGV (#155). A single argv argument is capped by the
  # kernel at MAX_ARG_STRLEN (32 pages = 131072 bytes), and this prompt embeds a GATE'S OWN FINDINGS —
  # a host candidate log or a reviewer's prose (each `tail -c 6000` today, but bounded only by that
  # choice) — so the argv form is a latent E2BIG: the exec fails and the fixer NEVER RUNS. stdin has no
  # such ceiling. It also CLOSES the inherited-stdin hole the old `</dev/null` guarded from the other
  # side: the model's stdin IS the prompt pipe now, so it can never drain the sweep's PR list off FD 0.
  # `set +o pipefail` inside the subshell keeps a printf SIGPIPE (a model that exits without draining)
  # from masquerading as the model's own failure.
  #
  # THE `cd` IS THE LAST STRAND OF THE ISOLATION, SO BIND THE BODY TO IT. `cd "$wt" && set +o pipefail;
  # <pipeline>` does NOT: `&&` binds to `set` ALONE and the `;` ends the list, so the pipeline would run
  # even when the cd FAILED — in the POLLER'S OWN cwd (a shared clone), with a prompt telling the model
  # to commit. That is the 2026-06-28 cross-branch-leak hazard `policy/CLAUDE.md` names by date, and the
  # shared-clone fallback this file swears it does not have. The BRACE GROUP binds the whole body to the
  # cd: no worktree, no model. run_fixer already refuses an unenterable tree (and says so), so this is
  # the structural belt behind that check — it cannot be reasoned away by a future edit up there.
  local out; out="$(cd "$wt" && { set +o pipefail; printf '%s' "$prompt" | timeout "$FIXER_TIMEOUT" $POLLER_FIXER 2>&1; })"
  local blocked bflag=0
  blocked="$(printf '%s' "$out" | grep -aoE '^FIXER_BLOCKED:.*' | head -1)"; [ -n "$blocked" ] && bflag=1

  # 3) THE HARNESS PUSHES — and only when the model actually committed and did not declare BLOCKED. The
  # refspec is EXPLICIT (HEAD:refs/heads/<ref>): this push can name no destination but the feature ref,
  # least of all main. Then VERIFY AT ORIGIN — the push's exit code is not evidence the fix landed.
  local head prc=0 remote=""
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  if [ "$bflag" = 0 ] && [ -n "$head" ] && [ "$head" != "$sha" ]; then
    git -C "$wt" push -q origin "HEAD:refs/heads/$ref" >/dev/null 2>&1 || prc=1
    remote="$(git -C "$wt" ls-remote origin "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
  fi

  # 4) REPORT THE TRUTH — every outcome is distinct in the log, and every NON-landing one surfaces
  # honestly and pushed nothing. No more "(if pushed)".
  case "$(fix_outcome "$bflag" "$sha" "$head" "$prc" "$remote")" in
    BLOCKED)
      log "FIXER BLOCKED $SLUG#$pr @ ${sha:0:7} — model declared it cannot fix this; nothing pushed"
      surface "$pr" "$sha" "blocked" "fixer reported BLOCKED — ${blocked#FIXER_BLOCKED:}" ;;
    NO_COMMIT)
      log "FIXER NO-COMMIT $SLUG#$pr @ ${sha:0:7} — the fixer committed nothing (timeout / no progress); nothing pushed"
      surface "$pr" "$sha" "blocked" "the fixer run finished without committing anything (it timed out, or could not make progress) — nothing was pushed and the head is unchanged. Failing gate: ${cause}. A human decision is needed." ;;
    PUSH_FAILED)
      log "FIXER PUSH FAILED $SLUG#$pr — committed ${head:0:7} but the push to $ref errored; the fix did NOT land"
      surface "$pr" "$sha" "blocked" "the fixer committed a fix but \`git push\` to \`$ref\` FAILED — the fix did NOT land (check credentials / branch protection). Nothing was merged." ;;
    NOT_LANDED)
      log "FIXER DID NOT LAND $SLUG#$pr — push reported success but origin/$ref holds ${remote:0:7}, not the fix ${head:0:7}"
      surface "$pr" "$sha" "blocked" "the fixer committed \`${head:0:7}\` and the push reported SUCCESS, but \`origin/$ref\` did not advance to it — the fix did NOT land. A human should check the remote / branch protection." ;;
    LANDED)
      log "FIXER LANDED $SLUG#$pr — ${sha:0:7} → ${head:0:7} pushed to $ref and VERIFIED at origin; the new head re-gates on the host's next sweep" ;;
  esac
}

# Retire superseded PRs (see header RETIRE). Trust anchor: only MERGED superseders are scanned (their
# body AS READ AT SCAN TIME — merged = it passed the click; post-merge body edits are trusted under
# the single-operator + App-token threat model, bounded by the scan-once marker and a reversible,
# audited close), and every declared target must still be an OPEN PR in the SAME repo. The list is
# sorted by UPDATE recency (`sort:updated-desc` — a merge updates the PR), so a long-parked PR that
# merges late still enters the window; plain `gh pr list` would order by CREATION date and miss it.
# Each merged PR is scanned exactly once — the marker is written only after a SUCCESSFUL body fetch,
# so a transient list/body failure retries next sweep. Per-target probes/closes are deliberately
# single-shot (no retry machinery): a transient failure there degrades to the status quo — the
# superseded PR stays open for a human, and the log says RETIRE FAILED, never a false success. An
# issue number or an already-closed target fails the OPEN probe → no-op. REOPEN IS DURABLE: a target
# already carrying a `Poller [retire]:` comment is never closed again (GitHub is the durable record,
# so a human reopen survives even total local-state loss), only re-marked locally.
retire_superseded(){
  local merged m
  merged="$(gh pr list --repo "$SLUG" --state merged --search 'sort:updated-desc' --limit "$RETIRE_LOOKBACK" --json number -q '.[].number' 2>/dev/null)"
  [ -n "$merged" ] || return 0
  for m in $merged; do
    local scanned="$STATE/retire-scan-${m}.done"
    [ -f "$scanned" ] && continue
    local body targets t
    body="$(gh pr view "$m" --repo "$SLUG" --json body -q .body 2>/dev/null)" || continue
    targets="$(printf '%s' "$body" | supersede_targets)"
    : > "$scanned"
    [ -n "$targets" ] || continue
    for t in $targets; do
      [ "$t" = "$m" ] && continue                     # never the superseder itself
      local rmark="$STATE/retired-${t}.done" tstate
      [ -f "$rmark" ] && continue
      tstate="$(gh pr view "$t" --repo "$SLUG" --json state -q .state 2>/dev/null)" || continue
      [ "$tstate" = "OPEN" ] || continue              # not an open PR (issue / closed / merged) → no-op
      # reopen guard: a prior poller retirement on this PR means a HUMAN reopened it — never re-close.
      # FAIL-CLOSED: the comments fetch is rc-checked into a variable — a transient fetch failure
      # SKIPS the close (status quo), it must never bypass the guard. grep reads to EOF (no -q) so a
      # large comment blob can't SIGPIPE the pipeline under pipefail.
      local tcomments
      tcomments="$(gh pr view "$t" --repo "$SLUG" --json comments -q '.comments[].body' 2>/dev/null)" || continue
      if printf '%s' "$tcomments" | grep 'Poller \[retire\]:' >/dev/null; then
        : > "$rmark"; continue
      fi
      if gh pr close "$t" --repo "$SLUG" \
           --comment "**Poller [retire]:** #$m (merged) declares \`Supersedes #$t\` — closing this superseded PR. Deterministic retirement (Step 5); reopen if this was wrong (a reopen is durable — the poller never re-closes a PR carrying this comment)." \
           >/dev/null 2>&1; then
        log "RETIRE $SLUG#$t — closed (superseded by merged #$m)"
        : > "$rmark"
      else
        log "RETIRE FAILED $SLUG#$t (superseded by merged #$m) — close error; single-shot, left open for a human"
      fi
    done
  done
}

# HOST-REFRESH tick (#163) — see the HOST_REFRESH config block above; the design lives in
# bin/host-refresh.sh's header. Called at the END of sweep(), so POLLER_HALTED is THIS tick's halt
# read (filing a redeploy ticket / surfacing a host-apply question is an ACTION — R9 gates it like
# every other action) and no sweep work is in flight. Failures are logged and SWALLOWED: a missed
# scan degrades to the status quo (the monthly workload-refresh timer), never to a stopped loop.
host_refresh_tick(){
  [ "${HOST_REFRESH_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
  HOST_REFRESH_TICKS=$((HOST_REFRESH_TICKS+1))
  [ "$HOST_REFRESH_TICKS" -ge "$HOST_REFRESH_EVERY" ] || return 0
  HOST_REFRESH_TICKS=0
  if [ "${POLLER_HALTED:-0}" = 1 ]; then
    log "host-refresh: R9 HALT — scan skipped this tick (no ticket filed, no comment posted; resumes when the halt clears)"
    return 0
  fi
  "$HOST_REFRESH_SCAN" --once 2>&1 | tee -a "$LOG" >&2 \
    || log "host-refresh: scan failed (continuing — a missed redeploy degrades to the monthly timer)"
  return 0
}

# RECONCILE tick (task #19) — proof-gated closure of backlog issues whose authored PR merged + published
# + went live. Same discipline as host_refresh_tick: END of a tick, R9-halt-gated (a close is an ACTION),
# rate-limited to once per RECONCILE_EVERY sweeps, failures logged + SWALLOWED (a missed close leaves the
# issue OPEN — the safe direction — for the next scan).
reconcile_tick(){
  [ "${RECONCILE_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
  RECONCILE_TICKS=$((RECONCILE_TICKS+1))
  [ "$RECONCILE_TICKS" -ge "$RECONCILE_EVERY" ] || return 0
  RECONCILE_TICKS=0
  if [ "${POLLER_HALTED:-0}" = 1 ]; then
    log "reconcile: R9 HALT — scan skipped this tick (no issue closed; resumes when the halt clears)"
    return 0
  fi
  "$RECONCILE_SCAN" --once 2>&1 | tee -a "$LOG" >&2 \
    || log "reconcile: scan failed (continuing — an unclosed issue stays OPEN for the next scan)"
  return 0
}

# SHIP ACTUATOR tick (R40, 2026-07-27) — the loop closes its OWN objective. Same wiring shape as
# reconcile: once per SHIP_ACTUATOR_EVERY sweeps, R9-halt-gated (running the R34 gate and announcing a
# ship are ACTIONS). Rarer than the others by default because a RUN_GATE costs a model run — but the
# actuator only reaches that branch when the backlog is already empty, and ship-gate.sh is idempotent
# per aggregate sha, so a steady state costs one cheap oracle read per tick. FAIL-SAFE (R39): the
# actuator returns 0 on every internal failure and this call swallows the rest — a ship that cannot be
# announced this tick is announced the next; it can never stall the loop.
ship_actuator_tick(){
  [ "${SHIP_ACTUATOR_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
  SHIP_ACTUATOR_TICKS=$((SHIP_ACTUATOR_TICKS+1))
  [ "$SHIP_ACTUATOR_TICKS" -ge "$SHIP_ACTUATOR_EVERY" ] || return 0
  SHIP_ACTUATOR_TICKS=0
  if [ "${POLLER_HALTED:-0}" = 1 ]; then
    log "ship-actuator: R9 HALT — skipped this tick (no gate run, no ship announced; resumes when the halt clears)"
    return 0
  fi
  "$SHIP_ACTUATOR" "$POLLER_REPO" 2>&1 | tee -a "$LOG" >&2 \
    || log "ship-actuator: tick failed (continuing — the objective simply stays open for the next tick)"
  return 0
}

# DEV-LOOP LAUNCH tick (self-arm, 2026-07-19) — see the DEV_LOOP config block above. Same discipline as
# host_refresh_tick/reconcile_tick: END of a tick, R9-halt-gated (launching a service is an ACTION),
# rate-limited. IDEMPOTENT: launches ONLY when no live dev-loop-service already holds the loop
# (`dev-loop-service.sh --is-live` adjudicates the holder's liveness the #173 way), so a re-tick and the
# entrypoint's own launch never stack a second looping service. DETACHED via setsid into its OWN session
# so it OUTLIVES this poller — including the poller's own self-refresh exit+relaunch (#162), which is the
# whole point: the authoring loop must survive the vehicle that started it. FAIL-SAFE: any failure is
# logged and swallowed (a missed launch degrades to the entrypoint's launch on the next rebuild).
dev_loop_launch_tick(){
  [ "${DEV_LOOP_LAUNCH_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
  DEV_LOOP_LAUNCH_TICKS=$((DEV_LOOP_LAUNCH_TICKS+1))
  [ "$DEV_LOOP_LAUNCH_TICKS" -ge "$DEV_LOOP_LAUNCH_EVERY" ] || return 0
  DEV_LOOP_LAUNCH_TICKS=0
  [ "${DEV_LOOP_ENABLED:-1}" != 0 ] || return 0   # #220 self-arm gate: default ON; explicit =0 disables
  if [ "${POLLER_HALTED:-0}" = 1 ]; then
    log "dev-loop-launch: R9 HALT — not launching the authoring loop this tick (resumes when the halt clears)"
    return 0
  fi
  [ -x "$DEV_LOOP_SERVICE" ] || { log "dev-loop-launch: $DEV_LOOP_SERVICE not executable — skipping (degrades to the entrypoint's launch on the next rebuild)"; return 0; }
  if "$DEV_LOOP_SERVICE" --is-live 2>/dev/null; then
    return 0    # a live authoring loop already holds it — nothing to do (quiet: this is the steady state)
  fi
  log "dev-loop-launch: no live authoring loop — starting dev-loop-service.sh detached (self-arm via the self-refreshing poller, no rebuild)"
  mkdir -p "$(dirname "$DEV_LOOP_SERVICE_LOG")" 2>/dev/null || :
  setsid "$DEV_LOOP_SERVICE" >>"$DEV_LOOP_SERVICE_LOG" 2>&1 </dev/null &
  return 0
}

# REBUILD-REQUEST tick (R17 approval flow, 2026-07-19) — see the REBUILD_REQUEST config block above.
# Same discipline as host_refresh_tick: END of a tick, R9-halt-gated (filing a ticket is an ACTION),
# rate-limited. Fires ONLY while the FLAG file exists; the flag is consumed on a successful filing (rc 0
# = filed or already-open) and KEPT on failure so the next firing retries. FAIL-SAFE: a filing failure
# logs and never stops the loop.
rebuild_request_tick(){
  [ "${REBUILD_REQUEST_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
  REBUILD_REQUEST_TICKS=$((REBUILD_REQUEST_TICKS+1))
  [ "$REBUILD_REQUEST_TICKS" -ge "$REBUILD_REQUEST_EVERY" ] || return 0
  REBUILD_REQUEST_TICKS=0
  [ -e "$REBUILD_REQUEST_FLAG" ] || return 0
  if [ "${POLLER_HALTED:-0}" = 1 ]; then
    log "rebuild-request: R9 HALT — not filing the approval ticket this tick (flag kept; resumes when the halt clears)"
    return 0
  fi
  [ -x "$REBUILD_REQUEST_SCRIPT" ] || { log "rebuild-request: $REBUILD_REQUEST_SCRIPT not executable — skipping (flag kept)"; return 0; }
  if "$REBUILD_REQUEST_SCRIPT" file 2>&1 | tee -a "$LOG" >&2; then
    rm -f "$REBUILD_REQUEST_FLAG" 2>/dev/null || :
    log "rebuild-request: approval ticket filed (or already open) — flag consumed; awaiting the maintainer's approved-label tap"
  else
    log "rebuild-request: filing FAILED — flag kept, retrying next firing"
  fi
  return 0
}

# ORG-WIDE wrapper (P0 uniform loop): one tick sweeps EVERY apparatus repo through the SAME harness,
# re-setting POLLER_REPO/SLUG per repo. sweep_repo() is the original single-repo body unchanged.
#
# R9 FLEET HALT (#151): the fleet-wide stop switch is read ONCE at the TOP of every tick — BEFORE any
# model run is spawned, any merge taken, any retire close, any comment posted (R9's bound is "within
# one sweep"). rc 0 alone means GO; ANY other outcome — a maintainer HALT, an unreadable-signal PAUSE,
# a checker that is missing or crashed — makes the whole tick OBSERVE-ONLY: sweep_repo still enumerates
# and logs what it WOULD do, so the operator sees the queue, but acts on nothing and writes no state
# marker. That is fail-closed TOWARD STOPPING (R9's deliberate inversion of the loop's usual
# fail-safe-toward-progress; the checker itself softens it — one blip PAUSES, only K consecutive
# unreadable reads HALT: bin/fleet-halt.sh). The poller does NOT exit: HALT stops NEW action, not
# running work (in-flight fixer/merge completes; the hard kill is App-key revocation, per R9), and a
# maintainer removing the label resumes action on the very next sweep — no restart, no re-arm.
sweep(){
  local _r _hmsg
  REVIEW_INFRA=""   # reviewer-infra health is a per-SWEEP fact (global across all repos) — re-probed lazily on the first review failure this sweep
  if _hmsg="$("$FLEET_HALT" 2>>"$LOG")"; then
    POLLER_HALTED=0
  else
    POLLER_HALTED=1
    log "FLEET HALT: ${_hmsg:-halt checker unavailable (fail-closed toward stopping)} — OBSERVE-ONLY tick: no fixer, no review, no merge, no retire, no comment"
  fi
  # R16 OPERATING SCOPE (#167): every swept repo is re-checked against the maintainer-confirmed
  # scope EVERY tick, whatever put it in $POLLER_REPOS (env, a stale process, a mutated default).
  # Out of scope ⇒ NO action of any kind — no sweep, no fixer, no review, no merge, no retire —
  # and ONE loud log line. A non-zero rc from the reader (127 included) is never a "go".
  [ -n "${POLLER_REPOS// /}" ] || log "R16 SCOPE: the operating scope resolved EMPTY (config emptied, or reader+config unavailable) — sweeping NOTHING (fail-closed)"
  for _r in $POLLER_REPOS; do
    if ! "$REPO_SCOPE" check "$_r" 2>/dev/null; then
      log "R16 SCOPE: repo '$_r' is NOT in the maintainer-confirmed operating scope (policy/scope.conf) — SKIPPED: no sweep, no fixer, no review, no merge, no retire"
      continue
    fi
    POLLER_REPO="$_r"; SLUG="oso-gato/$_r"; sweep_repo
  done
  host_refresh_tick
  reconcile_tick
  ship_actuator_tick
  dev_loop_launch_tick
  rebuild_request_tick
}
sweep_repo(){
  log "sweep: $SLUG open PRs (armed=$POLLER_ARMED)"
  # R9 HALT (#151): a halted tick retires nothing — a close is an ACTION, reversible or not.
  [ "${POLLER_HALTED:-0}" = 1 ] || retire_superseded
  # BATCHED list: ONE call yields number+ref+sha as TSV — the old per-PR headRefName/headRefOid
  # re-fetches duplicated fields this same list already carried (2 calls/PR saved). Branch names
  # cannot contain tabs, so TSV framing is safe; ref+sha come from the SAME list snapshot as the
  # number (no torn read across a mid-sweep push).
  #
  # author + isDraft ride this SAME call (R39/#278 unenrolled self-heal needs both, and a second list
  # call for two scalars the snapshot already holds would be pure waste).
  #
  # FIELD ORDER IS LOAD-BEARING. `IFS=$'\t' read` COLLAPSES runs of tabs — tab is IFS whitespace — so an
  # EMPTY field in the MIDDLE folds away and slides every later field one slot left (the hazard already
  # documented in bin/dev-loop.sh, where it slid a release count into an empty timestamp's slot). `labels`
  # is empty on most PRs, so it must stay LAST, where a trailing tab is merely stripped and the variable
  # reads empty — exactly as before. The two new fields therefore sit BEFORE it and neither can ever be
  # empty: `.author.login // "-"` has a placeholder for a deleted account, and `.isDraft` is a bare bool.
  local rows
  rows="$(gh pr list --repo "$SLUG" --state open --json number,headRefName,headRefOid,author,isDraft,labels \
          -q '.[] | "\(.number)\t\(.headRefName)\t\(.headRefOid)\t\(.author.login // "-")\t\(.isDraft)\t\([.labels[].name]|join(","))"' 2>/dev/null)" \
    || { log "pr list failed — skipping sweep"; return 0; }
  [ -n "$rows" ] || return 0                       # zero open PRs — quiet (rc 0 distinguishes it)
  # The rows ride FD 3, NOT stdin: loop-body children (the fixer's `claude -p`, fitness-review.sh)
  # may read stdin — off FD 0 they would EAT the remaining rows / hang the sweep. FD 9 is the
  # --watch flock; FD 3 is free.
  local pr ref sha author draft labels comments host tier fit action files fitraw ferr frc nf ef n last now since
  while IFS=$'\t' read -r -u 3 pr ref sha author draft labels; do
    [ -n "$pr" ] || continue
    [ -n "$sha" ] || { log "#$pr: no head sha — skip"; continue; }
    # newest host verdict authored by the trusted host bot ONLY (ignore anyone else) — bound to THIS
    # head's FULL sha, and read from the comment's FIRST LINE only (the machine-owned header carries
    # "<repo> @ <full-sha>"): a fresh, ungated head must never inherit a previous head's GREEN
    # (proven live: #117 read stale GREEN across two pushes), a 7-hex prefix would be grindable, and
    # embedded candidate-log prose must never select or decide (G2, mirrored from auto-merge.sh).
    comments="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body | split(\"\n\")[0] | select(contains(\"@ $sha\"))" 2>/dev/null)"
    host="$(printf '%s' "$comments" | host_verdict)"; host="${host:-NONE}"
    # dedup: act on each (pr,sha,host-verdict) at most once for the terminal actions; REVIEW/FIX manage
    # their own re-entry (fitness marker; progress signature), so only gate the whole sweep-action here.
    local done="$STATE/acted-${pr}-${sha}-${host}.done"
    # TERMINAL-STATE SKIP: once (pr,sha,GREEN) has ACTED (PRESENT posted / dry-run decided / merge
    # attempted), no further action exists for this tuple — the case arms below would only hit
    # their own `[ -f "$done" ] && continue`. Skip the GREEN-moment fetches too, so a PARKED GREEN
    # PR (awaiting the click; dry-run while disarmed) costs ONE comments call per sweep — this is
    # what makes the cost formula above true. A new head sha or verdict keys a NEW marker; a
    # REVIEW-pending PR never holds this marker (fitness re-entry unaffected); FIX never writes it.
    # NB (pre-existing semantics, unchanged): a dry-run marker also blocks a later ARMED merge of
    # the same (pr,sha) — arming re-routes only new heads; part of the #96 flip discussion.
    [ -f "$done" ] && { log "#$pr ${sha:0:7} host=$host — acted, parked"; continue; }
    # BATCHED gate reads: plan() consults tier + fitness ONLY on GREEN — so fetch them ONLY then
    # (a NOOP/RED PR costs exactly one comments call per sweep). Both GREEN-moment fetches are
    # rc-checked and SKIP this PR for THIS sweep on a transient failure (retry next sweep) — they
    # must never misroute: a failed files fetch defaulting to tier=A would PRESENT an
    # auto-mergeable PR and stick via the acted marker; a failed fitness fetch reading as NONE
    # would spuriously re-run the review harness. rc is only distinguishable on an UNPIPED
    # capture, hence the fetch-to-var-then-filter shape.
    tier=""; fit="NONE"
    if [ "$host" = "GREEN" ]; then
      files="$(gh pr view "$pr" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null)" \
        || { log "#$pr: files fetch failed — skip this sweep, retry next"; continue; }
      # newline-TERMINATE the captured paths ($(…) strips the final newline; an unterminated last
      # line would be dropped by a plain while-read gather — the single-file PR would classify
      # from ZERO paths). The [ -n ] guard keeps a zero-file PR fail-closed to A: a bare
      # printf '%s\n' "" would feed one EMPTY line and flip it to all-docs → C.
      tier="$([ -n "$files" ] && printf '%s\n' "$files" | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"
      if [ -n "$FITNESS_LOGIN" ]; then
        # fitness verdicts are also per-head — LINE 1 of the fitness comment carries
        # "… VERDICT X — head <full-sha>" (bin/fitness-review.sh); bind to THIS head's FULL sha on
        # that machine-owned line only, so a stale PASS/RETURN from a previous head — or an anchor
        # planted in the reviewer's rationale prose — never routes the new one.
        fitraw="$(gh pr view "$pr" --repo "$SLUG" --json comments \
               -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body | split(\"\n\")[0] | select(contains(\"head $sha\"))" 2>/dev/null)" \
          || { log "#$pr: fitness-comments fetch failed — skip this sweep, retry next"; continue; }
        fit="$(printf '%s' "$fitraw" | fitness_verdict)"; fit="${fit:-NONE}"
      fi
    fi
    # MOVE 1b (#274): a SKIPPED host verdict is merge-eligible ONLY for a PR that changes nothing the
    # gate exists to validate. Fetch the file list ONLY when it can change the decision (host=SKIPPED),
    # so the common GREEN/RED path costs no extra API call. Unreadable ⇒ treat as GATE-RELEVANT: the
    # fail-safe direction is to withhold the merge, never to grant one on missing evidence.
    local gaterel=0
    if [ "$host" = SKIPPED ]; then
      local _files
      if _files="$(timeout 20 gh pr view "$pr" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null)" \
         && [ -n "$_files" ]; then
        gaterel="$(printf '%s\n' "$_files" | gate_relevant)"
      else
        gaterel=1
        log "#$pr SKIPPED but the changed-file list is UNREADABLE — treating as gate-relevant (fail-safe: no merge on missing evidence)"
      fi
      [ "$gaterel" = 1 ] \
        && log "#$pr host=SKIPPED and the PR touches the image/run/gate contract — NOT merge-eligible; waiting for a base advance to re-gate" \
        || log "#$pr host=SKIPPED and the PR touches nothing the gate validates — NEUTRAL PASS, routing on fitness alone"
    fi
    action="$(plan "$host" "$tier" "$fit" "$POLLER_ARMED" "$gaterel")"
    log "#$pr ${sha:0:7} host=$host tier=$tier fitness=$fit ⇒ $action"
    # R9 HALT (#151): OBSERVE-ONLY — the decision above is LOGGED (the operator sees the queue) but not
    # acted on: no fixer model run, no review model run, no merge, no PRESENT/blocked comment — and no
    # state marker is written, so a halted sweep can never park, dedup or no-progress-signature a PR.
    if [ "${POLLER_HALTED:-0}" = 1 ]; then
      [ "$action" = NOOP ] || log "#$pr ${sha:0:7} HALTED — $action not taken (R9 fleet HALT; resumes the sweep after the halt clears)"
      continue
    fi
    case "$action" in
      NOOP)
        # R18 IDLE-WITH-WORK-PENDING (kd#23; audit 2026-07-18 CAT-42/01). host=NONE means no host verdict
        # yet. For a live-validate-LABELLED head that has sat here past POLLER_STALL_MAX, the gate has
        # almost certainly SKIPPED this sha (a stale host .done marker, or a transient fetch-failure
        # deduped as delivered) and will NOT re-gate on its own — SURFACE it once rather than NOOP
        # forever. Age = the head commit's committer date (GitHub truth). One `gh api` per stuck head
        # until surfaced, then the surface marker suppresses it. An UNLABELLED head is no longer a quiet NOOP —
        # it takes the self-heal arm below (R39/#278), because unlabelled means the gate will never look.
        case ",$labels," in
          *,live-validate,*)
            [ -f "$STATE/surfaced-${pr}-${sha}-stalled.done" ] && continue
            local cdate age
            cdate="$(timeout 20 gh api "repos/$SLUG/commits/$sha" -q '.commit.committer.date' 2>/dev/null)"
            [ -n "$cdate" ] || continue
            age=$(( $(date +%s) - $(date -d "$cdate" +%s 2>/dev/null || echo 0) ))
            if [ "$(stall_verdict NONE 1 "$age" "$POLLER_STALL_MAX")" = STALL ]; then
              # R39/#278 — REPAIR FIRST. A head the host gate will never re-verdict is the archetypal
              # stuck pipeline, and its own remediation text names an act the fixer can perform: push a
              # new commit, which mints a head the gate has no `.done` marker for. Bounded twice over —
              # POLLER_REPAIR_MAX attempts, and run_fixer's no-progress stop if a repair changes nothing.
              surface_or_repair "$pr" "$ref" "$sha" "stalled" "this \`live-validate\`-labelled head has had NO host live-gate verdict for ~$((age/60))m (surfacing bound $((POLLER_STALL_MAX/60))m). The host gate produced no GREEN/RED for \`${sha:0:7}\` and will not re-gate on its own — most likely it SKIPPED this sha (a stale per-(repo,sha) \`.done\` marker on the host, or a transient PR-head fetch-failure deduped as a delivered SKIP; audit CAT-01/CAT-04). REMEDIATION: on the host, remove \`~/.local/state/live-gate/$(basename "$SLUG")-${sha}.done\` to force a re-gate, or push a new commit. (R18 idle-with-work-pending — the poller had been silently NOOPing on this since the head was pushed.)"
            fi
            ;;
          *)
            # R39/#278 — UNENROLLED-PR SELF-HEAL. host=NONE on an UNLABELLED PR is not "the gate has not
            # got to it yet": the gate discovers work by this label alone, so it will never look. The old
            # comment above called this "a quiet NOOP" — quiet is precisely the defect, and it is the same
            # shape as every other #278 stall (a state with no rule, answered by silence). See enroll_pr:
            # dev-authored only (never a foreign contributor's PR), never a draft (dev-author opens draft →
            # ready → label, so a draft is mid-authoring, not forgotten), one shot per PR.
            # NORMALISE THE AUTHOR BEFORE COMPARING (bin/objective-status.sh does the same, for the same
            # reason): gh renders an App author as `app/<login>`, and some paths append `[bot]`. Every PR
            # this self-heal exists for is App-authored, so a raw `=` against DEV_LOGIN would match NONE
            # of them — the feature would ship green, dead, and silent, which is the #278 defect itself.
            local pauthor="${author#app/}"; pauthor="${pauthor%\[bot\]}"
            [ "$pauthor" = "$DEV_LOGIN" ] || continue
            [ "$draft" = false ] || continue
            enroll_pr "$pr" "$ref" "$sha" || true
            ;;
        esac
        ;;
      FIX)
        # R6 — FINDINGS ARE GENERATIVE. plan() routes FIX from TWO causes; derive the reason from the one
        # that ACTUALLY fired, and in BOTH cases from that gate's OWN COMMENT BODY.
        #
        # TRUST BOUNDARY (G2), and it holds for both arms: the VERDICT is read from LINE 1 ONLY (the
        # machine-owned header, sha-bound — that is what routed us here and what $comments holds). The
        # fetches below pull the gate's FULL comment body purely as PROMPT material for the fixer, bound
        # to THIS head's sha + that gate's own login, so prose can never flip a gate — it can only say
        # what to fix, and a stale verdict's text can never drive a fresh head.
        #
        # NB the reason CANNOT come from $comments: that stream is line-1-only (see the sha-binding
        # fetch above), so grepping it yields the verdict HEADER and never the failure detail. That was
        # the whole defect — a fitness RETURN found no host 'VERDICT RED' line at all and fell back to a
        # canned "host live-gate RED" (sending the fixer after a build failure that never happened),
        # while a host RED handed the fixer its own verdict token and called it "the findings".
        local cause reason; cause="$(fix_cause "$host" "$fit")"
        case "$cause" in
          HOST)
            # `contains`, NOT `startswith`: the host header is markdown-bold (`**Host live-gate …**`),
            # so a startswith("Host live-gate") match silently returns EMPTY. Verified against the live
            # comment. The candidate log's failure detail sits at the END of the body → tail, not head.
            reason="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                       -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body
                           | select(split(\"\n\")[0] | contains(\"@ $sha\") and contains(\"VERDICT RED\"))" \
                       2>/dev/null | tail -c 6000)"
            reason="${reason:-the host live-gate reported RED; see the host verdict comment on the PR}" ;;
          FITNESS)
            reason="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                       -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body
                           | select(startswith(\"Fitness review: VERDICT RETURN\")) | select(contains(\"head $sha\"))" \
                       2>/dev/null | head -c 6000)"
            reason="${reason:-the independent fitness review RETURNed this head; see its verdict comment on the PR}" ;;
          *)
            # R39/#278 — the PUREST unanticipated state there is: plan() routed FIX, so a gate DID fail,
            # yet neither gate's comment body can be read to say which. The poller still refuses to
            # INVENT a reason (the #135 R6 rule that stops the fixer hunting a failure that never
            # happened) — it hands the model the TRUE one: the pipeline disagrees with itself, here are
            # the raw verdict tokens, diagnose from the repo. INFRA/spent still reach the maintainer.
            log "#$pr: FIX routed with no known cause (host=$host fitness=$fit) — refusing to invent a reason; routing to bounded self-repair"
            surface_or_repair "$pr" "$ref" "$sha" "blocked" "the poller routed this PR to the fixer but cannot tell which gate failed (host=$host, fitness=$fit): plan() saw a failing gate, but neither the host nor the fitness comment body for \`${sha:0:7}\` could be read to say which. No gate reason is being invented here — that is the whole finding."
            continue ;;
        esac
        run_fixer "$pr" "$ref" "$sha" "$cause" "$reason"
        ;;
      REVIEW)
        [ -f "$done" ] && continue
        # GLOBAL REVIEW-INFRA GATE (2026-07-20): once this sweep has found the reviewer infra DOWN (a
        # global `claude -p` outage), skip WITHOUT running the expensive, doomed review — no strike, no
        # question. It self-heals next sweep the moment the probe passes (see review_infra_ok).
        if [ "$REVIEW_INFRA" = down ]; then
          log "#$pr fitness review SKIPPED @ ${sha:0:7} — reviewer infra is down this sweep (paused; auto-resumes when \`claude -p\` recovers)"
          continue
        fi
        # BOUNDED RETRY, THEN A QUESTION (#156). rc 3 says "no verdict for this head" and CANNOT say
        # whether the cause is permanent or transient (see review_due), so we do neither of the two
        # wrong things: we do not re-spin every sweep, and we do not park a host-GREEN PR forever on one
        # model-API blip. State is per-(pr,sha) — a new head starts clean, with no attempt to carry.
        nf="$STATE/reviewfail-${pr}-${sha}.n"; ef="$STATE/reviewfail-${pr}-${sha}.err"
        n=0; last=0; [ -f "$nf" ] && read -r n last < "$nf"
        case "$n"    in ''|*[!0-9]*) n=0;;    esac      # a corrupt/truncated marker must never abort
        case "$last" in ''|*[!0-9]*) last=0;; esac      # the sweep on arithmetic — start clean instead
        now="$(date +%s)"; since=$(( now - last ))
        case "$(review_due "$n" "$since" "$FITNESS_REVIEW_TRIES" "$FITNESS_RETRY_BACKOFF")" in
          PARKED)
            # The tries are spent and the question is asked. Re-assert it (idempotent; re-posts only if
            # the earlier post FAILED) and spend no model run. The PR is NOT parked on $done — a verdict
            # posted by hand still routes on the next sweep (see review_question).
            review_question "$pr" "$sha" "$n" "$(cat "$ef" 2>/dev/null)"
            log "#$pr fitness review PARKED @ ${sha:0:7} — $n failed attempts, question asked; not re-running the reviewer on this head"
            continue ;;
          WAIT)
            log "#$pr fitness review failed $n/$FITNESS_REVIEW_TRIES @ ${sha:0:7} — backing off (${since}s of ${FITNESS_RETRY_BACKOFF}s) before the next attempt"
            continue ;;
        esac
        log "#$pr GREEN + unreviewed → running fitness harness (attempt $((n+1))/$FITNESS_REVIEW_TRIES)"
        # Its STDOUT goes to the log; its STDERR is CAPTURED — that is where the harness reports the
        # REAL cause of a failed review (#155 R2), and a surfaced question that carries the cause beats
        # one that shrugs. rc is the harness's own (no pipe), and it is a CONTRACT (fitness-review.sh
        # header): 0 = verdict posted; 3 = the reviewer could not be RUN / emitted no verdict for THIS
        # head; anything else = a precondition refused it (retryable — the state can change on its own).
        ferr="$(FITNESS_LOGIN="$FITNESS_LOGIN" LG_HOST_LOGIN="$LG_HOST_LOGIN" \
                "$FITNESS_REVIEW" --post "$POLLER_REPO" "$pr" 2>&1 >>"$LOG")"; frc=$?
        case "$frc" in
          0) rm -f "$nf" "$ef"; infra_recovered; log "#$pr fitness posted — next sweep routes on it" ;;
          3)
            # DISAMBIGUATE GLOBAL vs PER-HEAD (2026-07-20). rc 3 = "no verdict for this head". A CHEAP probe
            # tells which: infra DOWN ⇒ this is a GLOBAL outage — do NOT strike this head, PAUSE the arm
            # (the rest of this sweep's reviews skip; it self-heals next sweep), surface only if it
            # persists; infra UP ⇒ genuinely PER-HEAD ⇒ the bounded retry + surface (#156), now correct.
            if ! review_infra_ok; then
              infra_down_note "$pr" "$sha"     # global: track the down-streak, surface ONCE only if persistent
              continue                          # NO strike — the head re-reviews once claude -p is back
            fi
            infra_recovered                     # the probe passed ⇒ infra is up; clear any down-streak
            # PER-HEAD: infra is up but THIS review failed. NEVER SPIN SILENTLY (#155 R4), NEVER STRAND ON
            # ONE BLIP (#156): count it, keep the cause, retry while tries remain, ask ONCE when they run out.
            n=$((n+1)); printf '%s %s\n' "$n" "$now" > "$nf"; printf '%s' "$ferr" > "$ef"
            printf '%s\n' "$ferr" >> "$LOG"
            if [ "$n" -ge "$FITNESS_REVIEW_TRIES" ]; then
              log "#$pr fitness reviewer COULD NOT PRODUCE A VERDICT @ ${sha:0:7} (rc=3, attempt $n/$FITNESS_REVIEW_TRIES — EXHAUSTED; infra UP ⇒ per-head) — surfacing the real cause; a new commit or a fix recovers it"
              review_question "$pr" "$sha" "$n" "$ferr"
            else
              log "#$pr fitness reviewer produced no verdict @ ${sha:0:7} (rc=3, attempt $n/$FITNESS_REVIEW_TRIES; infra UP ⇒ per-head) — retrying in ≥${FITNESS_RETRY_BACKOFF}s"
            fi ;;
          *)
            # RETRYABLE — but NOT SILENT. Capturing the harness's stderr and then DROPPING it makes the
            # one path that REPEATS FOREVER the only one that never says WHY. A precondition refusal is
            # not always self-healing (an unset FITNESS_LOGIN, no --post token, an SoD misconfig refuses
            # identically every sweep), and before its stderr was captured it at least reached the
            # service log. So it still does: the reason rides `log` (state file + stderr → the journal),
            # the same channel every other outcome here reports on. A harness whose thesis is that the
            # failure report tells the truth must not go quiet on its loudest loop.
            log "#$pr fitness harness declined (rc=$frc — a precondition, retryable; fail-closed: no PASS ⇒ no merge)"
            [ -n "$ferr" ] && log "#$pr fitness harness reported: $(printf '%s' "$ferr" | tr '\n' ' ' | tail -c 500)"
            ;;
        esac
        ;;
      MERGE|MERGE_DRYRUN)
        [ -f "$done" ] && continue
        local flag=""; [ "$action" = MERGE ] && flag="--commit"
        log "#$pr GREEN+B/C+PASS → auto-merge.sh $flag"
        # DISTINGUISH auto-merge's exit codes so a benign serialized merge-CONFLICT (rc 2 — the PR is
        # behind main / conflicts and just needs a REBASE) is NEVER mislabelled as a merge-trust REFUSAL
        # (rc 1 — the boundary actually disagrees: misconfigured anchors, same-identity while armed, or a
        # gate its stricter parse rejects). Crying "trust boundary broke" at a routine rebase is
        # alarm-fatigue on the ONE signal class that must stay meaningful. rc 3 = a non-gate merge-command
        # failure (transient GitHub error / head moved / a BLOCKED mergeStateStatus, which the classifier
        # folds here too) and deliberately does NOT write the acted marker: that marker is this arm's own
        # terminal-state skip ([ -f "$done" ] && continue above), so parking on it would strand a
        # host-GREEN + fitness-PASS PR on a single blip with NOTHING left to re-invoke the merge — the
        # #156 stranding class, under a comment claiming it retries. The retry is real and cheap: one
        # plain-shell auto-merge per sweep (no model run), until it lands, the head moves (a new head
        # re-gates itself), or a real refusal re-routes it; surface() keeps the operator comment at ONE
        # per (head,kind). The rc-2 and refused arms DO park — a conflicted head only merges via a rebase
        # push (a NEW head, which re-gates), and a refusal needs a human — each gating its marker on
        # surface()'s own POST success, so a throttled comment cannot silence the touchpoint.
        LG_HOST_LOGIN="$LG_HOST_LOGIN" FITNESS_LOGIN="$FITNESS_LOGIN" "$HERE/auto-merge.sh" $flag "$POLLER_REPO" "$pr" 2>&1 | tee -a "$LOG"
        local amrc=${PIPESTATUS[0]}
        case "$amrc" in
          0) : > "$done"; rm -f "$STATE/rebase-${pr}.n" ;;   # merged → clear the auto-rebase counter
          4) # TRINITY / MAINTAINER-MERGE hold (R1): auto-merge refuses to autonomously merge a
             # confirmed-spec change and has assigned + labelled it for the maintainer. Park QUIETLY —
             # this is an EXPECTED, correct hold, NOT the trust-boundary 'refused' alarm (the `*)` arm).
             log "#$pr ${sha:0:7} — MAINTAINER-MERGE hold (touches the Trinity/GOVERNANCE, R1): assigned to the maintainer for an explicit merge, parked"
             : > "$done" ;;
          2)  # CAT-17: OWN the mechanical rebase of a GREEN+PASS PR merely behind main — do NOT park it.
              # `gh pr update-branch` server-side-merges main into the PR branch (NO local clone touched,
              # unlike the fixer): CLEAN behind → succeeds, minting a NEW head that re-gates (PROGRESS,
              # not parked); a genuine CONFLICT → fails → surface + park (a human resolves). Bounded by
              # rebase_due so a head that keeps falling behind can't churn forever.
              local rn="$STATE/rebase-${pr}.n" rc_n=0; [ -f "$rn" ] && read -r rc_n < "$rn"
              case "$rc_n" in ''|*[!0-9]*) rc_n=0;; esac
              if [ "$(rebase_due "$rc_n" "$POLLER_REBASE_MAX")" = TRY ] \
                 && gh pr update-branch "$pr" --repo "$POLLER_REPO" >/dev/null 2>&1; then
                echo $((rc_n+1)) > "$rn"
                log "#$pr auto-rebased onto main (behind, clean) — attempt $((rc_n+1))/$POLLER_REBASE_MAX; the new head re-gates, NOT parked (CAT-17)"
              else
                # R39/#278 — a genuine merge CONFLICT is a stuck pipeline the model can actually clear
                # (resolving a conflict on the PR's own branch is ordinary dev work), so try bounded
                # repair before spending the human. PARKING IS GATED ON THE ROAD TAKEN: a REPAIR mints a
                # new head that re-gates, so parking it would strand the PR the repair just unstuck —
                # only a surfaced (INFRA/spent) outcome parks, and then still only on a SUCCESSFUL post.
                if surface_or_repair "$pr" "$ref" "$sha" "rebase" "auto-merge could not merge (behind \`main\` / conflict), and the poller's bounded auto-rebase then $( [ "$(rebase_due "$rc_n" "$POLLER_REBASE_MAX")" = GIVEUP ] && echo "hit its bound ($POLLER_REBASE_MAX attempts) — the head keeps falling behind" || echo "could not update-branch — likely a genuine merge CONFLICT to resolve by hand"). All gates were GREEN+PASS; NOT a merge-trust refusal. Rebase + push and it re-gates and auto-merges." \
                   && [ "$SOR_ROUTE" != REPAIR ]; then : > "$done"; fi
              fi
              ;;
          3) surface "$pr" "$sha" "merge-failed" "auto-merge's merge command failed for a non-gate reason (transient / the head moved) — NOT a merge-trust refusal. The poller keeps retrying the merge every sweep until it lands or the head moves (this comment posts once; see poller.log)." ;;
          *) surface "$pr" "$sha" "refused" "auto-merge REFUSED despite GREEN+PASS routing — the MERGE-TRUST boundary disagrees with the poller's reads (misconfigured anchors, same-identity while armed, or a gate its stricter parse rejects). INVESTIGATE (see poller.log)." \
               && : > "$done" ;;
        esac
        ;;
      PRESENT)
        # the acted marker is gated on surface()'s rc: a FAILED comment POST must NOT park the
        # tuple (the terminal-state skip would otherwise silence the human touchpoint forever
        # after one throttled POST — comment CREATION rate-limits while reads still succeed).
        # surface() returns 0 on its already-surfaced early-exit, so idempotence is preserved.
        surface "$pr" "$sha" "review" "GREEN PR needs your decision (tier=$tier, fitness=$fit). Present for a clickable merge — the poller does not auto-merge this." \
          && : > "$done"
        ;;
    esac
  done 3<<< "$rows"
}

# self_refresh_check — the SELF-REFRESH I/O (#162). Called at a SAFE POINT (the top of the --watch loop,
# between sweeps). Fetches (bounded + fail-safe), then refresh_decision() says whether to step aside.
# Returns 0 to CONTINUE the loop unchanged; returns POLLER_RELOAD_RC to ask --watch to exit for a
# supervised reload. It NEVER writes the clone — the ff-pull is poller-service.sh's job (req 4). Every
# failure path (off, not-a-clone, fetch failure, dirty, diverged) returns 0 and LEAVES THE POLLER RUNNING
# UNCHANGED (req 3): a refresh that cannot happen must never stop the loop. The staleness baseline is
# $LAUNCH_HEAD (#170) — what this PROCESS runs — never the clone's momentary HEAD (a false proxy the
# moment anything else pulls the clone); only cleanliness/divergence are re-read from the clone here.
self_refresh_check(){
  [ "$SELF_REFRESH" = 1 ] || return 0
  local clone="$SELF_REFRESH_CLONE"
  [ -d "$clone/.git" ] || return 0                        # not a git clone → nothing to refresh
  local running origin clean desc
  running="$LAUNCH_HEAD"                                  # the code THIS process runs (#170) — NEVER
                                                          # `git rev-parse HEAD` (see LAUNCH_HEAD above)
  if ! timeout "$SELF_REFRESH_FETCH_TIMEOUT" git -C "$clone" fetch -q "$SELF_REFRESH_REMOTE" 2>>"$LOG"; then
    log "self-refresh: git fetch ($SELF_REFRESH_REMOTE) FAILED — leaving the running poller unchanged (fail-safe toward progress)"
    return 0
  fi
  origin="$(git -C "$clone" rev-parse "refs/remotes/$SELF_REFRESH_REMOTE/$SELF_REFRESH_BRANCH" 2>/dev/null)"
  if [ -z "$(git -C "$clone" status --porcelain 2>/dev/null)" ]; then clean=1; else clean=0; fi
  git -C "$clone" merge-base --is-ancestor "$running" "$origin" 2>/dev/null && desc=1 || desc=0
  case "$(refresh_decision "$clean" "$running" "$origin" "$desc")" in
    RELOAD)
      log "self-refresh: origin/$SELF_REFRESH_BRANCH advanced ${running:0:7} (launched) → ${origin:0:7} — stepping aside at a safe point for a supervised reload"
      return "$POLLER_RELOAD_RC" ;;
    DIRTY)
      log "self-refresh: clone $clone is DIRTY (locally modified) — left untouched, poller stays on ${running:0:7} (a human edited it; not clobbering)" ;;
    DIVERGED)
      log "self-refresh: clone $clone DIVERGED from origin/$SELF_REFRESH_BRANCH (not a fast-forward) — left untouched, poller stays on ${running:0:7}" ;;
    NOFETCH)
      log "self-refresh: could not resolve origin/$SELF_REFRESH_BRANCH after fetch — leaving the poller unchanged" ;;
    UPTODATE) : ;;                                         # already current → silent no-op (req 5)
  esac
  return 0
}

case "${1:-}" in
  --once) sweep;;
  --self-refresh-check)                                    # test seam (#162): run ONE self-refresh check
    self_refresh_check; exit $?;;                          # exit 0 = continue, POLLER_RELOAD_RC = reload
                                                           # (#170: POLLER_LAUNCH_HEAD injects the launch
                                                           # head — a fresh process's capture would equal
                                                           # the clone HEAD, hiding exactly the defect)
  --watch)
    # #173 — ADJUDICATED singleton: a dead/foreign-generation holder's lingering flock is TAKEN OVER;
    # only a POSITIVELY-live same-generation holder defers a start — loudly, rc=POLLER_DEFER_RC, never
    # 0 (the bare `flock -n || exit 0` read a box-recreate orphan as a healthy peer: 4 h of silent
    # no-op, 2026-07-13). lock_acquire returns holding fd 9, or exits via lock_defer.
    lock_acquire
    trap 'log "poller stopping (signal)"; exit 0' TERM INT HUP
    log "pr-poller --watch up (repo=$SLUG interval=${POLL_INTERVAL}s armed=$POLLER_ARMED self-refresh=$SELF_REFRESH every=${SELF_REFRESH_EVERY} sweeps running=${LAUNCH_HEAD:0:7})"
    sweeps=0
    while :; do
      # GENERATION FENCE (2026-07-28) — FIRST, and before any work. The box can be REBUILT underneath a
      # running poller: the old container is torn down while this process keeps executing against its
      # destroyed rootfs. Anything already resolved keeps working (bash, date, grep) and anything looked
      # up fresh does not — `gh` vanishes with the deleted upper layer. The poller then sweeps forever,
      # fails every call, and looks perfectly healthy: process alive, log advancing, clone not behind.
      # That state stood for SIX DAYS and self-inflicted a fleet-wide R9 HALT (fleet-halt.sh reads its
      # signal only through `gh api`), which then gated the very ticket that could have repaired the box.
      # Exiting is the ONLY correct move — the supervisor cannot relaunch us into the live box until we
      # let go. Advisory by construction: box-generation.sh returns 0 on ANY uncertainty, so an
      # unstamped or unreadable box can never be killed by this.
      if [ -x "$BOX_GENERATION" ] && ! "$BOX_GENERATION" check; then
        log "GENERATION-ORPHAN — running in a container that is no longer live; exiting rc=$POLLER_ORPHAN_RC for a supervised relaunch in the LIVE box"
        exit "$POLLER_ORPHAN_RC"
      fi
      # SELF-REFRESH (#162) AT A SAFE POINT. This check sits at the TOP of the loop, OUTSIDE sweep(), so
      # it can only fire BETWEEN sweeps — never mid-fixer/review/merge (all synchronous inside sweep(), so
      # "never mid-sweep" IS "never mid-fixer"). Rate-limited to once per SELF_REFRESH_EVERY sweeps (req
      # 5). The counter starts at 0, so the FIRST check is SELF_REFRESH_EVERY sweeps in — after a
      # supervised relaunch that keeps a (rare) failed ff-pull from re-exiting immediately: real work
      # runs before the loop re-checks, so a stuck refresh is bounded to once per N sweeps, never a spin.
      sweeps=$((sweeps+1))
      if [ "$sweeps" -ge "$SELF_REFRESH_EVERY" ]; then
        sweeps=0
        self_refresh_check; rc=$?
        if [ "$rc" = "$POLLER_RELOAD_RC" ]; then
          log "self-refresh: exiting for a supervised reload (rc=$rc) — poller-service.sh will ff-pull + relaunch on the new code"
          exit "$POLLER_RELOAD_RC"
        fi
      fi
      sweep || log "sweep error (continuing)"
      sleep "$POLL_INTERVAL"
    done
    ;;
  *) echo "usage: pr-poller.sh --once | --watch | --self-refresh-check | --selftest" >&2; exit 2;;
esac
