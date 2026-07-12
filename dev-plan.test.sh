#!/usr/bin/env bash
# dev-plan.test.sh — MOCK dry-run of bin/dev-plan.sh: stubs gh + claude on PATH and asserts the
# confirmed-guard (R1), the file→backlog-issue creation, and the BLOCKED / unconfirmed / no-progress paths.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/bin/dev-plan.sh"
[ -f "$PLAN" ] || { echo "FATAL: bin/dev-plan.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: serve the spec's title/body/labels/comments (author-TSV), the issue TIMELINE (who applied the
# `approved` label) + the collaborator-permission API; log issue creates, label creates + comments; never
# touch GitHub. It also models the spec issue's COMMENT STREAM — the BUS — because the create-failure
# ask-once gate is DERIVED from it (no local marker): `issue comment` APPENDS to $BUS, and the newest-
# comment query reads it back. That is what lets the wiped-box row below mean anything. FAKE_CONFIRMED: 1 = maintainer line-1 token, 2 = NON-maintainer line-1 token, 3 =
# maintainer comment WITHOUT a line-1 token. FAKE_APPROVED_BY = who applied the label (default the
# maintainer). FAKE_CREATE_FAIL: 1 = the 2nd+ create fails (PARTIAL), all = EVERY create fails (TOTAL).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue view")
    case "$*" in
      *"-q .title"*) printf 'Ship a small thing';;
      *"-q .body"*)  printf 'The objective body.';;
      *"labels[].name"*) [ "${FAKE_APPROVED:-1}" = 1 ] && printf 'approved\n';;
      # the ask-once gate's newest-comment read: login<TAB>line-1 of the LAST comment on the bus (the
      # confirm-gate query below has no 'last' in it, so the two never collide).
      *last*) [ -s "${BUS:-}" ] && tail -1 "$BUS";;
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
    # TOTAL failure (all) models the repo-agnostic hazard: a repo with no `backlog` label / no issue-write
    # fails EVERY create identically. PARTIAL (1) fails only the 2nd+ — a transient blip.
    if [ "${FAKE_CREATE_FAIL:-0}" = all ]; then printf 'CREATEFAIL %s\n' "$*" >> "$GH_LOG"; exit 1; fi
    if [ "${FAKE_CREATE_FAIL:-0}" = 1 ] && grep -q '^CREATE ' "$GH_LOG" 2>/dev/null; then
      printf 'CREATEFAIL %s\n' "$*" >> "$GH_LOG"; exit 1
    fi
    printf 'CREATE %s\n' "$*" >> "$GH_LOG"; printf 'https://github.com/oso-gato/fedora-dev/issues/900\n';;
  "issue comment")
    printf 'COMMENT %s\n' "$*" >> "$GH_LOG"
    # the comment LANDS ON THE BUS, as a real one would — line 1, under this box's App identity
    printf '%s\t%s\n' "${DEV_LOGIN:-oso-gato-nox-claudebox}" "$(printf '%s' "$*" | sed -n 's/.*--body \(.*\)/\1/p' | head -1)" >> "${BUS:-/dev/null}" ;;
  "label create") printf 'LABELCREATE %s\n' "$*" >> "$GH_LOG";;
  "api "*)
    # Log every permission lookup: it is the DISCRIMINATOR the tests assert on. A line-1 token from a
    # non-maintainer MUST trigger a role fetch and then be rejected; maintainer PROSE must never reach
    # the API at all (line 1 kills it first). Without this log a test cannot tell "read it and rejected
    # it" from "never read it" — and would pass vacuously.
    printf 'API %s\n' "$*" >> "$GH_LOG"
    case "$*" in
      # WHO applied the `approved` label — the `labeled` timeline event the label gate now binds to a
      # maintainer role. Presence of the label alone must authorize NOTHING.
      *"/timeline"*) printf '%s\n' "${FAKE_APPROVED_BY:-arthur}";;
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
  many)    for i in 1 2 3 4 5; do printf '# Feature %s\nbody %s\n' "$i" "$i" > "feat-0$i.md"; done
           echo "PLAN_DONE: 5 features written";;
