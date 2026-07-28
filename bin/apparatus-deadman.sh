#!/usr/bin/env bash
# apparatus-deadman.sh — the APPARATUS LIVENESS DEADMAN (R18 — liveness / stall detection).
#
# WHY THIS EXISTS: the self-sustaining dev loop can STALL SILENTLY, and twice a stall was caught only
# because a HUMAN happened to notice — (1) a self-refresh wedged for an hour because the live clone was
# DIRTY so it could never fast-forward, and (2) a PR merged to `main` but nobody confirmed the running
# apparatus actually picked the new code up. Neither the poller nor its supervisor can be trusted to
# report their OWN death, so this is an INDEPENDENT watcher: it runs as its own supervised process
# (entrypoint.sh launches it beside — never inside — the poller), reads LIVE FACTS every check (never
# memory), and SURFACES anomalies on its own so no human and no agent has to remember to look.
#
# THE CLONE IS NEVER PULLED / MERGED / CHECKED-OUT / RESET by this watcher — the ONLY writer of the
# clone is poller-service.sh. It gets the true origin tip from `git ls-remote` (authoritative, writes
# NOTHING) and uses a bounded `git fetch` ONLY to bring objects local for the behind-COUNT — fetch
# touches remote-tracking refs, never HEAD / index / the working tree. Every git/gh call is
# `timeout`-bounded so the watcher itself can never hang. Tooling: coreutils + git + gh only (no
# diff/cmp/awk/sed).
#
# THE AUTONOMOUS RESPONDER (R18 recovery arm). `--check` is READ-ONLY, ALWAYS — a pure diagnostic that
# mutates nothing (set DEADMAN_RESPOND=1 to opt a --check into responding, for tests). Only the active
# `--watch` loop RESPONDS: on each anomaly it detects, BEFORE surfacing, it attempts a DETERMINISTIC,
# IDEMPOTENT, NEVER-DESTRUCTIVE recovery within a tight envelope, and refuses-and-surfaces anything it
# is not certain is safe. The pure decision core is respond_plan(); the I/O layer performs the action:
#   * SELF_REFRESH_BLOCKED (dirty+behind) — if EVERY dirty entry is UNTRACKED (`??`), QUARANTINE the
#     strays (mv into $DEADMAN_STATE/deadman-quarantine/<ts>/, path preserved — NEVER rm, NEVER
#     git clean) so the clone goes clean and self-refresh can ff. If ANY entry is a TRACKED change
#     (a real edit may be intentional) — or the paths are not cleanly nameable — it TOUCHES NOTHING
#     and SURFACES. The clone's HEAD, index and tracked files are never written; no pull/merge/reset.
#   * POLLER_FROZEN — send ONE SIGTERM to the wedged poller (identified via the SAME self-match-safe
#     poller_pids detection, never a loose string; never our own pid, never a stranger). It traps TERM,
#     exits cleanly, its supervisor relaunches it, work resumes from GitHub (idempotent).
#   * POLLER_DOWN — hold ONE grace window for the supervisor to relaunch (the responder never launches
#     supervision itself); still down next check ⇒ SURFACE.
#   * MERGED_NOT_LIVE (clean clone) — self-refresh (the single writer) owns the pull; the responder must
#     NOT pull ⇒ SURFACE as unexplained.
# IDEMPOTENT + ESCALATING: the responder acts AT MOST ONCE per distinct anomaly occurrence (a $STATE
# marker keyed to the anomaly token, cleared when that anomaly is no longer present / the loop is
# healthy). Finding the SAME anomaly STILL present after it already acted is NOT a re-act — it ESCALATES
# (surfaces loudly that auto-recovery was attempted and did not clear it). Never loop-acts. Every
# recovery action is logged AND noted on the surfaced/updated alarm issue (audit).
#
# THE FIVE ANOMALIES (the DECISION is the pure, --selftest-covered deadman_verdict; the facts are
# gathered separately by the I/O layer):
#   1. MERGED-NOT-LIVE  — the clone HEAD trails origin/main by >=1 for longer than DEADMAN_LAG_MAX checks
#                         (a clean clone lagging past the transient post-merge window).
#   2. SELF-REFRESH BLOCKED — the clone trails origin AND is DIRTY: it will NEVER ff until cleaned. The
#                         exact hour-long stall. Fires immediately (a dirty+behind clone is deterministically
#                         wedged; waiting the grace window cannot help it).
#   3. POLLER FROZEN    — a poller process EXISTS but its log mtime has not advanced within DEADMAN_SWEEP_MAX
#                         (alive but not sweeping).
#   4. POLLER DOWN      — no `pr-poller.sh --watch` process at all, while one is expected (DEADMAN_EXPECT_POLLER).
#   5. FITNESS TOKEN STALE — the ferried fitness token ($DEADMAN_FITNESS_ENV) has not re-minted past
#                         DEADMAN_FITNESS_STALE_MAX: the entrypoint ferry has stalled, so fitness-review
#                         cannot post as the DISTINCT fitness App and auto-merge refuses every PR — a
#                         SILENT merge stall no other check catches (the poller keeps sweeping, so
#                         POLLER-FROZEN never fires). ABSENT is NOT alarmed (a make-it-work box legitimately
#                         has none). Its verdict is the separate pure `fitness_token_verdict` (appended to
#                         the deadman_verdict token stream); it SURFACEs (no in-box fix — the fitness KEY
#                         never enters the box).
#
# FAIL DIRECTION — BIAS TOWARD SURFACING. A signal that cannot be READ (git/gh/timeout failure) is itself
# suspicious: after DEADMAN_UNREADABLE_MAX consecutive unreadable checks the deadman surfaces
# "cannot verify liveness" rather than silently passing. A single blip stays quiet (grace) but NEVER
# clears a standing anomaly — only a clean, readable, healthy check clears.
#
# SELF-MATCH SAFETY (non-negotiable — 5 prior self-match incidents in this codebase: probe pids/binaries,
# never a loose string). Poller detection scans /proc directly (no pgrep dependency) and CONFIRMS each
# candidate: it skips this deadman's OWN pid, its parent, any grep/pgrep matcher, and anything carrying
# our own name; a GENUINE poller is one running the real SCRIPT PATH (".../pr-poller.sh … --watch",
# slash-anchored) — a shell / decoy / self carrying only the bare string fails that anchor.
#
# SURFACE durably + dedup + quiet-when-healthy. On anomaly: create-or-update ONE issue in the control
# repo (DEADMAN_REPO), discovered BY TITLE (a fixed prefix, like fleet-halt — no hardcoded number); the
# body lists the current anomalies + a timestamp and is UPDATED in place on repeat (never spammed). When
# a later check is healthy: post a "cleared" comment + close it. While healthy the deadman makes NO gh
# writes and logs minimally. Dedup state is a single idempotent marker ($DEADMAN_STATE/anomaly.open) plus
# the by-title discovery, so a wiped box never double-files.
#
#   apparatus-deadman.sh --check     one-shot READ-ONLY diagnostic: print verdict + reasons; rc 0 =
#                                    healthy, non-zero = anomaly. Does NOT respond (mutates nothing)
#                                    unless DEADMAN_RESPOND=1 is set (the test seam).
#   apparatus-deadman.sh --watch     loop every DEADMAN_INTERVAL, RESPONDING to + surfacing/clearing
#                                    anomalies as it goes (the autonomous responder is active here).
#   apparatus-deadman.sh --selftest  exercise the pure core (streak_next, deadman_verdict, fitness_token_verdict, dirty_class,
#                                    respond_plan); no git/gh/net.
#
# ENV (all defaulted): DEADMAN_REPO (oso-gato/fedora-bootstrap) · DEADMAN_TITLE ("APPARATUS LIVENESS
# DEADMAN" — the discovery prefix) · DEADMAN_INTERVAL (120s) · DEADMAN_LAG_MAX (3 checks) ·
# DEADMAN_SWEEP_MAX (300s) · DEADMAN_UNREADABLE_MAX (3) · DEADMAN_EXPECT_POLLER (1) · DEADMAN_CLONE (the
# live clone, one level up from bin/) · DEADMAN_REMOTE/BRANCH (origin/main) · DEADMAN_POLLER_LOG
# (~/.local/state/pr-poller/poller.log) · DEADMAN_POLLER_NAME (pr-poller.sh — the script basename to
# match) · DEADMAN_STATE (~/.local/state/apparatus-deadman) · DEADMAN_GIT_TIMEOUT / DEADMAN_GH_TIMEOUT (30s)
# · DEADMAN_RESPOND (0 — set 1 to make --check respond; --watch always responds).
set -uo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
DEADMAN_REPO="${DEADMAN_REPO:-oso-gato/fedora-bootstrap}"
DEADMAN_TITLE="${DEADMAN_TITLE:-APPARATUS LIVENESS DEADMAN}"
DEADMAN_INTERVAL="${DEADMAN_INTERVAL:-120}"
DEADMAN_LAG_MAX="${DEADMAN_LAG_MAX:-3}"                 # consecutive behind-checks before merged-not-live fires
DEADMAN_SWEEP_MAX="${DEADMAN_SWEEP_MAX:-300}"          # seconds the poller log may be stale before FROZEN
DEADMAN_UNREADABLE_MAX="${DEADMAN_UNREADABLE_MAX:-3}"  # consecutive unreadable checks before CANNOT_VERIFY
DEADMAN_EXPECT_POLLER="${DEADMAN_EXPECT_POLLER:-1}"    # 1 = a poller SHOULD be running (alarm when absent)
DEADMAN_CLONE="${DEADMAN_CLONE:-$(dirname "$HERE")}"   # bin/ sits inside the live clone
DEADMAN_REMOTE="${DEADMAN_REMOTE:-origin}"
# WORK-PROGRESS axis (R18 IDLE-WITH-WORK-PENDING, 2026-07-28). How long open work may sit with NO state
# change before it is an alarm. 0 disables.
DEADMAN_WORK_STALL_MAX="${DEADMAN_WORK_STALL_MAX:-2700}"   # 45 min
DEADMAN_WORK_REPOS="${DEADMAN_WORK_REPOS:-}"               # default: the R16 installed set
DEADMAN_BRANCH="${DEADMAN_BRANCH:-main}"
# @mention the maintainer at the TOP of the anomaly-issue BODY → when the issue is OPENED, GitHub
# push-notifies that user, so the GitHub MOBILE APP (with "Direct Mentions" push on) rings the phone —
# the same mechanism rebuild-request.sh uses for the rebuild-approval ticket. Set empty to disable. A
# mention is a NOTIFICATION only, never authorization. (Editing the body on later updates does NOT
# re-notify — GitHub only fires on the create; that is the intended once-per-episode ping.)
APPARATUS_ALERT_MENTION="${APPARATUS_ALERT_MENTION:-@oso-gato}"
DEADMAN_POLLER_LOG="${DEADMAN_POLLER_LOG:-$HOME/.local/state/pr-poller/poller.log}"
# The FITNESS token ferry writes ~/.config/fitness/env and RE-MINTS every 40 min; if its mtime goes
# STALE the entrypoint ferry has stalled (a dropped secret / a dead tick), so fitness-review can no
# longer post as the DISTINCT fitness App and auto-merge refuses EVERY PR — the exact SILENT stall that
# blocked the merge pipeline for a day (2026-07-21). 90 min = past two 40-min ticks, so a single missed
# mint is not an alarm. ABSENT is NOT alarmed (a legitimate make-it-work box never provisioned it).
DEADMAN_FITNESS_ENV="${DEADMAN_FITNESS_ENV:-$HOME/.config/fitness/env}"
DEADMAN_FITNESS_STALE_MAX="${DEADMAN_FITNESS_STALE_MAX:-5400}"   # seconds the fitness token may age before STALE
DEADMAN_STATE="${DEADMAN_STATE:-$HOME/.local/state/apparatus-deadman}"
DEADMAN_GIT_TIMEOUT="${DEADMAN_GIT_TIMEOUT:-30}"
DEADMAN_GH_TIMEOUT="${DEADMAN_GH_TIMEOUT:-30}"
# the poller script BASENAME to match in /proc (the poller runs `…/pr-poller.sh --watch`). An env knob
# so a rename never silently blinds the deadman — and so a test can point it at a throwaway fixture to
# isolate from a REAL pr-poller.sh already running on the box.
DEADMAN_POLLER_NAME="${DEADMAN_POLLER_NAME:-pr-poller.sh}"
# our own name — every process carrying it (this watcher, its --watch loop, the test harness, our
# children) is EXCLUDED from poller detection so the deadman can never mistake itself for the poller.
DEADMAN_SELF="apparatus-deadman"

