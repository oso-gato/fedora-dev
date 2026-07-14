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
# READ-ONLY, ALWAYS. The deadman WATCHES; it never fixes. It NEVER pulls / merges / checks-out / resets
# the clone — the ONLY writer of the clone is poller-service.sh. Its only "write" is an issue on the
# control repo. It gets the true origin tip from `git ls-remote` (authoritative, writes NOTHING) and
# uses a bounded `git fetch` ONLY to bring objects local for the behind-COUNT — fetch touches remote-
# tracking refs, never HEAD / index / the working tree. Every git/gh call is `timeout`-bounded so the
# watcher itself can never hang. Tooling: coreutils + git + gh only (no diff/cmp/awk/sed).
#
# THE FOUR ANOMALIES (the DECISION is the pure, --selftest-covered deadman_verdict; the facts are
# gathered separately by the I/O layer):
#   1. MERGED-NOT-LIVE  — the clone HEAD trails origin/main by >=1 for longer than DEADMAN_LAG_MAX checks
#                         (a clean clone lagging past the transient post-merge window).
#   2. SELF-REFRESH BLOCKED — the clone trails origin AND is DIRTY: it will NEVER ff until cleaned. The
#                         exact hour-long stall. Fires immediately (a dirty+behind clone is deterministically
#                         wedged; waiting the grace window cannot help it).
#   3. POLLER FROZEN    — a poller process EXISTS but its log mtime has not advanced within DEADMAN_SWEEP_MAX
#                         (alive but not sweeping).
#   4. POLLER DOWN      — no `pr-poller.sh --watch` process at all, while one is expected (DEADMAN_EXPECT_POLLER).
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
#   apparatus-deadman.sh --check     one-shot: print verdict + reasons; rc 0 = healthy, non-zero = anomaly
#   apparatus-deadman.sh --watch     loop every DEADMAN_INTERVAL, surfacing/clearing as it goes
#   apparatus-deadman.sh --selftest  exercise the pure core (streak_next, deadman_verdict); no git/gh/net
#
# ENV (all defaulted): DEADMAN_REPO (oso-gato/fedora-bootstrap) · DEADMAN_TITLE ("APPARATUS LIVENESS
# DEADMAN" — the discovery prefix) · DEADMAN_INTERVAL (120s) · DEADMAN_LAG_MAX (3 checks) ·
# DEADMAN_SWEEP_MAX (300s) · DEADMAN_UNREADABLE_MAX (3) · DEADMAN_EXPECT_POLLER (1) · DEADMAN_CLONE (the
# live clone, one level up from bin/) · DEADMAN_REMOTE/BRANCH (origin/main) · DEADMAN_POLLER_LOG
# (~/.local/state/pr-poller/poller.log) · DEADMAN_POLLER_NAME (pr-poller.sh — the script basename to
# match) · DEADMAN_STATE (~/.local/state/apparatus-deadman) · DEADMAN_GIT_TIMEOUT / DEADMAN_GH_TIMEOUT (30s).
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
DEADMAN_BRANCH="${DEADMAN_BRANCH:-main}"
DEADMAN_POLLER_LOG="${DEADMAN_POLLER_LOG:-$HOME/.local/state/pr-poller/poller.log}"
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

# ── SELFTEST — the pure core only, so it can run anywhere (CI, a bare shell) with no side effects ──────
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
  G_UNREAD=0; G_BEHIND=0; G_DIRTY=""; G_WHY=""
  local clone="$DEADMAN_CLONE" head remote cnt
  # accept a normal clone OR a git worktree (fresh-tree.sh worktrees carry a .git FILE, not a dir).
  if ! timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    G_UNREAD=1; G_WHY="not a git work tree at $clone"; return
  fi
  head="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" rev-parse HEAD 2>/dev/null)" || head=""
  if [ -z "$head" ]; then G_UNREAD=1; G_WHY="cannot read HEAD of $clone"; return; fi
  remote="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" ls-remote "$DEADMAN_REMOTE" "refs/heads/$DEADMAN_BRANCH" 2>/dev/null | head -n1 | cut -f1)" || remote=""
  if [ -z "$remote" ]; then G_UNREAD=1; G_WHY="cannot reach $DEADMAN_REMOTE/$DEADMAN_BRANCH (ls-remote failed)"; return; fi
  # dirty state — READ ONLY (status never mutates). Paths start at column 4 of --porcelain.
  G_DIRTY="$(timeout "$DEADMAN_GIT_TIMEOUT" git -C "$clone" status --porcelain 2>/dev/null | cut -c4- | tr '\n' ' ')"
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

