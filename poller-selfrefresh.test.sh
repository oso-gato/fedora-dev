#!/usr/bin/env bash
# poller-selfrefresh.test.sh — the SELF-REFRESH suite (#162): the running poller deploys its OWN merged
# code (no human `git pull` + bounce), with ZERO GitHub / network / model.
#
# WHY THIS EXISTS: nothing on any cadence pulled the live clone, so every merged self-improvement
# (#147, #153, #156, #158, #160→#161…) needed a hand pull + hand bounce of `pr-poller.sh --watch` to
# take effect. This proves the closed loop instead: the poller DETECTS (at a safe point) that
# origin/main advanced and STEPS ASIDE; poller-service.sh ff-pulls the clone + relaunches on the new
# code. The three requirement-6 properties each get a biting, mutation-checked row.
#
# HOW IT BITES — the fixture is real where it must be: a REAL bare `origin` + REAL working clones + the
# REAL git fetch/merge. Only `gh` is stubbed (so a --watch sweep is a cheap NOOP); the self-refresh
# fetch/pull is REAL git against a real remote, which is the axis under test.
#   * REMOVE THE RELOAD  (restore the no-refresh behaviour): the --watch loop then never exits
#     POLLER_RELOAD_RC, so the "advanced origin → reload" row's `rc == 90` FAILS (timeout kills it → 124).
#   * MOVE THE CHECK MID-SWEEP: a `self-refresh:` line then appears INSIDE a sweep block → the
#     never-mid-fixer row FAILS (sweep()'s fixer/review/merge are synchronous, so "never mid-sweep" IS
#     "never mid-fixer").
#   * DROP THE DIRTY/DIVERGED GUARD or the fail-safe: the dirty and fetch-fail rows (loop keeps running,
#     clone untouched) FAIL.
#   * RESTORE THE CLONE-HEAD PROXY (#170: `running=$(git rev-parse HEAD)` inside the check — the defect
#     the FIRST live exercise found, 2026-07-13: a third party pulling the clone makes clone==origin
#     read UPTODATE forever while the process runs the launch-time build, so the reload silently
#     self-disables): the external-pull rows then read UPTODATE and FAIL. This one is not left to a
#     hand-run mutation — the proxy is RESTORED MECHANICALLY and RUN IN-SUITE below, and the sed must
#     genuinely change the copy or that row fails as vacuous.
#
# Run:  bash poller-selfrefresh.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
SERVICE="$HERE/bin/poller-service.sh"
[ -f "$POLLER" ]  || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
[ -f "$SERVICE" ] || { echo "FATAL: bin/poller-service.sh not found"; exit 2; }
command -v git >/dev/null     || { echo "FATAL: git required"; exit 2; }
command -v timeout >/dev/null || { echo "FATAL: timeout required"; exit 2; }
RELOAD_RC=90

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: one open PR, NO verdict → a sweep resolves to host=NONE ⇒ NOOP. Never touches GitHub. -
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")
    case "$*" in
      *"--state open"*) printf '%s\t%s\t%s\n' 1 feat/x 1234567890123456789012345678901234567890;;
      *) : ;;                                   # merged list (retire) etc. → empty
    esac ;;
  "pr view") : ;;                               # no comments → host=NONE → NOOP
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

# ---- fixture: a bare origin at `base`, a clean working clone off it. ------------------------------
setup_clone(){
  n=$((n+1)); CASE="$ROOT/c$n"; mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"; CLONE="$CASE/clone"; HOMEDIR="$CASE/home"; mkdir -p "$HOMEDIR"
  git init -q --bare -b main "$ORIGIN"
  SEED="$CASE/seed"
  git init -q -b main "$SEED"; git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
  echo base > "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm base
  git -C "$SEED" remote add origin "$ORIGIN"; git -C "$SEED" push -q origin main
  BASE_SHA="$(git -C "$SEED" rev-parse HEAD)"
  git clone -q "$ORIGIN" "$CLONE"
  git -C "$CLONE" config user.email claudebox@fedora-dev.local; git -C "$CLONE" config user.name claudebox
  NEW_SHA=""
}
advance_origin(){ # push a new main commit to origin (the "someone merged a self-improvement" event)
  echo more >> "$SEED/f"; git -C "$SEED" commit -qam more; git -C "$SEED" push -q origin main
  NEW_SHA="$(git -C "$SEED" rev-parse HEAD)"
}
clone_head(){ git -C "$CLONE" rev-parse HEAD 2>/dev/null; }
haslog(){ grep -qF "$1" "$OUT"; }

