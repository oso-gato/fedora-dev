#!/usr/bin/env bash
# repo-scope-session.test.sh — the PER-SESSION LAYER suite (R16/R27/R28) for bin/repo-scope.sh's optional
# SCOPE_SESSION narrowing, now OBJECTIVE-BACKED (2026-07-16). Drives the REAL bin/repo-scope.sh as
# subprocesses against a REAL bin/session-registry.sh (REAL flock, REAL /proc liveness), a TEMP SCOPE_FILE
# (ceiling) + TEMP SCOPE_REGISTRY_DIR, and a REAL GIT objective-doc fixture at a known sha (the
# git-anchored authority the read path re-verifies the cache against). No gh / network / model.
#
# WHAT IT PROVES:
#   * INERT when SCOPE_SESSION is unset — byte-for-byte the ceiling-only reader, EVEN with a populated
#     registry present (the running poller sets nothing, so landing this layer changes NOTHING).
#   * a git-BACKED session NARROWS the ceiling to its transcribed objective repo-list;
#   * a backed session can NOT exceed the ceiling (declares a repo ∉ ceiling → that repo still DENYs);
#   * the git-VERIFICATION is the boundary: an UNBACKED (no line-4), UNREADABLE (bad sha) or MISMATCH
#     (line-3 hand-edited to widen) session acts on NOTHING (SESSION_UNBACKED rc 3, the cause named) —
#     a hand-forged .session can never widen scope past the confirmed objective;
#   * DISJOINTNESS (R28): a repo held by another LIVE backed session is DENIED even when it is in your own
#     verified scope; freeing that holder flips it to ALLOW (the deny WAS the live cross-check);
#   * TWO MUTATION-CHECKS restored + run in-suite (each sed must genuinely change the copy, else vacuous):
#       (1) neutralize the session-narrowing → an out-of-session check WRONGLY ALLOWs;
#       (2) neutralize the git-VERIFY (verified_ok) → a FORGED cache (widened line-3) WRONGLY ALLOWs the
#           smuggled repo — proving the backing re-verification is the thing that stops the forgery.
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
command -v git   >/dev/null || { echo "FATAL: git required for the objective-doc fixture"; exit 2; }
# session_coords synthesizes a live-holder record for the disjointness + direct-injection rows.
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

# a REAL git clone holding per-repo-set objective docs, each with the exact "## Repositories this
# objective operates on" table the reader parses; ONE commit → a known sha the backings pin.
OBJ="$TMP/objclone"; mkdir -p "$OBJ"
git -C "$OBJ" init -q; git -C "$OBJ" config user.email x@y; git -C "$OBJ" config user.name x
objdoc(){ # <repo…> → an 00-OBJECTIVES-style doc
  printf '# T\n\n## Repositories this objective operates on\n\n| Repository | Role |\n|---|---|\n'
  for r in "$@"; do printf '| `oso-gato/%s` | role |\n' "$r"; done
  printf '\n## Document authority\n'
}
objdoc repo-a        > "$OBJ/obj-a.md"
objdoc repo-a repo-b > "$OBJ/obj-ab.md"
objdoc repo-a repo-z > "$OBJ/obj-az.md"
git -C "$OBJ" add -A; git -C "$OBJ" commit -qm init; OSHA="$(git -C "$OBJ" rev-parse HEAD)"
export SCOPE_OBJECTIVE_CLONE="$OBJ"   # the local backend objective_repos reads (repo field is nominal)

# detach the holder's std fds — else the backgrounded sleep inherits the $(…) command-sub pipe.
live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }
reset_reg(){ REGDIR="$TMP/reg.$1"; rm -rf "$REGDIR"; mkdir -p "$REGDIR"; export SCOPE_REGISTRY_DIR="$REGDIR"; }
entry_of(){ printf '%s/%s.session' "$SCOPE_REGISTRY_DIR" "${1//[^A-Za-z0-9._-]/_}"; }
# back_session <sid> <holder-pid> <objdoc-path> — transcribe the session (repos DERIVED from the doc).
back_session(){ SESSION_HOLDER_PID="$2" bash "$SCOPE" transcribe --backing "fedora-dev $3 $OSHA" "$1" >/dev/null 2>&1; }

