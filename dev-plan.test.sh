#!/usr/bin/env bash
# dev-plan.test.sh — MOCK dry-run of bin/dev-plan.sh: stubs gh + claude on PATH and asserts the
# confirmed-guard (R1), the file→backlog-issue creation, and the BLOCKED / unconfirmed / no-progress paths.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/bin/dev-plan.sh"
[ -f "$PLAN" ] || { echo "FATAL: bin/dev-plan.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: serve the spec's title/body/labels/comments; log issue creates + comments; never touch GitHub.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue view")
    case "$*" in
      *"-q .title"*) printf 'Ship a small thing';;
      *"-q .body"*)  printf 'The objective body.';;
      *"labels[].name"*) [ "${FAKE_APPROVED:-1}" = 1 ] && printf 'approved\n';;
      *"comments[].body"*) [ "${FAKE_CONFIRMED:-0}" = 1 ] && printf 'CONFIRMED yes\n';;
      *) printf '{}';;
    esac ;;
  "issue create") printf 'CREATE %s\n' "$*" >> "$GH_LOG"; printf 'https://github.com/oso-gato/fedora-dev/issues/900\n';;
  "issue comment") printf 'COMMENT %s\n' "$*" >> "$GH_LOG";;
  *) : ;;
esac
exit 0
EOF
# claude stub: per FAKE_PLAN — write N feature files / block / no-op.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_PLAN:-two}" in
  two)     printf '# Feature one\nbody one\n' > feat-01.md
           printf '# Feature two\nbody two\n' > feat-02.md
           echo "PLAN_DONE: 2 features written";;
  blocked) echo "PLAN_BLOCKED: objective too vague";;
  noop)    echo "hmm, wrote nothing";;
esac
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
run(){ # <desc> <envs> <expect: CREATE|COMMENT-ONLY|NONE> <expected-create-count-or-"">
  local desc="$1" envs="$2" expect="$3" ncreate="${4:-}"
  export HOME="$ROOT/h-$RANDOM"; mkdir -p "$HOME"; export GH_LOG="$HOME/gh.log"; : > "$GH_LOG"
  # shellcheck disable=SC2086
  env $envs PATH="$BIN:$PATH" PLAN_CLAUDE="claude -p" bash "$PLAN" fedora-dev 500 >/dev/null 2>&1 || true
  # grep -c always prints a count (0 on no match) but EXITS 1 when zero — capture the number, ignore rc
  # (a `|| echo 0` here would append a second line and break the numeric compare).
  local ok=1 creates; creates="$(grep -c '^CREATE' "$GH_LOG" 2>/dev/null)"; creates="${creates:-0}"
  case "$expect" in
    CREATE)      [ "$creates" -ge 1 ] || { ok=0; echo "  FAIL $desc: filed no backlog issues"; }
                 [ -n "$ncreate" ] && { [ "$creates" = "$ncreate" ] || { ok=0; echo "  FAIL $desc: filed $creates want $ncreate"; }; }
                 grep -q '^COMMENT.*planned' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no plan-summary comment"; } ;;
    COMMENT-ONLY) [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues when it should have blocked"; }
                 grep -q '^COMMENT' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no surfacing comment"; } ;;
    NONE)        [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues"; } ;;
  esac
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
}

echo "== confirmed (approved label) + planner writes 2 → 2 backlog issues + summary =="
run "plans a confirmed objective" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 2
echo "== confirmed via CONFIRMED comment (no label) also plans =="
run "CONFIRMED comment authorizes" "FAKE_APPROVED=0 FAKE_CONFIRMED=1 FAKE_PLAN=two" CREATE 2
echo "== UNCONFIRMED spec → refused, NO issues filed =="
run "refuses an unconfirmed spec" "FAKE_APPROVED=0 FAKE_CONFIRMED=0 FAKE_PLAN=two" COMMENT-ONLY
echo "== planner BLOCKED → surfaced, NO issues filed =="
run "planner block surfaces" "FAKE_APPROVED=1 FAKE_PLAN=blocked" COMMENT-ONLY
echo "== planner wrote nothing → no-progress surfaced, NO issues filed =="
run "no features → surfaced" "FAKE_APPROVED=1 FAKE_PLAN=noop" COMMENT-ONLY

echo
echo "dev-plan-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
