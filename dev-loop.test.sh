#!/usr/bin/env bash
# dev-loop.test.sh — MOCK dry-run of bin/dev-loop.sh: stubs gh + dev-author on PATH and asserts the
# driver enumerates the backlog and invokes the author once per issue, continuing past a stuck one —
# plus the two invariants the cap must actually hold: an in-flight skip costs NO cap slot (so the tail
# of the backlog is never starved), and an issue that surfaced a question is PARKED, not re-asked.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOP="$HERE/bin/dev-loop.sh"
[ -f "$LOOP" ] || { echo "FATAL: bin/dev-loop.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: `issue list` serves the fake backlog as the driver's number<TAB>updatedAt TSV (updatedAt is
# the PARK CLOCK); `issue view --json updatedAt` serves the stamp written when an issue is parked.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue list")
    # Serve whichever shape the caller ASKED for — the driver's number<TAB>updatedAt TSV, or bare
    # numbers. A stub that only knew one shape would make an old/new comparison meaningless (the other
    # side would just see an empty backlog and "pass" by doing nothing).
    for n in ${FAKE_BACKLOG:-}; do
      case "$*" in
        *updatedAt*) printf '%s\t%s\n' "$n" "${FAKE_UPDATED:-2026-07-12T00:00:00Z}";;
        *)           printf '%s\n' "$n";;
      esac
    done ;;
  "issue view") printf '%s\n' "${FAKE_PARK_STAMP:-2026-07-12T00:00:01Z}";;
  *) : ;;
esac
exit 0
EOF
# dev-author stub — mirrors the REAL (rc, stdout) contract the driver classifies on:
#   FAKE_AUTHOR_SKIP list → guard no-op: rc 0, NOTHING on stdout (already authored / a PR is in flight)
#   FAKE_AUTHOR_FAIL      → rc 4: BLOCKED, a dev-task question was posted on the issue
#   otherwise             → AUTHORED: rc 0 + the PR URL on stdout (its only stdout emission)
cat > "$BIN/dev-author.sh" <<'EOF'
#!/usr/bin/env bash
printf 'AUTHOR %s %s\n' "$1" "$2" >> "$AUTHOR_LOG"
for s in ${FAKE_AUTHOR_SKIP:-}; do [ "$2" = "$s" ] && exit 0; done
[ "$2" = "${FAKE_AUTHOR_FAIL:-}" ] && exit 4
printf 'https://github.com/oso-gato/fedora-dev/pull/%s\n' "$((900 + $2))"
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
# fresh — a clean park-state dir + author log + default fakes for an INDEPENDENT scenario.
fresh(){
  export AUTHOR_LOG="$ROOT/author-$RANDOM.log"; : > "$AUTHOR_LOG"
  export DEV_LOOP_STATE="$ROOT/state-$RANDOM"; rm -rf "$DEV_LOOP_STATE"
  export FAKE_BACKLOG="" FAKE_AUTHOR_FAIL="" FAKE_AUTHOR_SKIP=""
  export FAKE_UPDATED="2026-07-12T00:00:00Z" FAKE_PARK_STAMP="2026-07-12T00:00:01Z"
  unset MAX_PER_PASS
}
# drive — run ONE pass and assert exactly which issues the author was INVOKED for. Successive drive()
# calls without fresh() are successive passes over the SAME park state (that is how parking is proven).
drive(){ # <desc> <expected-author-invocations, space-separated>
  local desc="$1" want="$2"
  : > "$AUTHOR_LOG"
  PATH="$BIN:$PATH" DEV_AUTHOR="$BIN/dev-author.sh" bash "$LOOP" fedora-dev >/dev/null 2>&1 || true
  local got; got="$(awk '{print $3}' "$AUTHOR_LOG" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL %s\n       author invoked for=[%s] want=[%s]\n' "$desc" "$got" "$want"; fi
}

echo "== one pass authors every backlog issue, in order =="
fresh; FAKE_BACKLOG=$'7\n3\n12'
drive "drains the backlog" "3 7 12"

echo "== a stuck (non-zero) author does NOT wedge the rest =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7
drive "continues past a BLOCKED issue" "3 7 12"

echo "== empty backlog → no author invocations =="
fresh
drive "empty backlog is a no-op" ""

echo "== MAX_PER_PASS caps the AUTHOR RUNS (defer, not drop) =="
fresh; FAKE_BACKLOG=$'1\n2\n3\n4'; export MAX_PER_PASS=2
drive "caps to MAX_PER_PASS" "1 2"

# --- STARVATION (the defect this closes): dev-author leaves an authored issue OPEN and still backlog-
# --- labelled while its PR is in flight, and no-ops on it. If the cap TRUNCATED the enumeration, those
# --- in-flight issues would eat the whole cap every pass and the TAIL would never be authored at all —
# --- permanent starvation, not deferral. The cap must count RUNS SPAWNED, so a skip costs no slot.
echo "== in-flight (already-authored) issues cost NO cap slot — the tail is reached, not starved =="
fresh; FAKE_BACKLOG=$'1\n2\n3\n4\n5\n6\n7\n8'; FAKE_AUTHOR_SKIP="1 2 3"; export MAX_PER_PASS=2
drive "skips don't burn the cap; 4+5 still authored" "1 2 3 4 5"
unset MAX_PER_PASS

# --- PARKING: a BLOCKED author posts a dev-task question on the issue. Re-running the author every pass
# --- would re-spend a bounded model run, re-ask the same question into noise, and (counting toward the
# --- cap) hold a slot forever. So the issue is parked at its post-question updatedAt and re-offered only
# --- once a human touches it LATER than that.
echo "== an issue that surfaced a question is PARKED, not re-asked next pass =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7
drive "pass 1: 7 goes BLOCKED → question + park" "3 7 12"
drive "pass 2: 7 is PARKED — not re-invoked" "3 12"

echo "== a human touching the issue AFTER the question UN-parks it (defers, never drops) =="
FAKE_UPDATED="2026-07-13T00:00:00Z"   # later than the park stamp = someone answered/refined the issue
drive "pass 3: 7 is re-offered" "3 7 12"

echo
echo "dev-loop-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
