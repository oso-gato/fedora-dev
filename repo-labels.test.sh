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
  "label delete") [ "${3:-}" = "${FAKE_DELETE_FAIL:-}" ] && exit 1; exit 0 ;;
esac
# `gh api repos/<o>/<r>/issues?labels=<name>&… -q length` — the USAGE count prune reads before deleting.
# Only FAKE_USED_LABEL is in use (FAKE_USED_N, default 1); everything else answers 0. FAKE_USED_FAIL=1
# makes the read ERROR, which prune must treat as unreadable and HOLD on (never delete on a blind count).
case "${1:-}" in
  api) [ "${FAKE_USED_FAIL:-0}" = 1 ] && exit 1
       _l="${2#*labels=}"; _l="${_l%%&*}"
       if [ "$_l" = "${FAKE_USED_LABEL:-}" ]; then printf '%s\n' "${FAKE_USED_N:-1}"; else echo 0; fi
       exit 0 ;;
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
deleted(){    grep -cE "^label delete $1( |$)" "$GH_CALLS" 2>/dev/null || true; }
any_delete(){ grep -cE '^label delete '       "$GH_CALLS" 2>/dev/null || true; }
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

echo "== audit — the label ARGUMENT is CAPTURED, whatever shape it wears (fitness finding on 7282a3f) =="
# The audit's comment claimed a dynamically-built name was "flagged, not ignored". It was not: the two
# flags carried DIFFERENT literal alternatives and only `--label`'s tolerated a leading quote, so the
# host bus's real line — `--add-label "host-$st"`, fedora-bootstrap host-agent-watch.sh:235 — matched
# NOTHING and the guard was silent about the one construction it named. These rows are end-to-end
# through the real `audit` verb, because the fixture cannot live in the script's own --selftest: audit
# scans bin/*.sh INCLUDING ITSELF, so a fixture there would be read as production usage and reported as
# drift against the real tree (measured while writing this).
BINDIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
PROBE="$BINDIR/probe-label-$$.sh"; MUT5="$BINDIR/mut-tokre-$$.sh"
MUT2="$BINDIR/mut-audit-$$.sh"; MUT3="$BINDIR/mut-audit-old-$$.sh"
# ONE trap covering the tempdir AND every artifact this suite drops in bin/ — a later `trap … EXIT`
# REPLACES an earlier one, so each addition must re-state the whole set or something leaks.
trap 'rm -rf "$ROOT"; rm -f "$PROBE" "$MUT5" "$MUT2" "$MUT3"' EXIT

# Probe A — the host bus's verbatim construction. Expected: REPORTED as ungradeable (a NOTE), rc 0, and
# NO drift, because the truncated fragment `host-` is not a label anyone uses and naming it would be a
# false positive on a guard whose whole value is being trusted.
cat > "$PROBE" <<'PEOF'
#!/usr/bin/env bash
gh issue edit "$n" --repo "$r" --add-label "host-$st" >/dev/null 2>&1
PEOF
chmod +x "$PROBE"
run bash "$SCRIPT" audit
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q 'cannot be graded statically' \
  && echo "$OUT" | grep -qF 'host-$st' && ! echo "$OUT" | grep -q 'LABEL DRIFT'; } \
  && ok "a dynamic '--add-label \"host-\$st\"' is REPORTED ungradeable — rc 0, no false drift on 'host-'" \
  || bad "audit-dynamic-flagged" "rc=$RC out=[$OUT]"

# MUTATION: restore the pre-fix token grammar (the two divergent alternatives) on a COPY. Against the
# SAME probe the NOTE must VANISH — the construction silently ignored again, which is what makes the row
# above a measurement of the capture rather than of the reporting plumbing.
cat > "$ROOT/oldre.txt" <<'REOF'
LABEL_TOKEN_RE='--add-label ("?\$\{?[A-Za-z_]+\}?"?|[a-zA-Z][a-zA-Z0-9_-]*)|--label ("?\$\{?[A-Za-z_]+\}?"?|"?[a-z][a-z0-9-]{2,30}"?)'
REOF
awk -v f="$ROOT/oldre.txt" '/^LABEL_TOKEN_RE=/{while((getline l < f)>0) print l; next} {print}' \
    "$SCRIPT" > "$MUT5"; chmod +x "$MUT5"
