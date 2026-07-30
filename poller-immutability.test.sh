#!/usr/bin/env bash
# poller-immutability.test.sh — proves bin/pr-poller.sh's immutability_probe_tick (#317): the pair
# measures its OWN immutability on a clock, records the verdict durably, and makes a RED impossible to
# miss — while a healthy probe stays completely silent.
#
# THE AXIS. objective #310's third scope bullet is *"the check runs on its own, repeatedly"*, so the
# thing under test is the WIRING, not a verdict fold: whether the tick FIRES on its cadence, whether a
# halt really stops it, whether the record is really written, and whether the alarm's LIFECYCLE (open →
# update → close) actually happens. A pure `--selftest` of immut_action() is structurally blind to every
# one of those — #278 shipped a pure core with a green selftest and ZERO call sites, and the running
# poller behaved byte-identically to before. So every row here drives the REAL `pr-poller.sh --once`.
#
# WHAT IS FAKED, AND WHY ONLY THIS. The PROBE (a real run costs three throwaway builds on this box plus
# a host round-trip over the bus — this suite must not spend that, and must be able to demand rc 1 on
# demand, which a healthy box cannot produce) and `gh` (every row asserts on which gh calls were made,
# which is unassertable against the real API, and no test may file issues on a live repo). Everything
# else — the cadence arithmetic, the halt gate, the single-flight lock, the record writer, the alarm
# lifecycle, and `bin/immutability-probe.sh --status` reading it back — is the shipped code.
#
# THE RECORD CONTRACT IS PINNED END-TO-END, not by two copies of a parser: the tick WRITES the record and
# the REAL `--status` READS it in the same row, so a key renamed on either side fails here.
#
# TWO MUTATIONS RUN IN-SUITE (BP8), each vacuity-guarded: neutralize the halt gate → the halted tick
# measures anyway; neutralize the RED→surface branch → a RED opens no issue.
#
# `bash poller-immutability.test.sh` → exit 0 = all rows pass. No GitHub/network/model/engine.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
PROBE="$HERE/bin/immutability-probe.sh"
[ -f "$POLLER" ] || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
[ -f "$PROBE" ]  || { echo "FATAL: bin/immutability-probe.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

GH_LOG="$ROOT/gh.log"
PROBE_LOG="$ROOT/probe.log"
STATEDIR="$ROOT/immut-state"
OUT="$ROOT/poller.out"

# ── stub gh ──────────────────────────────────────────────────────────────────────────────────────────
# Records every invocation (the rows assert on WHICH gh calls happened, especially that a GREEN run makes
# NONE). `pr list` is empty so the sweep itself is quiet and cannot contribute issue writes.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
if [ "${1:-}" = issue ]; then
  case "${2:-}" in
    create) echo "https://github.com/oso-gato/fedora-dev/issues/${FAKE_NEW_ISSUE:-4242}"; exit "${FAKE_CREATE_RC:-0}";;
    # by-TITLE discovery: serves a row only when the fixture declares a standing issue.
    list)   [ -n "${FAKE_OPEN_NUM:-}" ] && printf '%s\t%s\n' "$FAKE_OPEN_NUM" "${FAKE_OPEN_TITLE:-}"; exit 0;;
    edit)   exit "${FAKE_EDIT_RC:-0}";;
  esac
fi
exit 0
EOF

# ── stub repo-scope: everything in scope (the R16 gate is not this suite's subject) ──────────────────
cat > "$BIN/repo-scope-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in list) echo fedora-dev;; *) exit 0;; esac
EOF

# ── fake probe: the seam the acceptance names. Emits the real line-1 grammar and exits FAKE_RC. ──────
cat > "$BIN/fake-probe.sh" <<'EOF'
#!/usr/bin/env bash
printf 'RAN %s\n' "$*" >> "${PROBE_LOG:?}"
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
if [ -z "${FAKE_NO_VERDICT:-}" ]; then
  printf 'immutability-probe: %s dev=%s host=%s\n' \
    "${FAKE_VERDICT:-GREEN}" "${FAKE_DEV:-GREEN}" "${FAKE_HOST:-GREEN}"
