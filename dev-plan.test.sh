#!/usr/bin/env bash
# dev-plan.test.sh — MOCK dry-run of bin/dev-plan.sh: stubs gh + claude on PATH and asserts the
# confirmed-guard (R1), the file→backlog-issue creation, and the BLOCKED / unconfirmed / no-progress paths.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/bin/dev-plan.sh"
[ -f "$PLAN" ] || { echo "FATAL: bin/dev-plan.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: serve the spec's title/body/labels/comments (author-TSV) + the collaborator-permission API;
# log issue creates + comments; never touch GitHub. FAKE_CONFIRMED: 1 = maintainer line-1 token,
# 2 = NON-maintainer line-1 token, 3 = maintainer comment WITHOUT a line-1 token.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue view")
    case "$*" in
      *"-q .title"*) printf 'Ship a small thing';;
      *"-q .body"*)  printf 'The objective body.';;
      *"labels[].name"*) [ "${FAKE_APPROVED:-1}" = 1 ] && printf 'approved\n';;
      *"@tsv"*)
        case "${FAKE_CONFIRMED:-0}" in
          1) printf 'arthur\tCONFIRMED yes\n';;
          2) printf 'randomer\tCONFIRMED yes\n';;
          3) printf 'arthur\tlooks good so far\n';;
        esac ;;
      *) printf '{}';;
    esac ;;
  "issue list") printf '%s\n' "${FAKE_EXISTING:-}";;
  "issue create")
    if [ "${FAKE_CREATE_FAIL:-0}" = 1 ] && grep -q '^CREATE ' "$GH_LOG" 2>/dev/null; then
      printf 'CREATEFAIL %s\n' "$*" >> "$GH_LOG"; exit 1
    fi
    printf 'CREATE %s\n' "$*" >> "$GH_LOG"; printf 'https://github.com/oso-gato/fedora-dev/issues/900\n';;
  "issue comment") printf 'COMMENT %s\n' "$*" >> "$GH_LOG";;
  "api "*)
    # Log every permission lookup: it is the DISCRIMINATOR the tests assert on. A line-1 token from a
    # non-maintainer MUST trigger a role fetch and then be rejected; maintainer PROSE must never reach
    # the API at all (line 1 kills it first). Without this log a test cannot tell "read it and rejected
    # it" from "never read it" — and would pass vacuously.
    printf 'API %s\n' "$*" >> "$GH_LOG"
    case "$*" in
      *"/collaborators/arthur/permission"*) printf 'admin';;
      *"/collaborators/"*) printf 'read';;
    esac ;;
  *) : ;;
esac
exit 0
EOF
# claude stub: per FAKE_PLAN — write N feature files / block / no-op / die mid-plan (files, no sentinel).
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_PLAN:-two}" in
  two)     printf '# Feature one\nbody one\n' > feat-01.md
           printf '# Feature two\nbody two\n' > feat-02.md
           echo "PLAN_DONE: 2 features written";;
  blocked) echo "PLAN_BLOCKED: objective too vague";;
  noop)    echo "hmm, wrote nothing";;
  partial) printf '# Feature one\nbody one\n' > feat-01.md;;
esac
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
run(){ # <desc> <envs> <expect: CREATE|DEFER|COMMENT-ONLY|NONE> <expected-create-count-or-""> <marker|nomarker|"">
  local desc="$1" envs="$2" expect="$3" ncreate="${4:-}" wantmark="${5:-}"
  export HOME="$ROOT/h-$RANDOM"; mkdir -p "$HOME"; export GH_LOG="$HOME/gh.log"; : > "$GH_LOG"
  # shellcheck disable=SC2086
  env $envs PATH="$BIN:$PATH" PLAN_CLAUDE="claude -p" bash "$PLAN" fedora-dev 500 >/dev/null 2>&1 || true
  # grep -c always prints a count (0 on no match) but EXITS 1 when zero — capture the number, ignore rc
  # (a `|| echo 0` here would append a second line and break the numeric compare).
  local ok=1 creates; creates="$(grep -c '^CREATE ' "$GH_LOG" 2>/dev/null)"; creates="${creates:-0}"
  case "$expect" in
    CREATE)      [ "$creates" -ge 1 ] || { ok=0; echo "  FAIL $desc: filed no backlog issues"; }
                 [ -n "$ncreate" ] && { [ "$creates" = "$ncreate" ] || { ok=0; echo "  FAIL $desc: filed $creates want $ncreate"; }; }
                 grep -q '^COMMENT.*planned' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no plan-summary comment"; } ;;
    # DEFER — a PARTIAL filing run: some issues were created, but the plan is INCOMPLETE, so it must NOT
    # claim success (no 'planned' summary) and must NOT write the marker (else the missing features are
    # lost forever behind idempotency). "Defers, never drops."
    DEFER)       [ "$creates" -ge 1 ] || { ok=0; echo "  FAIL $desc: expected a partial filing, got none"; }
                 grep -q '^COMMENT.*planned' "$GH_LOG" && { ok=0; echo "  FAIL $desc: claimed 'planned' on an INCOMPLETE plan"; } ;;
    COMMENT-ONLY) [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues when it should have refused"; }
                 grep -q '^COMMENT' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no surfacing comment"; } ;;
    NONE)        [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues"; } ;;
  esac
  # The idempotency marker is the "this spec is DONE, never re-plan it" tombstone — assert it lands ONLY
  # on a complete plan. A marker written on a refused/partial run permanently strands the spec.
  local mark; mark="$(find "$HOME" -name '*.planned' -type f 2>/dev/null | head -1)"
  case "$wantmark" in
    marker)   [ -n "$mark" ] || { ok=0; echo "  FAIL $desc: complete plan did NOT write the marker"; } ;;
    nomarker) [ -z "$mark" ] || { ok=0; echo "  FAIL $desc: wrote the .planned marker on an INCOMPLETE/refused run"; } ;;
  esac
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
  LAST_LOG="$GH_LOG"
}