# run ONE self-refresh check (the poller's detection seam). Sets RC + OUT.
run_check(){ # extra env…
  OUT="$CASE/check.out"
  # shellcheck disable=SC2086
  env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" "$@" bash "$POLLER" --self-refresh-check >"$OUT" 2>&1
  RC=$?
}
# run ONE supervisor ff-pull (the clone's only writer). Sets RC + OUT.
run_pull(){ # extra env…
  OUT="$CASE/pull.out"
  # shellcheck disable=SC2086
  env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" "$@" bash "$SERVICE" --self-refresh-pull >"$OUT" 2>&1
  RC=$?
}
# drive the REAL --watch loop for <secs>, SELF_REFRESH_EVERY=2 (so sweep 1 runs, then the check fires).
run_watch(){ # <secs> extra env…
  local secs="$1"; shift
  OUT="$CASE/watch.out"
  # shellcheck disable=SC2086
  env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" PATH="$BIN:$PATH" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FLEET_HALT=true \
      POLL_INTERVAL=1 SELF_REFRESH_EVERY=2 "$@" \
      timeout "$secs" bash "$POLLER" --watch >"$OUT" 2>&1
  RC=$?
}
# background the REAL --watch loop so the test can act on the clone MID-RUN (#170: the external actor).
# POLL_INTERVAL=2 gives the actor the whole first sleep (≥2 s for a local-disk git op) between the sweep
# line appearing and the first self-refresh check firing.
watch_bg(){ # <secs> extra env…
  local secs="$1"; shift
  OUT="$CASE/watch.out"; : > "$OUT"
  # shellcheck disable=SC2086
  env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" PATH="$BIN:$PATH" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FLEET_HALT=true \
      POLL_INTERVAL=2 SELF_REFRESH_EVERY=2 "$@" \
      timeout "$secs" bash "$POLLER" --watch >"$OUT" 2>&1 &
  WATCH_PID=$!
}
wait_log(){ # <fixed-string> <secs> — poll OUT until the line appears; non-zero on timeout
  local i=0 max=$(( ${2:-10} * 10 ))
  until grep -qF "$1" "$OUT"; do i=$((i+1)); [ "$i" -gt "$max" ] && return 1; sleep 0.1; done
}
wait_watch(){ wait "$WATCH_PID"; RC=$?; }
# sweeps that COMPLETED before the first self-refresh line (proves the rate-limit + boundary placement).
sweeps_before_refresh(){ awk '/self-refresh:/{exit} /sweep: .* open PRs/{c++} END{print c+0}' "$OUT"; }
# a self-refresh line inside a sweep block (between `sweep:` and its ` NOOP`) ⇒ mid-sweep ⇒ mid-fixer.
refresh_never_mid_sweep(){ awk '/sweep: .* open PRs/{ins=1} /self-refresh:/{if(ins)exit 1} / NOOP/{ins=0}' "$OUT"; }

# ===================================================================================================
echo "== DECISION: an advanced origin/main on a CLEAN clone → step aside (reload), clone NOT written =="
DESC="advanced origin + clean → the poller signals a reload and writes nothing"; OK=1
setup_clone; advance_origin
run_check
ck "$([ "$RC" = "$RELOAD_RC" ] && echo 1 || echo 0)" "did not signal a reload (rc=$RC want $RELOAD_RC)"
ck "$(haslog 'stepping aside' && echo 1 || echo 0)" "no 'stepping aside' log"
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "the poller WROTE the clone — detection only (req 4: the supervisor pulls)"
done_case