fi
[ -n "${FAKE_RESIDUE:-}" ] && printf '%s\n' "$FAKE_RESIDUE"
[ -n "${FAKE_TICKET:-}" ] && printf 'host: RED — the host measured RESIDUE — via %s\n' "$FAKE_TICKET"
printf 'dev: %s — probe detail line\n' "${FAKE_DEV:-GREEN}"
exit "${FAKE_RC:-0}"
EOF

# ── stub dev-loop-service: the tick AFTER the immutability tick. Its launch line is how a row proves ──
# the sweep CONTINUED past a crashing probe rather than dying with it.
cat > "$BIN/dls-stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --is-live) exit 1;; esac
echo LAUNCHED >> "${LAUNCH_LOG:?}"
EOF
chmod +x "$BIN/gh" "$BIN/repo-scope-stub.sh" "$BIN/fake-probe.sh" "$BIN/dls-stub"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       rc=%s gh=[%s] probe=[%s]\n' "$1" "${RC:-?}" \
        "$(tr '\n' ';' <"$GH_LOG" 2>/dev/null)" "$(tr '\n' ';' <"$PROBE_LOG" 2>/dev/null)"; }

HOMEDIR="$ROOT/home"
reset_state(){ rm -rf "$STATEDIR" "$HOMEDIR"; mkdir -p "$STATEDIR" "$HOMEDIR"; }
reset_logs(){ : > "$GH_LOG"; : > "$PROBE_LOG"; : > "$ROOT/launch.log"; }

