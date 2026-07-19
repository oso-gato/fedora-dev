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