echo "== DECISION: a DIRTY clone is left untouched and the loop is told to continue =="
DESC="a dirty clone → no reload, left untouched, logged"; OK=1
setup_clone; advance_origin; echo dirty >> "$CLONE/f"
run_check
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "a dirty clone did not return continue (rc=$RC want 0)"
ck "$(haslog DIRTY && echo 1 || echo 0)" "the dirty condition was not logged"
ck "$(haslog 'stepping aside' && echo 0 || echo 1)" "a dirty clone wrongly triggered a reload"
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "a dirty clone was moved off its head"
done_case

echo "== DECISION: a DIVERGED clone (local commits, not a ff) is left untouched =="
DESC="a diverged clone → no reload, left untouched, logged"; OK=1
setup_clone
echo local > "$CLONE/local.txt"; git -C "$CLONE" add -A; git -C "$CLONE" commit -qm "local divergent work"
DIVERGED_SHA="$(clone_head)"; advance_origin
run_check
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "a diverged clone did not return continue (rc=$RC want 0)"
ck "$(haslog DIVERGED && echo 1 || echo 0)" "the diverged condition was not logged"
ck "$(haslog 'stepping aside' && echo 0 || echo 1)" "a diverged clone wrongly triggered a reload"
ck "$([ "$(clone_head)" = "$DIVERGED_SHA" ] && echo 1 || echo 0)" "a diverged clone was moved off its head"
done_case

echo "== DECISION: a FAILED fetch leaves the poller unchanged (fail-safe toward progress) =="
DESC="an unreachable remote → no reload, logged, continue"; OK=1
setup_clone; advance_origin; rm -rf "$ORIGIN"          # the remote vanishes → git fetch fails
run_check
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "a failed fetch did not return continue (rc=$RC want 0)"
ck "$(haslog FAILED && echo 1 || echo 0)" "the fetch failure was not logged"
ck "$(haslog 'stepping aside' && echo 0 || echo 1)" "a failed fetch wrongly triggered a reload"
done_case

echo "== DECISION: an UP-TO-DATE clone is a silent no-op (req 5) =="
DESC="origin unchanged → no reload, no log at all"; OK=1
setup_clone                                            # origin NOT advanced
run_check
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "up-to-date did not return continue (rc=$RC want 0)"
ck "$(haslog 'self-refresh:' && echo 0 || echo 1)" "an up-to-date check was NOT silent (req 5)"
done_case

echo "== DECISION: SELF_REFRESH=0 disables the whole mechanism =="
DESC="disabled → no fetch, no reload, silent even with origin ahead"; OK=1
setup_clone; advance_origin
run_check SELF_REFRESH=0
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "disabled did not return continue (rc=$RC want 0)"
ck "$(haslog 'self-refresh:' && echo 0 || echo 1)" "disabled still ran the refresh"
done_case

echo "== DECISION (#170): an EXTERNAL pull of the clone between launch and the check → still RELOAD =="
DESC="a third party pulled the clone to origin → the LAUNCH head decides: reload"; OK=1
setup_clone; advance_origin
git -C "$CLONE" pull -q                                # the external actor (operator / orchestrator)
run_check POLLER_LAUNCH_HEAD="$BASE_SHA"               # …but THIS process was launched on BASE
ck "$([ "$RC" = "$RELOAD_RC" ] && echo 1 || echo 0)" "a pulled clone masked the stale process (rc=$RC want $RELOAD_RC — the clone-HEAD proxy reads clone==origin as UPTODATE and never reloads again)"
ck "$(haslog 'stepping aside' && echo 1 || echo 0)" "no 'stepping aside' log"
ck "$([ "$(clone_head)" = "$NEW_SHA" ] && echo 1 || echo 0)" "the check moved the externally-pulled clone (detection only — req 4)"
done_case