check_rc(){ # <sess-or-empty> <repo> → sets RC + ERR
  local sess="$1" repo="$2"
  if [ -n "$sess" ]; then ERR="$(SCOPE_SESSION="$sess" SCOPE_FILE="$FIX" bash "$SCOPE" check "$repo" 2>&1 >/dev/null)"; RC=$?
  else                    ERR="$(SCOPE_FILE="$FIX" bash "$SCOPE" check "$repo" 2>&1 >/dev/null)"; RC=$?; fi
}
list_out(){ # <sess-or-empty> → sets OUT
  local sess="$1"
  if [ -n "$sess" ]; then OUT="$(SCOPE_SESSION="$sess" SCOPE_FILE="$FIX" bash "$SCOPE" list 2>/dev/null)"
  else                    OUT="$(SCOPE_FILE="$FIX" bash "$SCOPE" list 2>/dev/null)"; fi
}

# ===================================================================================================
echo "== INERT: SCOPE_SESSION unset → the ceiling IS the answer (registry NOT consulted) =="
reset_reg unset
HPU="$(live_holder)"
SESSION_HOLDER_PID="$HPU" bash "$REG" register live-session repo-a >/dev/null
check_rc "" repo-a; [ "$RC" = 0 ] && ok "unset: check repo-a → ALLOW rc 0 (ceiling member)" || bad "unset: check repo-a rc=$RC (want 0)"
check_rc "" repo-b; [ "$RC" = 0 ] && ok "unset: check repo-b → ALLOW rc 0 (registry IGNORED — inert)" || bad "unset: check repo-b rc=$RC (want 0)"
check_rc "" repo-z; [ "$RC" = 3 ] && ok "unset: check repo-z → DENY rc 3 (outside the ceiling)" || bad "unset: check repo-z rc=$RC (want 3)"
list_out "";        [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = "repo-a repo-b" ] && ok "unset: list → the full ceiling {repo-a repo-b}" || bad "unset: list = [$OUT]"

# ===================================================================================================
echo "== NARROW: a git-BACKED session {repo-a} narrows the ceiling {repo-a,repo-b} =="
reset_reg narrow
HPN="$(live_holder)"
back_session sessA "$HPN" obj-a.md
[ "$(bash "$REG" resolve sessA)" = repo-a ] && ok "transcribe DERIVED {repo-a} from the objective doc" || bad "transcribe wrong: [$(bash "$REG" resolve sessA)]"
check_rc sessA repo-a; [ "$RC" = 0 ] && ok "sessA{a}: check repo-a → ALLOW rc 0 (verified member)" || bad "sessA: check repo-a rc=$RC err=[$ERR] (want 0)"
check_rc sessA repo-b; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'NARROWS'; } && ok "sessA{a}: check repo-b → DENY rc 3 (narrowed out)" || bad "sessA: check repo-b rc=$RC err=[$ERR] (want 3 + narrow log)"
list_out sessA; [ "$OUT" = "repo-a" ] && ok "sessA{a}: list → the effective set {repo-a}" || bad "sessA: list = [$OUT] (want repo-a)"

# ===================================================================================================
echo "== CANNOT EXCEED: a backed session {repo-a,repo-z} where repo-z ∉ ceiling =="
reset_reg exceed
HPE="$(live_holder)"
back_session sessC "$HPE" obj-az.md
check_rc sessC repo-z; [ "$RC" = 3 ] && ok "sessC{a,z}: check repo-z → DENY rc 3 (z is outside the ceiling)" || bad "sessC: check repo-z rc=$RC (want 3)"
check_rc sessC repo-a; [ "$RC" = 0 ] && ok "sessC{a,z}: check repo-a → ALLOW rc 0 (a is in both)" || bad "sessC: check repo-a rc=$RC (want 0)"
list_out sessC; [ "$OUT" = "repo-a" ] && ok "sessC{a,z}: list → {repo-a} (z dropped — session ∩ ceiling)" || bad "sessC: list = [$OUT] (want repo-a)"

