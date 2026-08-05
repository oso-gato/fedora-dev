#!/usr/bin/env bash
# poller-devloop-launch.test.sh — proves bin/pr-poller.sh's dev_loop_launch_tick (self-arm, 2026-07-19):
# the CLONE-side poller kick-starts the authoring loop (dev-loop-service.sh) so it self-arms on a running
# box with NO rebuild. The tick must: launch ONLY when no live authoring loop already holds it
# (`dev-loop-service.sh --is-live` adjudicates), stay quiet when one is live, respect the DEV_LOOP_ENABLED
# default-ON gate (explicit =0 disables), Drives the REAL pr-poller.sh --once with
# DEV_LOOP_LAUNCH_EVERY=1 (a lone --once fires the tick), an empty gh (quiet sweep), and a STUB
# dev-loop-service that answers --is-live and records a launch. MUTATION RUN IN-SUITE: neutralize the
# --is-live gate → the poller launches even when a loop is already live (double-launch). No GitHub/network/
# model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$POLLER" ] || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# stub gh: an empty PR list ⇒ a quiet sweep; everything else a clean no-op.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/gh"

# stub dev-loop-service.sh: --is-live exits 0 iff $IS_LIVE is set (the "a loop already holds it" fixture);
# any other invocation (the poller's detached no-arg launch) records ONE line to $LAUNCH_LOG.
cat > "$BIN/dls-stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --is-live) [ -n "${IS_LIVE:-}" ] && exit 0 || exit 1;; esac
echo "LAUNCHED" >> "${LAUNCH_LOG:?}"
EOF
chmod +x "$BIN/dls-stub"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       rc=%s launches=[%s] out<<%s>>\n' "$1" "${RC:-?}" "$(cat "$LAUNCH_LOG" 2>/dev/null | tr '\n' ',')" "$(tr '\n' '|' <"$OUT" 2>/dev/null)"; }

LAUNCH_LOG="$ROOT/launch.log"
OUT="$ROOT/poller.out"
run_poller(){ # <poller-script> [env=val…]
  local sc="$1"; shift
  : > "$LAUNCH_LOG"; local hd="$ROOT/home"; rm -rf "$hd"; mkdir -p "$hd"
  env HOME="$hd" PATH="$BIN:$PATH" POLLER_REPOS=fedora-dev POLLER_ARMED=0 \
      HOST_REFRESH_EVERY=0 RECONCILE_EVERY=0 DEV_LOOP_LAUNCH_EVERY=1 \
      DEV_LOOP_SERVICE="$BIN/dls-stub" DEV_LOOP_SERVICE_LOG="$ROOT/dls.log" LAUNCH_LOG="$LAUNCH_LOG" \
      REPO_SCOPE="$HERE/bin/repo-scope.sh" "$@" \
      bash "$sc" --once >"$OUT" 2>&1
  RC=$?
  # the launch is setsid-detached — give it a bounded beat to write
  local i; for i in $(seq 1 40); do [ -s "$LAUNCH_LOG" ] && break; sleep 0.1; done
}
launched(){ [ -s "$LAUNCH_LOG" ]; }

echo "== no live authoring loop + RUN + enabled → the poller LAUNCHES it (self-arm) =="
run_poller "$POLLER"
{ launched && grep -q 'no live authoring loop' "$OUT"; } \
  && ok "launched dev-loop-service when none was live" || no "did not launch a missing authoring loop"

echo "== a live authoring loop already holds it → the poller does NOT launch (quiet steady state) =="
run_poller "$POLLER" IS_LIVE=1
{ ! launched; } && ok "no launch when a loop is already live" || no "double-launched over a live loop"

echo "== DEV_LOOP_ENABLED=0 → disabled, no launch =="
run_poller "$POLLER" DEV_LOOP_ENABLED=0
{ ! launched; } && ok "DEV_LOOP_ENABLED=0 disables the launch" || no "launched despite DEV_LOOP_ENABLED=0"

echo "== MUTATION: neutralize the --is-live gate → the poller launches even over a LIVE loop =="
MUT="$ROOT/pr-poller-mut.sh"
sed 's#if "$DEV_LOOP_SERVICE" --is-live 2>/dev/null; then#if false; then#' "$POLLER" > "$MUT"
if grep -q -- '--is-live 2>/dev/null; then' "$POLLER" && ! grep -q -- '--is-live 2>/dev/null; then' "$MUT"; then
  run_poller "$MUT" IS_LIVE=1
  { launched; } && ok "mutant: launches over a live loop ⇒ the real --is-live gate discriminates" || no "mutant did not double-launch (the gate row would not bite)"
else
  no "mutation VACUOUS (sed did not change the --is-live gate)"
fi

echo; echo "poller-devloop-launch: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
