#!/usr/bin/env bash
# recoverability-drill.test.sh — proves bin/recoverability-drill.sh's R38 per-action reversibility DRILLS
# (#207): each autonomous mutation's REVERSE operation is drilled the way R10 drills the deploy rollback,
# and a broken reverse op SURFACES as RED (never a silent/fake GREEN — R37 / ANTI-THEATER).
#
# It drives the REAL script end-to-end (no stubs for the faithful drills — the axis under test is that the
# reverse operation ACTUALLY RUNS): the merge drill runs a REAL `git revert`, the scope drill runs the REAL
# `bin/repo-scope.sh transcribe` + session registry against a throwaway git objective — both must FIRE
# GREEN. close + rebuild must report STAGED offline (disclosed, never faked). `all` folds to PARTIAL/rc0,
# and `guard` arms ONLY on a fired GREEN.
#
# MUTATION RUN IN-SUITE (the fitness-review.test.sh discipline): a RED drill is forced FAITHFULLY (an
# isolated copy with no sibling repo-scope.sh → the scope drill's reverse op cannot run → RED), and the
# REAL `overall_verdict` must surface `verdict: RED` (rc 1). Neutralizing `overall_verdict` (the anchor)
# on the SAME fixture must then HIDE the RED — the sed must genuinely change the copy, else the row fails
# as vacuous — proving the fold is what surfaces a broken reverse op, not the plumbing.
#
# bash recoverability-drill.test.sh → exit 0 = all rows pass. No GitHub/network/model. Run after touching
# the drill harness or its verdict fold.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/recoverability-drill.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
# run the script clean of any ambient live-drill env (default = merge/scope fire, close/rebuild STAGED).
D(){ env -u RECOVERY_DRILL_LIVE -u RECOVERY_DRILL_REPO bash "$@"; }

echo "== merge drill FIRES GREEN — a REAL git revert restores the pre-merge tree =="
out="$(D "$SCRIPT" merge)"; rc=$?
{ grep -q '^merge .*: GREEN' <<<"$out" && [ "$rc" = 0 ]; } \
  && ok "merge → git revert GREEN (rc 0)" || no "merge did not fire GREEN (rc=$rc)" "$out"

echo "== scope drill FIRES GREEN — a REAL transcribe-narrow rolls the scope back =="
out="$(D "$SCRIPT" scope)"; rc=$?
{ grep -q '^scope .*: GREEN' <<<"$out" && [ "$rc" = 0 ]; } \
  && ok "scope → transcribe-narrow GREEN (rc 0)" || no "scope did not fire GREEN (rc=$rc)" "$out"

echo "== close + rebuild are STAGED offline (disclosed, never a fake GREEN — R37/ANTI-THEATER) =="
out="$(D "$SCRIPT" close)"; rc=$?
{ grep -q '^close .*: STAGED' <<<"$out" && [ "$rc" = 3 ]; } \
  && ok "close STAGED (rc 3), reverse op named" || no "close not STAGED (rc=$rc)" "$out"
out="$(D "$SCRIPT" rebuild)"; rc=$?
{ grep -q '^rebuild .*: STAGED' <<<"$out" && [ "$rc" = 3 ]; } \
  && ok "rebuild STAGED (rc 3), reverse op named" || no "rebuild not STAGED (rc=$rc)" "$out"

echo "== all → PARTIAL, rc 0 (fired where runnable; the 2 staged are surfaced, not a failure) =="
out="$(D "$SCRIPT" all)"; rc=$?
{ grep -q '^verdict: PARTIAL' <<<"$out" && [ "$rc" = 0 ]; } \
  && ok "all → PARTIAL rc 0" || no "all not PARTIAL/rc0 (rc=$rc)" "$out"

echo "== guard is the ARM GATE — only a fired GREEN arms (R10 generalized) =="
D "$SCRIPT" guard merge >/dev/null 2>&1 \
  && ok "guard merge ARMS (GREEN → rc 0)" || no "guard merge did not arm on a GREEN drill"
D "$SCRIPT" guard close >/dev/null 2>&1 \
  && no "guard close ARMED on a STAGED (not-yet-fired) drill" || ok "guard close BLOCKS (STAGED never arms)"
D "$SCRIPT" guard bogus >/dev/null 2>&1
[ "$?" = 2 ] && ok "guard <unknown> → usage rc 2 (fail-closed)" || no "guard unknown did not rc 2"

echo "== a broken reverse op SURFACES as RED; MUTATION: neutralize overall_verdict and it is HIDDEN =="
# FAITHFUL forced-RED: an isolated copy with NO sibling repo-scope.sh/session-registry.sh → the scope
# drill's reverse op cannot run → RED. No backdoor, no stub — a real broken dependency.
mkdir -p "$TMP/iso/bin"; cp "$SCRIPT" "$TMP/iso/bin/recoverability-drill.sh"
ISO="$TMP/iso/bin/recoverability-drill.sh"
out="$(D "$ISO" all)"; rc=$?
{ grep -q '^  scope .*: RED' <<<"$out" && grep -q '^verdict: RED' <<<"$out" && [ "$rc" = 1 ]; } \
  && ok "a RED drill → verdict RED, rc 1 (the reverse op failed and it is not hidden)" \
  || no "RED drill not surfaced (rc=$rc)" "$out"

MUT="$TMP/mut.sh"
sed 's/^overall_verdict(){/overall_verdict(){ printf PARTIAL; return;/' "$ISO" > "$MUT"
if ! grep -q 'overall_verdict(){ printf PARTIAL; return;' "$MUT"; then
  no "mutation VACUOUS (sed did not neutralize overall_verdict)"
else
  out="$(D "$MUT" all)"; rc=$?
  grep -q '^verdict: RED' <<<"$out" \
    && no "mutant STILL surfaced RED (the RED row would not discriminate)" \
    || ok "mutant HIDES the RED (verdict≠RED) ⇒ the real RED row discriminates on overall_verdict"
fi

echo; echo "recoverability-drill.test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
