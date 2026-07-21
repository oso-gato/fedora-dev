#!/usr/bin/env bash
# objective-status.test.sh — proves bin/objective-status.sh (the R30 ship oracle) LIVE PATH: drives the
# REAL script with a STUB gh (scenario files) + a real acceptance probe, asserting the STATUS verdict and
# the drive-action NEXT. The pure core (pr_drivable/classify/next_action) is covered by --selftest, run
# first here. Fail-closed to INDETERMINATE on any unreadable read is the safety the stop-gate relies on.
# A MUTATION runs in-suite (the live PR-counting). No network/model. `bash objective-status.test.sh` → 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/objective-status.sh"
[ -f "$SUT" ] || { echo "FATAL: bin/objective-status.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       got=<<%s>>\n' "$1" "${OUT:-}"; }

# ---- a scenario-driven gh stub on PATH ------------------------------------------------------------
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# scenario via files: $GH_OPEN_F (open backlog #s), $GH_ALL_F (all-state backlog #s), $GH_PRS_F (PR TSV).
# $GH_FAIL=open|pr forces that read to rc 1 (the fail-closed path).
args="$*"
case "$args" in
  *"issue list"*"--state open"*)
    [ "${GH_FAIL:-}" = open ] && exit 1
    [ -f "${GH_OPEN_F:-}" ] && cat "$GH_OPEN_F" || true ;;
  *"issue list"*"--state all"*)
    [ -f "${GH_ALL_F:-}" ] && cat "$GH_ALL_F" || true ;;
  *"pr list"*)
    [ "${GH_FAIL:-}" = pr ] && exit 1
    [ -f "${GH_PRS_F:-}" ] && cat "$GH_PRS_F" || true ;;
  *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# an empty scope-registry dir so a LEAKED session id (this suite runs inside a real session) resolves NO
# anchor — the oracle stays driven purely by the explicit repo arg / scenario files.
NOSCOPE="$ROOT/noscope"; mkdir -p "$NOSCOPE"
# scen <name> : make an empty scenario dir + files, echo the dir. Callers append to open/all/prs.
scen(){ local d; d="$(mktemp -d -p "$ROOT")"; : > "$d/open"; : > "$d/all"; : > "$d/prs"; printf '%s' "$d"; }
# run <scendir> [FAIL=..] : run the oracle for repo 'r' against a scenario; capture STATUS-block output.
# NOTE: the per-row overrides ride "$@" through `env`, NOT a shell assignment-prefix — "$@" is never an
# assignment-WORD at parse time, so as a shell prefix it becomes the command word (empty ⇒ works by luck,
# a value ⇒ bogus command). `env` re-detects name=value on its actual args, so both cases work.
run(){ local d="$1"; shift
  OUT="$(env PATH="$BIN:$PATH" GH_OPEN_F="$d/open" GH_ALL_F="$d/all" GH_PRS_F="$d/prs" \
         DEV_LOGIN=oso-gato-nox-claudebox SCOPE_REGISTRY_DIR="$NOSCOPE" "$@" bash "$SUT" --status r 2>/dev/null)"; }
status(){ printf '%s\n' "$OUT" | sed -n 's/^STATUS: *//p' | head -1; }
has(){ printf '%s\n' "$OUT" | grep -q "$1"; }

echo "== --selftest (pure core) =="
"$SUT" --selftest >/dev/null 2>&1 && ok "pure-core selftest passes" || no "pure-core selftest FAILED"

echo "== OPEN: a drivable dev PR → STATUS OPEN + drive action =="
d="$(scen)"; printf '%s\n' '41	oso-gato-nox-claudebox	live-validate' > "$d/prs"; printf '1\n' > "$d/all"
run "$d"; { [ "$(status)" = OPEN ] && has 'drive PR #41'; } && ok "drivable PR → OPEN w/ drive action" || no "drivable PR not OPEN"

echo "== OPEN: an open backlog issue → STATUS OPEN + author action =="
d="$(scen)"; printf '55\n' > "$d/open"; printf '55\n' > "$d/all"
run "$d"; { [ "$(status)" = OPEN ] && has 'author + ship backlog issue #55'; } && ok "open backlog → OPEN w/ author action" || no "open backlog not OPEN"

echo "== SHIPPED: no open work + backlog existed (proof evidence) → SHIPPED =="
d="$(scen)"; printf '9\n' > "$d/all"   # ever-backlog=1, none open, no PRs
run "$d"; [ "$(status)" = SHIPPED ] && ok "empty+evidence → SHIPPED" || no "empty+evidence not SHIPPED"