# ===================================================================================================
echo "== UNDECLARED: SCOPE_SESSION set but NOT registered → acts on NOTHING =="
reset_reg undeclared
check_rc ghost repo-a; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'declared NO operating scope'; } && ok "ghost: check repo-a → DENY rc 3 (undeclared)" || bad "ghost: check repo-a rc=$RC err=[$ERR] (want 3)"
list_out ghost; [ -z "$OUT" ] && ok "ghost: list → empty (undeclared)" || bad "ghost: list = [$OUT] (want empty)"

# ===================================================================================================
echo "== BACKING VERIFICATION (R16): UNBACKED / UNREADABLE / MISMATCH all fail closed =="
reset_reg unbacked
HPB1="$(live_holder)"
SESSION_HOLDER_PID="$HPB1" bash "$REG" register sessU repo-a >/dev/null   # NO --backing → line 4 = '-'
check_rc sessU repo-a; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'UNBACKED'; } && ok "sessU (no backing): check repo-a → DENY rc 3 (UNBACKED)" || bad "sessU: rc=$RC err=[$ERR] (want 3 + UNBACKED)"

reset_reg unreadable
HPB2="$(live_holder)"
SESSION_HOLDER_PID="$HPB2" bash "$REG" register --backing "fedora-dev obj-a.md deadbeef000badref" sessR repo-a >/dev/null
check_rc sessR repo-a; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'UNREADABLE'; } && ok "sessR (bad sha): check repo-a → DENY rc 3 (UNREADABLE)" || bad "sessR: rc=$RC err=[$ERR] (want 3 + UNREADABLE)"

