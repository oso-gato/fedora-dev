#!/usr/bin/env bash
# apparatus-deadman.test.sh — MOCK end-to-end suite for bin/apparatus-deadman.sh (R18 liveness deadman).
#
# REAL where it matters, stub only the boundary:
#   * a REAL bare origin + working clone you can set BEHIND / AHEAD / DIRTY (the git facts are real git);
#   * a REAL backgrounded process whose cmdline IS `bash …/pr-poller.sh --watch` (the "genuine poller")
#     + a REAL DECOY (`pr-poller.sh --watch` as a bare argv[0], no script path) — the self-match axis is
#     exercised against actual /proc, not asserted;
#   * a REAL poller-log file whose mtime is aged with `touch -d`;
#   * `gh` STUBBED to RECORD every create/edit/comment/close/search (no network).
#
# Asserts: each of the 4 anomalies fires with the right reason · all-healthy ⇒ ZERO gh writes · dedup
# (two anomalies ⇒ ONE issue, updated) · healthy-after-anomaly ⇒ cleared + closed · the SELF-MATCH decoy
# does NOT trip poller-alive · the deadman NEVER writes the clone (HEAD + status unchanged after a check)
# · an unreadable signal surfaces ONLY after the consecutive bound. In-suite MUTATION-CHECKS (grep-verified
# non-vacuous, since cmp/diff are forbidden): neutralize the lag gate ⇒ merged-not-live stops firing;
# neutralize the self-match exclusion ⇒ the decoy trips it.
#
#   bash apparatus-deadman.test.sh   → exit 0 = all rows pass. No GitHub / network / model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/apparatus-deadman.sh"
ROOT="$(mktemp -d)"
export GH_CALLS="$ROOT/gh.calls"
export GH_SEARCH_RESULT=""
export DEADMAN_REPO="oso-gato/fedora-bootstrap"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
GENUINE_PID=""; DECOY_PID=""

cleanup(){ stop_procs; rm -rf "$ROOT"; }
stop_procs(){
  [ -n "$GENUINE_PID" ] && kill "$GENUINE_PID" 2>/dev/null; wait "$GENUINE_PID" 2>/dev/null
  [ -n "$DECOY_PID" ]   && kill "$DECOY_PID"   2>/dev/null; wait "$DECOY_PID"   2>/dev/null
  GENUINE_PID=""; DECOY_PID=""
}
trap cleanup EXIT

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/stub" "$ROOT/fakebin"
cat > "$ROOT/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "${1:-}" in
  api)   [ -n "${GH_SEARCH_RESULT:-}" ] && [ -f "$GH_SEARCH_RESULT" ] && cat "$GH_SEARCH_RESULT"; exit 0;;
  issue) case "${2:-}" in create) echo "https://github.com/${DEADMAN_REPO:-x/y}/issues/4242";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$ROOT/stub/gh"
export PATH="$ROOT/stub:$PATH"

# The box runs a REAL `pr-poller.sh --watch`, and /proc is shared, so the fixture poller is named
# `fake-poller.sh` and every dm() passes DEADMAN_POLLER_NAME=fake-poller.sh — the deadman then matches
# ONLY the fixture, never the live poller. A fake poller whose cmdline stays `bash …/fake-poller.sh
# --watch` (two statements defeat bash's last-command exec optimization, so the bash process — not an
# exec'd sleep — is the one holding the path).
POLLER_NAME="fake-poller.sh"
cat > "$ROOT/fakebin/$POLLER_NAME" <<'EOF'
#!/bin/bash
sleep 100000 &
wait
EOF
chmod +x "$ROOT/fakebin/$POLLER_NAME"

start_genuine(){ bash "$ROOT/fakebin/$POLLER_NAME" --watch & GENUINE_PID=$!; sleep 0.25; }
# a "similarly-named process": the bare pattern as argv[0], a real sleep — NOT the poller
start_decoy(){ bash -c 'exec -a "fake-poller.sh --watch" sleep 100000' & DECOY_PID=$!; sleep 0.25; }