# ── PURE HELPERS (--selftest covers exactly these; no git / gh / network / filesystem) ────────────────

# streak_next <prev> <cond:0|1> -> prev+1 if cond==1 else 0. Non-integer prev coerces to 0. The
# consecutive-counter primitive behind the lag streak and the unreadable streak.
streak_next(){
  local prev="$1" cond="$2"
  case "$prev" in ''|*[!0-9]*) prev=0;; esac
  [ "$cond" = 1 ] && printf '%s' "$((prev+1))" || printf 0
}

# deadman_verdict <behind> <lag_streak> <lag_min> <dirty> <poller_alive> <log_age> <unreadable_now>
#                 <unreadable_streak> <expect_poller> <lag_max> <sweep_max> <unreadable_max>
#   -> zero or more "TOKEN|human reason" lines on stdout. NO lines = HEALTHY.
# The whole DECISION, pure and total. Facts in, verdict out — the I/O layer gathers the facts and acts on
# the tokens. behind<0 or unreadable_now=1 means "no fresh git facts this check"; the poller axis (local
# /proc + log mtime) is still evaluated because it never depends on git/gh being reachable.
deadman_verdict(){
  local behind="$1" lag_streak="$2" lag_min="$3" dirty="$4" poller_alive="$5" log_age="$6" \
        unreadable_now="$7" unreadable_streak="$8" expect_poller="$9" lag_max="${10}" \
        sweep_max="${11}" unreadable_max="${12}"
  case "$behind" in ''|*[!0-9]*) behind=0;; esac
  case "$log_age" in ''|-[0-9]*|*[!0-9-]*) : ;; esac   # log_age may be -1 (missing); leave as-is

  if [ "$unreadable_now" = 1 ]; then
    # FAIL TOWARD SURFACING: an unreadable signal is suspicious, but a single blip is not an outage —
    # only a PERSISTENT streak escalates. Below the bound: no git-axis verdict (we have no fresh facts).
    if [ "$unreadable_streak" -ge "$unreadable_max" ]; then
      printf 'CANNOT_VERIFY|cannot verify liveness: git/gh signal unreadable for %s consecutive check(s) (>= %s) — surfacing rather than silently passing\n' "$unreadable_streak" "$unreadable_max"
    fi
  else
    if [ "$behind" -ge 1 ] && [ -n "$dirty" ]; then
      # ANOMALY 2 — the exact hour-long stall. A dirty+behind clone is DETERMINISTICALLY wedged (ff-only
      # refuses a dirty tree), so it fires WITHOUT waiting out the lag grace.
      printf 'SELF_REFRESH_BLOCKED|self-refresh blocked: clone dirty [%s] — will never ff until cleaned (%s commit(s) behind origin/%s)\n' "$dirty" "$behind" "$DEADMAN_BRANCH"
    # MUTATION-SEAM(lag): the merged-not-live lag gate. Force it never-true and this row must stop firing.
    elif [ "$behind" -ge 1 ] && [ "$lag_streak" -ge "$lag_max" ]; then
      printf 'MERGED_NOT_LIVE|merged code is not live: clone %s commit(s) behind origin/%s for ~%s min\n' "$behind" "$DEADMAN_BRANCH" "$lag_min"
    fi
  fi

  if [ "$expect_poller" = 1 ]; then
    if [ "$poller_alive" != 1 ]; then
      printf 'POLLER_DOWN|poller not running (no pr-poller.sh --watch process) — the autonomous loop is not sweeping\n'
    elif [ "$log_age" -ge 0 ] && [ "$log_age" -gt "$sweep_max" ]; then
      printf 'POLLER_FROZEN|poller alive but not sweeping (log frozen ~%s min, > %ss) — the sweep loop is wedged\n' "$(( log_age / 60 ))" "$sweep_max"
    fi
  fi
}

