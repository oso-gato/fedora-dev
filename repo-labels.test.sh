#!/usr/bin/env bash
# repo-labels.test.sh — suite for bin/repo-labels.sh (THE LABEL CONTRACT).
#
# WHY IT EXISTS. bin/repo-labels.sh's own header claimed "Covered by repo-labels.test.sh" while no such
# file existed — a script asserting coverage it did not have, which is the same untrue-claim class the
# fitness gate blocks a PR body for. This is that file, and it tests the axes `--selftest` is
# structurally BLIND to: the pure conformance core is already selftested, but nothing exercised the two
# things that actually touch the world — WHICH labels get CREATED on WHICH repo, and whether the R16
# scope belt stops a write on a repo outside the operating scope.
#
# REAL where it matters, stub only the boundary: the REAL script, a stub `gh` that RECORDS every call
# (so "created nothing" is proven, not assumed) and a stub `repo-scope.sh` behind the script's own
# REPO_SCOPE seam. It also RUNS the `audit` drift guard against the real bin/ tree, which was previously
# reachable only if a human happened to type it — so label drift is now caught by CI (tests.yml globs
# *.test.sh) instead of by nobody.
#
# PER-ROW KNOBS ARE EXPORTED VARIABLES, ASSIGNED AND RESET — never a `VAR=x run …` assignment-prefix on
# a shell FUNCTION, whose propagation to the function's grandchildren is not something to rely on (the
# lesson objective-status.test.sh already records).
#
#   bash repo-labels.test.sh   → exit 0 = all rows pass. No GitHub / network / model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/repo-labels.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){  pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

export GH_CALLS="$ROOT/gh.calls"
export FAKE_LABELS="$ROOT/labels.txt"          # one already-existing label per line
export FAKE_LIST_FAIL=0                        # 1 ⇒ `gh label list` fails (unreadable)
export FAKE_CREATE_FAIL=""                     # a label name whose create fails
export SCOPE_BROKEN=0                          # 1 ⇒ the scope reader is MISSING (rc 127)

mkdir -p "$ROOT/stub"
cat > "$ROOT/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "${1:-} ${2:-}" in
  "label list")   [ "${FAKE_LIST_FAIL:-0}" = 1 ] && exit 1; cat "$FAKE_LABELS" 2>/dev/null; exit 0 ;;
  "label create") [ "${3:-}" = "${FAKE_CREATE_FAIL:-}" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/stub/gh"
export PATH="$ROOT/stub:$PATH"

# stub repo-scope.sh behind the script's own REPO_SCOPE seam: in scope unless the repo is "foreign",
# and rc 127 (a MISSING reader) under SCOPE_BROKEN=1 — the fail-closed case R16 names explicitly.
cat > "$ROOT/repo-scope.sh" <<'EOF'
#!/usr/bin/env bash
[ "${SCOPE_BROKEN:-0}" = 1 ] && exit 127
case "${2:-}" in foreign) exit 3;; esac
exit 0
EOF
chmod +x "$ROOT/repo-scope.sh"
export REPO_SCOPE="$ROOT/repo-scope.sh"

run(){ : > "$GH_CALLS"; OUT="$("$@" 2>&1)"; RC=$?; }
created(){    grep -cE "^label create $1( |$)" "$GH_CALLS" 2>/dev/null || true; }
any_create(){ grep -cE '^label create '       "$GH_CALLS" 2>/dev/null || true; }
setlabels(){ printf '%s\n' "$@" > "$FAKE_LABELS"; }
alllabels(){ bash "$SCRIPT" list | awk '{print $1}' > "$FAKE_LABELS"; }

echo "== ensure — establishes exactly the MISSING vocabulary, idempotently =="

setlabels backlog live-validate
run bash "$SCRIPT" ensure fedora-dev
{ [ "$RC" = 0 ] && [ "$(created escalate)" -ge 1 ] && [ "$(created blocked)" -ge 1 ] \
  && [ "$(created backlog)" = 0 ] && [ "$(created live-validate)" = 0 ]; } \
  && ok "creates every missing label and RE-creates none that already exist" \
  || bad "ensure-missing" "rc=$RC calls=[$(cat "$GH_CALLS")]"

alllabels
run bash "$SCRIPT" ensure fedora-dev
{ [ "$RC" = 0 ] && [ "$(any_create)" = 0 ] && echo "$OUT" | grep -q 'already conformant'; } \
  && ok "idempotent — a conformant repo is re-run for free (zero creates)" \
  || bad "ensure-idempotent" "rc=$RC creates=$(any_create) out=[$OUT]"

# The colour/description must come FROM THE REGISTRY, not be invented at the call site — that single
# home is the file's entire purpose, so a create that dropped them would defeat it silently.
setlabels backlog
run bash "$SCRIPT" ensure fedora-dev
{ grep -qE "^label create live-validate .*--color 1d76db" "$GH_CALLS" \
  && grep -qE "^label create live-validate .*--description .*live-gate" "$GH_CALLS"; } \
  && ok "creates carry the REGISTRY's declared colour + description" \
  || bad "ensure-registry-fields" "calls=[$(grep '^label create live-validate' "$GH_CALLS" || true)]"

setlabels backlog
FAKE_CREATE_FAIL=escalate
run bash "$SCRIPT" ensure fedora-dev
FAKE_CREATE_FAIL=""
{ [ "$RC" = 1 ] && echo "$OUT" | grep -q "could NOT create:.*escalate"; } \
  && ok "a failed create is REPORTED by name and exits non-zero (never a silent no-op)" \
  || bad "ensure-create-failed" "rc=$RC out=[$OUT]"