if cmp -s "$SCRIPT" "$MUT5" || ! grep -q '^LABEL_TOKEN_RE=' "$MUT5" || ! bash -n "$MUT5" 2>/dev/null; then
  bad "audit-dynamic-mutation-vacuous" "the old grammar was not substituted into a runnable copy"
else
  run bash "$MUT5" audit
  { [ "$RC" = 0 ] && ! echo "$OUT" | grep -qF 'host-$st'; } \
    && ok "MUTATION BITES: under the OLD grammar the same line is captured by nothing and never mentioned" \
    || bad "audit-dynamic-mutation" "rc=$RC out=[$OUT] (old grammar should be silent on it)"
fi
rm -f "$MUT5"

# Probe B — a QUOTED literal after --add-label, ungraded entirely before (the reviewer's related NOTE).
# It must now be graded like any other literal: undeclared ⇒ DRIFT, rc 1.
cat > "$PROBE" <<'PEOF'
#!/usr/bin/env bash
gh issue edit 1 --add-label "totally-undeclared" >/dev/null 2>&1
PEOF
run bash "$SCRIPT" audit
{ [ "$RC" = 1 ] && echo "$OUT" | grep -q 'LABEL DRIFT' && echo "$OUT" | grep -q 'totally-undeclared'; } \
  && ok "a QUOTED literal after --add-label is graded — undeclared ⇒ drift, rc 1 (was ungraded)" \
  || bad "audit-quoted-literal" "rc=$RC out=[$OUT]"
rm -f "$PROBE"

run bash "$SCRIPT" audit
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q 'no label drift'; } \
  && ok "…and the real tree is clean again once the probe is gone (no residue)" \
  || bad "audit-probe-residue" "rc=$RC out=[$OUT]"

echo "== prune — DESTRUCTIVE, so dry-run by default and it never touches the registry =="
# The maintainer's standing instruction is a SMALL controlled set per repo. Before `prune` existed the
# cleanup was a hand-run loop nothing could repeat — and a destructive verb with no WIRING test is the
# defect pattern this repo keeps finding (a pure core cannot see that nothing calls it).
alllabels; printf 'junk-label\n' >> "$FAKE_LABELS"
run bash "$SCRIPT" prune fedora-dev
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q "WOULD DELETE 'junk-label'" && [ "$(any_delete)" = 0 ]; } \
  && ok "dry-run by default: says what it WOULD delete and deletes nothing" \
  || bad "prune-dryrun" "rc=$RC deletes=$(any_delete) out=[$OUT]"

run bash "$SCRIPT" prune fedora-dev --commit
{ [ "$RC" = 0 ] && [ "$(deleted junk-label)" = 1 ] \
  && [ "$(deleted backlog)" = 0 ] && [ "$(deleted live-validate)" = 0 ] && [ "$(deleted approved)" = 0 ]; } \
  && ok "--commit deletes the off-registry label and NEVER a registry one" \
  || bad "prune-commit" "rc=$RC junk=$(deleted junk-label) backlog=$(deleted backlog) lv=$(deleted live-validate)"

alllabels; printf 'junk-label\n' >> "$FAKE_LABELS"
run env FAKE_USED_LABEL=junk-label FAKE_USED_N=3 bash "$SCRIPT" prune fedora-dev --commit
{ [ "$RC" = 0 ] && [ "$(deleted junk-label)" = 0 ] && echo "$OUT" | grep -q "HOLD 'junk-label'" \
  && echo "$OUT" | grep -q 'IN USE on 3' && echo "$OUT" | grep -q -- '--force'; } \
  && ok "an off-registry label IN USE is HELD, named, and left alone (deleting strips it from those items)" \
  || bad "prune-hold-inuse" "rc=$RC junk-deleted=$(deleted junk-label) out=[$OUT]"

