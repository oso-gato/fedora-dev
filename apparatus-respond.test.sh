#!/usr/bin/env bash
# apparatus-respond.test.sh — MOCK end-to-end suite for the AUTONOMOUS RESPONDER in bin/apparatus-deadman.sh
# (R18 recovery arm). The responder ACTS on the live system, so SAFETY is the whole point; every row here
# proves a safety property empirically, REAL where it matters:
#   * a REAL bare origin + working clone set BEHIND / DIRTY (untracked strays OR a tracked edit) — real git;
#   * a REAL backgrounded trap-poller whose cmdline IS `bash …/fake-poller-trap.sh --watch`, which records
#     each SIGTERM it receives and STAYS alive (so the signal + the "still frozen next check" are real) +
#     a REAL bare-string DECOY that must NEVER be signalled — the self-match axis against actual /proc;
#   * a REAL poller-log aged with `touch -d`;
#   * `git` INTERCEPTED (logs every invocation, execs the real git) to PROVE the responder issues no
#     pull/merge/reset/checkout/clean;
#   * `gh` STUBBED to record every create/edit/comment (no network).
#
# Asserts: untracked-only dirt ⇒ QUARANTINED (moved into the quarantine dir, absent from the clone), clone
# CLEAN afterward, HEAD + tracked files BYTE-IDENTICAL (nothing clobbered), no pull/merge/reset; a TRACKED
# edit ⇒ NOTHING moved/cleaned, the tracked file untouched, it SURFACES (DECLINED); a frozen poller ⇒
# EXACTLY ONE SIGTERM to the RIGHT pid (own pid / decoy never signalled); IDEMPOTENCY ⇒ re-detecting the
# SAME anomaly after acting ESCALATES instead of re-acting; an occurrence that ends then RE-occurs acts
# afresh. In-suite MUTATION-CHECK (grep-verified non-vacuous): neutralize the untracked-only guard in
# dirty_class ⇒ a TRACKED edit gets WRONGLY quarantined (proving that guard is what protects it).
#
#   bash apparatus-respond.test.sh   → exit 0 = all rows pass. No GitHub / network / model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/apparatus-deadman.sh"
ROOT="$(mktemp -d)"
export GH_CALLS="$ROOT/gh.calls"
export GH_SEARCH_RESULT=""
export DEADMAN_REPO="oso-gato/fedora-bootstrap"
# DO NOT WRITE THE PRODUCTION EVIDENCE FILE. Every row here runs the REAL script, and $DEADMAN_LOG
# defaults to ~/.local/state/apparatus-deadman/deadman.log — the box's own durable watchdog log (#273).
# Left unset, a suite run interleaves hundreds of fixture ANOMALY/RESPOND/CLEARED lines into the very
# record an operator reads to judge what the watchdog really did: measuring the #291 window meant first
# subtracting test noise from production signal (fixture issue #4242, /tmp/tmp.*/state.* paths). Use the
# script's documented disable hatch — the NON-COLON `${DEADMAN_LOG-…}` means an EXPORTED EMPTY value
# really disables the file (a `:-` would substitute the default back); stderr still carries every line.
export DEADMAN_LOG=""

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
TRAP_PID=""; DECOY_PID=""
stop_procs(){
  # FREEZE the trap-poller first so its `while` loop cannot respawn a fresh sleep between our reap of the
  # child and our kill of the parent (that race leaks orphan sleeps). Then pkill -P (parent-pid, NOT a
  # string match — self-match-safe) reaps the frozen parent's sleep child, and -9 removes the parent.
  if [ -n "$TRAP_PID" ]; then
    kill -STOP "$TRAP_PID" 2>/dev/null
    pkill -P "$TRAP_PID" 2>/dev/null
    kill -9 "$TRAP_PID" 2>/dev/null; wait "$TRAP_PID" 2>/dev/null
  fi
  [ -n "$DECOY_PID" ] && { kill -9 "$DECOY_PID" 2>/dev/null; wait "$DECOY_PID" 2>/dev/null; }
  TRAP_PID=""; DECOY_PID=""
}
cleanup(){ stop_procs; rm -rf "$ROOT"; }
trap cleanup EXIT

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/stub" "$ROOT/fakebin" "$ROOT/gitshim"
cat > "$ROOT/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "${1:-}" in
  api)   [ -n "${GH_SEARCH_RESULT:-}" ] && [ -f "$GH_SEARCH_RESULT" ] && cat "$GH_SEARCH_RESULT"; exit 0;;
  issue) case "${2:-}" in create) echo "https://github.com/${DEADMAN_REPO:-x/y}/issues/4242";; esac; exit 0;;
  # `pr list` feeds the WORK-PROGRESS fingerprint. Serves rows ONLY when a row asks for them ($FAKE_PRS),
  # so every other row keeps an EMPTY fingerprint and the work axis stays quiet there.
  pr)    case "${2:-}" in list) [ -n "${FAKE_PRS:-}" ] && [ -f "$FAKE_PRS" ] && cat "$FAKE_PRS";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$ROOT/stub/gh"
