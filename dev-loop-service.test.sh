#!/usr/bin/env bash
# dev-loop-service.test.sh — proves bin/dev-loop-service.sh's --one-cycle dispatch: it runs EXACTLY ONE
# dev-loop pass per R16-scoped repo, in order; authors NOTHING (never a hardcoded default) when the scope
# is empty; and a failing repo never wedges the rest. Drives the REAL dev-loop-service.sh with a stub
# repo-scope (controls the scoped set) + a stub dev-loop (records the repos it was dispatched for).
# MUTATION RUN IN-SUITE: replace the fail-closed empty-scope handling with a hardcoded `fedora-dev`
# fallback (the #165 leak) — the empty-scope row must then FAIL, proving that row bites. No GitHub/network/
# model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="$HERE/bin/dev-loop-service.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
DL_LOG="$ROOT/dispatched.log"

# stub repo-scope.sh: `list` prints the repos in $SCOPE_REPOS (empty ⇒ rc 0, no output — the fail-closed
# "readable but empty" case). Any other verb is a clean no-op.
cat > "$BIN/repo-scope.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in list) [ -n "${SCOPE_REPOS:-}" ] && printf '%s\n' $SCOPE_REPOS || : ;; *) exit 0;; esac
EOF
chmod +x "$BIN/repo-scope.sh"
# stub dev-loop.sh: append its <repo> arg to DL_LOG; exit 1 for $FAIL_REPO (else 0).
cat > "$BIN/dev-loop.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$DL_LOG"
[ "\$1" = "\${FAIL_REPO:-}" ] && exit 1 || exit 0
EOF
chmod +x "$BIN/dev-loop.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       dispatched=[%s] out=[%s]\n' "$1" "$(tr '\n' ' ' <"$DL_LOG")" "$(tr '\n' '|' <"$ROOT/out")"; }
run(){ # <svc-script> [env=val…]
  local sc="$1"; shift
  : > "$DL_LOG"
  env DEV_LOOP="$BIN/dev-loop.sh" REPO_SCOPE="$BIN/repo-scope.sh" HOME="$ROOT" "$@" \
    bash "$sc" --one-cycle > "$ROOT/out" 2>&1
}
dispatched(){ tr '\n' ' ' < "$DL_LOG"; }

echo "== a cycle runs ONE dev-loop pass per scoped repo, in order =="
run "$SVC" SCOPE_REPOS="fedora-dev fedora-bootstrap"
[ "$(dispatched)" = "fedora-dev fedora-bootstrap " ] && ok "dispatched exactly the scoped repos, in order" || no "wrong dispatch set/order"

echo "== an EMPTY scope authors NOTHING (fail-closed; never a hardcoded default) =="
run "$SVC" SCOPE_REPOS=""
{ [ ! -s "$DL_LOG" ] && grep -q 'yielded NO repos' "$ROOT/out"; } && ok "empty scope → zero dispatches + fail-closed log" || no "empty scope authored something or did not log fail-closed"

echo "== a failing repo does not wedge the rest (continue past failure) =="
run "$SVC" SCOPE_REPOS="fedora-dev fedora-bootstrap" FAIL_REPO="fedora-dev"
{ [ "$(dispatched)" = "fedora-dev fedora-bootstrap " ] && grep -q 'failed (continuing' "$ROOT/out"; } && ok "both repos dispatched despite the first failing" || no "a failing repo wedged the rest"

echo "== MUTATION: a hardcoded default on empty scope (the #165 leak) must make the empty-scope row FAIL =="
MUT="$ROOT/dev-loop-service-mut.sh"
sed 's#\[ "\$n" -gt 0 \] || log "R16 scope yielded NO repos.*#[ "$n" -gt 0 ] || "$DEV_LOOP" fedora-dev </dev/null#' "$SVC" > "$MUT"
if ! grep -q '"\$DEV_LOOP" fedora-dev </dev/null$' "$MUT"; then
  no "mutation VACUOUS (sed did not change the copy)"
else
  run "$MUT" SCOPE_REPOS=""
  [ "$(dispatched)" = "fedora-dev " ] && ok "mutant: empty scope authors the hardcoded default ⇒ the real fail-closed row discriminates" || no "mutant did not author a default on empty scope (row would not bite)"
fi

echo "== SINGLETON (#173-adjudicated liveness): --is-live reports the holder correctly =="
# The self-arm gives dev-loop-service TWO launchers (entrypoint + the poller's dev_loop_launch_tick), so a
# double-launch is routine and must dedup — WITHOUT the #173 dead-holder-blocks-forever bug. service_live
# (exposed as --is-live for the poller's launch probe) defers ONLY to a positively-live holder whose /proc
# cmdline still names this script; a dead or a RECYCLED pid never blocks a start.
PF="$ROOT/svc.pid"
islive(){ env HOME="$ROOT" PIDFILE="$1" bash "$SVC" --is-live >/dev/null 2>&1; RC=$?; }