git_q(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
new_origin_and_clone(){   # $1 = dir stem → creates $1.git (bare origin, main=seed) + $1 (clone at seed)
  local stem="$1"
  git init -q --bare "$stem.git"
  git clone -q "$stem.git" "$stem" 2>/dev/null
  ( cd "$stem" && git -c user.email=t@t -c user.name=t checkout -q -b main 2>/dev/null
    echo seed > seed.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed
    git push -q origin main )
}
advance_origin(){   # $1 = dir stem → add one commit to origin/main WITHOUT touching the clone
  local p="$ROOT/pusher.$RANDOM"
  git clone -q "$1.git" "$p" 2>/dev/null
  ( cd "$p" && git checkout -q main 2>/dev/null
    echo "adv $RANDOM" > adv.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm adv
    git push -q origin HEAD:main )
  rm -rf "$p"
}

# freshstate → a clean state dir for a scenario; agelog → set the poller-log mtime.
freshstate(){ local d="$ROOT/state.$RANDOM"; mkdir -p "$d"; printf '%s' "$d"; }
agelog(){ touch -d "@$(( $(date +%s) - ${2:-1000} ))" "$1"; }     # $1=log $2=age-seconds (default 1000)
freshlog(){ : > "$1"; touch "$1"; }

# dm → run one --check with scenario env; captures OUT + RC. Common knobs default here, override via env.
# DEADMAN_POLLER_NAME=fake-poller.sh keeps the deadman blind to the box's REAL running pr-poller.sh.
dm(){   # args: KEY=VAL … (extra env)
  OUT="$(env "$@" \
    DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_GIT_TIMEOUT=15 DEADMAN_GH_TIMEOUT=15 \
    bash "$SCRIPT" --check 2>>"$ROOT/deadman.stderr")"
  RC=$?
}

# ── ANOMALY 1 — MERGED-NOT-LIVE (clean clone behind past the lag grace) ─────────────────────────────
echo "== the four anomalies =="
S="$ROOT/mnl"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
{ echo "$OUT" | grep -q MERGED_NOT_LIVE && [ "$RC" != 0 ] && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "MERGED_NOT_LIVE fires on a clean behind clone + opens an issue" \
  || bad "MERGED_NOT_LIVE" "rc=$RC out=[$OUT] calls=[$(cat "$GH_CALLS")]"

# ── ANOMALY 2 — SELF-REFRESH BLOCKED (behind AND dirty ⇒ never ff) ──────────────────────────────────
S="$ROOT/srb"; new_origin_and_clone "$S"; advance_origin "$S"; echo dirt > "$S/dirty.txt"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=99
{ echo "$OUT" | grep -q SELF_REFRESH_BLOCKED && echo "$OUT" | grep -q 'dirty.txt' && [ "$RC" != 0 ]; } \
  && ok "SELF_REFRESH_BLOCKED fires immediately on a dirty+behind clone, naming the dirty path" \
  || bad "SELF_REFRESH_BLOCKED" "rc=$RC out=[$OUT]"

# ── ANOMALY 3 — POLLER FROZEN (alive but log mtime stale) ───────────────────────────────────────────
S="$ROOT/frz"; new_origin_and_clone "$S"; ST="$(freshstate)"; LOG="$ROOT/frozen.log"; freshlog "$LOG"; agelog "$LOG" 1000
: > "$GH_CALLS"; start_genuine
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" DEADMAN_SWEEP_MAX=300
{ echo "$OUT" | grep -q POLLER_FROZEN && [ "$RC" != 0 ]; } \
  && ok "POLLER_FROZEN fires when a live poller's log has not advanced" \
  || bad "POLLER_FROZEN" "rc=$RC out=[$OUT]"
stop_procs

# ── ANOMALY 4 — POLLER DOWN (no --watch process at all) ─────────────────────────────────────────────
S="$ROOT/down"; new_origin_and_clone "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$ROOT/none.log"
{ echo "$OUT" | grep -q POLLER_DOWN && [ "$RC" != 0 ]; } \
  && ok "POLLER_DOWN fires when no pr-poller.sh --watch process exists" \
  || bad "POLLER_DOWN" "rc=$RC out=[$OUT]"

# ── ALL-HEALTHY ⇒ ZERO gh writes ────────────────────────────────────────────────────────────────────
echo "== quiet-when-healthy, dedup, clear =="
S="$ROOT/ok"; new_origin_and_clone "$S"; ST="$(freshstate)"; LOG="$ROOT/ok.log"; freshlog "$LOG"
: > "$GH_CALLS"; start_genuine
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" DEADMAN_SWEEP_MAX=300
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q '^HEALTHY' && [ ! -s "$GH_CALLS" ]; } \
  && ok "all-healthy (current clone, live poller, fresh log) ⇒ rc 0 and ZERO gh writes" \
  || bad "healthy-quiet" "rc=$RC out=[$OUT] calls=[$(cat "$GH_CALLS")]"
stop_procs

# ── DEDUP — two anomalies ⇒ ONE issue, UPDATED (never a second create) ──────────────────────────────
S="$ROOT/dup"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
c_create="$(grep -c '^issue create' "$GH_CALLS")"; c_edit="$(grep -c '^issue edit' "$GH_CALLS")"
{ [ "$c_create" = 1 ] && [ "$c_edit" -ge 1 ]; } \
  && ok "dedup: two anomalies ⇒ exactly ONE create + an in-place update (edit)" \
  || bad "dedup" "creates=$c_create edits=$c_edit calls=[$(cat "$GH_CALLS")]"

# ── HEALTHY-AFTER-ANOMALY ⇒ cleared + closed ────────────────────────────────────────────────────────
S="$ROOT/clr"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1   # anomaly → creates 4242
git_q "$S" pull -q origin main 2>/dev/null    # operator/supervisor fixes it: clone catches up
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1   # now healthy
{ [ "$RC" = 0 ] && grep -q '^issue comment 4242' "$GH_CALLS" && grep -q '^issue close 4242' "$GH_CALLS"; } \
  && ok "healthy-after-anomaly ⇒ posts a cleared comment + closes the issue" \
  || bad "clear-on-heal" "rc=$RC calls=[$(cat "$GH_CALLS")]"

# ── SELF-MATCH — the decoy does NOT trip poller-alive ───────────────────────────────────────────────
echo "== self-match safety =="
S="$ROOT/decoy"; new_origin_and_clone "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
start_decoy   # a bare-string look-alike, NO genuine poller running
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$ROOT/none.log"
{ echo "$OUT" | grep -q POLLER_DOWN; } \
  && ok "the SELF-MATCH decoy does NOT fool poller-alive (POLLER_DOWN still fires)" \
  || bad "self-match-decoy" "the decoy was mistaken for the poller — out=[$OUT]"
stop_procs

# ── THE DEADMAN NEVER WRITES THE CLONE (HEAD + status unchanged after a check) ──────────────────────
echo "== read-only: the deadman never writes the clone =="
S="$ROOT/ro"; new_origin_and_clone "$S"; advance_origin "$S"; echo dirt > "$S/dirty.txt"; ST="$(freshstate)"
head_before="$(git -C "$S" rev-parse HEAD)"; status_before="$(git -C "$S" status --porcelain)"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
head_after="$(git -C "$S" rev-parse HEAD)"; status_after="$(git -C "$S" status --porcelain)"
{ [ "$head_before" = "$head_after" ] && [ "$status_before" = "$status_after" ]; } \
  && ok "clone HEAD + working-tree status are BYTE-IDENTICAL after a check (no pull/merge/checkout)" \
  || bad "read-only" "HEAD $head_before→$head_after  status changed"

# ── UNREADABLE surfaces ONLY after the consecutive bound ────────────────────────────────────────────
echo "== fail-toward-surfacing: unreadable only after the bound =="
S="$ROOT/unr"; new_origin_and_clone "$S"; git -C "$S" remote set-url origin /nonexistent/nope.git
ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_UNREADABLE_MAX=2   # check 1
r1_rc="$RC"; r1_cv=0; echo "$OUT" | grep -q CANNOT_VERIFY && r1_cv=1
r1_empty=1; [ -s "$GH_CALLS" ] && r1_empty=0                                                  # no gh write on the blip
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_UNREADABLE_MAX=2   # check 2 → bound
{ [ "$r1_cv" = 0 ] && [ "$r1_rc" = 0 ] && [ "$r1_empty" = 1 ] \
  && echo "$OUT" | grep -q CANNOT_VERIFY && [ "$RC" != 0 ] && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "one unreadable check stays quiet (no gh); the SECOND (>= bound) surfaces CANNOT_VERIFY" \
  || bad "unreadable-bound" "check1 rc=$r1_rc cv=$r1_cv empty=$r1_empty ; check2 rc=$RC out=[$OUT]"

# ── MUTATION-CHECK 1 — neutralize the lag gate ⇒ merged-not-live stops firing ───────────────────────
echo "== mutation-checks (grep-verified non-vacuous) =="
CP="$ROOT/mut-lag.sh"
sed 's/\[ "\$lag_streak" -ge "\$lag_max" \]/[ "$lag_streak" -ge 999999 ]/' "$SCRIPT" > "$CP"; chmod +x "$CP"
if grep -qF '[ "$lag_streak" -ge 999999 ]' "$CP" && ! grep -qF '[ "$lag_streak" -ge 999999 ]' "$SCRIPT"; then
  S="$ROOT/mut1"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"
  # baseline: the ORIGINAL fires
  OUT_o="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$SCRIPT" --check 2>/dev/null)"
  # mutant: merged-not-live must STOP firing
  OUT_m="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$CP" --check 2>/dev/null)"
  { echo "$OUT_o" | grep -q MERGED_NOT_LIVE && ! echo "$OUT_m" | grep -q MERGED_NOT_LIVE; } \
    && ok "neutralizing the lag gate makes MERGED_NOT_LIVE stop firing (row is non-vacuous)" \
    || bad "mutation-lag" "orig=[$OUT_o] mutant=[$OUT_m]"
