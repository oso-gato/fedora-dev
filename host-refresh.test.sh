#!/usr/bin/env bash
# host-refresh.test.sh — the HOST-HALF SELF-REFRESH suite (#163): a merged image/bootstrap change
# reaches the RUNNING host promptly + autonomously, with ZERO GitHub / network / model.
#
# WHY THIS EXISTS: the seam (host-ticket.sh → host-agent-watch.sh `redeploy` → container-refresh's
# health-gate + digest rollback) was proven live, but NOTHING fired it on a merge — a merged
# Containerfile/install/entrypoint change reached erebus only on the MONTHLY workload-refresh timer or
# a human runbook. This proves the trigger: bin/host-refresh.sh files exactly ONE `redeploy <workload>`
# ticket per image-baked merge (only AFTER CI actually published the image), and — for a CONTROL-repo
# merge touching host-executed paths — exactly ONE `apply-bootstrap` ticket (#133/#187: the bounded
# verb has landed; the arm that once only surfaced a question now files it).
#
# HOW IT BITES — only `gh` is stubbed (answering at gh's own -q output level, per-case fixture files);
# the ticket producer is the REAL bin/host-ticket.sh (so the recorded ticket pins the consumer's
# `host-op:` line-1 grammar), and the poller rows drive the REAL bin/pr-poller.sh --once. The issue's
# two named mutations are RESTORED MECHANICALLY AND RUN IN-SUITE (the fitness-review.test.sh
# discipline — the sed must genuinely change the copy, else the row fails as vacuous):
#   * "file a redeploy on EVERY merge" (classifier neutralized) → the live-clone-only row's fixture
#     must then file a ticket the real script refused — proving that row discriminates.
#   * "file BEFORE publish" (publish gate forced PUBLISHED) → the pending-CI fixture must then file
#     a stale-digest ticket the real script refused — proving the publish-gate row discriminates.
#
# Run:  bash host-refresh.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/host-refresh.sh"
HTICKET="$HERE/bin/host-ticket.sh"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$SCRIPT" ]  || { echo "FATAL: bin/host-refresh.sh not found"; exit 2; }
[ -f "$HTICKET" ] || { echo "FATAL: bin/host-ticket.sh not found"; exit 2; }
[ -f "$POLLER" ]  || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"      # the merge commit under test (40-hex, G2 discipline)
FRESH="$(date -u +%FT%TZ)"                          # a merge inside the catch-up window

# ---- stub gh: scenario-driven via per-case fixture files; answers at gh's own -q output level. ------
#   merged-<repo>.tsv        → pr list  (number \t merge-oid \t mergedAt — what the real -q emits)
#   files-<repo>-<pr>.txt    → pr view --json files    (one path per line)
#   comments-<repo>-<pr>.txt → pr view --json comments (comment bodies)
#   run-<oid>.tsv            → run list --commit       (status \t conclusion — absent = no run yet)
# Records: tickets.log + ticket-bodies.txt (issue create), prcomments.log (pr comment), calls.log.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
repo=""; oid=""; prev=""
for a in "$@"; do
  case "$prev" in --repo) repo="${a#*/}";; --commit) oid="$a";; esac
  prev="$a"