# fitness_token_verdict <env_age_secs> <stale_max> -> a "FITNESS_TOKEN_STALE|reason" line, or nothing.
# PURE (--selftest-covered). An INDEPENDENT axis (not git, not poller): the ferried fitness token's
# freshness. age<0 = ABSENT ⇒ SILENT (a make-it-work box legitimately never provisioned it — never a
# false alarm); age>max ⇒ STALE (the ferry ran then STOPPED re-minting — the merge-blocking silent stall
# that no other check catches: the poller keeps sweeping, so POLLER_FROZEN never fires, yet nothing merges).
fitness_token_verdict(){
  local age="$1" max="$2"
  case "$age" in ''|*[!0-9-]*) return 0;; esac          # unparseable ⇒ silent (fail-safe: no false alarm)
  [ "$age" -lt 0 ] && return 0                           # ABSENT ⇒ not alarmed (never-provisioned is legitimate)
  if [ "$age" -gt "$max" ]; then
    printf 'FITNESS_TOKEN_STALE|fitness token stale: %s not re-minted in ~%s min (>%ss) — the entrypoint ferry has stalled, so fitness-review cannot post as the DISTINCT fitness App and auto-merge REFUSES every PR (the silent merge stall). Host fix: re-mount the gh_app_key_fitness secret + recreate the box.\n' "$DEADMAN_FITNESS_ENV" "$(( age / 60 ))" "$max"
  fi
}

# dirty_class <git-status-porcelain> -> EMPTY | UNTRACKED_ONLY | HAS_TRACKED | UNPARSEABLE
#   THE LOAD-BEARING UNTRACKED-ONLY GUARD (pure, --selftest-covered). It decides — all-or-nothing —
#   whether a dirty clone is SAFE to quarantine: only when EVERY entry is an UNTRACKED stray (`??`) that
#   is cleanly nameable. A single TRACKED change (M/A/D/R/C/space-M …) makes the WHOLE set HAS_TRACKED
#   (a real edit may be intentional; the responder must never touch it). A path git had to C-quote (a
#   name with a quote/newline/tab) is UNPARSEABLE ⇒ fail-closed to "do not act". EMPTY = clean.
#   Porcelain v1: each line is `XY PATH`; XY at columns 1-2, PATH from column 4. `??`=untracked.
dirty_class(){
  local raw="$1" line saw=0 tracked path
  [ -n "$raw" ] || { printf EMPTY; return; }
  # PASS 1 — ANY tracked change dominates (safety wins over everything: HAS_TRACKED ⇒ never act).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    saw=1
    tracked=0; case "${line:0:2}" in '??') ;; *) tracked=1;; esac
    [ "$tracked" = 1 ] && { printf HAS_TRACKED; return; }   # MUTATION-SEAM(untracked-only): the guard
  done <<<"$raw"
  [ "$saw" = 1 ] || { printf EMPTY; return; }
  # PASS 2 — all untracked: every stray must be cleanly nameable to be quarantined; else fail closed.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in ''|'"'*) printf UNPARSEABLE; return;; esac   # git C-quoted the name ⇒ don't touch it
  done <<<"$raw"
  printf UNTRACKED_ONLY
}

# respond_plan <token> <acted:0|1> <dirty_class> <have_target:0|1>
#   -> QUARANTINE | SIGTERM | WAIT | SURFACE | ESCALATE   (the PURE recovery decision; --selftest-covered)
# Facts in, ACTION out — the I/O layer performs the action. IDEMPOTENT: <acted>=1 means the responder
# ALREADY acted on this ongoing occurrence (its per-token marker is present); finding the same anomaly
# still present after acting ESCALATES, it never re-acts (no loop-acting). SURFACE = the responder takes
# NO recovery action; the anomaly rides the normal surfacing path.
respond_plan(){
  local token="$1" acted="$2" dclass="$3" have_target="$4"
  case "$token" in
    SELF_REFRESH_BLOCKED)
      # ONLY an all-untracked, cleanly-nameable dirty set is quarantined; anything else is surfaced,
      # untouched (tracked edits may be intentional — the load-bearing safety of the whole responder).
      case "$dclass" in
        UNTRACKED_ONLY) [ "$acted" = 1 ] && printf ESCALATE || printf QUARANTINE ;;
        *)              printf SURFACE ;;
      esac ;;
    POLLER_FROZEN)
      # signal ONLY a self-match-confirmed poller pid; none found ⇒ surface rather than signal a stranger.
      if   [ "$have_target" != 1 ]; then printf SURFACE
      elif [ "$acted" = 1 ];        then printf ESCALATE
      else                               printf SIGTERM; fi ;;
    POLLER_DOWN)
      # never launch supervision here: hold ONE grace window, then surface if still down.
      [ "$acted" = 1 ] && printf SURFACE || printf WAIT ;;
    WORK_STALLED)
      # A poller that is ALIVE and SWEEPING but has moved no work is FUNCTIONALLY frozen, so it gets the
      # SAME bounded remedy as POLLER_FROZEN. Proven necessary 2026-07-28: the loop evaluated ZERO PRs
      # for 40 minutes while `gh` failed inside the poller's environment and succeeded identically from
      # an interactive shell. POLLER_FROZEN could not fire (the log was advancing — with failures), and
      # POLLER_DOWN could not fire (the process was alive), so no axis and no responder could see it.
      # TERM is the right remedy precisely BECAUSE the fault was environmental: the supervisor relaunches
      # with a freshly-built environment, and work resumes from GitHub (idempotent — nothing is lost).
      # Bounded exactly like POLLER_FROZEN: signal ONCE per occurrence, then escalate to the human rather
      # than churn a restart loop. No confirmed poller pid ⇒ SURFACE (never signal a stranger).
      if   [ "$have_target" != 1 ]; then printf SURFACE
      elif [ "$acted" = 1 ];        then printf ESCALATE
      else                               printf SIGTERM; fi ;;
    *)  # MERGED_NOT_LIVE (self-refresh owns the pull — the responder must NOT pull), CANNOT_VERIFY, etc.
      printf SURFACE ;;
  esac
}