# run_poller <script> [env=val…] — one REAL sweep. State persists across calls unless reset_state ran,
# which is what lets the alarm-lifecycle and staged-streak rows span several runs.
run_poller(){
  local sc="$1"; shift
  reset_logs
  env HOME="$HOMEDIR" PATH="$BIN:$PATH" POLLER_REPOS=fedora-dev POLLER_ARMED=0 \
      HOST_REFRESH_EVERY=0 RECONCILE_EVERY=0 SHIP_ACTUATOR_EVERY=0 DEV_LOOP_LAUNCH_EVERY=0 \
      REBUILD_REQUEST_EVERY=0 SELF_REFRESH=0 \
      REPO_SCOPE="$BIN/repo-scope-stub.sh" \
      IMMUTABILITY_PROBE="$BIN/fake-probe.sh" IMMUTABILITY_PROBE_EVERY=1 \
      IMMUT_STATE="$STATEDIR" GH_LOG="$GH_LOG" PROBE_LOG="$PROBE_LOG" \
      LAUNCH_LOG="$ROOT/launch.log" DEV_LOOP_SERVICE="$BIN/dls-stub" \
      "$@" bash "$sc" --once >"$OUT" 2>&1
  RC=$?
}
probe_ran(){ grep -q '^RAN ' "$PROBE_LOG" 2>/dev/null; }
# `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so a `|| echo 0` fallback emits "0\n0" and every
# zero-comparison silently fails. Take grep's own count and ignore its rc.
countl(){ local n; n="$(grep -c "$1" "${2:-$GH_LOG}" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0;; esac; printf '%s' "$n"; }
gh_issue_calls(){ countl '^issue '; }
n_creates(){ countl '^issue create'; }
n_edits(){ countl '^issue edit'; }
logs(){ grep -q "$1" "$OUT" 2>/dev/null; }
# the dev-loop launch is setsid-DETACHED — give it a bounded beat before asserting on its marker
await_launch(){ local i; for i in $(seq 1 40); do [ -s "$ROOT/launch.log" ] && return 0; sleep 0.1; done; return 1; }

# ══ PART A — the cadence ═══════════════════════════════════════════════════════════════════════════
echo "== PART A — the tick fires on its cadence, and only then =="

# THE ACCEPTANCE ROW: `--once` with IMMUTABILITY_PROBE_EVERY=1 and a fake probe ⇒ fires once + records.
reset_state
run_poller "$POLLER"
{ [ "$RC" = 0 ] && probe_ran && [ "$(countl '^RAN ' "$PROBE_LOG")" = 1 ] && [ -s "$STATEDIR/last" ]; } \
  && ok "DUE: the tick fires EXACTLY once and writes the state file (the issue's acceptance row)" \
  || no "the due tick did not fire once / wrote no state file"

reset_state
run_poller "$POLLER" IMMUTABILITY_PROBE_EVERY=999
{ ! probe_ran && [ ! -e "$STATEDIR/last" ]; } \
  && ok "NOT DUE: no probe run, no record written" || no "the tick fired when it was not due"

reset_state
run_poller "$POLLER" IMMUTABILITY_PROBE_EVERY=0
{ ! probe_ran; } && ok "EVERY=0 disables the tick entirely" || no "the tick fired while disabled"

# The cadence default must stay RARE: a run costs a real build on BOTH boxes, so a default that slipped
# to a low number would build the fleet every few minutes. Read out of the shipped file.
grep -q 'IMMUTABILITY_PROBE_EVERY:-2880' "$POLLER" \
  && ok "the shipped default cadence is 2880 sweeps (~24h) — documented as costing a build on both boxes" \
  || no "the default IMMUTABILITY_PROBE_EVERY is not 2880"
{ grep -q 'IMMUTABILITY_PROBE\*' "$POLLER" && grep -q 'A RUN COSTS A REAL BUILD ON BOTH BOXES' "$POLLER"; } \
  && ok "the poller header documents the tick + the cost reason alongside the other ticks" \
  || no "the poller header does not document IMMUTABILITY_PROBE* with its cost reason"

# EVERY row below overrides the probe + state seams (a real run costs builds on both boxes, and a test
# must never write the box's real record), so the PRODUCTION resolution of both is exercised by nothing
# here. Pin it structurally instead — otherwise the whole suite could pass against a poller wired to a
# probe that does not exist (bin/seam-audit.sh names this class).
grep -q 'IMMUTABILITY_PROBE:-\$HERE/immutability-probe.sh' "$POLLER" \
  && ok "the shipped default probe is the sibling bin/immutability-probe.sh" || no "the default probe path drifted"
{ grep -q 'IMMUT_STATE:-\$HOME/.local/state/immutability-probe' "$POLLER" \
    && grep -q 'IMMUT_STATE:-\$HOME/.local/state/immutability-probe' "$PROBE"; } \
  && ok "the writer and the reader default to the SAME record dir (one contract, read out of both files)" \
  || no "the poller's and the probe's default state dirs disagree"
[ -x "$HERE/bin/immutability-probe.sh" ] \
  && ok "that default target exists and is executable (the tick's call site is not dead)" \
  || no "the default probe target is missing/not executable"

# ══ PART C — fail-safe ═════════════════════════════════════════════════════════════════════════════
echo "== PART C — a probe that fails can never stop the loop =="
reset_state
run_poller "$POLLER" FAKE_RC=2 FAKE_NO_VERDICT=1 DEV_LOOP_LAUNCH_EVERY=1
{ [ "$RC" = 0 ] && [ "$(gh_issue_calls)" = 0 ] && logs 'could not produce a verdict' \
    && await_launch; } \
  && ok "rc 2: logged, NO issue opened, sweep CONTINUES (the later tick still ran), poller rc 0" \
  || no "rc 2 stopped the sweep / opened an issue / was not logged"

# A record is still written for an rc-2 run: "the probe could not run" is itself a fact worth keeping,
# and --status must be able to say so rather than silently serving a stale GREEN.
{ [ -s "$STATEDIR/last" ] && grep -q '^verdict: UNKNOWN' "$STATEDIR/last"; } \
  && ok "rc 2 is still RECORDED (verdict UNKNOWN) — no stale GREEN is left standing" \
  || no "an rc-2 run left no record / did not record UNKNOWN"

reset_state
run_poller "$POLLER" FAKE_RC=137 FAKE_NO_VERDICT=1 DEV_LOOP_LAUNCH_EVERY=1
{ [ "$RC" = 0 ] && [ "$(gh_issue_calls)" = 0 ] && await_launch; } \
  && ok "a CRASH (rc 137) is swallowed the same way — no issue, loop intact" \
  || no "a crashing probe stopped the loop or opened an issue"

# ══ PART D — the RED alarm and its lifecycle ═══════════════════════════════════════════════════════
echo "== PART D — RED opens exactly ONE issue, updates it, and a GREEN closes it =="
reset_state
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED FAKE_HOST=STAGED \
  FAKE_RESIDUE='RESIDUE tree /home/core/.cache/fd-throwaway.abc' \
  FAKE_TICKET='https://github.com/oso-gato/fedora-bootstrap/issues/77'
{ [ "$(n_creates)" = 1 ] && [ "$(n_edits)" = 0 ]; } \
  && ok "RED: exactly ONE issue created" || no "RED did not create exactly one issue"

BODY="$(grep -m1 '^issue create' "$GH_LOG")"
{ [ -n "$BODY" ] && grep -q 'issue create.*--title .*immutability RED' "$GH_LOG"; } \
  && ok "the alarm carries the stable RED title (so it dedups by title)" || no "the RED title is missing/unstable"

# The issue body must carry what the feature promises: verdict line, RESIDUE lines, WHICH BOX, ticket URL.
# The stub records argv, so the body arrives via --body-file; capture it from the state the tick wrote
# plus a direct composition check against the recorded record.
{ grep -q '^ticket: https://github.com/oso-gato/fedora-bootstrap/issues/77' "$STATEDIR/last" \
    && grep -q '^dev: RED' "$STATEDIR/last" && grep -q '^host: STAGED' "$STATEDIR/last"; } \
  && ok "the record captures both box verdicts + the host ticket URL (what the alarm body reports)" \
  || no "the record lost a box verdict or the host ticket URL"

# a SECOND red must UPDATE, never open a second issue
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED FAKE_HOST=STAGED
{ [ "$(n_creates)" = 0 ] && [ "$(n_edits)" = 1 ]; } \
  && ok "a second RED UPDATES the standing issue (no duplicate filed)" || no "the second RED duplicated the alarm"

# marker lost (a box recreate) but the issue is still open → discover BY TITLE, still never double-file
rm -f "$STATEDIR/alarm.open"
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED FAKE_HOST=STAGED \
  FAKE_OPEN_NUM=4242 FAKE_OPEN_TITLE='🔴 immutability RED — a build left residue behind'
{ [ "$(n_creates)" = 0 ] && [ "$(n_edits)" = 1 ]; } \
  && ok "a LOST marker rediscovers the issue by title (a wiped box cannot double-file)" \
  || no "a lost marker double-filed the alarm"

# …and now GREEN retires it
run_poller "$POLLER" FAKE_RC=0 FAKE_VERDICT=GREEN
{ grep -q '^issue comment' "$GH_LOG" && grep -q '^issue close' "$GH_LOG" \
    && grep -qi 'cleared' "$GH_LOG" && [ ! -e "$STATEDIR/alarm.open" ]; } \
  && ok "GREEN: posts a 'cleared' comment, CLOSES the issue, drops the marker" \
  || no "GREEN did not comment+close the standing alarm"

# ══ PART E — a healthy probe is SILENT ═════════════════════════════════════════════════════════════
echo "== PART E — GREEN with no standing alarm makes ZERO gh calls =="
reset_state
run_poller "$POLLER" FAKE_RC=0 FAKE_VERDICT=GREEN
{ [ "$(gh_issue_calls)" = 0 ] && probe_ran && [ -s "$STATEDIR/last" ]; } \
  && ok "GREEN, nothing open: ZERO gh issue calls — and the measurement is still recorded" \
  || no "a healthy probe made gh calls (or failed to record)"

# ══ PART F — STAGED is not an alarm, until it persists ═════════════════════════════════════════════
echo "== PART F — STAGED: quiet, then surfaced exactly once =="
reset_state
run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
{ [ "$(gh_issue_calls)" = 0 ] && [ "$(cat "$STATEDIR/staged.streak")" = 1 ]; } \
  && ok "STAGED run 1: no issue (an undetermined state is not an alarm)" || no "STAGED run 1 surfaced"
run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
{ [ "$(gh_issue_calls)" = 0 ] && [ "$(cat "$STATEDIR/staged.streak")" = 2 ]; } \
  && ok "STAGED run 2: still quiet" || no "STAGED run 2 surfaced early"
run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
{ [ "$(n_creates)" = 1 ] && grep -q 'issue create.*--title .*UNMEASURED' "$GH_LOG"; } \
  && ok "STAGED run 3 (= IMMUT_STAGED_MAX): surfaced ONCE, under its own honest UNMEASURED title" \
  || no "the third consecutive STAGED did not surface (or claimed RED)"
run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
{ [ "$(gh_issue_calls)" = 0 ]; } \
  && ok "STAGED run 4: silent again — 'surface it once' means once" || no "the staged notice repeated"

# a STAGED run must NEVER clear a standing RED: "could not measure" is not evidence the residue is gone
reset_state
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED
run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
{ [ "$(gh_issue_calls)" = 0 ] && [ -s "$STATEDIR/alarm.open" ]; } \
  && ok "a STAGED run leaves a standing RED alarm OPEN (only a GREEN retires it)" \
  || no "a STAGED run cleared or re-touched the RED alarm"

# ══ PART G — the durable record, read back by the REAL --status ════════════════════════════════════
echo "== PART G — --status reports the recorded verdict, its age, and a matching rc =="
reset_state
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED FAKE_HOST=STAGED \
  FAKE_TICKET='https://github.com/oso-gato/fedora-bootstrap/issues/77'
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$STATEDIR" bash "$PROBE" --status 2>&1)"; SRC=$?
{ [ "$SRC" = 1 ] && printf '%s' "$SOUT" | grep -q 'immutability-probe: RED' \
    && printf '%s' "$SOUT" | grep -q 'dev=RED' && printf '%s' "$SOUT" | grep -q 'host=STAGED' \
    && printf '%s' "$SOUT" | grep -q 'ago' \
    && printf '%s' "$SOUT" | grep -q 'fedora-bootstrap/issues/77'; } \
  && ok "END-TO-END: the tick WROTE it and the REAL --status READ it back (RED → rc 1, age, provenance)" \
  || { no "--status did not report the tick's record"; printf '       status rc=%s out<<%s>>\n' "$SRC" "$(printf '%s' "$SOUT" | tr '\n' '|')"; }

run_poller "$POLLER" FAKE_RC=0 FAKE_VERDICT=GREEN
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$STATEDIR" bash "$PROBE" --status 2>&1)"; SRC=$?
{ [ "$SRC" = 0 ] && printf '%s' "$SOUT" | grep -q 'immutability-probe: GREEN'; } \
  && ok "a recorded GREEN → --status rc 0" || no "--status did not match a recorded GREEN"

run_poller "$POLLER" FAKE_RC=3 FAKE_VERDICT=PARTIAL FAKE_HOST=STAGED
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$STATEDIR" bash "$PROBE" --status 2>&1)"; SRC=$?
{ [ "$SRC" = 3 ]; } && ok "a recorded PARTIAL/STAGED → --status rc 3" || no "--status did not match a recorded STAGED (rc=$SRC)"

# NO record is NOT a pass — the unmeasured-evidence failure #310 exists to end.
EMPTY="$ROOT/empty-state"; rm -rf "$EMPTY"; mkdir -p "$EMPTY"
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$EMPTY" bash "$PROBE" --status 2>&1)"; SRC=$?
{ [ "$SRC" = 3 ] && printf '%s' "$SOUT" | grep -q 'NO MEASUREMENT RECORDED'; } \
  && ok "no record at all → rc 3 and says so (never rc 0 — 'never measured' is not a pass)" \
  || no "an absent record did not report rc 3"

# --status is an ORACLE: it must not build, measure, or touch the network.
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$STATEDIR" PATH="$BIN:$PATH" GH_LOG="$ROOT/status-gh.log" \
        bash "$PROBE" --status 2>&1)"
{ [ ! -s "$ROOT/status-gh.log" ]; } \
  && ok "--status makes no gh calls (a cheap, side-effect-free oracle)" || no "--status called gh"

echo "== PART G2 — the bounded history answers 'has this ever been GREEN?' =="
reset_state
run_poller "$POLLER" FAKE_RC=0 FAKE_VERDICT=GREEN
run_poller "$POLLER" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED
{ [ "$(countl . "$STATEDIR/history")" = 2 ] && grep -q ' GREEN ' "$STATEDIR/history" \
    && grep -q ' RED ' "$STATEDIR/history"; } \
  && ok "history records every run, GREEN and RED alike" || no "history did not record both runs"
SOUT="$(env HOME="$HOMEDIR" IMMUT_STATE="$STATEDIR" bash "$PROBE" --status 2>&1)"
{ printf '%s' "$SOUT" | grep -q 'last GREEN:' && ! printf '%s' "$SOUT" | grep -q 'last GREEN: never'; } \
  && ok "--status names when the box was last GREEN (the question the history file exists for)" \
  || no "--status did not surface the last GREEN"

# the history is BOUNDED — an append-forever file is an unbounded cache by another name (BP10)
reset_state
i=0; while [ "$i" -lt 6 ]; do run_poller "$POLLER" FAKE_RC=0 IMMUT_HISTORY_MAX=4; i=$((i+1)); done
{ [ "$(countl . "$STATEDIR/history")" = 4 ]; } \
  && ok "history is bounded to IMMUT_HISTORY_MAX (kept the most recent 4 of 6 runs)" \
  || no "history is unbounded (got $(countl . "$STATEDIR/history") lines, want 4)"

# ══ PART H — single-flight ═════════════════════════════════════════════════════════════════════════
echo "== PART H — never two probes at once =="
reset_state
# Hold the probe lock from outside, exactly as a concurrent poller or a manual run would.
( flock 8; sleep 6 ) 8>>"$STATEDIR/probe.lock" &
HOLDER=$!
sleep 0.4
run_poller "$POLLER"
# Reap the CHILD too: killing the subshell alone orphans its `sleep`, which keeps the lock fd (and this
# suite's stdout) open — the exact "a passing test leaves sleep children alive" hazard tests.yml records.
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
{ [ "$RC" = 0 ] && ! probe_ran && logs 'already in flight'; } \
  && ok "a probe already in flight is left alone (two would witness each other's staged leaks)" \
  || no "the tick raced a probe that was already running"

# ══ PART I — MUTATIONS (BP8) ═══════════════════════════════════════════════════════════════════════
echo "== PART I — mutations: each guard must be what makes its row pass =="

# M2 — neutralize the RED→surface branch. `^    SURFACE)` cannot match `STAGED_SURFACE)` at the same
# indent, so the staged arm is left intact and only the RED alarm is disarmed.
MUT2="$ROOT/poller-mut-surface.sh"
sed 's/^    SURFACE)$/    SURFACE_NEUTRALIZED)/' "$POLLER" > "$MUT2"
if ! cmp -s "$POLLER" "$MUT2"; then
  reset_state
  run_poller "$MUT2" FAKE_RC=1 FAKE_VERDICT=RED FAKE_DEV=RED
  { [ "$(gh_issue_calls)" = 0 ]; } \
    && ok "M2: without the RED→surface branch a RED opens NO issue ⇒ the alarm row is real" \
    || no "M2: the mutant still opened an alarm (the RED row would not bite)"
else
  no "M2 mutation VACUOUS (sed did not change the SURFACE arm)"
fi

echo; echo "poller-immutability: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