done
case "$1 $2" in
  "pr list")  cat "$CASE/merged-$repo.tsv" 2>/dev/null; exit 0;;
  "pr view")
    case "$*" in
      *"--json files"*)    cat "$CASE/files-$repo-$3.txt" 2>/dev/null;;
      *"--json comments"*) cat "$CASE/comments-$repo-$3.txt" 2>/dev/null;;
    esac; exit 0;;
  "issue view")   # ticket_outcome reads the filed apply-bootstrap ticket directly (state + comments)
    case "$*" in
      *"--json state"*)    cat "$CASE/ticket-state-$3.txt" 2>/dev/null;;
      *"--json comments"*) cat "$CASE/ticket-comments-$3.txt" 2>/dev/null;;
    esac; exit 0;;
  "api -X")       # surface_blocked's alarm dedup: `api -X GET search/issues …` → open alarm number or empty
    cat "$CASE/search-issues.txt" 2>/dev/null; exit 0;;
  "run list")
    echo "runlist $repo $oid" >> "$CASE/calls.log"
    cat "$CASE/run-$oid.tsv" 2>/dev/null; exit 0;;
  "pr comment")
    body=""; prev=""
    for a in "$@"; do [ "$prev" = "--body" ] && body="$a"; prev="$a"; done
    printf 'comment %s %s: %s\n' "$repo" "$3" "$body" >> "$CASE/prcomments.log"; exit 0;;
  "label create") exit 0;;
  "issue create")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--title" ] && echo "title: $a" >> "$CASE/tickets.log"
      [ "$prev" = "--body-file" ] && cat "$a" >> "$CASE/ticket-bodies.txt"
      [ "$prev" = "--body" ] && printf '%s\n' "$a" >> "$CASE/issue-bodies.txt"   # surface_blocked's alarm uses --body
      prev="$a"
    done
    echo "https://github.com/oso-gato/fedora-bootstrap/issues/42"; exit 0;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# scan recorder — stands in for bin/host-refresh.sh in the poller-wiring rows.
cat > "$BIN/scan-rec" <<'EOF'
#!/usr/bin/env bash
echo "scan $*" >> "${RECORD:?}"
exit 0
EOF
chmod +x "$BIN/scan-rec"

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

setup_case(){
  n=$((n+1)); CASE="$ROOT/c$n"; HOMEDIR="$CASE/home"; mkdir -p "$HOMEDIR"
  TARGET="$SCRIPT"
}
run_scan(){ # extra env…
  OUT="$CASE/scan.out"
  # REPO_SCOPE pinned to the real reader: the mutation rows run sed-COPIES from $ROOT, where the
  # default $HERE/repo-scope.sh does not exist — a missing reader is a fail-closed R16 refusal
  # (#167) that would starve those rows of the very ticket they must prove the mutant files.
  env HOME="$HOMEDIR" CASE="$CASE" PATH="$BIN:$PATH" REPO_SCOPE="$HERE/bin/repo-scope.sh" \
      HOST_REFRESH_WORKLOADS="fedora-dev" HOST_TICKET="$HTICKET" "$@" \
      bash "$TARGET" --once >"$OUT" 2>&1
  RC=$?
}
run_poller(){ # extra env…  (drives the REAL poller --once; empty fixtures ⇒ a quiet sweep)
  OUT="$CASE/poller.out"
  env HOME="$HOMEDIR" CASE="$CASE" PATH="$BIN:$PATH" RECORD="$CASE/scan.rec" \
      POLLER_REPOS=fedora-dev POLLER_ARMED=0 HOST_REFRESH_SCAN="$BIN/scan-rec" "$@" \
      bash "$POLLER" --once >"$OUT" 2>&1
  RC=$?
}
haslog(){ grep -qF "$1" "$OUT"; }
tickets(){ wc -l 2>/dev/null < "$CASE/tickets.log" || echo 0; }
recs(){ wc -l 2>/dev/null < "$CASE/scan.rec" || echo 0; }
# grep -c emits "0"+exit1 on an existing-but-unmatched file, so a `|| echo 0` would double-emit; capture
# then default so the helper ALWAYS prints exactly one number (missing file → "" → 0; match → N).
applyqs(){ local n; n="$(grep -cF 'host-apply needed' "$CASE/prcomments.log" 2>/dev/null || true)"; echo "${n:-0}"; }
applyfiled(){ local n; n="$(grep -cF 'host-refresh → apply-filed:' "$CASE/prcomments.log" 2>/dev/null || true)"; echo "${n:-0}"; }
# apply-bootstrap tickets ONLY (line-1 grammar in the ticket body) — excludes the surface_blocked alarm,
# which is created via `gh issue create --body` (no --body-file) so it never lands in ticket-bodies.txt.
applytix(){ local n; n="$(grep -cF 'host-op: apply-bootstrap' "$CASE/ticket-bodies.txt" 2>/dev/null || true)"; echo "${n:-0}"; }
# the deduped BLOCKED alarm issue (its --title is recorded to tickets.log).
alarms(){ local n; n="$(grep -cF 'BLOCKED: host apply-bootstrap' "$CASE/tickets.log" 2>/dev/null || true)"; echo "${n:-0}"; }
# the loud terminal apply-blocked PR comment.
applyblocked(){ local n; n="$(grep -cF 'host-refresh → apply-blocked:' "$CASE/prcomments.log" 2>/dev/null || true)"; echo "${n:-0}"; }