# ── SELFTEST — the pure core only, so it can run anywhere (CI, a bare shell) with no side effects ──────
# work_stall_verdict <fingerprint> <prev-fingerprint> <unchanged-seconds> <max> → a reason line, or empty.
# THE AXIS THAT WAS MISSING. Every other axis asks "is the machine RUNNING?" — poller alive, log fresh,
# token minted, clone not behind. A poller that sweeps happily and NOOPs forever passes ALL of them.
# On 2026-07-27 six authored PRs sat ungated for 12 HOURS while the poller logged `host=NONE ⇒ NOOP`
# 1,142 times: fresh log, live process, zero alarms. The watchdog was measuring LIVENESS OF THE PROCESS
# instead of PROGRESS OF THE WORK. This asks the other question: there IS open work, and its state has
# not changed in too long. Empty fingerprint = no open work = nothing to be stalled about (quiet).
work_stall_verdict(){
  local fp="$1" prev="$2" age="$3" max="$4"
  [ "${max:-0}" -gt 0 ] 2>/dev/null || return 0        # axis disabled
  [ -n "$fp" ] || return 0                             # no open work → quiet
  [ "$fp" = "$prev" ] || return 0                      # state changed → progress → quiet
  case "$age" in ''|*[!0-9]*) return 0;; esac
  [ "$age" -ge "$max" ] || return 0
  printf 'WORK_STALLED|open work has not changed state in ~%s min (bound %ss): the loop is ALIVE but nothing is MOVING. Every liveness axis (poller up, log fresh, token minted) reads healthy — this is the IDLE-WITH-WORK-PENDING case (R18). Check the open PRs: are they gated? enrolled? waiting on a verdict that will never come?\n' "$(( age / 60 ))" "$max"
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  # tok: the TOKENS deadman_verdict emits, comma-joined (order = git-axis then poller-axis)
  tok(){ deadman_verdict "$@" | cut -d'|' -f1 | tr '\n' ',' ; }

  echo "== streak_next (the consecutive-counter primitive) =="
  ck "0,cond → 1"        "$(streak_next 0 1)" 1
  ck "2,cond → 3"        "$(streak_next 2 1)" 3
  ck "5,reset → 0"       "$(streak_next 5 0)" 0
  ck "garbage,cond → 1"  "$(streak_next xx 1)" 1
  ck "garbage,reset → 0" "$(streak_next '' 0)" 0

  echo "== deadman_verdict (facts → anomaly tokens; empty = HEALTHY) =="
  #                        behind lstreak lmin dirty  alive age  unrd ustreak exp lmax swpmax umax
  ck "all healthy → none"    "$(tok 0  0 0  ''      1 10   0 0  1 3 300 3)" ""
  ck "clean+behind past grace → MERGED_NOT_LIVE" \
                             "$(tok 2  3 6  ''      1 10   0 0  1 3 300 3)" "MERGED_NOT_LIVE,"
  ck "behind within grace → none" \
                             "$(tok 2  1 2  ''      1 10   0 0  1 3 300 3)" ""
  ck "dirty+behind → SELF_REFRESH_BLOCKED (immediate)" \
                             "$(tok 1  1 2  foo.sh  1 10   0 0  1 3 300 3)" "SELF_REFRESH_BLOCKED,"
  ck "dirty+behind wins over lag (only one git row)" \
                             "$(tok 1  5 9  'a b'   1 10   0 0  1 3 300 3)" "SELF_REFRESH_BLOCKED,"
  ck "poller down → POLLER_DOWN" \
                             "$(tok 0  0 0  ''      0 10   0 0  1 3 300 3)" "POLLER_DOWN,"
  ck "poller down suppressed when not expected" \
                             "$(tok 0  0 0  ''      0 10   0 0  0 3 300 3)" ""
  ck "poller frozen → POLLER_FROZEN" \
                             "$(tok 0  0 0  ''      1 400  0 0  1 3 300 3)" "POLLER_FROZEN,"
  ck "log fresh → no frozen" "$(tok 0  0 0  ''      1 100  0 0  1 3 300 3)" ""
  ck "log missing (age -1) → no frozen" \
                             "$(tok 0  0 0  ''      1 -1   0 0  1 3 300 3)" ""
  ck "unreadable below bound → none (grace)" \
                             "$(tok -1 0 0  ''      1 10   1 1  0 3 300 3)" ""
  ck "unreadable at bound → CANNOT_VERIFY" \
                             "$(tok -1 0 0  ''      1 10   1 3  0 3 300 3)" "CANNOT_VERIFY,"
  ck "unreadable suppresses git axis but poller still checked" \
                             "$(tok -1 0 0  ''      0 10   1 1  1 3 300 3)" "POLLER_DOWN,"
  ck "combined: lag + frozen (git-axis then poller-axis)" \
                             "$(tok 2  3 6  ''      1 400  0 0  1 3 300 3)" "MERGED_NOT_LIVE,POLLER_FROZEN,"
  ck "combined: cannot-verify + poller-down" \
                             "$(tok -1 0 0  ''      0 10   1 3  1 3 300 3)" "CANNOT_VERIFY,POLLER_DOWN,"

  echo "== fitness_token_verdict (fitness env age → FITNESS_TOKEN_STALE; the silent-stall axis) =="
  ftok(){ fitness_token_verdict "$@" | cut -d'|' -f1 | tr '\n' ',' ; }
  ck "fresh (age<max) → none"              "$(ftok 100 5400)"  ""
  ck "stale (age>max) → FITNESS_TOKEN_STALE" "$(ftok 6000 5400)" "FITNESS_TOKEN_STALE,"
  ck "exactly at bound → none"             "$(ftok 5400 5400)" ""
  ck "ABSENT (age -1) → none (make-it-work box is legit)" "$(ftok -1 5400)" ""
  ck "unparseable age → none (fail-safe, no false alarm)" "$(ftok xx 5400)" ""

  echo "== dirty_class (porcelain → classification; the load-bearing untracked-only guard) =="
  ck "clean → EMPTY"                    "$(dirty_class "")" EMPTY
  ck "only ?? → UNTRACKED_ONLY"         "$(dirty_class '?? a.txt
