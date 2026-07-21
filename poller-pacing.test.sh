#!/usr/bin/env bash
# poller-pacing.test.sh — the ADAPTIVE RATE-LIMIT PACING wiring suite (2026-07-20).
#
# `interval_for` (the pure decision) is covered by --selftest; THIS suite proves the WIRING: the
# --watch loop actually READS the live GraphQL budget (graphql_remaining) and THROTTLES the sweep
# interval when it is low — the behaviour a revert to a plain `sleep "$POLL_INTERVAL"` would silently
# break while every pure selftest still passed (the poller-fixer.test.sh lesson: --selftest alone let
# real defects ship). DETERMINISTIC, not timing-flaky: the adaptive log line is emitted BEFORE the
# sleep, so wait_log detects it the instant a sweep completes — independent of the sleep's length.
#
# Drives the REAL `bin/pr-poller.sh --watch` against a stub `gh` whose `api rate_limit` remaining is
# controllable per-row; only `gh` is stubbed (the budget read under test is real). No GitHub/network/model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
BUDGET_FILE="$ROOT/budget"          # the stub reads the current rate_limit remaining from here

# ---- stub gh: one open PR (host=NONE → a NOOP sweep) + a controllable rate_limit remaining. ---------
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "api rate_limit") cat "$BUDGET_FILE" 2>/dev/null || :; exit 0;;   # the FREE budget read under test
  "pr list")
    case "\$*" in
      *"--state open"*) printf '%s\t%s\t%s\t%s\n' 1 feat/x 1234567890123456789012345678901234567890 '';;
      *) : ;;
    esac ;;
  "pr view") : ;;                                                    # no comments → host=NONE → NOOP
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# ---- fixture: a bare origin + clean clone (--watch needs a real clone for LAUNCH_HEAD + a $HOME). ---
ORIGIN="$ROOT/origin.git"; CLONE="$ROOT/clone"; HOMEDIR="$ROOT/home"; mkdir -p "$HOMEDIR"
git init -q --bare -b main "$ORIGIN"
SEED="$ROOT/seed"; git init -q -b main "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
echo base > "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" remote add origin "$ORIGIN"; git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$CLONE"

SWEPT='sweep: oso-gato/fedora-dev open PRs'   # the per-repo sweep-completion marker (SLUG-prefixed)
pass=0; fail=0
ck(){ [ "$1" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$2"; } || { fail=$((fail+1)); printf '  FAIL %s\n' "$2"; }; }

# background the REAL --watch loop; SELF_REFRESH=0 (no reload machinery), FLEET_HALT=true (=RUN).
# POLL_INTERVAL=1 base; the pacing thresholds are pinned so the throttled values are unambiguous.
watch_bg(){ # <script> <secs>
  OUT="$ROOT/watch.out"; : > "$OUT"
  env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" PATH="$BIN:$PATH" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FLEET_HALT=true SELF_REFRESH=0 \
      POLL_INTERVAL=1 POLL_GRAPHQL_AMPLE=2000 POLL_GRAPHQL_LOW=500 POLL_SLOW_MULT=4 POLL_PAUSE_INTERVAL=7 \
      timeout "$2" bash "$1" --watch >"$OUT" 2>&1 &
  WATCH_PID=$!
}
wait_log(){ # <fixed-string> <secs>
  local i=0 max=$(( ${2:-8} * 10 ))
  until grep -qF "$1" "$OUT"; do i=$((i+1)); [ "$i" -gt "$max" ] && return 1; sleep 0.1; done
}
stop_watch(){ kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; }

echo "== LOW band (500 ≤ remaining < 2000) → back off to base×4 =="
printf '800\n' > "$BUDGET_FILE"
watch_bg "$POLLER" 6
if wait_log 'adaptive pacing: graphql remaining=800' 6; then
  ck "$(grep -qF 'sleeping 4s' "$OUT" && echo 1 || echo 0)" "LOW → logs 'sleeping 4s' (base 1 × mult 4)"
else ck 0 "LOW → adaptive pacing line never appeared"; fi
stop_watch

echo "== CRITICAL (remaining < 500) → the long pause (rides the hourly reset) =="
printf '100\n' > "$BUDGET_FILE"
watch_bg "$POLLER" 5
if wait_log 'adaptive pacing: graphql remaining=100' 5; then
  ck "$(grep -qF 'sleeping 7s' "$OUT" && echo 1 || echo 0)" "CRITICAL → logs 'sleeping 7s' (POLL_PAUSE_INTERVAL)"
else ck 0 "CRITICAL → adaptive pacing line never appeared"; fi
stop_watch

echo "== AMPLE (remaining ≥ 2000) → base cadence, NO adaptive log (no per-sweep noise) =="
printf '5000\n' > "$BUDGET_FILE"
watch_bg "$POLLER" 4
wait_log "$SWEPT" 4    # a sweep actually completed
sleep 1                # let the post-sweep pacing decision run
ck "$(grep -qF 'adaptive pacing' "$OUT" && echo 0 || echo 1)" "AMPLE → no adaptive pacing line logged"
stop_watch

echo "== UNREADABLE budget (empty read) → fail-safe to base, NO adaptive log =="
: > "$BUDGET_FILE"
watch_bg "$POLLER" 4
wait_log "$SWEPT" 4
sleep 1
ck "$(grep -qF 'adaptive pacing' "$OUT" && echo 0 || echo 1)" "UNREADABLE → fail-safe to base, quiet"
stop_watch

echo "== MUTATION (run in-suite): neutralize the interval_for wiring → sleep hardcoded to base =="
# The wiring must be what throttles. Restore a plain `sleep "$POLL_INTERVAL"` (interval_for uncalled)
# and the LOW row must then log NO adaptive line. The mutant sits BESIDE a COPY of bin/ so it resolves
# its real sibling scripts (repo-scope.sh, fleet-halt.sh) via its own $HERE. The sed must genuinely
# change the copy, else the row is vacuous.
MUTBIN="$ROOT/mutbin"; cp -r "$HERE/bin" "$MUTBIN"
sed -i 's/nap="\$(interval_for "\$rem" "\$POLL_INTERVAL")"/nap="\$POLL_INTERVAL"/' "$MUTBIN/pr-poller.sh"
if cmp -s "$POLLER" "$MUTBIN/pr-poller.sh"; then
  ck 0 "MUTATION was vacuous — the sed changed nothing (guard the wiring's shape)"
else
  printf '800\n' > "$BUDGET_FILE"
  watch_bg "$MUTBIN/pr-poller.sh" 4
  wait_log "$SWEPT" 4
  sleep 1
  ck "$(grep -qF 'adaptive pacing' "$OUT" && echo 0 || echo 1)" "MUTANT (hardcoded base) logs NO adaptive line — the real wiring is what throttles"
  stop_watch
fi

echo
echo "poller-pacing: $pass passed, $fail failed"
[ "$fail" = 0 ]