# ===================================================================================================
echo "== REQ 1+6: an image-baked merge files exactly ONE redeploy ticket — AFTER publish =="
DESC="image-path merge + published CI → one ticket, right grammar, audit comment, idempotent"; OK=1
setup_case
printf '7\t%s\t%s\n' "$OID" "$FRESH"              > "$CASE/merged-fedora-dev.tsv"
printf 'Containerfile\nREADME.md\n'               > "$CASE/files-fedora-dev-7.txt"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "scan rc=$RC want 0"
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "filed $(tickets) tickets, want exactly 1"
ck "$(grep -q 'redeploy fedora-dev' "$CASE/tickets.log" && echo 1 || echo 0)" "ticket title lacks 'redeploy fedora-dev'"
ck "$([ "$(head -1 "$CASE/ticket-bodies.txt" 2>/dev/null)" = "host-op: redeploy fedora-dev" ] && echo 1 || echo 0)" "ticket line 1 is not the consumer's 'host-op: redeploy fedora-dev' grammar"
ck "$(grep -q 'host-refresh → filed:' "$CASE/prcomments.log" 2>/dev/null && echo 1 || echo 0)" "no 'filed:' audit/dedup comment on the merged PR"
ck "$(grep -q "runlist fedora-dev $OID" "$CASE/calls.log" && echo 1 || echo 0)" "the publish gate never checked THIS merge commit's CI run"
run_scan                                           # same HOME — the scan-once marker parks it
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "a re-scan filed again ($(tickets) total) — not idempotent"
done_case

echo "== REQ 6: a live-clone-only merge (bin/ + policy/) files NOTHING — #162 owns that half =="
DESC="bin/+policy/-only merge → no ticket ever (publish success is available, classification refuses)"; OK=1
setup_case
printf '8\t%s\t%s\n' "$OID" "$FRESH"              > "$CASE/merged-fedora-dev.tsv"
printf 'bin/pr-poller.sh\npolicy/CLAUDE.md\n'     > "$CASE/files-fedora-dev-8.txt"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
run_scan; run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "filed $(tickets) tickets for a live-clone-only merge, want 0"
LIVEONLY_CASE="$CASE"                              # re-used by the mutation row below
done_case

echo "== REQ 1+5+6: a publish that has NOT completed files none — and files ONCE when it lands =="
DESC="pending CI → no ticket, retried (no park); CI success on a later scan → exactly one ticket"; OK=1
setup_case
printf '9\t%s\t%s\n' "$OID" "$FRESH"              > "$CASE/merged-fedora-dev.tsv"
printf 'entrypoint.sh\n'                          > "$CASE/files-fedora-dev-9.txt"
printf 'in_progress\t\n'                          > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "filed $(tickets) tickets BEFORE the publish, want 0 (the host must never pull a stale digest)"
ck "$(haslog 'PENDING' && echo 1 || echo 0)" "the pending publish was not logged"
cp "$OUT" "$CASE/pending-scan.out"                 # snapshot — the mutation row's sanity check reads it
PENDING_CASE="$CASE"                               # re-used by the publish-gate mutation row below
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "after the publish landed: $(tickets) tickets, want exactly 1 (a pending merge must be retried, not parked)"
done_case