esac
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
run(){ # <desc> <envs> <expect: CREATE|DEFER|COMMENT-ONLY|NONE> <expected-create-count-or-""> <marker|nomarker|"">
  local desc="$1" envs="$2" expect="$3" ncreate="${4:-}" wantmark="${5:-}"
  export HOME="$ROOT/h-$RANDOM"; mkdir -p "$HOME"; export GH_LOG="$HOME/gh.log"; : > "$GH_LOG"
  # The BUS (GitHub) is deliberately OUTSIDE $HOME: every run() gets a WIPED box, so anything that
  # survives across runs survived on the bus alone — which is the whole point of the derivation.
  export BUS="${KEEP_BUS:+$BUS}"; [ -n "$BUS" ] || { export BUS="$ROOT/bus-$RANDOM"; : > "$BUS"; }
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

echo "== confirmed (MAINTAINER-applied approved label) + planner writes 2 → 2 backlog issues + summary =="
run "plans a confirmed objective" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 2 marker

# MAX_FEATURES is DOCUMENTED as a cap, but a prompt line is a request, not a bound — the model can write
# any number of feat-*.md files. The HARNESS owns every write to GitHub, so it must own the cap. Without
# enforcement this row files 5 (DISCRIMINATOR: fails against the pre-fix script, which filed all 5).
echo "== MAX_FEATURES is a CAP the harness enforces, not advice in the prompt =="
run "a 5-feature plan under MAX_FEATURES=3 files only 3" "FAKE_APPROVED=1 FAKE_PLAN=many MAX_FEATURES=3" CREATE 3 marker
ck_log "  └─ and the DROP is logged, never silent" absent 'CREATE .*Feature 5'
# DISCRIMINATOR: the label was not merely SEEN — the gate resolved WHO applied it and role-checked him.
ck_log "  └─ and it resolved WHO applied the label (timeline)" present 'API .*issues/500/timeline'
ck_log "  └─ and it role-checked that applier" present 'API .*collaborators/arthur/permission'
# create-on-use: dev-plan is repo-agnostic, so it must not assume the label pre-exists in the repo.
ck_log "  └─ and it created the backlog label on use" present 'LABELCREATE'
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

# --- The LABEL path is the other half of the anchor. Applying a label needs only triage/write — which
# --- every fleet App identity holds (dev-author adds `live-validate`; dev-plan itself adds `backlog`) —
# --- so a PRESENCE-only check let the autonomous side self-authorize an unratified objective with one
# --- `gh issue edit --add-label approved`. The APPLIER must be maintainer-bound, exactly like the
# --- comment's author. This is the loop's only human anchor; it cannot rest on an unauthenticated label.
echo "== NON-maintainer applies the approved label → INERT (applier-bound) =="
run "a non-maintainer's label cannot confirm" "FAKE_APPROVED=1 FAKE_APPROVED_BY=randomer FAKE_CONFIRMED=0 FAKE_PLAN=two" COMMENT-ONLY "" nomarker
# DISCRIMINATOR: it must have RESOLVED the applier and REJECTED him on role — not merely failed to see
# the label (which is how a presence-only check would also "pass" this row).
ck_log "  └─ and it REJECTED the applier on role (not blind to the label)" present 'API .*collaborators/randomer/permission'

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

# --- TOTAL create failure is NOT a transient blip: a repo with no `backlog` label or no issue-write fails
# --- EVERY create identically. Deferring that silently spins forever with nobody ever told — so it must
# --- surface a dev-task QUESTION (and still never write the .planned marker, so a fixed repo re-plans).
echo "== EVERY create fails → surfaces a question (not a silent, endless defer) =="
run "total create failure asks a human" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" COMMENT-ONLY "" nomarker
ck_log "  └─ and the comment is a BLOCKED dev-task question" present 'COMMENT.*BLOCKED'
# The create-failure question carries its OWN line-1 anchor. The other dev-plan questions (planner-blocked,
# no-sentinel, no-features) share the generic prefix and are posted on paths that exit BEFORE the create
# step — so a generic anchor would let a STALE one of those mute this one, the run's only way to tell a
# human that NOTHING can be filed at all.
ck_log "  └─ under its own distinct anchor (not the generic BLOCKED prefix)" present 'COMMENT.*issue-create failed'

# --- ASK-ONCE, DERIVED FROM THE BUS (spec #135: no local state anywhere; R14 E2E-KILL: resume from the bus
# --- alone). A timer must not re-ask the identical question every pass — but the record of "we asked" is
# --- the QUESTION ITSELF, sitting on the spec issue, not a marker file. run() hands every row a WIPED HOME,
# --- so this row IS the E2E-KILL case: a fresh box, the same bus, and it must stay quiet.
echo "== the same failure on a WIPED box does NOT re-ask — the question on the bus is the record =="
KEEP_BUS=1 run "wiped box + question already on the bus → silent" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" NONE "" nomarker
ck_log "  └─ and it posted NO duplicate question" absent '^COMMENT'

# --- …but ask-once must not become ask-NEVER. Once anything lands after it (a maintainer's reply, or the
# --- `planned:` summary of a later run whose creates worked), the question is no longer the newest comment
# --- and a FRESH failure asks afresh — the same semantics the deleted marker had, with nothing on disk.
echo "== after a reply lands, a fresh total failure asks AGAIN (ask-once, not ask-never) =="
printf 'arthur\tfixed the label, try again\n' >> "$BUS"
KEEP_BUS=1 run "a reply un-mutes the question" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" COMMENT-ONLY "" nomarker

echo
echo "dev-plan-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