?? bin/b.sh')" UNTRACKED_ONLY
  ck "a modified (space-M) → HAS_TRACKED"  "$(dirty_class ' M tracked.txt')" HAS_TRACKED
  ck "staged add (A ) → HAS_TRACKED"       "$(dirty_class 'A  added.txt')" HAS_TRACKED
  ck "deleted ( D) → HAS_TRACKED"          "$(dirty_class ' D gone.txt')" HAS_TRACKED
  ck "rename (R ) → HAS_TRACKED"           "$(dirty_class 'R  old.txt -> new.txt')" HAS_TRACKED
  ck "MIX ?? + tracked → HAS_TRACKED (safety wins)" \
                                       "$(dirty_class '?? stray.txt
 M tracked.txt')" HAS_TRACKED
  ck "quoted untracked → UNPARSEABLE"   "$(dirty_class '?? "weird name".txt')" UNPARSEABLE

  echo "== respond_plan (facts → recovery ACTION; the pure decision core) =="
  #                                                      token                acted dclass         target
  ck "SRB untracked, not acted → QUARANTINE" "$(respond_plan SELF_REFRESH_BLOCKED 0 UNTRACKED_ONLY 0)" QUARANTINE
  ck "SRB untracked, ALREADY acted → ESCALATE" "$(respond_plan SELF_REFRESH_BLOCKED 1 UNTRACKED_ONLY 0)" ESCALATE
  ck "SRB tracked → SURFACE (never touch)"   "$(respond_plan SELF_REFRESH_BLOCKED 0 HAS_TRACKED 0)" SURFACE
  ck "SRB tracked stays SURFACE even if acted" "$(respond_plan SELF_REFRESH_BLOCKED 1 HAS_TRACKED 0)" SURFACE
  ck "SRB unparseable → SURFACE"             "$(respond_plan SELF_REFRESH_BLOCKED 0 UNPARSEABLE 0)" SURFACE
  ck "FROZEN + target, not acted → SIGTERM"  "$(respond_plan POLLER_FROZEN 0 - 1)" SIGTERM
  ck "FROZEN + target, ALREADY acted → ESCALATE" "$(respond_plan POLLER_FROZEN 1 - 1)" ESCALATE
  ck "FROZEN + NO target → SURFACE (never signal a stranger)" "$(respond_plan POLLER_FROZEN 0 - 0)" SURFACE
  ck "DOWN first sighting → WAIT (grace)"    "$(respond_plan POLLER_DOWN 0 - 0)" WAIT
  ck "DOWN still down → SURFACE"             "$(respond_plan POLLER_DOWN 1 - 0)" SURFACE
  ck "FITNESS_TOKEN_STALE → SURFACE (no in-box fix)" "$(respond_plan FITNESS_TOKEN_STALE 0 - 0)" SURFACE
  ck "MERGED_NOT_LIVE → SURFACE (never pull)" "$(respond_plan MERGED_NOT_LIVE 0 - 1)" SURFACE
  ck "CANNOT_VERIFY → SURFACE"               "$(respond_plan CANNOT_VERIFY 0 - 1)" SURFACE

  echo "== work_stall_verdict — the axis that was MISSING on 2026-07-27 =="
  wf(){ [ -n "$(work_stall_verdict "$1" "$2" "$3" "$4")" ] && echo FIRE || echo quiet; }
  WFP="e2e-beta#9 abc 0 live-validate"
  ck "THE INCIDENT: open work frozen 12h FIRES" "$(wf "$WFP" "$WFP" 43200 2700)" "FIRE"
  ck "at the bound FIRES"                       "$(wf "$WFP" "$WFP" 2700 2700)" "FIRE"
  ck "no open work = quiet (not stalled)"       "$(wf "" "" 99999 2700)" "quiet"
  ck "a verdict ARRIVED = progress = quiet"     "$(wf "$WFP" "e2e-beta#9 abc 1 live-validate" 99999 2700)" "quiet"
  ck "under the bound = quiet"                  "$(wf "$WFP" "$WFP" 600 2700)" "quiet"
  ck "axis disabled (0) = quiet"                "$(wf "$WFP" "$WFP" 99999 0)" "quiet"
  ck "unreadable age = quiet (no false alarm)"  "$(wf "$WFP" "$WFP" "" 2700)" "quiet"
  echo "== WORK_STALLED responder — a poller that moves no work is FUNCTIONALLY frozen =="
  rp(){ local got; got="$(respond_plan "$2" "$3" "$4" "$5")"; ck "$1" "$got" "$6"; }
  rp "stalled work TERMs the poller once"      WORK_STALLED 0 "" 1 SIGTERM
  rp "already acted -> escalate, never churn"  WORK_STALLED 1 "" 1 ESCALATE
  rp "no confirmed pid -> surface, never signal a stranger" WORK_STALLED 0 "" 0 SURFACE
  rp "parity with POLLER_FROZEN (same remedy)" POLLER_FROZEN 0 "" 1 SIGTERM
  echo; echo "apparatus-deadman selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ── I/O LAYER — gather LIVE facts, act on the verdict. Never runs under --selftest. ───────────────────
log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] apparatus-deadman: $*" >&2; }
now_iso(){ date -u +%FT%TZ 2>/dev/null || date; }
read_int(){ local v; v="$(cat "$1" 2>/dev/null)"; case "$v" in ''|*[!0-9]*) printf 0;; *) printf '%s' "$v";; esac; }

# git_facts — READ-ONLY liveness read. Sets G_UNREAD (1 = a signal could not be read this check),
# G_BEHIND (commits behind origin/BRANCH; 0 = current), G_DIRTY (space-joined dirty paths; "" = clean),
# G_WHY (why unreadable). The origin tip comes from `git ls-remote` (authoritative, writes NOTHING —
# and it sidesteps the stale remote-tracking-ref trap a narrow fetch refspec can cause); `git fetch`
# runs ONLY to bring objects local for the exact behind-COUNT and never touches HEAD/index/worktree.
git_facts(){
  G_UNREAD=0; G_BEHIND=0; G_DIRTY=""; G_DIRTY_RAW=""; G_WHY=""
  local clone="$DEADMAN_CLONE" head remote cnt
  # accept a normal clone OR a git worktree (fresh-tree.sh worktrees carry a .git FILE, not a dir).
  if ! timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    G_UNREAD=1; G_WHY="not a git work tree at $clone"; return
  fi
  head="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" rev-parse HEAD 2>/dev/null)" || head=""
  if [ -z "$head" ]; then G_UNREAD=1; G_WHY="cannot read HEAD of $clone"; return; fi
  remote="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" ls-remote "$DEADMAN_REMOTE" "refs/heads/$DEADMAN_BRANCH" 2>/dev/null | head -n1 | cut -f1)" || remote=""
  if [ -z "$remote" ]; then G_UNREAD=1; G_WHY="cannot reach $DEADMAN_REMOTE/$DEADMAN_BRANCH (ls-remote failed)"; return; fi
  # dirty state — READ ONLY (status never mutates). G_DIRTY_RAW keeps the FULL porcelain (XY code +
  # path) for the responder's untracked-only classification; quotepath=false keeps non-ASCII paths
  # literal (a name git must C-quote still gets a leading `"`, which dirty_class treats as UNPARSEABLE).
  # G_DIRTY is the space-joined PATHS (column 4+) for the verdict's human reason — derived from the
  # same single read so the two can never disagree.
  G_DIRTY_RAW="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" -c core.quotepath=false status --porcelain 2>/dev/null)"
  G_DIRTY="$(printf '%s' "$G_DIRTY_RAW" | cut -c4- | tr '\n' ' ')"
  while [ "${G_DIRTY% }" != "$G_DIRTY" ]; do G_DIRTY="${G_DIRTY% }"; done   # trim trailing space, pure bash
  if [ "$head" = "$remote" ]; then G_BEHIND=0; return; fi
  # HEAD differs from the tip → bring objects local to COUNT (fetch is read-only to HEAD/index/worktree).
  timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" fetch -q "$DEADMAN_REMOTE" 2>/dev/null || true
  cnt="$(git -C "$clone" rev-list --count "HEAD..$remote" 2>/dev/null)" || cnt=""
  case "$cnt" in
    ''|*[!0-9]*) G_BEHIND=1 ;;    # objects absent / count failed, but HEAD != tip ⇒ definitely not current
    *)           G_BEHIND="$cnt" ;;  # 0 here = ahead/diverged, NOT behind — reported as 0 (not our stall)
  esac
}