echo "== REQ 5+6: a publish that NEVER completes (CI failed) files none — the MISS is logged =="
DESC="failed CI → no ticket ever, MISS logged, terminal (a later success does not resurrect it)"; OK=1
setup_case
printf '10\t%s\t%s\n' "$OID" "$FRESH"             > "$CASE/merged-fedora-dev.tsv"
printf 'install.sh\n'                             > "$CASE/files-fedora-dev-10.txt"
printf 'completed\tfailure\n'                     > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "filed $(tickets) tickets for a NEVER-published image, want 0"
ck "$(haslog 'MISS' && echo 1 || echo 0)" "the miss was not logged (req 5: degrade to the status quo AND log it)"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "a terminal FAILED merge was resurrected ($(tickets) tickets)"
done_case

echo "== REQ 4: wiped local state does NOT file twice — the PR's own comment stream is the record =="
DESC="fresh HOME + a prior 'filed:' anchor on the PR → no second ticket"; OK=1
setup_case
printf '11\t%s\t%s\n' "$OID" "$FRESH"             > "$CASE/merged-fedora-dev.tsv"
printf 'Containerfile\n'                          > "$CASE/files-fedora-dev-11.txt"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
printf '**host-refresh → filed:** https://github.com/oso-gato/fedora-bootstrap/issues/41 — …\n' \
                                                  > "$CASE/comments-fedora-dev-11.txt"
run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "a wiped box re-filed ($(tickets) tickets) despite the PR's own anchor"
ck "$(haslog 'not filing twice' && echo 1 || echo 0)" "the dedup was not logged"
done_case

echo "== BOUNDS: a merge outside the catch-up window is the monthly timer's — parked, logged =="
DESC="stale merge (mergedAt long past MAX_AGE) → no ticket, window log, no CI poll"; OK=1
setup_case
printf '12\t%s\t2020-01-01T00:00:00Z\n' "$OID"    > "$CASE/merged-fedora-dev.tsv"
printf 'Containerfile\n'                          > "$CASE/files-fedora-dev-12.txt"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
run_scan
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "filed $(tickets) tickets for a stale merge, want 0"
ck "$(haslog 'catch-up window' && echo 1 || echo 0)" "the window park was not logged"
done_case

echo "== REQ 2 (#133/#187): a merged CONTROL-repo change FILES one apply-bootstrap ticket =="
DESC="host-path bootstrap merge → one apply-bootstrap ticket (right grammar) + apply-filed anchor; idempotent"; OK=1
setup_case
printf '126\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'container-refresh.sh\n'                   > "$CASE/files-fedora-bootstrap-126.txt"
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "filed $(tickets) apply-bootstrap tickets, want exactly 1"
ck "$([ "$(head -1 "$CASE/ticket-bodies.txt" 2>/dev/null)" = "host-op: apply-bootstrap" ] && echo 1 || echo 0)" "ticket line 1 is not the consumer's 'host-op: apply-bootstrap' grammar (no arg)"
ck "$([ "$(applyfiled)" = 1 ] && echo 1 || echo 0)" "no 'apply-filed:' audit/dedup comment on the merged PR"
ck "$([ "$(applyqs)" = 0 ] && echo 1 || echo 0)" "surfaced the pre-#187 question ($(applyqs)) — the verb exists now, it must FILE not ask"
# Idempotency under OUTCOME-keying: scan 1 posted an apply-filed comment (issues/42, the stub's URL) and
# the ticket is now in-flight. Simulate that comment landing on the PR + the ticket PENDING (no verdict) —
# the re-scan reads the anchor, sees PENDING, and WAITS (no second apply ticket).
printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/42 — attempt 1/3.\n' \
                                                  > "$CASE/comments-fedora-bootstrap-126.txt"