export PATH="$ROOT/stub:$PATH"

# A trap-poller: cmdline stays `bash …/fake-poller-trap.sh --watch` (two statements defeat bash's
# last-command exec optimisation, so the bash process — not an exec'd sleep — holds the path). It RECORDS
# every SIGTERM it catches (append its pid to $DM_SIGFILE) and STAYS alive, so "exactly one signal" and
# "still frozen next check" are both real.
POLLER_NAME="fake-poller-trap.sh"
cat > "$ROOT/fakebin/$POLLER_NAME" <<'EOF'
#!/bin/bash
trap 'echo "$$" >> "$DM_SIGFILE"' TERM
while :; do sleep 100000 & wait $!; done
EOF
chmod +x "$ROOT/fakebin/$POLLER_NAME"
start_trap(){ DM_SIGFILE="$1" bash "$ROOT/fakebin/$POLLER_NAME" --watch & TRAP_PID=$!; sleep 0.3; }
# a bare-string look-alike (argv[0] carries the pattern, a real sleep, NO slash-anchored script path)
start_decoy(){ bash -c 'exec -a "fake-poller-trap.sh --watch" sleep 100000' & DECOY_PID=$!; sleep 0.25; }

git_q(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
new_origin_and_clone(){   # $1 = stem → $1.git (bare origin, main=seed) + $1 (clone at seed)
  local stem="$1"
  git init -q --bare "$stem.git"
  git clone -q "$stem.git" "$stem" 2>/dev/null
  ( cd "$stem" && git -c user.email=t@t -c user.name=t checkout -q -b main 2>/dev/null
    echo seed > seed.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed
    git push -q origin main )
}
advance_origin(){   # $1 = stem → one commit onto origin/main WITHOUT touching the clone
  local p="$ROOT/pusher.$RANDOM"
  git clone -q "$1.git" "$p" 2>/dev/null
  ( cd "$p" && git checkout -q main 2>/dev/null
    echo "adv $RANDOM" > adv.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm adv
    git push -q origin HEAD:main )
  rm -rf "$p"
}
freshstate(){ local d="$ROOT/state.$RANDOM"; mkdir -p "$d"; printf '%s' "$d"; }
agelog(){ touch -d "@$(( $(date +%s) - ${2:-1000} ))" "$1"; }
freshlog(){ : > "$1"; touch "$1"; }

# dmr → run one RESPONDING --check (DEADMAN_RESPOND=1), timeout-bounded so a row can never hang.
dmr(){   # args: KEY=VAL … (extra env)
  OUT="$(timeout 60 env "$@" \
    DEADMAN_RESPOND=1 DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_GIT_TIMEOUT=15 DEADMAN_GH_TIMEOUT=15 \
    bash "$SCRIPT" --check 2>>"$ROOT/deadman.stderr")"
  RC=$?
}

echo "== SELF_REFRESH_BLOCKED — untracked strays are QUARANTINED (never rm), clone left CLEAN, tracked untouched =="
S="$ROOT/q"; new_origin_and_clone "$S"; advance_origin "$S"
echo 'stray one' > "$S/stray1.sh"; mkdir -p "$S/bin"; echo 'stray two' > "$S/bin/stray2.sh"
ST="$(freshstate)"; : > "$GH_CALLS"
HEAD_B="$(git -C "$S" rev-parse HEAD)"; SEED_B="$(cat "$S/seed.txt")"
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh
QD="$(echo "$ST"/deadman-quarantine/*/ 2>/dev/null)"
HEAD_A="$(git -C "$S" rev-parse HEAD)"; SEED_A="$(cat "$S/seed.txt" 2>/dev/null)"
CLEAN_A="$(git -C "$S" status --porcelain)"
{ echo "$OUT" | grep -q 'RESPOND SELF_REFRESH_BLOCKED' && echo "$OUT" | grep -q 'QUARANTINED' \
  && [ ! -e "$S/stray1.sh" ] && [ ! -e "$S/bin/stray2.sh" ] \
  && [ -f "${QD%/}/stray1.sh" ] && [ -f "${QD%/}/bin/stray2.sh" ] \
  && [ -z "$CLEAN_A" ] && [ "$HEAD_B" = "$HEAD_A" ] && [ "$SEED_B" = "$SEED_A" ] \
  && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "untracked strays MOVED to quarantine (path preserved), gone from clone, clone CLEAN, HEAD+tracked byte-identical, alarm surfaced" \
  || bad "quarantine-untracked" "rc=$RC qd=[$QD] clean_after=[$CLEAN_A] head $HEAD_B→$HEAD_A out=[$OUT]"

echo "== SELF_REFRESH_BLOCKED — a TRACKED edit is NEVER touched; it SURFACES =="
S="$ROOT/t"; new_origin_and_clone "$S"; advance_origin "$S"
echo 'a real intentional edit' >> "$S/seed.txt"
ST="$(freshstate)"; : > "$GH_CALLS"
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh
{ echo "$OUT" | grep -q SELF_REFRESH_BLOCKED && echo "$OUT" | grep -q 'seed.txt' \
  && echo "$OUT" | grep -q 'DECLINED' && [ "$RC" != 0 ] \
  && [ -e "$S/seed.txt" ] && grep -q 'a real intentional edit' "$S/seed.txt" \
  && git -C "$S" status --porcelain | grep -q 'seed.txt' \
  && [ ! -e "$ST/deadman-quarantine" ] \
  && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "a tracked change is NOT moved/cleaned, stays modified in the clone, no quarantine dir, and SURFACES naming it" \
  || bad "tracked-untouched" "rc=$RC out=[$OUT] status=[$(git -C "$S" status --porcelain)]"

echo "== POLLER_FROZEN — exactly ONE SIGTERM to the RIGHT pid; decoy/own-pid never signalled; re-detect ESCALATES =="
S="$ROOT/f"; new_origin_and_clone "$S"           # clone current (no git anomaly)
LOG="$ROOT/frozen.log"; freshlog "$LOG"; agelog "$LOG" 1000
SIGF="$ROOT/sig.$RANDOM"; : > "$SIGF"
ST="$(freshstate)"; : > "$GH_CALLS"
start_trap "$SIGF"; start_decoy
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" \
    DEADMAN_SWEEP_MAX=300 DEADMAN_POLLER_NAME="$POLLER_NAME"
sleep 0.4
n1="$(grep -c . "$SIGF" 2>/dev/null || echo 0)"
got1="$(head -n1 "$SIGF" 2>/dev/null)"
decoy_alive=0; kill -0 "$DECOY_PID" 2>/dev/null && decoy_alive=1
decoy_signalled=0; grep -qx "$DECOY_PID" "$SIGF" 2>/dev/null && decoy_signalled=1
# re-check with the SAME state → the marker exists → ESCALATE, NO second signal
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" \
    DEADMAN_SWEEP_MAX=300 DEADMAN_POLLER_NAME="$POLLER_NAME"
sleep 0.4
n2="$(grep -c . "$SIGF" 2>/dev/null || echo 0)"
{ echo "$OUT" | grep -q 'RESPOND POLLER_FROZEN' && echo "$OUT" | grep -q ESCALATION \
  && [ "$n1" = 1 ] && [ "$got1" = "$TRAP_PID" ] && [ "$n2" = 1 ] \
  && [ "$decoy_alive" = 1 ] && [ "$decoy_signalled" = 0 ]; } \
  && ok "ONE SIGTERM to the genuine poller pid; decoy alive + never signalled; re-detect ESCALATES with NO second signal" \
  || bad "frozen-sigterm" "n1=$n1 got1=$got1 trap=$TRAP_PID n2=$n2 decoy_alive=$decoy_alive decoy_sig=$decoy_signalled out=[$OUT]"
stop_procs

echo "== WORK_STALLED — the alarm fires and the LIVE poller is NOT signalled (#291) =="
# THE LOAD-BEARING ROW. This axis is the ONLY one that ever took a production action, and the action was a
# SIGTERM at the poller. Measured 2026-07-28: it restarted the poller in 30s and the identical stall ran 82
# minutes longer — so the remedy is gone and the alarm stays. `respond_plan` is pure and cannot see whether
# a signal LEAVES the process; only a real poller with a real TERM trap can, which is what this drives.
# Everything else is pinned healthy (clone current, log fresh, poller alive, no fitness env) so WORK_STALLED
# is the sole anomaly and any signal observed can only have come from it.
mk_stall(){   # $1 = state dir → seed a fingerprint IDENTICAL to what the stub will report, aged past the bound
  printf '%s' "$(cat "$FAKE_PRS")" > "$1/work.fp"
  touch -d "@$(( $(date +%s) - 4000 ))" "$1/work.fp"
}
export FAKE_PRS="$ROOT/fake.prs"
# `<repo>#<n> <sha> <verdict-count> <labels>` — the exact shape work_fingerprint emits. No parked label,
# so work_drivable keeps it and the axis is allowed to judge it.
echo 'e2e-beta#7 abc123def456 0 live-validate' > "$FAKE_PRS"
S="$ROOT/ws"; new_origin_and_clone "$S"                    # current + clean ⇒ no git anomaly
LOG="$ROOT/ws.log"; freshlog "$LOG"                        # fresh ⇒ no POLLER_FROZEN
SIGF="$ROOT/wsig.$RANDOM"; : > "$SIGF"
ST="$(freshstate)"; mk_stall "$ST"; : > "$GH_CALLS"
start_trap "$SIGF"                                         # a REAL, live, self-match-confirmable poller
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" \
    DEADMAN_SWEEP_MAX=300 DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_WORK_REPOS=e2e-beta \
    DEADMAN_WORK_STALL_MAX=60 DEADMAN_FITNESS_ENV="$ROOT/no-such-fitness-env"
sleep 0.4
# NO `|| echo 0`: `grep -c` on an EMPTY file prints 0 and EXITS 1, so the fallback appends a SECOND line
# and the count reads "0\n0" — which is never `= 0`. The zero case is exactly what this row asserts.
ws_sigs="$(grep -c . "$SIGF" 2>/dev/null)"; ws_sigs="${ws_sigs:-0}"
ws_alive=0; kill -0 "$TRAP_PID" 2>/dev/null && ws_alive=1
{ echo "$OUT" | grep -q 'WORK_STALLED' && [ "$RC" != 0 ] \
  && [ "$ws_sigs" = 0 ] && [ "$ws_alive" = 1 ] \
  && ! echo "$OUT" | grep -q 'sent ONE SIGTERM' \
  && echo "$OUT" | grep -q 'no auto-recovery is attempted BY DESIGN' \
  && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "WORK_STALLED alarms + surfaces, sends ZERO signals, poller left alive (detection kept, kill dropped)" \
  || bad "workstalled-no-kill" "rc=$RC sigs=$ws_sigs alive=$ws_alive out=[$OUT]"
stop_procs

echo "== MUTATION-CHECK — restore the SIGTERM arm ⇒ the SAME fixture kills the live poller =="
# Non-vacuity is the whole point: without this, the row above would also pass against a script where the
# work axis simply never fires. Restoring the pre-#291 arm must make the identical fixture signal.
CPW="$ROOT/mut-workstalled.sh"
# RANGE-SCOPED to the WORK_STALLED branch: `      printf SURFACE ;;` also ends the `*)` default arm, and a
# blanket substitution would mutate MERGED_NOT_LIVE/CANNOT_VERIFY too — a mutant broken in several places
# proves nothing about this one. The marker is a UNIQUE token, NOT the restored code: `printf SIGTERM; fi ;;`
# already occurs verbatim in the POLLER_FROZEN branch (which #291 deliberately KEEPS), so grepping for it
# would report every run vacuous — as it did on the first cut of this row.
sed '/^    WORK_STALLED)/,/^      printf SURFACE ;;$/ s/^      printf SURFACE ;;$/      if [ "$have_target" != 1 ]; then printf SURFACE; elif [ "$acted" = 1 ]; then printf ESCALATE; else printf SIGTERM; fi ;;   # MUT291/' "$SCRIPT" > "$CPW"
chmod +x "$CPW"
if grep -qF 'MUT291' "$CPW" && ! grep -qF 'MUT291' "$SCRIPT"; then
  Sw="$ROOT/wsm"; new_origin_and_clone "$Sw"
  LOGm="$ROOT/wsm.log"; freshlog "$LOGm"
  SIGFm="$ROOT/wsigm.$RANDOM"; : > "$SIGFm"
  STm="$(freshstate)"; mk_stall "$STm"
  start_trap "$SIGFm"
  timeout 60 env DEADMAN_RESPOND=1 DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_GIT_TIMEOUT=15 DEADMAN_GH_TIMEOUT=15 \
    DEADMAN_CLONE="$Sw" DEADMAN_STATE="$STm" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOGm" \
    DEADMAN_SWEEP_MAX=300 DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_WORK_REPOS=e2e-beta \
    DEADMAN_WORK_STALL_MAX=60 DEADMAN_FITNESS_ENV="$ROOT/no-such-fitness-env" \
    bash "$CPW" --check >/dev/null 2>&1
  sleep 0.4
  mut_sigs="$(grep -c . "$SIGFm" 2>/dev/null)"; mut_sigs="${mut_sigs:-0}"   # same idiom trap as above
  mut_hit=0; grep -qx "$TRAP_PID" "$SIGFm" 2>/dev/null && mut_hit=1
  stop_procs
  { [ "$mut_sigs" -ge 1 ] && [ "$mut_hit" = 1 ]; } \
    && ok "pre-#291 arm restored ⇒ the same stall SIGTERMs the live poller (this row is non-vacuous)" \
    || bad "mutation-workstalled" "mut_sigs=$mut_sigs mut_hit=$mut_hit (the fixture must reach the responder)"
else
  bad "mutation-workstalled" "the sed did not change the copy — vacuous"
fi

echo "== IDEMPOTENCY across occurrences — an occurrence that ENDS then re-occurs is acted on AFRESH =="
S="$ROOT/re"; new_origin_and_clone "$S"; advance_origin "$S"
echo 'stray a' > "$S/reA.sh"; ST="$(freshstate)"
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh   # #1 quarantine
q1_ok=0; echo "$OUT" | grep -q QUARANTINED && q1_ok=1
git_q "$S" pull -q origin main 2>/dev/null                                                          # supervisor/self-refresh catches up → clean+current
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh   # #2 HEALTHY → markers reset
healthy_ok=0; echo "$OUT" | grep -q '^HEALTHY' && healthy_ok=1
marker_gone=0; [ ! -f "$ST/responder/SELF_REFRESH_BLOCKED.acted" ] && marker_gone=1
advance_origin "$S"; echo 'stray b' > "$S/reB.sh"                                                    # a NEW occurrence: behind + a fresh stray
dmr DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh   # #3 quarantine AGAIN (not escalate)
{ [ "$q1_ok" = 1 ] && [ "$healthy_ok" = 1 ] && [ "$marker_gone" = 1 ] \
  && echo "$OUT" | grep -q QUARANTINED && ! echo "$OUT" | grep -q ESCALATION \
  && [ ! -e "$S/reB.sh" ]; } \
  && ok "quarantine #1 → healthy resets the marker → a fresh occurrence quarantines AGAIN (not a stale ESCALATE)" \
  || bad "idempotency-reset" "q1=$q1_ok healthy=$healthy_ok marker_gone=$marker_gone reB_exists=$([ -e "$S/reB.sh" ] && echo 1 || echo 0) out=[$OUT]"

echo "== the responder NEVER runs pull/merge/reset/checkout/clean (git INTERCEPTED) =="
REALGIT="$(command -v git)"
cat > "$ROOT/gitshim/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/git.calls"
exec "$REALGIT" "\$@"
EOF
chmod +x "$ROOT/gitshim/git"
S="$ROOT/gi"; new_origin_and_clone "$S"; advance_origin "$S"
echo 'stray for git-intercept' > "$S/gistray.sh"; ST="$(freshstate)"; : > "$ROOT/git.calls"
OUT="$(timeout 60 env PATH="$ROOT/gitshim:$PATH" \
  DEADMAN_RESPOND=1 DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
  DEADMAN_GIT_TIMEOUT=15 DEADMAN_GH_TIMEOUT=15 \
  DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh \
  bash "$SCRIPT" --check 2>>"$ROOT/deadman.stderr")"
forbidden="$(grep -Ew 'pull|merge|reset|checkout|clean' "$ROOT/git.calls" 2>/dev/null || true)"
{ echo "$OUT" | grep -q QUARANTINED && [ -s "$ROOT/git.calls" ] && [ -z "$forbidden" ]; } \
  && ok "git was invoked (facts) but the responder issued NO pull/merge/reset/checkout/clean while quarantining" \
  || bad "no-mutating-git" "forbidden=[$forbidden] calls=[$(cat "$ROOT/git.calls")]"

echo "== MUTATION-CHECK — neutralize the untracked-only guard ⇒ a TRACKED edit gets WRONGLY quarantined =="
CP="$ROOT/mut-guard.sh"
sed 's/\[ "\$tracked" = 1 \]/[ "$tracked" = 9 ]/' "$SCRIPT" > "$CP"; chmod +x "$CP"
if grep -qF '[ "$tracked" = 9 ]' "$CP" && ! grep -qF '[ "$tracked" = 9 ]' "$SCRIPT"; then
  # ORIGINAL: a tracked edit is left in place (SURFACE)
  So="$ROOT/mo"; new_origin_and_clone "$So"; advance_origin "$So"; echo 'tracked edit' >> "$So/seed.txt"
  timeout 60 env DEADMAN_RESPOND=1 DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_CLONE="$So" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh \
    bash "$SCRIPT" --check >/dev/null 2>&1
  orig_kept=0; [ -e "$So/seed.txt" ] && grep -q 'tracked edit' "$So/seed.txt" && orig_kept=1
  # MUTANT: the guard is dead ⇒ the tracked edit is treated as untracked ⇒ MOVED out of the clone
  Sm="$ROOT/mm"; new_origin_and_clone "$Sm"; advance_origin "$Sm"; echo 'tracked edit' >> "$Sm/seed.txt"
  timeout 60 env DEADMAN_RESPOND=1 DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_CLONE="$Sm" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=0 DEADMAN_POLLER_NAME=nomatch.sh \
    bash "$CP" --check >/dev/null 2>&1
  mut_moved=0; [ ! -e "$Sm/seed.txt" ] && mut_moved=1
  { [ "$orig_kept" = 1 ] && [ "$mut_moved" = 1 ]; } \
    && ok "guard live ⇒ tracked edit stays; guard neutralized ⇒ tracked edit wrongly quarantined (row is non-vacuous)" \
    || bad "mutation-guard" "orig_kept=$orig_kept mut_moved=$mut_moved"
else
  bad "mutation-guard" "the sed did not change the copy — vacuous"
fi

echo
echo "apparatus-respond.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