# poller_pids — echo the PID of every genuine `<name> --watch` process (newline-separated; empty = none).
# SELF-MATCH-SAFE, pgrep-free: scan /proc directly and CONFIRM each candidate by its real script PATH,
# never a loose string match. This is the ONE detector — poller_alive AND the responder's SIGTERM target
# both derive from it, so the self-match safety (5 prior self-match incidents) lives in exactly one place
# and the responder can never signal our own pid, a matcher, or a bare-string decoy.
poller_pids(){
  local d pid cmd comm
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue                          # never OURSELVES
    [ "$pid" = "${PPID:-0}" ] && continue                  # nor our parent (the --watch loop / test shell)
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" || continue
    [ -n "$cmd" ] || continue
    case "$cmd" in *"$DEADMAN_SELF"*) continue;; esac       # anything carrying our name is US, not the poller
    comm="$(cat "$d/comm" 2>/dev/null)"
    case "$comm" in pgrep|grep|egrep|fgrep) continue;; esac # a matcher carries the pattern in its OWN argv
    # SELF-MATCH GUARD (mutation seam): a GENUINE poller runs the real SCRIPT PATH ".../pr-poller.sh …
    # --watch"; a shell / decoy / self carrying only the bare string has no slash-anchored path. Neutralize
    # the "/" and a decoy trips this (the test's non-vacuity check).
    case "$cmd" in */$DEADMAN_POLLER_NAME*--watch*) printf '%s\n' "$pid";; esac
  done
}
# poller_alive — rc 0 iff at least one genuine poller is running (the boolean over poller_pids).
poller_alive(){ [ -n "$(poller_pids)" ]; }

# poller_log_age — seconds since the poller log mtime last advanced, or -1 if the log is missing/unreadable.
poller_log_age(){
  local m now
  m="$(stat -c %Y "$DEADMAN_POLLER_LOG" 2>/dev/null)" || { printf -- '-1'; return; }
  case "$m" in ''|*[!0-9]*) printf -- '-1'; return;; esac
  now="$(date +%s)"
  printf '%s' "$(( now - m ))"
}

# fitness_env_age -> seconds since $DEADMAN_FITNESS_ENV mtime, or -1 if ABSENT/unreadable (the ferry
# never wrote it). Mirrors poller_log_age; the freshness fact for the fitness-token silent-stall check.
fitness_env_age(){
  local m now
  m="$(stat -c %Y "$DEADMAN_FITNESS_ENV" 2>/dev/null)" || { printf -- '-1'; return; }
  case "$m" in ''|*[!0-9]*) printf -- '-1'; return;; esac
  now="$(date +%s)"
  printf '%s' "$(( now - m ))"
}

# ── AUTONOMOUS RESPONDER (the recovery arm; only reached under --watch or DEADMAN_RESPOND=1) ───────────
# Design law: respond_plan() (pure, above) DECIDES; these functions PERFORM. Every action is deterministic,
# idempotent, and never destructive — quarantining an untracked stray touches neither HEAD, the index, nor
# any tracked file, and a SIGTERM goes only to a self-match-confirmed poller pid. Anything not provably
# safe SURFACEs instead of acting.

# marker_path <token> — the per-anomaly idempotency marker ("this occurrence was already acted on").
marker_path(){ printf '%s/responder/%s.acted' "$DEADMAN_STATE" "$1"; }

# quarantine_strays <clone> <raw-porcelain> <quarantine-dir> — MOVE each untracked stray into the
# quarantine dir, PATH PRESERVED. NEVER rm, NEVER git clean, NEVER touches a tracked path. Echoes the
# moved paths (space-joined). PRECONDITION: only ever called when dirty_class(raw)==UNTRACKED_ONLY — the
# single load-bearing guard is dirty_class; this mover trusts it (a mixed/tracked set never reaches here).
quarantine_strays(){
  local clone="$1" raw="$2" qdir="$3" line path src dst moved=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in ''|'"'*) continue;; esac         # belt: an unnameable path is never moved
    src="$clone/$path"; dst="$qdir/$path"
    [ -e "$src" ] || continue
    mkdir -p "$qdir/$(dirname "$path")" 2>/dev/null || continue
    mv "$src" "$dst" 2>/dev/null && moved="$moved $path"
  done <<<"$raw"
  printf '%s' "${moved# }"
}

# respond_act <token> <plan> <poller-pids> — perform the plan's side effect, manage the idempotency
# marker, and echo ONE audit line `TOKEN|human note` (or nothing). Markers are written for the "first
# response" actions (QUARANTINE / SIGTERM / WAIT); ESCALATE/SURFACE leave any existing marker as-is.
respond_act(){
  local token="$1" plan="$2" pids="$3" mk qdir ts moved p killed
  mk="$(marker_path "$token")"
  case "$plan" in
    QUARANTINE)
      ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
      qdir="$DEADMAN_STATE/deadman-quarantine/$ts"
      mkdir -p "$qdir" 2>/dev/null || true
      moved="$(quarantine_strays "$DEADMAN_CLONE" "$G_DIRTY_RAW" "$qdir")"
      printf 'quarantined [%s] -> %s\n' "$moved" "$qdir" > "$mk"
      log "RESPOND $token: QUARANTINED untracked stray(s) [$moved] -> $qdir (clone goes clean; self-refresh can ff)"
      printf '%s|auto-recovery QUARANTINED untracked stray(s) [%s] into %s so the clone goes clean and self-refresh can fast-forward. Nothing tracked was touched (HEAD, index and every tracked file are unchanged); no pull/merge/reset/checkout/clean was run.' "$token" "$moved" "$qdir"
      ;;
    SIGTERM)
      killed=""
      for p in $pids; do
        [ -n "$p" ] || continue
        [ "$p" = "$$" ] && continue                    # belt: never ourselves (poller_pids already excludes)
        kill -TERM "$p" 2>/dev/null && killed="$killed $p"
      done
      printf 'sigterm ->%s\n' "$killed" > "$mk"
      log "RESPOND $token: sent ONE SIGTERM ->${killed:- (no pid)}"
      printf '%s|auto-recovery sent ONE SIGTERM to the wedged poller (pid(s):%s) — it traps TERM, exits cleanly, its supervisor relaunches it and work resumes from GitHub (idempotent). Kicked at most once for this anomaly window.' "$token" "$killed"
      ;;
    WAIT)
      printf 'grace\n' > "$mk"
      log "RESPOND $token: WAIT — holding one grace window for the supervisor to relaunch the poller"
      printf '%s|auto-recovery is holding ONE grace window for the supervisor to relaunch the poller; the responder does NOT launch supervision itself. If it is still down next check this SURFACES for a human.' "$token"
      ;;
    ESCALATE)
      log "RESPOND $token: ESCALATE — auto-recovery already attempted, anomaly persists; NOT acting again"
      printf '%s|ESCALATION — auto-recovery was ALREADY attempted for this anomaly and it is STILL present. The responder will NOT act again (no loop-acting); a human must intervene.' "$token"
      ;;
    SURFACE|*)
      case "$token" in
        SELF_REFRESH_BLOCKED) printf '%s|auto-recovery DECLINED — the dirty clone carries a TRACKED or unparseable change; a real edit may be intentional, so NOTHING was moved, cleaned or reset. Surfacing for a human.' "$token" ;;
        MERGED_NOT_LIVE)      printf '%s|auto-recovery not applicable — the clone is clean; only the poller self-refresh (the single writer) may pull it, and the responder must not. Surfacing as unexplained.' "$token" ;;
        POLLER_FROZEN)        printf '%s|auto-recovery could NOT identify a safe poller pid (self-match-safe detection found none) — surfacing rather than signalling a stranger.' "$token" ;;
        POLLER_DOWN)          printf '%s|auto-recovery DECLINED — the responder does not launch supervision and the grace window has elapsed with the poller still down. Surfacing for a human.' "$token" ;;
        FITNESS_TOKEN_STALE)  printf '%s|auto-recovery not possible in-box — the fitness KEY never enters the box (only the token is ferried) and core cannot re-mint it. HOST fix: re-mount the gh_app_key_fitness podman secret + recreate fedora-dev; then re-run fitness-review --post on the parked host-GREEN PRs.' "$token" ;;
        *)                    printf '%s|auto-recovery not applicable; surfacing for a human.' "$token" ;;
      esac
      ;;
  esac
}

