#!/usr/bin/env bash
# repo-scope-session.test.sh — the PER-SESSION LAYER suite (R27/R28) for bin/repo-scope.sh's optional
# SCOPE_SESSION narrowing. Drives the REAL bin/repo-scope.sh as subprocesses against a REAL
# bin/session-registry.sh (REAL flock, REAL /proc liveness) and a TEMP SCOPE_FILE (ceiling) + TEMP
# SCOPE_REGISTRY_DIR. No gh / network / model. Coreutils-only (NO cmp/diff — a minimal host lacks them).
#
# WHAT IT PROVES:
#   * INERT when SCOPE_SESSION is unset — the reader is byte-for-byte the ceiling-only reader, EVEN with
#     a populated registry present (the registry is not consulted at all). This is the merge-safety: the
#     running poller sets nothing, so landing this layer changes NOTHING until a caller opts in.
#   * a session NARROWS the ceiling (declared {repo-a} vs ceiling {repo-a,repo-b} → a ALLOW, b DENY);
#   * a session can NOT exceed the ceiling (declares {repo-a,repo-z}, z ∉ ceiling → z DENY, a ALLOW);
#   * an UNDECLARED session (SCOPE_SESSION set, unregistered) acts on NOTHING (a DENY, list empty);
#   * DISJOINTNESS (R28): a repo held by another LIVE session is DENIED even when it is in your own
#     declared scope AND the ceiling — with a REAL backgrounded holder; freeing that holder flips it to
#     ALLOW, proving the deny was the live cross-check and nothing else;
#   * MUTATION-CHECK: neutralizing the session-narrowing line makes an out-of-session `check repo-b`
#     WRONGLY ALLOW — restored mechanically and run in-suite (the sed must genuinely change the copy, or
#     the row fails as vacuous), proving the narrowing is the thing gating.
#
# Run:  bash repo-scope-session.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="$HERE/bin/repo-scope.sh"
REG="$HERE/bin/session-registry.sh"
for f in "$SCOPE" "$REG" "$HERE/bin/session-id.sh" "$HERE/bin/lock-lib.sh"; do
  [ -f "$f" ] || { echo "FATAL: $f not found"; exit 2; }
done
command -v flock >/dev/null || { echo "FATAL: flock required"; exit 2; }
# session_coords is needed to synthesize a live-holder record for the disjointness row (the registry
# would refuse to REGISTER a repo a live peer holds — that is its job; here we inject the cross-session
# state the repo-scope check is defense-in-depth against, with a REAL live holder pid).
# shellcheck source=bin/session-id.sh
. "$HERE/bin/session-id.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"; HOLDERS=""
trap 'kill $HOLDERS >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

# the CEILING: a readable scope of {repo-a, repo-b} (repo-z is deliberately OUTSIDE it).
FIX="$TMP/scope.conf"
{ printf '# fixture ceiling\n'; printf 'repo-a\n'; printf 'repo-b\n'; } > "$FIX"

# detach the holder's std fds — else the backgrounded sleep inherits the $(…) command-sub pipe and the
# capture blocks for the full 300 s waiting for an EOF that never comes (the mt-foundation idiom).
live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }
reset_reg(){ REGDIR="$TMP/reg.$1"; rm -rf "$REGDIR"; mkdir -p "$REGDIR"; export SCOPE_REGISTRY_DIR="$REGDIR"; }

# run `repo-scope check <repo>` → sets RC (exit code) and ERR (stderr). Empty <sess> ⇒ SCOPE_SESSION unset.
check_rc(){ # <sess-or-empty> <repo>
  local sess="$1" repo="$2"
  if [ -n "$sess" ]; then ERR="$(SCOPE_SESSION="$sess" SCOPE_FILE="$FIX" bash "$SCOPE" check "$repo" 2>&1 >/dev/null)"; RC=$?
  else                    ERR="$(SCOPE_FILE="$FIX" bash "$SCOPE" check "$repo" 2>&1 >/dev/null)"; RC=$?; fi
}
list_out(){ # <sess-or-empty> → sets OUT (stdout, one repo per line)
  local sess="$1"
  if [ -n "$sess" ]; then OUT="$(SCOPE_SESSION="$sess" SCOPE_FILE="$FIX" bash "$SCOPE" list 2>/dev/null)"
  else                    OUT="$(SCOPE_FILE="$FIX" bash "$SCOPE" list 2>/dev/null)"; fi
}