rm -f "$PF"; islive "$PF"
[ "$RC" = 1 ] && ok "no pidfile → not live" || no "no pidfile misjudged live (rc=$RC)"

# a pid that has already exited (a subshell's own $$, dead the moment the substitution returns) — no
# background kill (killing a fresh `cmd &` before its exec runs the inherited EXIT trap, nuking $ROOT).
dp="$(bash -c 'echo $$')"; echo "$dp" > "$PF"; islive "$PF"
[ "$RC" = 1 ] && ok "dead pid → not live" || no "dead pid misjudged live (rc=$RC)"

# a live pid whose cmdline does NOT name the service = a recycled pid wearing the old number
sleep 300 & rp=$!; echo "$rp" > "$PF"; islive "$PF"
[ "$RC" = 1 ] && ok "live but unrelated cmdline (recycled pid) → not live" || no "recycled pid misjudged live (rc=$RC)"

# a live pid whose cmdline NAMES the service (exec -a sets argv0 in-place, so $! IS the named process)
bash -c 'exec -a "/x/bin/dev-loop-service.sh" sleep 300' & lp=$!; echo "$lp" > "$PF"; islive "$PF"
[ "$RC" = 0 ] && ok "live + cmdline names the service → live" || no "live-named holder misjudged not-live (rc=$RC)"

echo "== SINGLETON: a second launch exits cleanly when a verified peer is live; a start proceeds otherwise =="
# peer ($lp) is live and holds $PF → the persistent launch must exit 0 WITHOUT cycling (never reaches one_cycle)
: > "$DL_LOG"
env HOME="$ROOT" PIDFILE="$PF" DEV_LOOP="$BIN/dev-loop.sh" REPO_SCOPE="$BIN/repo-scope.sh" SCOPE_REPOS="fedora-dev" \
  timeout 5 bash "$SVC" > "$ROOT/out" 2>&1; RC=$?
{ [ "$RC" = 0 ] && [ ! -s "$DL_LOG" ] && grep -q 'already holds the loop' "$ROOT/out"; } \
  && ok "peer live → launch exits 0 without cycling (singleton dedup)" || no "singleton did not dedup a live peer (rc=$RC)"

# no live peer (kill the holders, clear the pidfile) → the launch PASSES the singleton and reaches the
# readiness wait (blocks on .assembled, which never appears) — proving a dead/absent holder never blocks.
kill "$lp" "$rp" 2>/dev/null; rm -f "$PF"
env HOME="$ROOT" PIDFILE="$PF" DEV_LOOP="$BIN/dev-loop.sh" REPO_SCOPE="$BIN/repo-scope.sh" \
  timeout 3 bash "$SVC" > "$ROOT/out" 2>&1; RC=$?
{ [ "$RC" = 124 ] && grep -q 'waiting for claudebox assembly' "$ROOT/out"; } \
  && ok "no live peer → passes singleton, waits for assembly (a dead/absent holder never blocks)" || no "singleton wrongly blocked a start OR did not reach readiness (rc=$RC)"
rm -f "$PF"

echo "== MUTATION: neutralize the /proc cmdline verify → a recycled pid reads as LIVE (the verify row bites) =="
MUT2="$ROOT/dev-loop-service-mut2.sh"
sed "/grep -q 'dev-loop-service/d" "$SVC" > "$MUT2"
if grep -q "grep -q 'dev-loop-service" "$SVC" && ! grep -q "grep -q 'dev-loop-service" "$MUT2"; then
  sleep 300 & mp=$!; echo "$mp" > "$PF"
  env HOME="$ROOT" PIDFILE="$PF" bash "$MUT2" --is-live >/dev/null 2>&1; MRC=$?
  kill "$mp" 2>/dev/null
  [ "$MRC" = 0 ] && ok "mutant: recycled pid misjudged LIVE ⇒ the real cmdline-verify row discriminates" || no "mutant did not flip the recycled-pid row (mrc=$MRC)"
else
  no "mutation VACUOUS (sed did not remove the cmdline verify)"
fi
rm -f "$PF"

echo "== DRIFT GUARD: the entrypoint gate is ARMED BY DEFAULT (self-arm) — never default-off =="
# The loop self-arms ONLY if entrypoint.sh's gate defaults ON. A regression back to `${DEV_LOOP_ENABLED:-0}`
# (default-off) silently re-introduces the manual host arm that breaks self-arming — catch it here.
ENTRY="$HERE/entrypoint.sh"
if [ -f "$ENTRY" ]; then
  if grep -q 'DEV_LOOP_ENABLED:-1' "$ENTRY" && ! grep -q '"${DEV_LOOP_ENABLED:-0}" = 1' "$ENTRY"; then
    ok "entrypoint gate defaults ON (\${DEV_LOOP_ENABLED:-1} != 0) — the loop self-arms"
  else
    no "entrypoint gate is NOT default-on — the authoring loop would need a MANUAL host arm (breaks self-arming)"
  fi
else
  echo "  skip drift guard (entrypoint.sh not beside the test)"
fi

echo; echo "dev-loop-service: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