# deadman_respond <reasons> <poller-pids> — run respond_plan/respond_act for EACH detected anomaly,
# gather the audit notes into RESP_NOTES (read by the caller's dynamic scope). Facts computed ONCE.
deadman_respond(){
  local reasons="$1" pids="$2" line token acted plan note dclass have_target
  mkdir -p "$DEADMAN_STATE/responder" 2>/dev/null || true
  dclass="$(dirty_class "$G_DIRTY_RAW")"
  have_target=0; [ -n "$pids" ] && have_target=1
  RESP_NOTES=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    token="${line%%|*}"
    acted=0; [ -f "$(marker_path "$token")" ] && acted=1
    plan="$(respond_plan "$token" "$acted" "$dclass" "$have_target")"
    note="$(respond_act "$token" "$plan" "$pids")"
    [ -n "$note" ] && RESP_NOTES="$RESP_NOTES$note"$'\n'
  done <<<"$reasons"
}

# responder_prune <reasons> — an occurrence ends when its anomaly is no longer present: drop the acted
# marker for any token NOT in the current reasons, so a later RE-occurrence gets a fresh action (not a
# stale ESCALATE). Keeps per-token idempotency independent of which OTHER anomalies stand.
responder_prune(){
  local reasons="$1" dir="$DEADMAN_STATE/responder" f base token
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.acted; do
    [ -e "$f" ] || continue
    base="${f##*/}"; token="${base%.acted}"
    case "$reasons" in
      *"$token|"*) : ;;                                  # still present ⇒ keep the marker (would ESCALATE)
      *) rm -f "$f"; log "RESPOND: cleared stale acted-marker for $token (occurrence ended)";;
    esac
  done
}

# responder_reset — a CONFIRMED-healthy check ends every occurrence: drop all acted markers.
responder_reset(){ rm -f "$DEADMAN_STATE/responder"/*.acted 2>/dev/null || true; }

# find_open_issue — discover the ONE anomaly issue BY TITLE prefix (fleet-halt's discipline: no hardcoded
# number; the search matches words, the strict local prefix is the contract). Echoes a number or nothing.
find_open_issue(){
  local rows num title
  rows="$(timeout "$DEADMAN_GH_TIMEOUT" gh api -X GET search/issues \
          -f q="repo:$DEADMAN_REPO in:title \"$DEADMAN_TITLE\" state:open" \
          -q '.items[] | [(.number|tostring), .title] | @tsv' 2>/dev/null)" || return 0
  while IFS=$'\t' read -r num title; do
    case "$num" in ''|*[!0-9]*) continue;; esac
    case "$title" in "$DEADMAN_TITLE"*) printf '%s' "$num"; return 0;; esac
  done <<<"$rows"
}

# fmt_body <reasons> [resp-notes] — the issue body: the current anomalies + the auto-recovery actions
# taken (audit) + a timestamp.
fmt_body(){
  local reasons="$1" resp="${2:-}" line
  [ -n "$APPARATUS_ALERT_MENTION" ] && printf '%s — apparatus liveness anomaly (mobile-app push).\n\n' "$APPARATUS_ALERT_MENTION"
  printf '**Apparatus deadman → operator [liveness anomaly]:** the running loop failed a liveness check at %s. Current anomalies:\n\n' "$(now_iso)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf -- '- **%s** — %s\n' "${line%%|*}" "${line#*|}"
  done <<<"$reasons"
  if [ -n "$resp" ]; then
    printf '\n**Auto-recovery (responder) — actions taken this check:**\n\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf -- '- **%s** — %s\n' "${line%%|*}" "${line#*|}"
    done <<<"$resp"
  fi
  printf '\n<sub>apparatus liveness deadman (R18); an INDEPENDENT watcher that never merges and never pulls/merges/resets the clone. Under --watch it also RESPONDS within a safe envelope (quarantine untracked strays; SIGTERM a wedged poller) and records what it did here. This issue is updated in place while any anomaly stands and closed automatically when the loop is healthy again.</sub>\n'
}

# work_fingerprint → one line per open PR of ours across the in-scope repos:
# "<repo>#<n> <head-sha> <gated:0|1> <labels>". ANY change (new PR, new head, a verdict arriving, a
# merge, a label) changes the fingerprint and proves progress. Unreadable → empty → quiet (never a
# false alarm from a GitHub blip; the CANNOT_VERIFY axis owns that failure).
work_fingerprint(){
  local repos="$DEADMAN_WORK_REPOS" r
  [ -n "$repos" ] || repos="$("$(dirname "$(readlink -f "$0")")/repo-scope.sh" list 2>/dev/null)"
  [ -n "$repos" ] || return 0
  for r in $repos; do
    gh pr list --repo "oso-gato/$r" --state open --limit 50 \
       --json number,headRefOid,labels,comments \
       -q ".[] | \"$r#\(.number) \(.headRefOid[0:12]) \([.comments[]|select(.body|test(\"Host live-gate|Fitness review\"))]|length) \([.labels[].name]|sort|join(\",\"))\"" 2>/dev/null
  done | sort
}

# surface_anomaly <reasons> [resp-notes] — create-or-UPDATE the ONE issue, dedup via the marker + by-title
# discovery. The responder's audit notes ride the body so the record shows what auto-recovery did.
surface_anomaly(){
  local reasons="$1" resp="${2:-}" mk="$DEADMAN_STATE/anomaly.open" num body tmp url
  num="$(cat "$mk" 2>/dev/null)"; case "$num" in ''|*[!0-9]*) num="";; esac
  [ -n "$num" ] || num="$(find_open_issue)"     # marker lost? discover by title so we never double-file
  body="$(fmt_body "$reasons" "$resp")"
  tmp="$(mktemp)"; printf '%s\n' "$body" > "$tmp"
  if [ -n "$num" ]; then
    if timeout "$DEADMAN_GH_TIMEOUT" gh issue edit "$num" --repo "$DEADMAN_REPO" --body-file "$tmp" >/dev/null 2>&1; then
      log "SURFACE: updated $DEADMAN_REPO#$num with the current anomalies"
      printf '%s' "$num" > "$mk"
    else
      log "SURFACE: FAILED to update $DEADMAN_REPO#$num (gh error) — will retry next check"
    fi
  else
    if url="$(timeout "$DEADMAN_GH_TIMEOUT" gh issue create --repo "$DEADMAN_REPO" --title "$DEADMAN_TITLE" --body-file "$tmp" 2>/dev/null)"; then
      num="${url##*/}"; case "$num" in ''|*[!0-9]*) num="";; esac
      [ -n "$num" ] && printf '%s' "$num" > "$mk"
      log "SURFACE: opened the anomaly issue on $DEADMAN_REPO (${url:-created})"
    else
      log "SURFACE: FAILED to open the anomaly issue (gh error) — will retry next check"
    fi
  fi
  rm -f "$tmp"
}