# ===================================================================================================
echo "== INERT: SCOPE_SESSION unset → the ceiling IS the answer (registry NOT consulted) =="
reset_reg unset
# populate the registry with a session that would, IF consulted, narrow the ceiling to {repo-a}:
HPU="$(live_holder)"
SESSION_HOLDER_PID="$HPU" bash "$REG" register live-session repo-a >/dev/null
check_rc "" repo-a; [ "$RC" = 0 ] && ok "unset: check repo-a → ALLOW rc 0 (ceiling member)" || bad "unset: check repo-a rc=$RC (want 0)"
check_rc "" repo-b; [ "$RC" = 0 ] && ok "unset: check repo-b → ALLOW rc 0 (registry IGNORED — inert)" || bad "unset: check repo-b rc=$RC (want 0 — the registry must not narrow when SCOPE_SESSION is unset)"
check_rc "" repo-z; [ "$RC" = 3 ] && ok "unset: check repo-z → DENY rc 3 (outside the ceiling)" || bad "unset: check repo-z rc=$RC (want 3)"
list_out "";        [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = "repo-a repo-b" ] && ok "unset: list → the full ceiling {repo-a repo-b}" || bad "unset: list = [$OUT] (want the ceiling, registry ignored)"

# ===================================================================================================
echo "== NARROW: a registered session {repo-a} narrows the ceiling {repo-a,repo-b} =="
reset_reg narrow
HPN="$(live_holder)"
SESSION_HOLDER_PID="$HPN" bash "$REG" register sessA repo-a >/dev/null
check_rc sessA repo-a; [ "$RC" = 0 ] && ok "sessA{a}: check repo-a → ALLOW rc 0 (in effective set)" || bad "sessA: check repo-a rc=$RC (want 0)"
check_rc sessA repo-b; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'NARROWS\|only NARROWS'; } && ok "sessA{a}: check repo-b → DENY rc 3 (narrowed out of the ceiling)" || bad "sessA: check repo-b rc=$RC err=[$ERR] (want 3 + narrow log)"
list_out sessA; [ "$OUT" = "repo-a" ] && ok "sessA{a}: list → the effective set {repo-a}" || bad "sessA: list = [$OUT] (want repo-a)"

# ===================================================================================================
echo "== CANNOT EXCEED: a session declaring {repo-a,repo-z} where repo-z ∉ ceiling =="
reset_reg exceed
HPE="$(live_holder)"
SESSION_HOLDER_PID="$HPE" bash "$REG" register sessC repo-a repo-z >/dev/null
check_rc sessC repo-z; [ "$RC" = 3 ] && ok "sessC{a,z}: check repo-z → DENY rc 3 (z is outside the ceiling — cannot exceed it)" || bad "sessC: check repo-z rc=$RC (want 3)"
check_rc sessC repo-a; [ "$RC" = 0 ] && ok "sessC{a,z}: check repo-a → ALLOW rc 0 (a is in both)" || bad "sessC: check repo-a rc=$RC (want 0)"
list_out sessC; [ "$OUT" = "repo-a" ] && ok "sessC{a,z}: list → {repo-a} (z dropped — session ∩ ceiling)" || bad "sessC: list = [$OUT] (want repo-a)"

# ===================================================================================================
echo "== UNDECLARED: SCOPE_SESSION set but the session is NOT registered → acts on NOTHING =="
reset_reg undeclared   # empty registry
check_rc ghost repo-a; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'declared NO operating scope'; } && ok "ghost: check repo-a → DENY rc 3 (undeclared — fail-closed to nothing)" || bad "ghost: check repo-a rc=$RC err=[$ERR] (want 3 + register-first log)"
list_out ghost; [ -z "$OUT" ] && ok "ghost: list → empty (undeclared)" || bad "ghost: list = [$OUT] (want empty)"

