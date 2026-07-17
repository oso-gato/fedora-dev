#!/usr/bin/env bash
# session-scope-seed.test.sh — proves bin/session-scope-seed.sh (the launch-time scope binder, R16/R27):
# SELF-SEED a declared new session · REFRESH a persisted (resumed) one · NO-OP undeclared · fail-safe on a
# bad config · + TWO in-suite mutation rows + a bin/claude wiring drift-guard. Drives the REAL seed against
# the REAL session-registry.sh + repo-scope.sh + a REAL git objective fixture. No gh/network/model.
set -uo pipefail
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SCOPE_SESSION 2>/dev/null || true
HERE="$(cd "$(dirname "$0")" && pwd)"
SEED="$HERE/bin/session-scope-seed.sh"; REG="$HERE/bin/session-registry.sh"; RS="$HERE/bin/repo-scope.sh"
for f in "$SEED" "$REG" "$RS" "$HERE/bin/claude" "$HERE/bin/session-id.sh"; do [ -f "$f" ] || { echo "FATAL: $f not found"; exit 2; }; done
command -v flock >/dev/null || { echo "FATAL: flock"; exit 2; }
command -v git   >/dev/null || { echo "FATAL: git"; exit 2; }

pass=0; fail=0; ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }; bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
TMP="$(mktemp -d)"; HOLDERS=""; trap 'kill $HOLDERS >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }

# a real objective-doc clone; SCOPE_CLONE_ROOTS makes objective_clone_dir resolve <root>/wl-obj.
ROOT="$TMP/clones"; mkdir -p "$ROOT/wl-obj"
git -C "$ROOT/wl-obj" init -q; git -C "$ROOT/wl-obj" config user.email x@y; git -C "$ROOT/wl-obj" config user.name x
printf '# T\n\n## Repositories this objective operates on\n\n| Repository | Role |\n|---|---|\n| `oso-gato/wl-obj` | dev |\n\n## Document authority\n' > "$ROOT/wl-obj/00-OBJECTIVES.md"
git -C "$ROOT/wl-obj" add -A; git -C "$ROOT/wl-obj" commit -qm init

REGDIR="$TMP/reg"; mkdir -p "$REGDIR"
run_seed(){     SESSION_HOLDER_PID="$1" SCOPE_REGISTRY_DIR="$REGDIR" SCOPE_CLONE_ROOTS="$ROOT" SCOPE_REGISTRY_CLI="$REG" REPO_SCOPE_CLI="$RS" bash "$SEED" "$2" >/dev/null 2>&1; }
run_seed_bin(){ SESSION_HOLDER_PID="$1" SCOPE_REGISTRY_DIR="$REGDIR" SCOPE_CLONE_ROOTS="$ROOT" SCOPE_REGISTRY_CLI="$REG" REPO_SCOPE_CLI="$RS" bash "$3" "$2" >/dev/null 2>&1; }  # <holder> <sid> <script>
resolve(){ SCOPE_REGISTRY_DIR="$REGDIR" bash "$REG" resolve "$1"; }
resolveb(){ SCOPE_REGISTRY_DIR="$REGDIR" bash "$REG" resolve-backing "$1"; }
entry(){ printf '%s/%s.session' "$REGDIR" "${1//[^A-Za-z0-9._-]/_}"; }
objcfg(){ printf '%s\n' "$2" > "$REGDIR/${1//[^A-Za-z0-9._-]/_}.objective"; }

echo "== SELF-SEED: a declared new session is transcribed from its confirmed objective =="
objcfg svc-new "wl-obj 00-OBJECTIVES.md"
run_seed "$(live_holder)" svc-new
[ "$(resolve svc-new)" = wl-obj ] && ok "self-seed DERIVED {wl-obj} from the objective doc" || bad "self-seed did not bind: [$(resolve svc-new)]"
[ -n "$(resolveb svc-new)" ] && ok "self-seed recorded a backing ref (git-anchored)" || bad "self-seed left no backing"

