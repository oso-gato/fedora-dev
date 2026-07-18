#!/usr/bin/env bash
# poller-stall.test.sh — R18 IDLE-WITH-WORK-PENDING (audit 2026-07-18 CAT-42/01; the kd#23 six-hour
# silent stall). Drives the REAL `pr-poller.sh --once` against a stub gh serving ONE live-validate-
# labelled open PR with NO host verdict (host=NONE) and a CONTROLLABLE head-commit age, and asserts the
# poller SURFACES a 'stalled' comment once the head has sat past POLLER_STALL_MAX — instead of NOOPing
# forever — while staying quiet when the head is fresh or unlabelled. MUTATION: neutralize stall_verdict
# to never return STALL and the aged head must surface NOTHING (proving the WORK-age clock is what bites,
# not the surface plumbing). No real GitHub/network/model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; POLLER="$HERE/bin/pr-poller.sh"
[ -f "$POLLER" ] || { echo "FATAL: $POLLER not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# stub gh: one open PR (labelled), host=NONE (no verdict comments), controllable commit date.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;                                                    # retire pass: nothing merged
      *"--state open"*)   printf '%s\t%s\t%s\t%s\n' 1 feat/x "$FAKE_SHA" "${FAKE_LABELS:-live-validate}";;
    esac ;;
  "pr view") : ;;                                                                 # NO host/fitness verdict → host=NONE
  "api "*)   case "$*" in *"/commits/"*) printf '%s\n' "$FAKE_COMMIT_DATE";; esac ;;
  "pr comment") printf 'SURFACE %s\n' "$*" >> "$GH_LOG";;
  "issue create") printf 'ISSUE %s\n' "$*" >> "$GH_LOG";;
  *) printf 'GH %s\n' "$*" >> "$GH_LOG";;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# minimal live clone the sweep's self-refresh / scope reads (fresh HOME each run)
setup(){
  HOMEDIR="$ROOT/home"; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR/.local/share"
  local o="$ROOT/origin.git" s="$ROOT/seed"; rm -rf "$o" "$s"
  git init -q --bare -b main "$o"; git init -q -b main "$s"
  git -C "$s" config user.email t@t; git -C "$s" config user.name t
  echo base > "$s/f"; git -C "$s" add -A; git -C "$s" commit -qm base
  git -C "$s" remote add origin "$o"; git -C "$s" push -q origin main
  git clone -q "$o" "$HOMEDIR/.local/share/fedora-dev"
  git -C "$HOMEDIR/.local/share/fedora-dev" config user.email c@c
  git -C "$HOMEDIR/.local/share/fedora-dev" config user.name c
  GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"
}
run(){ # <script> <commit-date> [env…]
  local script="$1" cd="$2"; shift 2
  env PATH="$BIN:$PATH" HOME="$HOMEDIR" GH_LOG="$GH_LOG" \
    POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FLEET_HALT=true \
    FAKE_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef FAKE_COMMIT_DATE="$cd" "$@" \
    bash "$script" --once > "$ROOT/out.log" 2>&1
}
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       gh: %s\n' "$1" "$(tr '\n' '|' <"$GH_LOG")"; }
surfaced(){ grep -q 'SURFACE.*\[stalled\]' "$GH_LOG"; }

OLD="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== STALL: a live-validate head at host=NONE for 3h → surfaces [stalled] =="
setup; run "$POLLER" "$OLD"
surfaced && ok "aged labelled host=NONE → surfaced [stalled] (was NOOP-forever)" || no "aged labelled host=NONE did NOT surface"

echo "== FRESH: same PR, head just pushed (< bound) → quiet NOOP =="
setup; run "$POLLER" "$NOW"
surfaced && no "a fresh head wrongly surfaced" || ok "fresh labelled host=NONE → quiet NOOP"

echo "== UNLABELLED: aged host=NONE but no live-validate label → quiet NOOP (no gate expected) =="
setup; run "$POLLER" "$OLD" FAKE_LABELS="some-other-label"
surfaced && no "an unlabelled aged head wrongly surfaced" || ok "unlabelled host=NONE → quiet NOOP"

echo "== MUTATION: neutralize stall_verdict (never STALL) → aged head surfaces NOTHING =="
MUT="$ROOT/pr-poller-mut.sh"
sed 's/then echo STALL; else/then echo OK; else/' "$POLLER" > "$MUT"
if grep -q 'echo STALL' "$MUT"; then no "mutation VACUOUS (echo STALL still present)"; else
  setup; run "$MUT" "$OLD"
  surfaced && no "mutant STILL surfaced — stall_verdict is not what bites" || ok "mutation: without the STALL clock, the aged head surfaces nothing (the clock bites)"
fi

echo; echo "poller-stall: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