# ===================================================================================================
echo "== DISJOINTNESS (R28): a repo held by another LIVE session is DENIED even when in your own scope =="
reset_reg held
HPA="$(live_holder)"; HPB="$(live_holder)"
# sessA legitimately holds repo-a (live).
SESSION_HOLDER_PID="$HPA" bash "$REG" register sessA repo-a >/dev/null
# Inject sessB DIRECTLY, also declaring repo-a, with a REAL live-holder record (registration would deny
# this — the registry's job; we synthesize the cross-session state repo-scope's check guards against, so
# the SESSION_HELD path is exercised with sessB genuinely a member).
recB="$(SESSION_HOLDER_PID="$HPB" session_coords)"
{ printf '%s\n' sessB; printf '%s\n' "$recB"; printf '%s\n' repo-a; } > "$SCOPE_REGISTRY_DIR/sessB.session"
check_rc sessB repo-a
{ [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q "held by another LIVE session 'sessA'"; } \
  && ok "sessB{a}: check repo-a → DENY rc 3 (repo-a held by live sessA — disjointness), naming the holder" \
  || bad "sessB: check repo-a rc=$RC err=[$ERR] (want 3 + 'held by another LIVE session sessA')"
# free the holder → the cross-check no longer sees a live claimant → the SAME query now ALLOWs.
kill "$HPA" 2>/dev/null; wait "$HPA" 2>/dev/null || true
check_rc sessB repo-a
[ "$RC" = 0 ] && ok "sessB{a}: after sessA's holder dies, check repo-a → ALLOW rc 0 (the deny WAS the live cross-check)" \
  || bad "sessB: post-death check repo-a rc=$RC (want 0 — the held-deny must have been the only thing denying)"

# ===================================================================================================
echo "== MUTATION-CHECK: neutralizing the session-narrowing makes an out-of-session check WRONGLY ALLOW =="
MUT="$TMP/mut"; mkdir -p "$MUT"
cp "$HERE/bin/repo-scope.sh" "$HERE/bin/session-registry.sh" "$HERE/bin/session-id.sh" "$HERE/bin/lock-lib.sh" "$MUT/"
# flatten the single narrowing line (the only line carrying BOTH `smember` and `SESSION_DENY`) to a no-op.
sed -i 's|.*smember.*SESSION_DENY.*|  : # narrowing neutralized|' "$MUT/repo-scope.sh"
if [ "$(cat "$HERE/bin/repo-scope.sh")" = "$(cat "$MUT/repo-scope.sh")" ]; then
  bad "mutation: the sed changed NOTHING — this row is vacuous"
else
  ok "mutation: session-narrowing line neutralized in the copy"
  MREG="$TMP/mreg"; rm -rf "$MREG"; mkdir -p "$MREG"
  HPM="$(live_holder)"
  SESSION_HOLDER_PID="$HPM" SCOPE_REGISTRY_DIR="$MREG" bash "$REG" register sessM repo-a >/dev/null
  # baseline: the REAL script narrows repo-b out (declared {repo-a}) → DENY rc 3.
  RC=0; SCOPE_SESSION=sessM SCOPE_FILE="$FIX" SCOPE_REGISTRY_DIR="$MREG" bash "$SCOPE" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 3 ] && ok "real script: sessM{a} check repo-b → DENY rc 3 (narrowing bites)" || bad "real script: check repo-b rc=$RC (want 3)"
  # mutant: with the narrowing gone, repo-b (in ceiling, NOT in session scope) WRONGLY ALLOWs → rc 0.
  RC=0; SCOPE_SESSION=sessM SCOPE_FILE="$FIX" SCOPE_REGISTRY_DIR="$MREG" bash "$MUT/repo-scope.sh" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 0 ] && ok "mutant: with the narrowing gone, check repo-b WRONGLY ALLOWs rc 0 (the row bites)" \
    || bad "mutant: check repo-b rc=$RC — the narrowing is NOT the thing gating (want a wrongful 0)"
fi

echo
echo "repo-scope-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