echo "== MUTATION (#170): the clone-HEAD proxy RESTORED MECHANICALLY → the external-pull row must FAIL =="
DESC="running=\$(git rev-parse HEAD) restored in a copy → same fixture reads UPTODATE (the row bites)"; OK=1
MUT="$ROOT/pr-poller.proxy-mutant.sh"; cp "$POLLER" "$MUT"
sed -i 's|^  running="\$LAUNCH_HEAD".*|  running="$(git -C "$clone" rev-parse HEAD 2>/dev/null)"|' "$MUT"
ck "$(cmp -s "$POLLER" "$MUT" && echo 0 || echo 1)" "the mutation sed changed NOTHING — this row is vacuous"
setup_clone; advance_origin
git -C "$CLONE" pull -q
OUT="$CASE/mutant.out"
env HOME="$HOMEDIR" SELF_REFRESH_CLONE="$CLONE" POLLER_LAUNCH_HEAD="$BASE_SHA" bash "$MUT" --self-refresh-check >"$OUT" 2>&1
RC=$?
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "the proxy mutant did not read UPTODATE (rc=$RC want 0) — the external-pull row would not discriminate"
ck "$(haslog 'stepping aside' && echo 0 || echo 1)" "the proxy mutant still reloaded — the external-pull row would not discriminate"
done_case

echo "== SUPERVISOR: ff-pull advances a clean clone to origin/main =="
DESC="clean + ff → the supervisor advances the clone to the new head"; OK=1
setup_clone; advance_origin
run_pull
ck "$([ "$(clone_head)" = "$NEW_SHA" ] && echo 1 || echo 0)" "the clone did NOT advance to origin (${NEW_SHA:0:7})"
ck "$(haslog advanced && echo 1 || echo 0)" "the advance was not logged old→new"
done_case

echo "== SUPERVISOR: ff-pull REFUSES a dirty clone (fast-forward only, never clobber) =="
DESC="a dirty clone → the supervisor refuses and leaves it untouched"; OK=1
setup_clone; advance_origin; echo dirty >> "$CLONE/f"
run_pull
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "a dirty clone was advanced anyway (clobbered a human's edit)"
ck "$(haslog REFUSED && echo 1 || echo 0)" "the refusal was not logged"
done_case

echo "== SUPERVISOR: an already-current clone is a no-op advance =="
DESC="origin unchanged → ff-pull is a silent no-op, clone stays put"; OK=1
setup_clone                                            # origin NOT advanced
run_pull
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "an up-to-date clone moved"
ck "$(haslog 'already current' && echo 1 || echo 0)" "an up-to-date pull did not report already-current"
done_case

# ---------------------------------------------------------------------------------------------------
# THE LOOP ROWS — the reload fires from the REAL --watch loop, at a SAFE POINT, and NOT mid-fixer.
# ---------------------------------------------------------------------------------------------------
echo "== LOOP: advanced origin → the running poller reloads at a loop boundary, AFTER a full sweep =="
DESC="a --watch loop exits POLLER_RELOAD_RC at a safe point, never mid-sweep (= never mid-fixer)"; OK=1
setup_clone; advance_origin
run_watch 20
ck "$([ "$RC" = "$RELOAD_RC" ] && echo 1 || echo 0)" "the loop did not exit for a reload (rc=$RC want $RELOAD_RC — restoring no-refresh yields the timeout 124)"
ck "$(haslog 'exiting for a supervised reload' && echo 1 || echo 0)" "the reload exit was not logged"
ck "$([ "$(sweeps_before_refresh)" = 1 ] && echo 1 || echo 0)" "the check did not honour SELF_REFRESH_EVERY (sweeps before reload=$(sweeps_before_refresh) want 1)"
ck "$(refresh_never_mid_sweep && echo 1 || echo 0)" "a self-refresh line appeared MID-SWEEP — the reload must never interrupt a fixer/review/merge"
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "the --watch poller WROTE the clone — the poller detects, the supervisor pulls (req 4)"
done_case