run env FAKE_USED_LABEL=junk-label FAKE_USED_N=3 bash "$SCRIPT" prune fedora-dev --commit --force
{ [ "$RC" = 0 ] && [ "$(deleted junk-label)" = 1 ]; } \
  && ok "--force deletes an in-use off-registry label (the explicit, recorded choice)" \
  || bad "prune-force" "rc=$RC deleted=$(deleted junk-label) out=[$OUT]"

run env FAKE_USED_FAIL=1 bash "$SCRIPT" prune fedora-dev --commit
{ [ "$RC" = 0 ] && [ "$(any_delete)" = 0 ] && echo "$OUT" | grep -q 'could not read its usage'; } \
  && ok "an UNREADABLE usage count HOLDS — never delete on a blind count (fail-closed)" \
  || bad "prune-usage-unreadable" "rc=$RC deletes=$(any_delete) out=[$OUT]"

run bash "$SCRIPT" prune foreign --commit
{ [ "$RC" = 4 ] && [ "$(any_delete)" = 0 ] && echo "$OUT" | grep -q 'R16 SCOPE'; } \
  && ok "an OUT-OF-SCOPE repo is refused before any delete (R16 rule 4 — a destructive actuator checks)" \
  || bad "prune-scope" "rc=$RC deletes=$(any_delete) out=[$OUT]"

SCOPE_BROKEN=1
run bash "$SCRIPT" prune fedora-dev --commit
{ [ "$RC" = 4 ] && [ "$(any_delete)" = 0 ]; } \
  && ok "a MISSING scope reader (rc 127) refuses too — fail-closed, not a go" \
  || bad "prune-scope-broken" "rc=$RC deletes=$(any_delete)"
SCOPE_BROKEN=0

run env FAKE_LIST_FAIL=1 bash "$SCRIPT" prune fedora-dev --commit
{ [ "$RC" = 3 ] && [ "$(any_delete)" = 0 ]; } \
  && ok "an unreadable label list prunes NOTHING blind" \
  || bad "prune-list-unreadable" "rc=$RC deletes=$(any_delete)"

echo "== prune keeps each repo's picker SMALL: control-only labels go from a TENANT =="
alllabels
run bash "$SCRIPT" prune fedora-dev
{ echo "$OUT" | grep -q "WOULD DELETE 'host-done'" && echo "$OUT" | grep -q "WOULD DELETE 'rebuild-approval'"; } \
  && ok "control-scoped labels are pruned from a tenant repo (they are decorative there)" \
  || bad "prune-control-scope-tenant" "out=[$OUT]"
run bash "$SCRIPT" prune fedora-bootstrap
{ ! echo "$OUT" | grep -q "WOULD DELETE 'host-done'"; } \
  && ok "…and KEPT on the control repo, where the machinery actually reads them" \
  || bad "prune-control-scope-control" "out=[$OUT]"

echo "== MUTATION — the audit RESOLVES variable defaults (it used to discard them) =="
# The old audit ended its pipeline with `grep -vE '^\$'`, so `--label "$APPROVED_LABEL"` was found and
# then thrown away: six real labels were invisible and it reported "no drift" over the hole. Proof that
# the fix bites: drop a label declared ONLY via a variable default and require the audit to catch it.
# BINDIR / MUT2 / MUT3 and the cleanup trap are declared once, above — a second `trap … EXIT` here would
# REPLACE that one and leak both the tempdir and the bin/ probe.
sed '/^approved|/d' "$SCRIPT" > "$MUT2"; chmod +x "$MUT2"
if cmp -s "$SCRIPT" "$MUT2"; then bad "audit-resolve-vacuous" "the sed changed nothing"; else
  bash "$MUT2" audit >/dev/null 2>&1; mrc=$?
  sed 's|names="$(resolve_token "$t" "$defs")"|names="$(printf "%s" "$t" \| grep -vE "^\\"?\\$" \|\| true)"|' "$MUT2" > "$MUT3"
  bash "$MUT3" audit >/dev/null 2>&1; orc=$?
  { [ "$mrc" = 1 ] && [ "$orc" = 0 ]; } \
    && ok "resolving bites: fixed audit rc=1 on a var-only label, OLD audit rc=0 (blind)" \
    || bad "audit-resolve" "fixed-rc=$mrc old-rc=$orc (want 1 and 0)"
fi

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