reset_reg mismatch
HPB3="$(live_holder)"
back_session sessX "$HPB3" obj-a.md          # legitimately {repo-a}, backed to obj-a
sed -i '3s/$/ repo-b/' "$(entry_of sessX)"    # FORGE: hand-edit line 3 to widen to {repo-a repo-b}
check_rc sessX repo-a; { [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q 'MISMATCH'; } && ok "sessX (forged line-3): check repo-a → DENY rc 3 (MISMATCH — the whole session fails closed)" || bad "sessX: check repo-a rc=$RC err=[$ERR] (want 3 + MISMATCH)"
check_rc sessX repo-b; [ "$RC" = 3 ] && ok "sessX (forged): the SMUGGLED repo-b is NOT allowed rc 3 (forgery blocked)" || bad "sessX: check repo-b rc=$RC (want 3 — the forged widen must not act)"

# ===================================================================================================
echo "== DISJOINTNESS (R28): a repo held by another LIVE backed session is DENIED =="
reset_reg held
HPA="$(live_holder)"; HPB="$(live_holder)"
back_session sessA "$HPA" obj-a.md            # sessA legitimately holds repo-a (live, backed)
# inject sessB directly (also {repo-a}, valid backing + a REAL live holder) — the cross-session state the
# registry's own register would refuse, so the SESSION_HELD path is exercised with sessB genuinely a member.
recB="$(SESSION_HOLDER_PID="$HPB" session_coords)"
{ printf '%s\n' sessB; printf '%s\n' "$recB"; printf '%s\n' repo-a; printf '%s\n' "fedora-dev obj-a.md $OSHA"; } > "$(entry_of sessB)"
check_rc sessB repo-a
{ [ "$RC" = 3 ] && printf '%s' "$ERR" | grep -q "held by another LIVE session 'sessA'"; } \
  && ok "sessB{a}: check repo-a → DENY rc 3 (held by live sessA — R28), naming the holder" \
  || bad "sessB: check repo-a rc=$RC err=[$ERR] (want 3 + held-by sessA)"
kill "$HPA" 2>/dev/null; wait "$HPA" 2>/dev/null || true
check_rc sessB repo-a
[ "$RC" = 0 ] && ok "sessB{a}: after sessA's holder dies, check repo-a → ALLOW rc 0 (the deny WAS the live cross-check)" \
  || bad "sessB: post-death check repo-a rc=$RC (want 0)"

# ===================================================================================================
echo "== MUTATION 1: neutralizing the session-narrowing makes an out-of-session check WRONGLY ALLOW =="
MUT="$TMP/mut"; mkdir -p "$MUT"
cp "$HERE/bin/repo-scope.sh" "$HERE/bin/session-registry.sh" "$HERE/bin/session-id.sh" "$HERE/bin/lock-lib.sh" "$MUT/"
sed -i 's|.*smember.*SESSION_DENY.*|  : # narrowing neutralized|' "$MUT/repo-scope.sh"
if [ "$(cat "$HERE/bin/repo-scope.sh")" = "$(cat "$MUT/repo-scope.sh")" ]; then
  bad "mutation1: the sed changed NOTHING — vacuous"
else
  ok "mutation1: session-narrowing line neutralized in the copy"
  reset_reg mut1; HPM="$(live_holder)"; back_session sessM "$HPM" obj-a.md
  RC=0; SCOPE_SESSION=sessM SCOPE_FILE="$FIX" bash "$SCOPE" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 3 ] && ok "real script: sessM{a} check repo-b → DENY rc 3 (narrowing bites)" || bad "real: check repo-b rc=$RC (want 3)"
  RC=0; SCOPE_SESSION=sessM SCOPE_FILE="$FIX" bash "$MUT/repo-scope.sh" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 0 ] && ok "mutant: with the narrowing gone, check repo-b WRONGLY ALLOWs rc 0 (the row bites)" \
    || bad "mutant: check repo-b rc=$RC (want a wrongful 0)"
fi

# ===================================================================================================
echo "== MUTATION 2: neutralizing the git-VERIFY makes a FORGED cache WRONGLY ALLOW the smuggled repo =="
MUT2="$TMP/mut2"; mkdir -p "$MUT2"
cp "$HERE/bin/repo-scope.sh" "$HERE/bin/session-registry.sh" "$HERE/bin/session-id.sh" "$HERE/bin/lock-lib.sh" "$MUT2/"
sed -i 's|verified_ok=0|verified_ok=1|' "$MUT2/repo-scope.sh"   # force the verify to ALWAYS pass
if [ "$(cat "$HERE/bin/repo-scope.sh")" = "$(cat "$MUT2/repo-scope.sh")" ]; then
  bad "mutation2: the sed changed NOTHING — vacuous"
else
  ok "mutation2: backing-verify (verified_ok) neutralized in the copy"
  reset_reg mut2; HPF="$(live_holder)"; back_session sessF "$HPF" obj-a.md      # {repo-a}, backed
  sed -i '3s/$/ repo-b/' "$(entry_of sessF)"                                    # FORGE line-3 → {repo-a repo-b}
  RC=0; SCOPE_SESSION=sessF SCOPE_FILE="$FIX" bash "$SCOPE" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 3 ] && ok "real script: forged sessF check repo-b → DENY rc 3 (verify catches the forgery)" || bad "real: forged check repo-b rc=$RC (want 3)"
  RC=0; SCOPE_SESSION=sessF SCOPE_FILE="$FIX" bash "$MUT2/repo-scope.sh" check repo-b >/dev/null 2>&1 || RC=$?
  [ "$RC" = 0 ] && ok "mutant: with the verify gone, the forged repo-b WRONGLY ALLOWs rc 0 (the verify IS the boundary)" \
    || bad "mutant: forged check repo-b rc=$RC (want a wrongful 0)"
fi

echo
echo "repo-scope-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