# Assert on the PREVIOUS run's gh log — used to prove the confirmation gate actually EVALUATED a comment
# (fetched the author's role) rather than silently never reading it.
ck_log(){ # <desc> <present|absent> <pattern>
  local desc="$1" want="$2" pat="$3"
  if grep -q -- "$pat" "$LAST_LOG" 2>/dev/null; then
    [ "$want" = present ] && { pass=$((pass+1)); printf '  ok   %s\n' "$desc"; return; }
    fail=$((fail+1)); echo "  FAIL $desc: '$pat' present but should be absent"
  else
    [ "$want" = absent ] && { pass=$((pass+1)); printf '  ok   %s\n' "$desc"; return; }
    fail=$((fail+1)); echo "  FAIL $desc: '$pat' NOT found — the gate never evaluated the comment"
  fi
}

echo "== confirmed (approved label) + planner writes 2 → 2 backlog issues + summary =="
run "plans a confirmed objective" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 2 marker
echo "== confirmed via MAINTAINER line-1 CONFIRMED comment (no label) also plans =="
run "maintainer CONFIRMED authorizes" "FAKE_APPROVED=0 FAKE_CONFIRMED=1 FAKE_PLAN=two" CREATE 2 marker
ck_log "  └─ and it VERIFIED the author's role via the API" present 'API .*collaborators/arthur/permission'
echo "== UNCONFIRMED spec → refused, NO issues filed =="
run "refuses an unconfirmed spec" "FAKE_APPROVED=0 FAKE_CONFIRMED=0 FAKE_PLAN=two" COMMENT-ONLY "" nomarker

# --- R1 tamper-evidence: the confirmation is the loop's ONLY human anchor, so it must be bound to a
# --- MAINTAINER (author-bound) AND to line 1 (position-bound) — exactly the auto-merge G2 discipline.
# --- Before this, ANY commenter could authorize autonomous planning with a stray 'CONFIRMED'.
echo "== NON-maintainer posts a line-1 CONFIRMED → INERT (author-bound) =="
run "non-maintainer cannot confirm" "FAKE_APPROVED=0 FAKE_CONFIRMED=2 FAKE_PLAN=two" COMMENT-ONLY "" nomarker
# DISCRIMINATOR: it must have READ the token, LOOKED UP the author, and REJECTED him on role — not
# merely failed to see the comment (which is how the OLD forgeable code would also "pass" this).
ck_log "  └─ and it REJECTED him on role (not merely blind to the comment)" present 'API .*collaborators/randomer/permission'

echo "== maintainer comments prose (no line-1 token) → INERT (position-bound) =="
run "prose is not a confirmation" "FAKE_APPROVED=0 FAKE_CONFIRMED=3 FAKE_PLAN=two" COMMENT-ONLY "" nomarker
# DISCRIMINATOR: line 1 must kill it BEFORE any role lookup — a maintainer's prose never even reaches
# the permission API. This is what makes the token position-bound, not just author-bound.
ck_log "  └─ and line-1 killed it BEFORE any role lookup" absent 'API .*collaborators/'

# --- Both-end rigor: a planner killed mid-write (timeout) leaves feature files but NO PLAN_DONE. Filing
# --- them would ship a silently TRUNCATED backlog behind a permanent marker.
echo "== planner died mid-plan (files, no PLAN_DONE) → files NOTHING, no marker =="
run "no sentinel → refuses partial plan" "FAKE_APPROVED=1 FAKE_PLAN=partial" COMMENT-ONLY "" nomarker

# --- Defers, never drops: if ANY create fails, the marker must stay unwritten so a re-run recovers the
# --- missing features (the title dedup below stops the successful ones from being filed twice).
echo "== a create FAILS mid-run → DEFER: no 'planned' claim, marker unwritten =="
run "partial create defers" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=1" DEFER "" nomarker

echo "== re-run after a defer: already-filed features are DEDUPED, not duplicated =="
FAKE_EXISTING='Feature one' run "dedup skips already-filed" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 1 marker

echo
echo "dev-plan-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
