#!/usr/bin/env bash
# poller-lock.test.sh — the LOCK-LIVENESS suite (#173): the flock singleton survives a box recreate,
# with ZERO GitHub / network / model.
#
# WHY THIS EXISTS: the --watch lock lives on the HOME VOLUME, which outlives the poller process. On
# 2026-07-13 a claudebox-rebuild orphaned the running poller (the box shares fedora-dev's PID
# namespace, so `distrobox rm` does not reap what it spawned); the orphan's lingering process/FD kept
# the flock held while sweeping NOTHING, and the fresh poller found the lock held and politely exited
# 0 — every 30 s, 08:27→12:23: FOUR HOURS of zero sweeps, zero merges, and nothing anywhere said "the
# poller is down". The singleton exists to prevent TWO pollers; it produced ZERO and reported success.
#
# HOW IT BITES — the fixture is real where it must be: the flock is REALLY held by a lingering
# background process (an inherited fd on the lock inode, exactly the incident's shape), the recorded
# holders are REAL processes with REAL /proc starttimes, and the rows drive the REAL
# `bin/pr-poller.sh --watch`. Only `gh` is stubbed (a sweep is a cheap NOOP; issue creates are
# recorded, never posted).
#   * THE MUTATION IS RESTORED MECHANICALLY AND RUN IN-SUITE (issue req 4: "restoring the bare-flock
#     behavior must fail the dead-holder row"): a copy of the poller gets the bare
#     `flock -n 9 || exit 0` back, and against the dead-holder fixture it must exit rc=0 WITHOUT
#     sweeping — the incident's exact lie — proving the real row discriminates. The sed must genuinely
#     change the copy or that row fails as vacuous.
#   * The LIVE-holder row is the discriminator the issue names: adjudication must not decay into
#     take-always (two pollers must never both run).
#   * The DEFER rows pin req 2: a deferral exits POLLER_DEFER_RC (never 0), and a CONSECUTIVE streak
#     surfaces exactly ONE question.
#
# Run:  bash poller-lock.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$POLLER" ] || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
command -v flock >/dev/null   || { echo "FATAL: flock required"; exit 2; }
command -v timeout >/dev/null || { echo "FATAL: timeout required"; exit 2; }
DEFER_RC=91
BOOTID="$(cat /proc/sys/kernel/random/boot_id)"

ROOT="$(mktemp -d)"; HOLDERS=""
trap 'kill $HOLDERS >/dev/null 2>&1; rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: one open PR, NO verdict → a sweep resolves to host=NONE ⇒ NOOP. Records every call to
# $GH_CALLS (the surface rows count `issue create`); never touches GitHub. -----------------------------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_CALLS:-}" ] && printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list")
    case "$*" in
      *"--state open"*) printf '%s\t%s\t%s\n' 1 feat/x 1234567890123456789012345678901234567890;;
      *) : ;;                                   # merged list (retire) etc. → empty
    esac ;;
  "pr view") : ;;                               # no comments → host=NONE → NOOP
  "issue create") echo "https://github.com/oso-gato/fedora-dev/issues/999";;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }
haslog(){ grep -qF "$1" "$OUT"; }

