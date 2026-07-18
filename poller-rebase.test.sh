#!/usr/bin/env bash
# poller-rebase.test.sh — CAT-17 (audit 2026-07-18, rank #2): the poller OWNS the mechanical rebase of a
# GREEN+PASS PR that is merely BEHIND main, instead of parking it terminally (which strands the backlog
# O(N^2) as siblings merge). Drives the REAL sweep with a GREEN+PASS PR whose auto-merge returns rc 2
# (behind main) and a controllable `gh pr update-branch`: a CLEAN behind → the poller update-branches
# (PROGRESS: no rebase surface, NOT parked, the new head re-gates); a CONFLICT (update-branch fails) →
# surface [rebase] + park. MUTATION: force rebase_due to always GIVEUP → even a clean-behind PR gets no
# update-branch and parks (the old terminal behaviour) — proving the bounded auto-rebase is what makes
# progress. No real GitHub/network/model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# copy bin/ so the stub auto-merge.sh sits BESIDE the real siblings ($HERE/auto-merge.sh is what the
# poller calls); pr-poller.sh resolves $HERE to this copied dir.
TBIN="$ROOT/bin"; cp -r "$HERE/bin" "$TBIN"; POLLER="$TBIN/pr-poller.sh"
cat > "$TBIN/auto-merge.sh" <<'EOF'
#!/usr/bin/env bash
echo "[stub auto-merge] $*"; exit 2   # always: behind main / conflict (rc 2)
EOF
chmod +x "$TBIN/auto-merge.sh"

GHBIN="$ROOT/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;
      *"--state open"*)   printf '%s\t%s\t%s\t%s\n' 1 feat/x "$FAKE_SHA" live-validate;;
    esac ;;
  "pr view")
    case "$*" in
      *"--json comments"*) printf '**Host live-gate (Gate B): VERDICT GREEN** — fedora-dev @ %s\nFitness review: VERDICT PASS — head %s\n' "$FAKE_SHA" "$FAKE_SHA";;
      *"--json files"*)    printf 'bin/x.sh\n';;
    esac ;;
  "pr update-branch") printf 'UPDATEBRANCH %s\n' "$*" >> "$GH_LOG"; [ "${UPDATE_OK:-1}" = 1 ] && exit 0 || exit 1;;
  "pr comment")       printf 'SURFACE %s\n' "$*" >> "$GH_LOG";;
  *)                  printf 'GH %s\n' "$*" >> "$GH_LOG";;
esac
exit 0
EOF
chmod +x "$GHBIN/gh"

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
  GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"; STATE="$HOMEDIR/.local/state/pr-poller"
}
run(){ # <poller-script> [env…]
  local sc="$1"; shift
  env PATH="$GHBIN:$PATH" HOME="$HOMEDIR" GH_LOG="$GH_LOG" \
    POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=1 FLEET_HALT=true \
    FAKE_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$@" \
    bash "$sc" --once > "$ROOT/out.log" 2>&1
}
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       gh: %s\n' "$1" "$(tr '\n' '|' <"$GH_LOG")"; }
updated(){ grep -q 'UPDATEBRANCH' "$GH_LOG"; }
rebase_surfaced(){ grep -q 'SURFACE.*\[rebase\]' "$GH_LOG"; }
parked(){ ls "$STATE"/acted-1-*-GREEN.done >/dev/null 2>&1; }

echo "== CLEAN behind main → poller auto-rebases (update-branch), does NOT surface [rebase], does NOT park =="
setup; run "$POLLER" UPDATE_OK=1
{ updated && ! rebase_surfaced && ! parked; } && ok "clean-behind → update-branch, new head re-gates (not parked)" || no "clean-behind was not auto-rebased / was parked"

echo "== genuine CONFLICT (update-branch fails) → surface [rebase] + park =="
setup; run "$POLLER" UPDATE_OK=0
{ updated && rebase_surfaced && parked; } && ok "conflict → tried update-branch, then surfaced [rebase] + parked" || no "conflict was not surfaced/parked"

echo "== MUTATION: rebase_due always GIVEUP → even a clean-behind PR gets NO update-branch and parks (old terminal behaviour) =="
MUT="$TBIN/pr-poller-mut.sh"
sed 's/\[ "\$n" -lt "\$max" \] \&\& echo TRY || echo GIVEUP/echo GIVEUP/' "$POLLER" > "$MUT"
if grep -q 'echo TRY' "$MUT"; then no "mutation VACUOUS (echo TRY still present)"; else
  setup; run "$MUT" UPDATE_OK=1
  { ! updated && rebase_surfaced && parked; } && ok "mutation: no auto-rebase ⇒ clean-behind PR parks terminally (the bug the fix removes)" || no "mutant did not park a clean-behind PR without rebasing"
fi

echo; echo "poller-rebase: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