# clear_anomaly — on a healthy check, comment + close the standing issue. QUIET when nothing is open (no
# gh writes): it acts ONLY when the marker names an issue we opened, so a healthy steady state is silent.
clear_anomaly(){
  local mk="$DEADMAN_STATE/anomaly.open" num
  num="$(cat "$mk" 2>/dev/null)"; case "$num" in ''|*[!0-9]*) num="";; esac
  [ -n "$num" ] || return 0
  timeout "$DEADMAN_GH_TIMEOUT" gh issue comment "$num" --repo "$DEADMAN_REPO" \
    --body "**Deadman → operator [cleared]:** apparatus liveness is HEALTHY again as of $(now_iso). Closing." >/dev/null 2>&1
  timeout "$DEADMAN_GH_TIMEOUT" gh issue close "$num" --repo "$DEADMAN_REPO" >/dev/null 2>&1
  log "CLEARED: liveness healthy — commented + closed $DEADMAN_REPO#$num"
  rm -f "$mk"
}

# run_check [respond:0|1] — ONE check: gather live facts, update the streaks, compute the verdict, act
# (respond/surface/clear), print the verdict to stdout. rc 0 = healthy, non-zero = anomaly. respond=1
# (the --watch default) activates the autonomous responder; respond=0 (the --check default) is READ-ONLY.
run_check(){
  local respond="${1:-0}"
  mkdir -p "$DEADMAN_STATE" 2>/dev/null || true
  git_facts
  local unreadable_now="$G_UNREAD" behind="$G_BEHIND" dirty="$G_DIRTY" why="$G_WHY"
  local pids alive lage
  pids="$(poller_pids)"; [ -n "$pids" ] && alive=1 || alive=0   # ONE self-match-safe scan: alive + target
  lage="$(poller_log_age)"
  # streaks — persisted so the "for M min / N checks" thresholds survive across one-shot --check runs too.
  local lag_cond=0
  [ "$unreadable_now" = 0 ] && [ "$behind" -ge 1 ] && lag_cond=1
  local lag_streak unread_streak
  lag_streak="$(streak_next "$(read_int "$DEADMAN_STATE/lag.count")" "$lag_cond")"
  unread_streak="$(streak_next "$(read_int "$DEADMAN_STATE/unreadable.count")" "$unreadable_now")"
  printf '%s' "$lag_streak" > "$DEADMAN_STATE/lag.count" 2>/dev/null || true
  printf '%s' "$unread_streak" > "$DEADMAN_STATE/unreadable.count" 2>/dev/null || true
  local lag_min=$(( lag_streak * DEADMAN_INTERVAL / 60 ))

  local reasons
  reasons="$(deadman_verdict "$behind" "$lag_streak" "$lag_min" "$dirty" "$alive" "$lage" \
             "$unreadable_now" "$unread_streak" "$DEADMAN_EXPECT_POLLER" \
             "$DEADMAN_LAG_MAX" "$DEADMAN_SWEEP_MAX" "$DEADMAN_UNREADABLE_MAX")"
  # The fitness-token freshness axis is INDEPENDENT of git-readability and the poller — evaluate + append
  # it here so a stale token surfaces even during a git blip (empty git-axis) or a healthy sweep.
  local freason; freason="$(fitness_token_verdict "$(fitness_env_age)" "$DEADMAN_FITNESS_STALE_MAX")"
  [ -n "$freason" ] && reasons="${reasons:+$reasons$'\n'}$freason"
  # WORK-PROGRESS axis — independent of every liveness axis above, and the one that was missing.
  local _wfp _wprev _wf="$DEADMAN_STATE/work.fp" _wage=0 _wreason
  _wfp="$(work_fingerprint)"
  _wprev="$(cat "$_wf" 2>/dev/null || true)"
  if [ "$_wfp" != "$_wprev" ]; then
    printf '%s' "$_wfp" > "$_wf" 2>/dev/null; touch "$_wf" 2>/dev/null      # progress → reset the clock
  else
    _wage=$(( $(date +%s) - $(stat -c %Y "$_wf" 2>/dev/null || date +%s) ))
  fi
  _wreason="$(work_stall_verdict "$_wfp" "$_wprev" "$_wage" "$DEADMAN_WORK_STALL_MAX")"
  [ -n "$_wreason" ] && reasons="${reasons:+$reasons$'\n'}$_wreason"

  if [ -z "$reasons" ]; then
    if [ "$unreadable_now" = 1 ]; then
      # a blip below the bound: quiet, and DO NOT clear a standing anomaly (we could not confirm health).
      log "unverified blip ($why) — $unread_streak/$DEADMAN_UNREADABLE_MAX consecutive, below bound; quiet, not clearing"
      echo "HEALTHY (unverified blip $unread_streak/$DEADMAN_UNREADABLE_MAX: $why)"
      return 0
    fi
    log "healthy (behind=$behind poller_alive=$alive log_age=${lage}s)"
    echo "HEALTHY"
    [ "$respond" = 1 ] && responder_reset   # a CONFIRMED-healthy check ends every occurrence (fresh next time)
    clear_anomaly
    return 0
  fi

  echo "ANOMALY"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line"
    log "ANOMALY ${line%%|*}: ${line#*|}"
  done <<<"$reasons"

  # RESPOND — BEFORE surfacing, so the audit notes ride the issue body. Read-only under respond=0.
  local RESP_NOTES="" rl
  if [ "$respond" = 1 ]; then
    deadman_respond "$reasons" "$pids"   # sets RESP_NOTES (dynamic scope); performs actions + markers
    responder_prune "$reasons"           # drop markers for anomalies no longer present
    while IFS= read -r rl; do [ -n "$rl" ] && echo "RESPOND ${rl%%|*}: ${rl#*|}"; done <<<"$RESP_NOTES"
  fi

  surface_anomaly "$reasons" "$RESP_NOTES"
  return 1
}

case "${1:-}" in
  --check) run_check "${DEADMAN_RESPOND:-0}"; exit $?;;   # READ-ONLY by default; DEADMAN_RESPOND=1 opts in
  --watch)
    trap 'log "deadman stopping (signal)"; exit 0' TERM INT HUP
    log "apparatus-deadman --watch up (interval=${DEADMAN_INTERVAL}s clone=$DEADMAN_CLONE repo=$DEADMAN_REPO expect_poller=$DEADMAN_EXPECT_POLLER responder=on)"
    while :; do
      run_check 1 >/dev/null || true    # --watch RESPONDS; the verdict + actions ride the log
      sleep "$DEADMAN_INTERVAL"
    done
    ;;
  *) echo "usage: apparatus-deadman.sh --check | --watch | --selftest" >&2; exit 2;;
esac