echo "== INDETERMINATE: no open work + NO evidence (never decomposed, no probe) → INDETERMINATE =="
d="$(scen)"   # all empty
run "$d"; [ "$(status)" = INDETERMINATE ] && ok "no evidence → INDETERMINATE (oracle cannot certify)" || no "no-evidence not INDETERMINATE"

echo "== INDETERMINATE (fail-closed): the backlog read fails → INDETERMINATE =="
d="$(scen)"; printf '41	oso-gato-nox-claudebox	\n' > "$d/prs"
run "$d" GH_FAIL=open; [ "$(status)" = INDETERMINATE ] && has 'fail-closed' && ok "unreadable backlog → INDETERMINATE" || no "fail-closed not INDETERMINATE"

echo "== INDETERMINATE (fail-closed): the PR read fails → INDETERMINATE =="
d="$(scen)"; printf '9\n' > "$d/all"
run "$d" GH_FAIL=pr; [ "$(status)" = INDETERMINATE ] && ok "unreadable PRs → INDETERMINATE" || no "PR fail-closed not INDETERMINATE"

echo "== escalated dev PR is NOT drivable → does not force OPEN (with evidence → SHIPPED) =="
d="$(scen)"; printf '%s\n' '41	oso-gato-nox-claudebox	live-validate,escalate' > "$d/prs"; printf '1\n' > "$d/all"
run "$d"; [ "$(status)" = SHIPPED ] && ok "escalated PR excluded from drivable" || no "escalated PR wrongly counted"

echo "== someone else's open PR is NOT mine → not drivable (with evidence → SHIPPED) =="
d="$(scen)"; printf '%s\n' '41	arthur	live-validate' > "$d/prs"; printf '1\n' > "$d/all"
run "$d"; [ "$(status)" = SHIPPED ] && ok "foreign PR excluded" || no "foreign PR wrongly counted"

echo "== app/-prefixed author is normalised to the dev login → drivable =="
d="$(scen)"; printf '%s\n' '41	app/oso-gato-nox-claudebox	live-validate' > "$d/prs"; printf '1\n' > "$d/all"
run "$d"; [ "$(status)" = OPEN ] && ok "app/ prefix normalised → OPEN" || no "app/ prefix not normalised"

echo "== PROBE FAIL: a declared failing probe + empty backlog → OPEN =="
d="$(scen)"; probe="$ROOT/p_fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$probe"; chmod +x "$probe"
run "$d" OBJECTIVE_ACCEPTANCE="$probe"; { [ "$(status)" = OPEN ] && has 'acceptance probe fails'; } && ok "failing probe → OPEN" || no "failing probe not OPEN"

echo "== PROBE PASS: a passing probe is the ship evidence (empty backlog, no ever) → SHIPPED =="
d="$(scen)"; probe="$ROOT/p_ok.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$probe"; chmod +x "$probe"
run "$d" OBJECTIVE_ACCEPTANCE="$probe"; [ "$(status)" = SHIPPED ] && ok "passing probe → SHIPPED" || no "passing probe not SHIPPED"

echo "== no repo resolvable → INDETERMINATE (the oracle cannot speak) =="
OUT="$(PATH="$BIN:$PATH" SCOPE_REGISTRY_DIR="$NOSCOPE" env -u OBJECTIVE_REPO -u OBJECTIVE_SID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash "$SUT" --status 2>/dev/null)"
[ "$(status)" = INDETERMINATE ] && has 'no bound objective' && ok "no anchor → INDETERMINATE" || no "no-anchor not INDETERMINATE"

echo "== MUTATION: neutralize the live drivable-PR count → a drivable PR reads SHIPPED (proves the count bites) =="
MUT="$ROOT/mut.sh"; sed 's/drivable=\$((drivable+1))/drivable=$((drivable+0))/' "$SUT" > "$MUT"; chmod +x "$MUT"
if ! cmp -s "$SUT" "$MUT"; then
  d="$(scen)"; printf '%s\n' '41	oso-gato-nox-claudebox	live-validate' > "$d/prs"; printf '1\n' > "$d/all"
  OUT="$(PATH="$BIN:$PATH" GH_OPEN_F="$d/open" GH_ALL_F="$d/all" GH_PRS_F="$d/prs" DEV_LOGIN=oso-gato-nox-claudebox bash "$MUT" --status r 2>/dev/null)"
  [ "$(status)" = SHIPPED ] && ok "mutant reads SHIPPED ⇒ the real PR-count is what yields OPEN" || no "PR-count mutation vacuous"
else no "PR-count mutation VACUOUS (sed changed nothing)"; fi

echo; echo "objective-status: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