FAKE_LIST_FAIL=1
run bash "$SCRIPT" ensure fedora-dev
FAKE_LIST_FAIL=0
{ [ "$RC" = 3 ] && [ "$(any_create)" = 0 ] && echo "$OUT" | grep -q 'fail-closed'; } \
  && ok "unreadable label list ⇒ fail-closed, establishes NOTHING blind" \
  || bad "ensure-unreadable" "rc=$RC creates=$(any_create) out=[$OUT]"

echo "== the R16 scope belt — a WRITE actuator checks scope itself =="

setlabels backlog
run bash "$SCRIPT" ensure foreign
{ [ "$RC" = 4 ] && [ "$(any_create)" = 0 ] && ! grep -q 'foreign' "$GH_CALLS" \
  && echo "$OUT" | grep -q 'R16 SCOPE'; } \
  && ok "out-of-scope repo ⇒ rc 4, ZERO gh calls, nothing created on it" \
  || bad "scope-refuses" "rc=$RC calls=[$(cat "$GH_CALLS")]"

setlabels backlog
SCOPE_BROKEN=1
run bash "$SCRIPT" ensure fedora-dev
SCOPE_BROKEN=0
{ [ "$RC" = 4 ] && [ "$(any_create)" = 0 ]; } \
  && ok "a MISSING scope reader (rc 127) is a refusal, never a go (fail-closed)" \
  || bad "scope-broken" "rc=$RC creates=$(any_create) out=[$OUT]"

echo "== check — reports, never writes =="

setlabels backlog
run bash "$SCRIPT" check fedora-dev
{ [ "$RC" = 1 ] && [ "$(any_create)" = 0 ] && echo "$OUT" | grep -q 'MISSING:.*live-validate'; } \
  && ok "check names what is missing and creates nothing" \
  || bad "check-missing" "rc=$RC out=[$OUT]"

alllabels
run bash "$SCRIPT" check fedora-dev
{ [ "$RC" = 0 ] && [ "$(any_create)" = 0 ]; } \
  && ok "check on a conformant repo ⇒ rc 0" || bad "check-ok" "rc=$RC out=[$OUT]"

FAKE_LIST_FAIL=1
run bash "$SCRIPT" check fedora-dev
FAKE_LIST_FAIL=0
{ [ "$RC" = 3 ] && echo "$OUT" | grep -q "NOT the same as 'none missing'"; } \
  && ok "unreadable ⇒ rc 3, explicitly NOT 'nothing missing'" || bad "check-unreadable" "rc=$RC out=[$OUT]"

echo "== parked — the non-drivable set the deadman's work axis consumes =="

run bash "$SCRIPT" parked
{ [ "$RC" = 0 ] \
  && echo "$OUT" | grep -qx 'maintainer-merge'    && echo "$OUT" | grep -qx 'escalate' \
  && echo "$OUT" | grep -qx 'blocked'             && echo "$OUT" | grep -qx 'awaiting-maintainer' \
  && echo "$OUT" | grep -qx 'needs-decision'      && echo "$OUT" | grep -qx 'apparatus-blocked' \
  && ! echo "$OUT" | grep -qx 'live-validate'; } \
  && ok "parked prints every held label and NOT the drivable ones" \
  || bad "parked" "rc=$RC out=[$OUT]"

# LOCKSTEP with the consumer: apparatus-deadman.sh shells out to this exact verb on every check, and a
# rename here would not break it loudly — it would silently empty the parked set and quietly restore the
# false-firing this contract removes. Pin both ends.
{ grep -q 'repo-labels.sh" parked' "$HERE/bin/apparatus-deadman.sh" && grep -q '^  parked)' "$SCRIPT"; } \
  && ok "the deadman calls the 'parked' verb and this script serves it (contract pinned)" \
  || bad "parked-lockstep" "consumer/producer drift"

echo "== audit — the drift guard, now actually RUN (it was reachable only by hand) =="

run bash "$SCRIPT" audit
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q 'no label drift'; } \
  && ok "every label literal used in the real bin/ tree is declared in the registry" \
  || bad "audit-clean" "rc=$RC out=[$OUT] — add the label to REGISTRY or stop using it"

echo "== MUTATION — the scope belt must be what refuses, not the stub =="

# A COPY with the two R16 check lines DELETED. If removing them does not let a foreign repo through,
# the scope row above proved nothing about the belt.
MUT="$ROOT/mutant.sh"
awk '/"\$REPO_SCOPE" check "\$REPO"/{next} /R16 SCOPE: /{next} {print}' "$SCRIPT" > "$MUT"
chmod +x "$MUT"
before="$(grep -c 'REPO_SCOPE" check' "$SCRIPT" || true)"
after="$(grep -c 'REPO_SCOPE" check'  "$MUT"    || true)"
if [ "$before" -le "$after" ] || ! bash -n "$MUT" 2>/dev/null; then
  bad "mutation-vacuous" "the mutation did not remove a working scope check (before=$before after=$after)"
else
  setlabels backlog
  run bash "$MUT" ensure foreign
  { [ "$(any_create)" -ge 1 ] && grep -q 'foreign' "$GH_CALLS"; } \
    && ok "MUTATION BITES: without the belt, labels ARE created on the out-of-scope repo" \
    || bad "mutation-no-bite" "rc=$RC creates=$(any_create) calls=[$(cat "$GH_CALLS")]"
fi

echo
echo "repo-labels.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
