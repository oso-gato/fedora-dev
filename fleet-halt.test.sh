#!/usr/bin/env bash
# fleet-halt.test.sh — MOCK dry-run of bin/fleet-halt.sh, the R9 fleet HALT reader (#151). Stubs `gh`
# on PATH (answering at gh's own `-q` OUTPUT level, like every other suite's stub) and drives the REAL
# checker through the states its contract promises, asserting BOTH channels callers rely on: the exit
# code (rc 0 = RUN is the ONLY "go"; 10 = HALT; 20 = PAUSE) and the first word of the stdout line.
#
# THE ROWS THAT BITE (the #151 acceptance set):
#   * a MAINTAINER-applied `halt` halts — and an APP-applied one is INERT: presence-only reading of the
#     label is exactly the self-halt/self-un-halt hole the requirements close (an App holds the
#     write/triage needed to add any label). The discriminator pair is maintainer-vs-App on the SAME
#     timeline shape.
#   * an App REMOVING a maintainer's `halt` does NOT un-halt (the fold decides by the newest MAINTAINER
#     event, never by presence) — the mirror hole, closed.
#   * ABSENT is a definite "no halt asserted" ⇒ RUN — a tidied-away control issue must never freeze the
#     fleet (#151's deployment-hazard note) — while an UNREADABLE signal PAUSES, and only K CONSECUTIVE
#     unreadable reads escalate to HALT (the deliberate, softened fail-closed inversion). A clean read
#     resets the escalation.
#   * a decoy issue matching the title cannot MASK a halted control (all matches are read, any HALT wins).
#
# Run:  bash fleet-halt.test.sh   → exit 0 = all rows pass.  No GitHub / network / model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$HERE/bin/fleet-halt.sh"
[ -f "$CHECKER" ] || { echo "FATAL: bin/fleet-halt.sh not found"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: the three reads the checker performs, each independently steerable ------------------
#   search/issues …            → $FAKE_SEARCH ("number\ttitle" rows) or fails with $FAKE_SEARCH_RC
#   …/issues/<n>/timeline …    → $FAKE_TL_DIR/<n> ("event\tactor" rows, oldest→newest) or $FAKE_TL_RC
#   …/collaborators/<a>/permission → $FAKE_ROLES/<a> (the role_name string) or fails with $FAKE_PERM_RC
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *search/issues*)
    [ "${FAKE_SEARCH_RC:-0}" = 0 ] || { echo "gh: search unavailable (test)" >&2; exit "$FAKE_SEARCH_RC"; }
    [ -n "${FAKE_SEARCH:-}" ] && printf '%s\n' "$FAKE_SEARCH"; exit 0;;
  */timeline*)
    [ "${FAKE_TL_RC:-0}" = 0 ] || { echo "gh: timeline unavailable (test)" >&2; exit "$FAKE_TL_RC"; }
    num="${args##*/issues/}"; num="${num%%/*}"
    [ -f "$FAKE_TL_DIR/$num" ] && cat "$FAKE_TL_DIR/$num"; exit 0;;
  */permission*)
    [ "${FAKE_PERM_RC:-0}" = 0 ] || { echo "gh: permission unavailable (test)" >&2; exit "$FAKE_PERM_RC"; }
    login="${args##*collaborators/}"; login="${login%/permission*}"
    [ -f "$FAKE_ROLES/$login" ] && cat "$FAKE_ROLES/$login"; exit 0;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

pass=0; fail=0; T=$'\t'
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
      else fail=$((fail+1)); printf '  FAIL %s\n       got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

# fresh — an isolated scenario: its own state dir (the PAUSE→HALT counter), bus stores, roles.
CN=0
fresh(){
  CN=$((CN+1)); CASE="$ROOT/case-$CN"; mkdir -p "$CASE/state" "$CASE/tl" "$CASE/roles"
  export HALT_STATE_DIR="$CASE/state" FAKE_TL_DIR="$CASE/tl" FAKE_ROLES="$CASE/roles"
  export FAKE_SEARCH="" FAKE_SEARCH_RC=0 FAKE_TL_RC=0 FAKE_PERM_RC=0
  printf 'admin'    > "$CASE/roles/arthur"
  printf 'maintain' > "$CASE/roles/co-maintainer"
  printf ''         > "$CASE/roles/nox[bot]"       # what the permission API really answers for an App bot
}
# check — run the REAL checker; capture rc, stdout token line, stderr detail.
check(){
  OUT="$(PATH="$BIN:$PATH" bash "$CHECKER" 2>"$CASE/err")"; RC=$?
  ERR="$(cat "$CASE/err")"
}
word1(){ printf '%s' "$OUT" | awk '{print $1}'; }
tl(){ printf '%s\n' "$2" > "$FAKE_TL_DIR/$1"; }      # <issue> <"event\tactor" rows, oldest→newest>
CONTROL="128${T}FLEET HALT CONTROL — apply the 'halt' label to freeze every sweeper (R9)"