printf 'OPEN\n'                                   > "$CASE/ticket-state-42.txt"
: > "$CASE/ticket-comments-42.txt"
run_scan HOST_REFRESH_WORKLOADS=                   # same HOME — an in-flight ticket must be waited on
ck "$([ "$(applytix)" = 1 ] && echo 1 || echo 0)" "a re-scan re-filed ($(applytix) total) — an in-flight apply must be waited on, not re-filed"
done_case

DESC="doc-only bootstrap merge → no ticket (nothing for the running host to apply)"; OK=1
setup_case
printf '127\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'README.md\n'                              > "$CASE/files-fedora-bootstrap-127.txt"
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "filed $(tickets) tickets for a doc-only merge, want 0"
done_case

DESC="REQ 4: wiped state + a prior apply-filed anchor whose ticket is DONE → terminal skip, no re-file"; OK=1
setup_case
printf '128\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'host-agent-watch.sh\n'                    > "$CASE/files-fedora-bootstrap-128.txt"
printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/41 — …\n' \
                                                  > "$CASE/comments-fedora-bootstrap-128.txt"
printf 'CLOSED\n'                                 > "$CASE/ticket-state-41.txt"
printf '**host-agent: DONE** — applied, healthy.\n' > "$CASE/ticket-comments-41.txt"
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(applytix)" = 0 ] && echo 1 || echo 0)" "a DONE apply re-filed ($(applytix)) — a terminal-success ticket must skip"
done_case

DESC="TRANSITION: a PR carrying the pre-#187 'host-apply needed:' question is left alone (never re-filed)"; OK=1
setup_case
printf '129\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'host-agent-watch.sh\n'                    > "$CASE/files-fedora-bootstrap-129.txt"
printf '**host-refresh → host-apply needed:** …\n' > "$CASE/comments-fedora-bootstrap-129.txt"
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(tickets)" = 0 ] && echo 1 || echo 0)" "re-filed apply-bootstrap ($(tickets)) for a PR already surfaced for a human — the transition must leave it alone"
done_case

# ---------------------------------------------------------------------------------------------------
# OUTCOME-KEYED RETRY (audit #7) — a FAILED apply must RE-FILE (not sit stranded on the filed-anchor),
# a PENDING one waits, and repeated failure surfaces BLOCKED. The old dedup skipped on "was filed".
# ---------------------------------------------------------------------------------------------------
echo "== OUTCOME: a FAILED apply RE-FILES (bounded); the old filed-anchor dedup stranded the host =="
DESC="apply-filed anchor + ticket verdict FAILED (attempts<MAX) → re-files, no alarm, and is NOT parked"; OK=1
setup_case
printf '130\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'host-agent-watch.sh\n'                    > "$CASE/files-fedora-bootstrap-130.txt"
printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/50 — attempt 1/3.\n' \
                                                  > "$CASE/comments-fedora-bootstrap-130.txt"
printf 'CLOSED\n'                                 > "$CASE/ticket-state-50.txt"
printf '**host-agent: FAILED** — apply rolled back to prior commit.\n' > "$CASE/ticket-comments-50.txt"
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(applytix)" = 1 ] && echo 1 || echo 0)" "a FAILED apply did NOT re-file ($(applytix) apply tickets) — the host would stay on prior code"
ck "$([ "$(applyfiled)" = 1 ] && echo 1 || echo 0)" "no new apply-filed anchor posted on the retry ($(applyfiled))"
ck "$([ "$(alarms)" = 0 ] && echo 1 || echo 0)" "surfaced BLOCKED ($(alarms)) below the retry bound"
run_scan HOST_REFRESH_WORKLOADS=                  # same HOME — a still-FAILED ticket must NOT be parked
ck "$([ "$(applytix)" = 2 ] && echo 1 || echo 0)" "a failed apply was PARKED by a marker ($(applytix) total after re-scan, want 2) — no marker may be written on a non-terminal state"
done_case