else
  bad "mutation-lag" "the sed did not change the copy — vacuous"
fi

# ── MUTATION-CHECK 2 — neutralize the self-match exclusion ⇒ the decoy trips it ─────────────────────
CP2="$ROOT/mut-self.sh"
sed 's#\*/\$DEADMAN_POLLER_NAME\*--watch\*) return 0#*$DEADMAN_POLLER_NAME*--watch*) return 0#' "$SCRIPT" > "$CP2"; chmod +x "$CP2"
if grep -qF '*$DEADMAN_POLLER_NAME*--watch*) return 0' "$CP2" && ! grep -qF '*$DEADMAN_POLLER_NAME*--watch*) return 0' "$SCRIPT"; then
  S="$ROOT/mut2"; new_origin_and_clone "$S"; freshlog "$ROOT/mut2.log"; : > "$GH_CALLS"
  start_decoy   # decoy running, NO genuine poller
  OUT_o="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=1 \
             DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_POLLER_LOG="$ROOT/mut2.log" DEADMAN_SWEEP_MAX=300 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$SCRIPT" --check 2>/dev/null)"   # original: decoy ignored ⇒ POLLER_DOWN
  OUT_m="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=1 \
             DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_POLLER_LOG="$ROOT/mut2.log" DEADMAN_SWEEP_MAX=300 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$CP2" --check 2>/dev/null)"       # mutant: decoy counted alive ⇒ no POLLER_DOWN
  stop_procs
  { echo "$OUT_o" | grep -q POLLER_DOWN && ! echo "$OUT_m" | grep -q POLLER_DOWN; } \
    && ok "neutralizing the slash-anchored self-match guard lets the decoy trip poller-alive (non-vacuous)" \
    || bad "mutation-self" "orig=[$OUT_o] mutant=[$OUT_m]"
else
  bad "mutation-self" "the sed did not change the copy — vacuous"
fi

echo
echo "apparatus-deadman.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