echo "== ABSENT is a definite 'no halt asserted' → RUN (a tidied-away issue never freezes the fleet) =="
fresh; FAKE_SEARCH=""
check; ck "no control issue → RUN"      "$(word1)/$RC" "RUN/0"
fresh; FAKE_SEARCH="42${T}an unrelated issue that mentions FLEET elsewhere"
check; ck "no TITLE-PREFIX match → RUN (search word-matches; the prefix is the contract)" "$(word1)/$RC" "RUN/0"

echo "== control issue present, label never touched → RUN =="
fresh; FAKE_SEARCH="$CONTROL"
check; ck "empty halt timeline → RUN"   "$(word1)/$RC" "RUN/0"

echo "== a MAINTAINER-applied halt HALTS — and names its maintainer =="
fresh; FAKE_SEARCH="$CONTROL"; tl 128 "labeled${T}arthur"
check; ck "maintainer labeled → HALT rc 10" "$(word1)/$RC" "HALT/10"
ck "…naming the maintainer and the control issue" \
   "$(printf '%s' "$OUT" | grep -c 'by maintainer @arthur')" "1"

echo "== an APP-applied halt is INERT (self-halt closed) — and logged loudly =="
fresh; FAKE_SEARCH="$CONTROL"; tl 128 "labeled${T}nox[bot]"
check; ck "App labeled → RUN (presence proves nothing)" "$(word1)/$RC" "RUN/0"
ck "…and the INERT touch is logged loudly" "$(printf '%s' "$ERR" | grep -c 'INERT')" "1"

echo "== an App REMOVING a maintainer's halt does NOT un-halt (self-un-halt closed) =="
fresh; FAKE_SEARCH="$CONTROL"; tl 128 "labeled${T}arthur
unlabeled${T}nox[bot]"
check; ck "App unlabeled atop maintainer labeled → still HALT" "$(word1)/$RC" "HALT/10"

echo "== a MAINTAINER removing it DOES un-halt — within one read, no restart =="
fresh; FAKE_SEARCH="$CONTROL"; tl 128 "labeled${T}arthur
unlabeled${T}arthur"
check; ck "maintainer unlabeled → RUN" "$(word1)/$RC" "RUN/0"
tl 128 "labeled${T}arthur
unlabeled${T}arthur
labeled${T}co-maintainer"
check; ck "…and a maintain-role re-halt reads HALT again" "$(word1)/$RC" "HALT/10"

echo "== a decoy issue cannot MASK a halted control (all title matches are read; any HALT wins) =="
fresh; FAKE_SEARCH="900${T}FLEET HALT CONTROL (decoy)
${CONTROL}"
tl 128 "labeled${T}arthur"                            # decoy #900 has no events at all
check; ck "unlabelled decoy + halted control → HALT" "$(word1)/$RC" "HALT/10"

echo "== UNREADABLE signal: PAUSE, then only K CONSECUTIVE failures escalate to HALT =="
fresh; FAKE_SEARCH="$CONTROL"; export FAKE_SEARCH_RC=1
check; ck "1st failed read → PAUSE rc 20"  "$(word1)/$RC" "PAUSE/20"
check; ck "2nd failed read → PAUSE"        "$(word1)/$RC" "PAUSE/20"
check; ck "3rd consecutive → HALT (K=3 default)" "$(word1)/$RC" "HALT/10"
ck "…which says it is the unreadable-signal escalation, not a maintainer" \
   "$(printf '%s' "$OUT" | grep -c 'unreadable')" "1"
export FAKE_SEARCH_RC=0
check; ck "a clean read RESETS the escalation → RUN" "$(word1)/$RC" "RUN/0"
export FAKE_SEARCH_RC=1
check; ck "…so the next single blip is a PAUSE (1/3) again" "$(word1)/$RC" "PAUSE/20"

echo "== an unreadable TIMELINE pauses the same way (every structural read is gated) =="
fresh; FAKE_SEARCH="$CONTROL"; export FAKE_TL_RC=1
check; ck "timeline fetch failed → PAUSE" "$(word1)/$RC" "PAUSE/20"

echo "== an UNRESOLVABLE actor role pauses (bias toward stopping — it might be a maintainer) =="
fresh; FAKE_SEARCH="$CONTROL"; tl 128 "labeled${T}arthur"; export FAKE_PERM_RC=1
check; ck "role lookup failed on a halt event → PAUSE, never a silent RUN" "$(word1)/$RC" "PAUSE/20"
export FAKE_PERM_RC=0
check; ck "…and resolves to HALT the moment the role reads again" "$(word1)/$RC" "HALT/10"

echo "== fail-closed BY CONSTRUCTION: callers branching on rc treat a dead checker as 'no go' =="
"$ROOT/no-such-checker" >/dev/null 2>&1; rc=$?
ck "a missing checker exits non-zero (rc $rc), which every caller reads as 'take no action'" \
   "$([ "$rc" != 0 ] && echo 1 || echo 0)" "1"

echo
echo "fleet-halt-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