echo "== OUTCOME: a PENDING apply WAITS (no re-file); it re-files once the verdict turns FAILED =="
DESC="apply-filed anchor + ticket still OPEN/no-verdict → wait; flip to FAILED → re-file"; OK=1
setup_case
printf '131\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'setup-host.sh\n'                          > "$CASE/files-fedora-bootstrap-131.txt"
printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/51 — attempt 1/3.\n' \
                                                  > "$CASE/comments-fedora-bootstrap-131.txt"
printf 'OPEN\n'                                   > "$CASE/ticket-state-51.txt"
: > "$CASE/ticket-comments-51.txt"                # in-flight: no host-agent verdict yet
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(applytix)" = 0 ] && echo 1 || echo 0)" "an in-flight (PENDING) apply re-filed ($(applytix)) — it must wait for the verdict"
ck "$(haslog 'in-flight' && echo 1 || echo 0)" "the PENDING wait was not logged"
printf 'CLOSED\n'                                 > "$CASE/ticket-state-51.txt"
printf '**host-agent: FAILED** — rolled back.\n'  > "$CASE/ticket-comments-51.txt"
run_scan HOST_REFRESH_WORKLOADS=                  # verdict now FAILED → the wait releases into a retry
ck "$([ "$(applytix)" = 1 ] && echo 1 || echo 0)" "once PENDING turned FAILED the apply did not re-file ($(applytix))"
done_case

echo "== OUTCOME: retries exhausted → BLOCKED surfaced (loud), no further auto-retry =="
DESC="MAX_APPLY_RETRIES apply-filed anchors + last ticket FAILED → BLOCKED alarm + PR comment, no new apply"; OK=1
setup_case
printf '132\t%s\t%s\n' "$OID" "$FRESH"            > "$CASE/merged-fedora-bootstrap.tsv"
printf 'host-apply.sh\n'                          > "$CASE/files-fedora-bootstrap-132.txt"
{ printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/60 — attempt 1/3.\n'
  printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/61 — attempt 2/3.\n'
  printf '**host-refresh → apply-filed:** https://github.com/oso-gato/fedora-bootstrap/issues/62 — attempt 3/3.\n'
} > "$CASE/comments-fedora-bootstrap-132.txt"
printf 'CLOSED\n'                                 > "$CASE/ticket-state-62.txt"
printf '**host-agent: FAILED** — rolled back again.\n' > "$CASE/ticket-comments-62.txt"
: > "$CASE/search-issues.txt"                      # no open alarm yet → surface_blocked creates one
run_scan HOST_REFRESH_WORKLOADS=
ck "$([ "$(applytix)" = 0 ] && echo 1 || echo 0)" "retries exhausted but still filed an apply ticket ($(applytix)) — must stop and surface"
ck "$([ "$(applyblocked)" = 1 ] && echo 1 || echo 0)" "no loud apply-blocked PR comment on exhaustion ($(applyblocked))"
ck "$([ "$(alarms)" = 1 ] && echo 1 || echo 0)" "no deduped BLOCKED alarm issue on exhaustion ($(alarms))"
ck "$(grep -q '@oso-gato' "$CASE/issue-bodies.txt" 2>/dev/null && echo 1 || echo 0)" "the BLOCKED alarm body does not @mention the maintainer (no GitHub mobile-app push)"
printf '77\n'                                     > "$CASE/search-issues.txt"   # now an alarm is open
run_scan HOST_REFRESH_WORKLOADS=                  # re-scan: terminal marker parks it, no duplicate alarm
ck "$([ "$(alarms)" = 1 ] && echo 1 || echo 0)" "a re-scan duplicated the BLOCKED alarm ($(alarms) total) — it must dedup and park"
done_case

# ---------------------------------------------------------------------------------------------------
# POLLER WIRING — the real bin/pr-poller.sh fires the scan on its cadence, R9-halt-gated.
# ---------------------------------------------------------------------------------------------------
echo "== WIRING: the poller fires the scan at HOST_REFRESH_EVERY =="
DESC="--once + HOST_REFRESH_EVERY=1 → the scan runs once"; OK=1
setup_case
run_poller HOST_REFRESH_EVERY=1
ck "$([ "$(recs)" = 1 ] && echo 1 || echo 0)" "scan invoked $(recs) times, want 1"
done_case

