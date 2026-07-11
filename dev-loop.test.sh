#!/usr/bin/env bash
# dev-loop.test.sh — MOCK dry-run of bin/dev-loop.sh: stubs gh + dev-author on PATH and asserts the
# driver enumerates the backlog and invokes the author once per issue, continuing past a stuck one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOP="$HERE/bin/dev-loop.sh"
[ -f "$LOOP" ] || { echo "FATAL: bin/dev-loop.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: `issue list` returns the fake backlog numbers; log nothing else needed.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue list") printf '%s\n' ${FAKE_BACKLOG:-};;
  *) : ;;
esac
exit 0
EOF
# dev-author stub: record each (repo,issue) it is invoked with; fail for the issue in FAKE_AUTHOR_FAIL.
cat > "$BIN/dev-author.sh" <<'EOF'
#!/usr/bin/env bash
printf 'AUTHOR %s %s\n' "$1" "$2" >> "$AUTHOR_LOG"
[ "$2" = "${FAKE_AUTHOR_FAIL:-}" ] && exit 4 || exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
run(){ # <desc> <FAKE_BACKLOG> <FAKE_AUTHOR_FAIL> <expected-authored-issues-space-list>
  local desc="$1" backlog="$2" failissue="$3" want="$4"
  export AUTHOR_LOG="$ROOT/author-$RANDOM.log"; : > "$AUTHOR_LOG"
  FAKE_BACKLOG="$backlog" FAKE_AUTHOR_FAIL="$failissue" \
    PATH="$BIN:$PATH" DEV_AUTHOR="$BIN/dev-author.sh" bash "$LOOP" fedora-dev >/dev/null 2>&1 || true
  local got; got="$(awk '{print $3}' "$AUTHOR_LOG" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL %s\n       author invoked for=[%s] want=[%s]\n' "$desc" "$got" "$want"; fi
}

echo "== one pass authors every backlog issue, in order =="
run "drains the backlog" $'7\n3\n12' "" "3 7 12"
echo "== a stuck (non-zero) author does NOT wedge the rest =="
run "continues past a BLOCKED issue" $'3\n7\n12' "7" "3 7 12"
echo "== empty backlog → no author invocations =="
run "empty backlog is a no-op" "" "" ""
echo "== MAX_PER_PASS caps the pass (defer, not drop) =="
export MAX_PER_PASS=2
run "caps to MAX_PER_PASS" $'1\n2\n3\n4' "" "1 2"
unset MAX_PER_PASS

echo
echo "dev-loop-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
