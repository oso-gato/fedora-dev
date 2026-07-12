#!/usr/bin/env bash
# dev-plan.test.sh — MOCK dry-run of bin/dev-plan.sh: stubs gh + claude on PATH and asserts the
# confirmed-guard (R1), the file→backlog-issue creation, and the BLOCKED / unconfirmed / no-progress paths.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/bin/dev-plan.sh"
[ -f "$PLAN" ] || { echo "FATAL: bin/dev-plan.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# gh stub: serve the spec's title/body/labels, the issue TIMELINE (who applied the `approved` label), the
# collaborator-permission API + the COMMENT STREAM; log issue creates, label creates + comments; never
# touch GitHub. It MODELS THE BUS, because the planner now keeps NO local state and derives BOTH of its
# durable facts from that stream: (a) ALREADY-PLANNED — its own `planned:` summary anywhere in the thread,
# the tombstone that replaced the `.planned` file; (b) ALREADY-ASKED — its own question as the NEWEST
# comment. `issue comment` APPENDS to $BUS (login<TAB>line-1, as GitHub would) and the comments API reads
# it back, oldest→newest. That is what lets the wiped-box rows below mean anything.
# FAKE_CONFIRMED: 1 = maintainer line-1 token, 2 = NON-maintainer line-1 token, 3 = maintainer comment
# WITHOUT a line-1 token. FAKE_APPROVED_BY = who applied the label (default the maintainer).
# FAKE_CREATE_FAIL: 1 = the 2nd+ create fails (PARTIAL), all = EVERY create fails (TOTAL).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue view")
    case "$*" in
      *"-q .title"*) printf 'Ship a small thing';;
      *"-q .body"*)  printf 'The objective body.';;
      *"labels[].name"*) [ "${FAKE_APPROVED:-1}" = 1 ] && printf 'approved\n';;
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
    # Log every API call: it is the DISCRIMINATOR the tests assert on. A line-1 token from a
    # non-maintainer MUST trigger a role fetch and then be rejected; maintainer PROSE must never reach
    # the permission API at all (line 1 kills it first). Without this log a test cannot tell "read it and
    # rejected it" from "never read it" — and would pass vacuously.
    printf 'API %s\n' "$*" >> "$GH_LOG"
    case "$*" in
      # THE BUS, oldest→newest: any confirmation comment first, then everything the run has posted. This
      # ONE stream feeds the confirmation gate, the planned-tombstone read AND the ask-once read.
      *"/comments"*)
        case "${FAKE_CONFIRMED:-0}" in
          1) printf 'arthur\tCONFIRMED yes\n';;
          2) printf 'randomer\tCONFIRMED yes\n';;
          3) printf 'arthur\tlooks good so far\n';;
        esac
        [ -s "${BUS:-}" ] && cat "$BUS"; : ;;
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
# It logs to the SAME action log as gh: a bounded model run is the planner's most expensive outward act,
# and "did it re-spend one?" is exactly what the idempotency rows must be able to assert.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'CLAUDE plan=%s\n' "${FAKE_PLAN:-two}" >> "$GH_LOG"
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
run(){ # <desc> <envs> <expect: CREATE|RECOVER|TRUNC|DEFER|COMMENT-ONLY|NONE> <expected-create-count-or-"">
  local desc="$1" envs="$2" expect="$3" ncreate="${4:-}"
  export HOME="$ROOT/h-$RANDOM"; mkdir -p "$HOME"
  # The action log lives OUTSIDE $HOME — $HOME must end every run EMPTY (asserted below), so nothing the
  # harness itself writes may sit in it.
  export GH_LOG="$ROOT/act-$RANDOM.log"; : > "$GH_LOG"
  # The BUS (GitHub) is likewise OUTSIDE $HOME: every run() gets a WIPED box, so anything that survives
  # across runs survived on the bus alone — which is the whole point of the derivation.
  export BUS="${KEEP_BUS:+$BUS}"; [ -n "$BUS" ] || { export BUS="$ROOT/bus-$RANDOM"; : > "$BUS"; }
  # shellcheck disable=SC2086
  env $envs PATH="$BIN:$PATH" PLAN_CLAUDE="claude -p" bash "$PLAN" fedora-dev 500 >/dev/null 2>&1 || true
  # grep -c always prints a count (0 on no match) but EXITS 1 when zero — capture the number, ignore rc
  # (a `|| echo 0` here would append a second line and break the numeric compare).
  local ok=1 creates; creates="$(grep -c '^CREATE ' "$GH_LOG" 2>/dev/null)"; creates="${creates:-0}"
  case "$expect" in
    CREATE)      [ "$creates" -ge 1 ] || { ok=0; echo "  FAIL $desc: filed no backlog issues"; }
                 [ -n "$ncreate" ] && { [ "$creates" = "$ncreate" ] || { ok=0; echo "  FAIL $desc: filed $creates want $ncreate"; }; }
                 grep -q '^COMMENT.*planned:' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no plan-summary comment"; } ;;
    # RECOVER — a re-run whose features were ALL already filed (a recovery from an earlier defer). It files
    # nothing new, but the plan IS complete, so it must still post the `planned:` summary: that comment is
    # now the ONLY tombstone, and without it this spec would be re-planned forever.
    RECOVER)     [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: re-filed an already-filed feature"; }
                 grep -q '^COMMENT.*planned:' "$GH_LOG" || { ok=0; echo "  FAIL $desc: a COMPLETE plan left NO record on the bus — it will re-plan forever"; } ;;
    # TRUNC — the plan overflowed MAX_FEATURES. The cap must DEFER, not drop: file the first N, surface the
    # rest ON THE BUS, and leave the spec UNPLANNED (no summary) so a raised cap can still file them.
    TRUNC)       [ "$creates" = "$ncreate" ] || { ok=0; echo "  FAIL $desc: filed $creates want $ncreate"; }
                 grep -q '^COMMENT.*planned:' "$GH_LOG" && { ok=0; echo "  FAIL $desc: claimed 'planned' on a CAPPED (incomplete) plan — the surplus is lost forever"; } ;;
    # DEFER — a PARTIAL filing run: some issues were created, but the plan is INCOMPLETE, so it must NOT
    # claim success (no 'planned' summary), else the missing features are lost forever behind idempotency.
    DEFER)       [ "$creates" -ge 1 ] || { ok=0; echo "  FAIL $desc: expected a partial filing, got none"; }
                 grep -q '^COMMENT.*planned:' "$GH_LOG" && { ok=0; echo "  FAIL $desc: claimed 'planned' on an INCOMPLETE plan"; } ;;
    COMMENT-ONLY) [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues when it should have refused"; }
                 grep -q '^COMMENT' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no surfacing comment"; } ;;
    NONE)        [ "$creates" = 0 ] || { ok=0; echo "  FAIL $desc: created issues"; } ;;
  esac
  # NO LOCAL STATE — spec #135's design law, asserted on EVERY row, not just the wiped-box ones: the
  # planner must resume from GitHub alone, so it may leave NOTHING on disk. (This replaces the old
  # marker/nomarker assertions: the `.planned` tombstone now lives on the bus as the `planned:` comment,
  # and each expect-case above asserts its presence/absence there.)
  local leaked; leaked="$(find "$HOME" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')"
  [ -z "$leaked" ] || { ok=0; echo "  FAIL $desc: left LOCAL STATE behind ($leaked) — every fact must live on the bus"; }
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
run "plans a confirmed objective" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 2