DESC="default cadence: a single --once sweep does NOT fire the scan (counter < 30)"; OK=1
setup_case
run_poller
ck "$([ "$(recs)" = 0 ] && echo 1 || echo 0)" "the scan fired on the first sweep under the default cadence"
done_case

DESC="HOST_REFRESH_EVERY=0 disables the mechanism"; OK=1
setup_case
run_poller HOST_REFRESH_EVERY=0
ck "$([ "$(recs)" = 0 ] && echo 1 || echo 0)" "a disabled host-refresh still ran"
done_case

# ---------------------------------------------------------------------------------------------------
# THE ISSUE'S TWO NAMED MUTATIONS — restored mechanically and run IN-SUITE (must fail the suite).
# ---------------------------------------------------------------------------------------------------
echo "== MUTATION: restore 'file a redeploy on EVERY merge' → the live-clone-only row must bite =="
DESC="classifier neutralized → the bin/+policy/ fixture NOW files (proving the real row discriminates)"; OK=1
MUT1="$ROOT/mutant-every-merge.sh"; cp "$SCRIPT" "$MUT1"
sed -i 's/| image_relevant;/| true;/' "$MUT1"
ck "$(cmp -s "$SCRIPT" "$MUT1" && echo 0 || echo 1)" "the sed changed nothing — the mutation row is vacuous"
setup_case
printf '8\t%s\t%s\n' "$OID" "$FRESH"              > "$CASE/merged-fedora-dev.tsv"
printf 'bin/pr-poller.sh\npolicy/CLAUDE.md\n'     > "$CASE/files-fedora-dev-8.txt"
printf 'completed\tsuccess\n'                     > "$CASE/run-$OID.tsv"
TARGET="$MUT1"; run_scan
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "the file-on-every-merge mutant filed $(tickets) tickets on the live-clone fixture — the real row would not catch this mutation"
ck "$([ -f "$LIVEONLY_CASE/tickets.log" ] && echo 0 || echo 1)" "sanity lost: the REAL script had filed on the same fixture"
done_case

echo "== MUTATION: restore 'file BEFORE publish' → the pending-CI row must bite =="
DESC="publish gate forced PUBLISHED → the pending fixture NOW files a stale-digest ticket"; OK=1
MUT2="$ROOT/mutant-before-publish.sh"; cp "$SCRIPT" "$MUT2"
sed -i 's/pub=.*publish_state.*/pub=PUBLISHED/' "$MUT2"
ck "$(cmp -s "$SCRIPT" "$MUT2" && echo 0 || echo 1)" "the sed changed nothing — the mutation row is vacuous"
setup_case
printf '9\t%s\t%s\n' "$OID" "$FRESH"              > "$CASE/merged-fedora-dev.tsv"
printf 'entrypoint.sh\n'                          > "$CASE/files-fedora-dev-9.txt"
printf 'in_progress\t\n'                          > "$CASE/run-$OID.tsv"
TARGET="$MUT2"; run_scan
ck "$([ "$(tickets)" = 1 ] && echo 1 || echo 0)" "the file-before-publish mutant filed $(tickets) tickets on a PENDING publish — the real row would not catch this mutation"
ck "$(grep -q 'PENDING' "$PENDING_CASE/pending-scan.out" && echo 1 || echo 0)" "sanity lost: the REAL script no longer waits on a pending publish"
done_case

echo "== SELFTEST: the pure core =="
DESC="bin/host-refresh.sh --selftest exits 0"; OK=1
bash "$SCRIPT" --selftest >"$ROOT/selftest.out" 2>&1
ck "$([ $? = 0 ] && echo 1 || echo 0)" "selftest failed: $(tail -3 "$ROOT/selftest.out" | tr '\n' ' ')"
done_case

echo
echo "host-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