echo "== LOOP: a DIRTY clone leaves the running poller alone — it keeps sweeping =="
DESC="a dirty clone under --watch → no reload, the loop keeps running, clone untouched"; OK=1
setup_clone; advance_origin; echo dirty >> "$CLONE/f"
run_watch 5
ck "$([ "$RC" != "$RELOAD_RC" ] && echo 1 || echo 0)" "a dirty clone triggered a reload (rc=$RC)"
ck "$(haslog 'exiting for a supervised reload' && echo 0 || echo 1)" "a dirty clone exited for a reload"
ck "$(haslog DIRTY && echo 1 || echo 0)" "the dirty condition was not logged under --watch"
ck "$([ "$(grep -cF 'open PRs' "$OUT")" -ge 2 ] && echo 1 || echo 0)" "the loop did not keep sweeping past the dirty check"
ck "$([ "$(clone_head)" = "$BASE_SHA" ] && echo 1 || echo 0)" "a dirty clone was moved under --watch"
done_case

echo "== LOOP: a FAILED fetch does not stop the loop (fail-safe toward progress) =="
DESC="an unreachable remote under --watch → no reload, the loop keeps running"; OK=1
setup_clone; advance_origin; rm -rf "$ORIGIN"
run_watch 5
ck "$([ "$RC" != "$RELOAD_RC" ] && echo 1 || echo 0)" "a failed fetch triggered a reload (rc=$RC)"
ck "$(haslog FAILED && echo 1 || echo 0)" "the fetch failure was not logged under --watch"
ck "$([ "$(grep -cF 'open PRs' "$OUT")" -ge 2 ] && echo 1 || echo 0)" "the loop stopped after a failed fetch — it must carry on"
done_case

echo "== LOOP (#170): a third-party pull MID-RUN cannot mask the reload — the launch head is captured at startup =="
DESC="--watch launched on BASE, clone pulled to origin while it runs → still reloads"; OK=1
setup_clone; advance_origin                            # origin ahead; the clone (and the launch) on BASE
watch_bg 30
wait_log 'open PRs' 15 || ck 0 "the first sweep never appeared — cannot order the external pull"
git -C "$CLONE" pull -q                                # the external actor pulls AFTER launch, BEFORE the first check
wait_watch
ck "$([ "$RC" = "$RELOAD_RC" ] && echo 1 || echo 0)" "the loop did not reload after an external pull (rc=$RC want $RELOAD_RC — the clone-HEAD proxy reads UPTODATE forever and the reload self-disables)"
ck "$(haslog "advanced ${BASE_SHA:0:7} (launched)" && echo 1 || echo 0)" "the reload did not name the LAUNCH head as what origin advanced past"
ck "$([ "$(clone_head)" = "$NEW_SHA" ] && echo 1 || echo 0)" "the poller moved the clone off the external pull (detection only — req 4)"
done_case

echo "== LOOP (#170): a DIRTY clone LATER CLEANED resumes reloading — no sticky state =="
DESC="dirty blocks the reload only while dirty; cleaning lets the SAME running loop reload"; OK=1
setup_clone; advance_origin; echo dirty >> "$CLONE/f"
watch_bg 40
wait_log 'DIRTY' 20 || ck 0 "the dirty condition was never logged — cannot order the clean"
git -C "$CLONE" checkout -q -- f                       # the human cleans the clone; the loop keeps running
wait_watch
ck "$([ "$RC" = "$RELOAD_RC" ] && echo 1 || echo 0)" "the cleaned clone did not resume reloading (rc=$RC want $RELOAD_RC — sticky dirty state)"
ck "$(haslog 'stepping aside' && echo 1 || echo 0)" "no 'stepping aside' after the clean"
done_case

echo
echo "poller-selfrefresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