# --- IDEMPOTENCY, DERIVED FROM THE BUS (spec #135: no local state anywhere; R14 E2E-KILL). The `.planned`
# --- file is GONE; the `planned:` summary the run above posted IS the tombstone. This row hands a FRESH,
# --- WIPED box the same bus and demands it recognise the spec as done. It cannot lean on the title dedup
# --- instead: that is an exact-title match against a NON-DETERMINISTIC model, so a re-plan that reworded
# --- half the features would file a near-duplicate backlog — and dev-loop would author each into its own
# --- PR. DISCRIMINATOR: against the pre-fix (marker-based) script this wiped box re-planned and filed 2.
echo "== a WIPED box does NOT re-plan a planned spec — the 'planned:' summary on the bus is the tombstone =="
KEEP_BUS=1 run "already-planned spec is a no-op on a fresh box" "FAKE_APPROVED=1 FAKE_PLAN=two" NONE
ck_log "  └─ and it filed no duplicate backlog issues" absent '^CREATE '
ck_log "  └─ and it posted nothing" absent '^COMMENT'
ck_log "  └─ and it did not re-spend a bounded model run" absent '^CLAUDE'

# MAX_FEATURES is DOCUMENTED as a cap, but a prompt line is a request, not a bound — the model can write
# any number of feat-*.md files. The HARNESS owns every write to GitHub, so it must own the cap. And a cap
# must DEFER, NOT DROP: $OUTDIR is a mktemp the EXIT trap deletes, so a feature merely skipped is DELETED
# WORK from a maintainer's confirmed objective. So the surplus must (a) reach the BUS by title and (b)
# leave the spec UNPLANNED, or the re-run remedy the log advertises is a no-op behind the tombstone.
echo "== MAX_FEATURES is a CAP THAT DEFERS — files N, surfaces the surplus, leaves the spec re-plannable =="
run "a 5-feature plan under MAX_FEATURES=3 files only 3" "FAKE_APPROVED=1 FAKE_PLAN=many MAX_FEATURES=3" TRUNC 3
ck_log "  └─ the 4th/5th are NOT filed" absent 'CREATE .*Feature 5'
# The row that used to sit here asserted ONLY the line above — that feature 5 was not filed — under the
# name "the DROP is logged, never silent". It never checked that anything, anywhere, recorded the drop.
# These three do: the surplus is surfaced ON THE BUS, BY TITLE, under its own anchor.
ck_log "  └─ …and the DROP is surfaced on the BUS as a question" present 'COMMENT.*exceeded MAX_FEATURES'
ck_log "  └─ …naming the dropped features, so \$OUTDIR's teardown loses nothing" present '^- Feature 5'
ck_log "  └─ …and it did not re-spend the model to say so" present '^CLAUDE'
# DISCRIMINATOR: the label was not merely SEEN — the gate resolved WHO applied it and role-checked him.
ck_log "  └─ and it resolved WHO applied the label (timeline)" present 'API .*issues/500/timeline'
ck_log "  └─ and it role-checked that applier" present 'API .*collaborators/arthur/permission'
# create-on-use: dev-plan is repo-agnostic, so it must not assume the label pre-exists in the repo.
ck_log "  └─ and it created the backlog label on use" present 'LABELCREATE'