newcase(){
  n=$((n+1)); CASE="$ROOT/c$n"; HOMEDIR="$CASE/home"
  STATE="$HOMEDIR/.local/state/pr-poller"; mkdir -p "$STATE"
  LOCK="$STATE/poller.lock"; GH_CALLS="$CASE/gh.calls"; : > "$GH_CALLS"; runs=0
}
# drive the REAL --watch for <secs>. A poller that RUNS is killed by timeout → rc=124 (its TERM trap
# exits 0, but GNU timeout reports 124 on a timeout); a poller that DEFERS exits DEFER_RC well before.
run_watch(){ # <secs> extra env…
  local secs="$1"; shift
  runs=$((runs+1)); OUT="$CASE/watch.$runs.out"
  # shellcheck disable=SC2086
  env HOME="$HOMEDIR" PATH="$BIN:$PATH" GH_CALLS="$GH_CALLS" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FLEET_HALT=true \
      SELF_REFRESH=0 HOST_REFRESH_EVERY=0 POLL_INTERVAL=1 "$@" \
      timeout "$secs" bash "${SUBJECT:-$POLLER}" --watch >"$OUT" 2>&1
  RC=$?
}
# a LINGERING flock holder that records a GIVEN line (the incident's shape: the fd survives, the
# recorded process does not have to). `exec sleep` keeps the pid AND the inherited fd 9.
start_holder(){ # <record-line>
  (
    exec 9>>"$LOCK"
    flock 9 || exit 1
    printf '%s\n' "$1" > "$LOCK"
    exec sleep 300
  ) &
  HOLDER=$!; HOLDERS="$HOLDERS $HOLDER"
  local i=0
  until [ "$(head -n1 "$LOCK" 2>/dev/null)" = "$1" ]; do
    i=$((i+1)); [ "$i" -gt 50 ] && return 1; sleep 0.1
  done
}
# a holder that records its OWN true identity (pid + boot + real /proc starttime) — the live-poller
# stand-in. <gen> is the box generation it claims to belong to.
start_live_holder(){ # <gen>
  (
    g="$1"                                    # capture BEFORE `set --` clobbers the positional params
    exec 9>>"$LOCK"
    flock 9 || exit 1
    s="$(cat "/proc/$BASHPID/stat")"; s="${s##*) }"; set -- $s
    printf '%s %s %s %s\n' "$BASHPID" "$(cat /proc/sys/kernel/random/boot_id)" "${20}" "$g" > "$LOCK"
    exec sleep 300
  ) &
  HOLDER=$!; HOLDERS="$HOLDERS $HOLDER"
  local i=0
  until head -n1 "$LOCK" 2>/dev/null | grep -q "^$HOLDER "; do
    i=$((i+1)); [ "$i" -gt 50 ] && return 1; sleep 0.1
  done
}
dead_pid(){ sleep 0.01 & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
proc_start_of(){ local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0; s="${s##*) }"; set -- $s; printf '%s' "${20:-}"; }
lock_pid(){ awk '{print $1; exit}' "$LOCK" 2>/dev/null; }

# ===================================================================================================
echo "== DEAD HOLDER (the incident class): a lingering FD whose recorded holder is dead → TAKE + SWEEP =="
DESC="dead recorded holder → the new poller rotates the lock, starts, and sweeps"; OK=1
newcase
DP="$(dead_pid)"
start_holder "$DP $BOOTID 424242 genX" || ck 0 "fixture: the lingering holder never wrote its record"
run_watch 5 POLLER_BOX_GEN=genX
ck "$([ "$RC" = 124 ] && echo 1 || echo 0)" "the poller did not RUN to the timeout (rc=$RC want 124) — a bare flock defers to a dead holder's lingering FD forever"
ck "$(haslog 'TAKEOVER_DEAD' && echo 1 || echo 0)" "the takeover did not name its cause (TAKEOVER_DEAD)"
ck "$(haslog 'sweep: oso-gato/fedora-dev open PRs' && echo 1 || echo 0)" "the new poller never swept"
ck "$([ "$(lock_pid)" != "$DP" ] && echo 1 || echo 0)" "the lock still records the dead holder — the new poller never wrote its own record"
ck "$(kill -0 "$HOLDER" 2>/dev/null && echo 1 || echo 0)" "the lingering FD-holder was signalled — it is NOT the recorded process (an innocent stranger must never be killed)"
kill "$HOLDER" 2>/dev/null
done_case

echo "== LIVE HOLDER (the discriminator): a genuinely live same-generation poller → still DEFER, loudly =="
DESC="live same-gen holder → defer with rc=$DEFER_RC (never 0), no second poller"; OK=1
newcase
start_live_holder genX || ck 0 "fixture: the live holder never wrote its record"
run_watch 5 POLLER_BOX_GEN=genX
ck "$([ "$RC" = "$DEFER_RC" ] && echo 1 || echo 0)" "a LIVE same-generation holder did not defer (rc=$RC want $DEFER_RC) — adjudication must not decay into take-always"
ck "$([ "$RC" != 0 ] && echo 1 || echo 0)" "a deferral exited rc=0 — the incident's exact lie (req 2)"
ck "$(haslog 'lock DEFER #1' && echo 1 || echo 0)" "the deferral was not logged with its streak count"
ck "$(haslog 'sweep:' && echo 0 || echo 1)" "a SECOND poller swept alongside a live holder"
ck "$(haslog 'pr-poller --watch up' && echo 0 || echo 1)" "a second poller came up alongside a live holder"
ck "$([ "$(cat "$STATE/lock-defer.count" 2>/dev/null)" = 1 ] && echo 1 || echo 0)" "the deferral streak counter is not 1"
ck "$([ "$(lock_pid)" = "$HOLDER" ] && echo 1 || echo 0)" "the holder's record was clobbered by the contender"
ck "$(kill -0 "$HOLDER" 2>/dev/null && echo 1 || echo 0)" "the live holder was signalled"
kill "$HOLDER" 2>/dev/null
done_case

echo "== PREVIOUS GENERATION (THE incident): a live orphan of a torn-down box → TERM + TAKE + SWEEP =="
DESC="live previous-generation orphan → TERMed, lock taken, sweeps resume"; OK=1
newcase
start_live_holder genOLD || ck 0 "fixture: the orphan never wrote its record"
run_watch 5 POLLER_BOX_GEN=genNEW
ck "$([ "$RC" = 124 ] && echo 1 || echo 0)" "the box-recreate orphan kept the singleton down (rc=$RC want 124)"
ck "$(haslog 'TAKEOVER_GENERATION' && echo 1 || echo 0)" "the takeover did not name its cause (TAKEOVER_GENERATION)"
ck "$(haslog 'sweep: oso-gato/fedora-dev open PRs' && echo 1 || echo 0)" "sweeps did not resume"
ck "$(kill -0 "$HOLDER" 2>/dev/null && echo 0 || echo 1)" "the previous-generation orphan was not TERMed (still alive)"
ck "$([ "$(lock_pid)" != "$HOLDER" ] && echo 1 || echo 0)" "the lock still records the orphan"
done_case

echo "== RECYCLED PID: the recorded pid now wears a different starttime → TAKE, and the stranger is NOT killed =="
DESC="recycled pid → takeover; the innocent process wearing the pid is never signalled"; OK=1
newcase
sleep 300 & INNOCENT=$!; HOLDERS="$HOLDERS $INNOCENT"
IST="$(proc_start_of "$INNOCENT")"
[ -n "$IST" ] || ck 0 "fixture: could not read the innocent's starttime"
start_holder "$INNOCENT $BOOTID $((IST+7)) genX" || ck 0 "fixture: the lingering holder never wrote its record"
run_watch 5 POLLER_BOX_GEN=genX
ck "$([ "$RC" = 124 ] && echo 1 || echo 0)" "the poller did not run (rc=$RC want 124)"
ck "$(haslog 'TAKEOVER_RECYCLED' && echo 1 || echo 0)" "the takeover did not name its cause (TAKEOVER_RECYCLED)"
ck "$(haslog 'sweep:' && echo 1 || echo 0)" "the poller never swept"
ck "$(kill -0 "$INNOCENT" 2>/dev/null && echo 1 || echo 0)" "the innocent stranger wearing the recycled pid was signalled"
kill "$INNOCENT" "$HOLDER" 2>/dev/null
done_case

echo "== DEFERRAL STREAK (req 2): N consecutive deferrals surface ONE question; acquisition resets =="
DESC="LOCK_DEFER_MAX consecutive deferrals → exactly one issue; a later acquisition resets the streak"; OK=1
newcase
start_live_holder genX || ck 0 "fixture: the live holder never wrote its record"
run_watch 5 POLLER_BOX_GEN=genX LOCK_DEFER_MAX=3
ck "$([ "$RC" = "$DEFER_RC" ] && echo 1 || echo 0)" "defer #1 did not exit $DEFER_RC (rc=$RC)"
run_watch 5 POLLER_BOX_GEN=genX LOCK_DEFER_MAX=3
ck "$([ "$(grep -c '^issue create' "$GH_CALLS")" = 0 ] && echo 1 || echo 0)" "a question was surfaced BEFORE the streak reached the bound"
run_watch 5 POLLER_BOX_GEN=genX LOCK_DEFER_MAX=3
ck "$([ "$RC" = "$DEFER_RC" ] && echo 1 || echo 0)" "defer #3 did not exit $DEFER_RC (rc=$RC)"
ck "$(haslog 'lock DEFER #3' && echo 1 || echo 0)" "the third deferral did not carry its streak count"
ck "$([ "$(grep -c '^issue create' "$GH_CALLS")" = 1 ] && echo 1 || echo 0)" "the streak did not surface exactly one question ($(grep -c '^issue create' "$GH_CALLS") issue creates)"
run_watch 5 POLLER_BOX_GEN=genX LOCK_DEFER_MAX=3
ck "$([ "$(grep -c '^issue create' "$GH_CALLS")" = 1 ] && echo 1 || echo 0)" "a further deferral re-posted the question (the marker must gate it)"
kill "$HOLDER" 2>/dev/null; sleep 0.3                    # the holder exits → the flock frees
run_watch 5 POLLER_BOX_GEN=genX LOCK_DEFER_MAX=3
ck "$([ "$RC" = 124 ] && echo 1 || echo 0)" "the poller did not start once the holder exited (rc=$RC want 124)"
ck "$(haslog 'ACQUIRED (fresh) after 4 deferral(s)' && echo 1 || echo 0)" "the acquisition did not report the streak it ends"
ck "$([ ! -f "$STATE/lock-defer.count" ] && echo 1 || echo 0)" "the streak counter survived an acquisition"
ck "$([ ! -f "$STATE/lock-defer.surfaced" ] && echo 1 || echo 0)" "the surfaced marker survived an acquisition (the NEXT incident's question would be swallowed)"
done_case

echo "== STREAK WINDOW: a stray deferral from hours ago never pre-charges a fresh streak =="
DESC="a defer older than LOCK_DEFER_WINDOW resets the count — the 'consecutive' claim stays true"; OK=1
newcase
start_live_holder genX || ck 0 "fixture: the live holder never wrote its record"
run_watch 5 POLLER_BOX_GEN=genX
ck "$(haslog 'lock DEFER #1' && echo 1 || echo 0)" "the first deferral is not #1"
touch -d '-2 hours' "$STATE/lock-defer.count"
run_watch 5 POLLER_BOX_GEN=genX
ck "$(haslog 'lock DEFER #1' && echo 1 || echo 0)" "a 2-hour-old stray deferral pre-charged the streak (want #1 again, got: $(grep -o 'lock DEFER #[0-9]*' "$OUT" | tail -1))"
kill "$HOLDER" 2>/dev/null
done_case

echo "== MUTATION (req 4): the bare flock RESTORED MECHANICALLY → the dead-holder row must FAIL =="
DESC="bare 'flock -n 9 || exit 0' restored in a copy → same fixture defers rc=0 without sweeping (the row bites)"; OK=1
MUT="$ROOT/pr-poller.bareflock-mutant.sh"; cp "$POLLER" "$MUT"
sed -i 's#^    lock_acquire$#    exec 9>"$STATE/poller.lock"; flock -n 9 || { echo "another pr-poller --watch holds the lock; exiting" >\&2; exit 0; }#' "$MUT"
ck "$(cmp -s "$POLLER" "$MUT" && echo 0 || echo 1)" "the mutation sed changed NOTHING — this row is vacuous"
newcase
DP="$(dead_pid)"
start_holder "$DP $BOOTID 424242 genX" || ck 0 "fixture: the lingering holder never wrote its record"
SUBJECT="$MUT" run_watch 5 POLLER_BOX_GEN=genX
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "the bare-flock mutant did not exit rc=0 (rc=$RC) — the dead-holder row would not discriminate"
ck "$(haslog 'sweep:' && echo 0 || echo 1)" "the bare-flock mutant swept — the dead-holder row would not discriminate"
ck "$(haslog 'pr-poller --watch up' && echo 0 || echo 1)" "the bare-flock mutant came up"
kill "$HOLDER" 2>/dev/null
done_case

echo
echo "poller-lock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