# poller_alive — is a genuine `pr-poller.sh --watch` process running? SELF-MATCH-SAFE, pgrep-free: scan
# /proc directly and CONFIRM each candidate by its real script PATH, never a loose string match.
poller_alive(){
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
    case "$cmd" in */$DEADMAN_POLLER_NAME*--watch*) return 0;; esac
  done
  return 1
}

# poller_log_age — seconds since the poller log mtime last advanced, or -1 if the log is missing/unreadable.
poller_log_age(){
  local m now
  m="$(stat -c %Y "$DEADMAN_POLLER_LOG" 2>/dev/null)" || { printf -- '-1'; return; }
  case "$m" in ''|*[!0-9]*) printf -- '-1'; return;; esac
  now="$(date +%s)"
  printf '%s' "$(( now - m ))"
}

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

# fmt_body <reasons> — the issue body: the current anomalies + a timestamp.
fmt_body(){
  local reasons="$1" line
  printf '**Apparatus deadman → operator [liveness anomaly]:** the running loop failed a liveness check at %s. Current anomalies:\n\n' "$(now_iso)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf -- '- **%s** — %s\n' "${line%%|*}" "${line#*|}"
  done <<<"$reasons"
  printf '\n<sub>apparatus liveness deadman (R18); an INDEPENDENT read-only watcher — it never merges and never writes the clone. This issue is updated in place while any anomaly stands and closed automatically when the loop is healthy again.</sub>\n'
}

# surface_anomaly <reasons> — create-or-UPDATE the ONE issue, dedup via the marker + by-title discovery.
surface_anomaly(){
  local reasons="$1" mk="$DEADMAN_STATE/anomaly.open" num body tmp url
  num="$(cat "$mk" 2>/dev/null)"; case "$num" in ''|*[!0-9]*) num="";; esac
  [ -n "$num" ] || num="$(find_open_issue)"     # marker lost? discover by title so we never double-file
  body="$(fmt_body "$reasons")"
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

# run_check — ONE check: gather live facts, update the streaks, compute the verdict, act (surface/clear),
# print the verdict to stdout. rc 0 = healthy, non-zero = anomaly.
run_check(){
  mkdir -p "$DEADMAN_STATE" 2>/dev/null || true
  git_facts
  local unreadable_now="$G_UNREAD" behind="$G_BEHIND" dirty="$G_DIRTY" why="$G_WHY"
  local alive lage
  poller_alive && alive=1 || alive=0
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

  if [ -z "$reasons" ]; then
    if [ "$unreadable_now" = 1 ]; then
      # a blip below the bound: quiet, and DO NOT clear a standing anomaly (we could not confirm health).
      log "unverified blip ($why) — $unread_streak/$DEADMAN_UNREADABLE_MAX consecutive, below bound; quiet, not clearing"
      echo "HEALTHY (unverified blip $unread_streak/$DEADMAN_UNREADABLE_MAX: $why)"
      return 0
    fi
    log "healthy (behind=$behind poller_alive=$alive log_age=${lage}s)"
    echo "HEALTHY"
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
  surface_anomaly "$reasons"
  return 1
}

case "${1:-}" in
  --check) run_check; exit $?;;
  --watch)
    trap 'log "deadman stopping (signal)"; exit 0' TERM INT HUP
    log "apparatus-deadman --watch up (interval=${DEADMAN_INTERVAL}s clone=$DEADMAN_CLONE repo=$DEADMAN_REPO expect_poller=$DEADMAN_EXPECT_POLLER)"
    while :; do
      run_check >/dev/null || true    # the verdict rides the log in --watch; stdout is for --check
      sleep "$DEADMAN_INTERVAL"
    done
    ;;
  *) echo "usage: apparatus-deadman.sh --check | --watch | --selftest" >&2; exit 2;;
esac