# --- THE PROOF THE CAP DEFERRED RATHER THAN DROPPED: same bus, wiped box, cap raised → the spec is still
# --- plannable (no tombstone was written) and the two deferred features DO get filed. Against the pre-fix
# --- script this row is impossible: it wrote `.planned` on the truncated run, so the re-run exited 0 at
# --- the top and features 4 and 5 were gone for good.
echo "== raise the cap and re-run → the DEFERRED features are filed (a cap defers, it never drops) =="
KEEP_BUS=1 FAKE_EXISTING=$'Feature 1\nFeature 2\nFeature 3' \
  run "the deferred surplus is recoverable" "FAKE_APPROVED=1 FAKE_PLAN=many MAX_FEATURES=8" CREATE 2
ck_log "  └─ and it filed exactly the two that were deferred" present 'CREATE .*Feature 5'
ck_log "  └─ and did not re-file the three already on the backlog" absent 'CREATE .*Feature 1'

echo "== confirmed via MAINTAINER line-1 CONFIRMED comment (no label) also plans =="
run "maintainer CONFIRMED authorizes" "FAKE_APPROVED=0 FAKE_CONFIRMED=1 FAKE_PLAN=two" CREATE 2
ck_log "  └─ and it VERIFIED the author's role via the API" present 'API .*collaborators/arthur/permission'
echo "== UNCONFIRMED spec → refused, NO issues filed =="
run "refuses an unconfirmed spec" "FAKE_APPROVED=0 FAKE_CONFIRMED=0 FAKE_PLAN=two" COMMENT-ONLY

# --- R1 tamper-evidence: the confirmation is the loop's ONLY human anchor, so it must be bound to a
# --- MAINTAINER (author-bound) AND to line 1 (position-bound) — exactly the auto-merge G2 discipline.
# --- Before this, ANY commenter could authorize autonomous planning with a stray 'CONFIRMED'.
echo "== NON-maintainer posts a line-1 CONFIRMED → INERT (author-bound) =="
run "non-maintainer cannot confirm" "FAKE_APPROVED=0 FAKE_CONFIRMED=2 FAKE_PLAN=two" COMMENT-ONLY
# DISCRIMINATOR: it must have READ the token, LOOKED UP the author, and REJECTED him on role — not
# merely failed to see the comment (which is how the OLD forgeable code would also "pass" this).
ck_log "  └─ and it REJECTED him on role (not merely blind to the comment)" present 'API .*collaborators/randomer/permission'