echo "== REFRESH: a persisted (resumed) session gets NEW coords, scope PRESERVED (no re-transcribe) =="
HOLD="$(live_holder)"; SESSION_HOLDER_PID="$HOLD" SCOPE_REGISTRY_DIR="$REGDIR" bash "$REG" register --backing 'wl-obj 00-OBJECTIVES.md deadbeef' svc-res repo-x >/dev/null
HNEW="$(live_holder)"; run_seed "$HNEW" svc-res
grep -q "^$HNEW " "$(entry svc-res)" && ok "refresh wrote the RESUMING holder's coords" || bad "refresh did not update coords"
[ "$(resolve svc-res)" = repo-x ] && ok "refresh PRESERVED the scope (did NOT re-transcribe)" || bad "refresh mangled the scope"

echo "== NO-OP: an undeclared session (no entry, no config) binds nothing =="
run_seed "$(live_holder)" svc-undeclared
[ -e "$(entry svc-undeclared)" ] && bad "an undeclared session got an entry" || ok "undeclared → no entry (runs on the ceiling)"

echo "== FAIL-SAFE: a declared objective with NO local clone is a safe no-op (never blocks a launch) =="
objcfg svc-badclone "no-such-repo 00-OBJECTIVES.md"
run_seed "$(live_holder)" svc-badclone && ok "bad-clone seed exits 0" || bad "bad-clone seed returned non-zero (would risk a launch)"
[ -e "$(entry svc-badclone)" ] && bad "bad-clone created a bogus entry" || ok "bad-clone bound nothing"

echo "== MUTATION 1: neutralize the SELF-SEED transcribe → a declared session binds nothing =="
MUT1="$TMP/seed-mut1.sh"; sed 's@bash "\$RS" transcribe@true "\$RS" transcribe@' "$SEED" > "$MUT1"; chmod +x "$MUT1"
if cmp -s "$SEED" "$MUT1"; then bad "mutation1 VACUOUS (sed changed nothing)"; else
  ok "mutation1: transcribe neutralized in the copy"
  objcfg svc-m1 "wl-obj 00-OBJECTIVES.md"; run_seed_bin "$(live_holder)" svc-m1 "$MUT1"
  [ -e "$(entry svc-m1)" ] && bad "mutant still bound → transcribe is NOT the binder (vacuous)" || ok "mutant: a declared session bound NOTHING (transcribe IS the binder)"
fi

echo "== MUTATION 2: neutralize the REFRESH → a resumed session's coords stay stale =="
MUT2="$TMP/seed-mut2.sh"; sed 's@bash "\$REG" refresh@true "\$REG" refresh@' "$SEED" > "$MUT2"; chmod +x "$MUT2"
if cmp -s "$SEED" "$MUT2"; then bad "mutation2 VACUOUS"; else
  ok "mutation2: refresh neutralized in the copy"
  HOLD2="$(live_holder)"; SESSION_HOLDER_PID="$HOLD2" SCOPE_REGISTRY_DIR="$REGDIR" bash "$REG" register svc-res2 repo-y >/dev/null
  HN2="$(live_holder)"; run_seed_bin "$HN2" svc-res2 "$MUT2"
  grep -q "^$HN2 " "$(entry svc-res2)" && bad "mutant refreshed anyway → refresh is NOT the thing (vacuous)" || ok "mutant: coords NOT refreshed (refresh IS what keeps a resumed entry live)"
fi

echo "== DRIFT GUARD: bin/claude carries the self-seed wiring with a session-lifetime holder =="
grep -q 'session-scope-seed.sh' "$HERE/bin/claude" && ok "bin/claude invokes session-scope-seed.sh" || bad "bin/claude LOST the self-seed wiring"
grep -qF 'SESSION_HOLDER_PID=$$' "$HERE/bin/claude" && ok 'bin/claude passes $$ as the session-lifetime holder' || bad 'bin/claude does not pass the $$ holder'

echo; echo "session-scope-seed: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