echo "== maintainer comments prose (no line-1 token) → INERT (position-bound) =="
run "prose is not a confirmation" "FAKE_APPROVED=0 FAKE_CONFIRMED=3 FAKE_PLAN=two" COMMENT-ONLY
# DISCRIMINATOR: line 1 must kill it BEFORE any role lookup — a maintainer's prose never even reaches
# the permission API. This is what makes the token position-bound, not just author-bound.
ck_log "  └─ and line-1 killed it BEFORE any role lookup" absent 'API .*collaborators/'

# --- The LABEL path is the other half of the anchor. Applying a label needs only triage/write — which
# --- every fleet App identity holds (dev-author adds `live-validate`; dev-plan itself adds `backlog`) —
# --- so a PRESENCE-only check let the autonomous side self-authorize an unratified objective with one
# --- `gh issue edit --add-label approved`. The APPLIER must be maintainer-bound, exactly like the
# --- comment's author. This is the loop's only human anchor; it cannot rest on an unauthenticated label.
echo "== NON-maintainer applies the approved label → INERT (applier-bound) =="
run "a non-maintainer's label cannot confirm" "FAKE_APPROVED=1 FAKE_APPROVED_BY=randomer FAKE_CONFIRMED=0 FAKE_PLAN=two" COMMENT-ONLY
# DISCRIMINATOR: it must have RESOLVED the applier and REJECTED him on role — not merely failed to see
# the label (which is how a presence-only check would also "pass" this row).
ck_log "  └─ and it REJECTED the applier on role (not blind to the label)" present 'API .*collaborators/randomer/permission'

# --- Both-end rigor: a planner killed mid-write (timeout) leaves feature files but NO PLAN_DONE. Filing
# --- them would ship a silently TRUNCATED backlog behind a permanent tombstone.
echo "== planner died mid-plan (files, no PLAN_DONE) → files NOTHING, spec left unplanned =="
run "no sentinel → refuses partial plan" "FAKE_APPROVED=1 FAKE_PLAN=partial" COMMENT-ONLY

# --- Defers, never drops: if ANY create fails, the spec must stay UNPLANNED (no summary) so a re-run
# --- recovers the missing features (the title dedup below stops the successful ones being filed twice).
echo "== a create FAILS mid-run → DEFER: no 'planned' claim, spec left re-plannable =="
run "partial create defers" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=1" DEFER

echo "== re-run after a defer: already-filed features are DEDUPED, not duplicated =="
FAKE_EXISTING='Feature one' run "dedup skips already-filed" "FAKE_APPROVED=1 FAKE_PLAN=two" CREATE 1

# --- …and the recovery run where EVERYTHING was already filed must still leave the tombstone. It files no
# --- issue, so the old code just logged "already filed" and wrote the local marker — with that marker gone,
# --- a summary-less run here would be re-planned on every future pass, forever. The plan is COMPLETE, so
# --- it must SAY SO on the bus. DISCRIMINATOR: the pre-fix script posts no comment on this path at all.
echo "== an ALL-DEDUPED recovery run is a COMPLETE plan → it still records 'planned:' on the bus =="
FAKE_EXISTING=$'Feature one\nFeature two' run "a complete plan always leaves its tombstone" "FAKE_APPROVED=1 FAKE_PLAN=two" RECOVER
ck_log "  └─ and the summary says nothing new was filed" present 'COMMENT.*already filed'

# --- TOTAL create failure is NOT a transient blip: a repo with no `backlog` label or no issue-write fails
# --- EVERY create identically. Deferring that silently spins forever with nobody ever told — so it must
# --- surface a dev-task QUESTION (and still leave the spec unplanned, so a fixed repo re-plans).
echo "== EVERY create fails → surfaces a question (not a silent, endless defer) =="
run "total create failure asks a human" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" COMMENT-ONLY
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
KEEP_BUS=1 run "wiped box + question already on the bus → silent" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" NONE
ck_log "  └─ and it posted NO duplicate question" absent '^COMMENT'

# --- …but ask-once must not become ask-NEVER. Once anything lands after it (a maintainer's reply, or the
# --- `planned:` summary of a later run whose creates worked), the question is no longer the newest comment
# --- and a FRESH failure asks afresh — the same semantics the deleted marker had, with nothing on disk.
echo "== after a reply lands, a fresh total failure asks AGAIN (ask-once, not ask-never) =="
printf 'arthur\tfixed the label, try again\n' >> "$BUS"
KEEP_BUS=1 run "a reply un-mutes the question" "FAKE_APPROVED=1 FAKE_PLAN=two FAKE_CREATE_FAIL=all" COMMENT-ONLY

echo
echo "dev-plan-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
