#!/usr/bin/env bash
# pr-poller.sh — the DEV-SIDE POLLER / wake-up mechanism (GOVERNANCE §5 / #93 Step 5).
#
# The host is already autonomous: it live-gates a labelled PR and posts a GREEN/RED verdict on its own
# timer. This closes the DEV-side gap — a supervised, PLAIN-SHELL (NO Claude in the loop) watcher on
# fedora-dev that reacts to each new host verdict:
#
#   RED   → spawn a BOUNDED headless `claude -p` fixer in an ISOLATED WORKTREE checked out on the PR's
#           own gated head; the model COMMITS, the HARNESS pushes the FEATURE branch and VERIFIES the
#           landing at ORIGIN (the new head SHA re-triggers the host gate). The dev pushes fixes —
#           NEVER the host, NEVER main; the fixer holds NO merge step. NO FIXED ITERATION CAP: it loops
#           until GREEN or until it stops making progress (same failure signature twice / the fixer
#           reports BLOCKED), which is SURFACED as a decision — never a quiet quit (doctrine mandate 6).
#   GREEN → run the independent fitness harness (bin/fitness-review.sh); then the merge decision:
#           Tier A → present to Arthur (never auto); Tier B/C + fitness PASS → bin/auto-merge.sh.
#
#   CONFLICTING → the THIRD route (#150). A PR whose base moved under it can be host-GREEN and
#           fitness-PASS and STILL be mechanically unmergeable — both gates judge the PR's own head,
#           which compiles and reviews fine IN ISOLATION; only the MERGE is impossible. The old state
#           machine modelled two gates and no mergeability, so such a PR routed to MERGE every sweep,
#           auto-merge failed every sweep, and the loop span forever with NO surfaced question and NO
#           fixer iteration (observed live 2026-07-12 on #149). Now the sweep reads GitHub's own
#           `mergeable` and treats CONFLICTING as a FIRST-CLASS state: never MERGE — route to the
#           FIXER with a truthful RECONCILE reason (R6's "findings are generative", applied to a third
#           cause). UNKNOWN (GitHub has not finished computing it) is NOOP-and-wait — fail-closed: the
#           poller never merges a PR whose mergeability it could not read.
#
#   RETIRE → each sweep FIRST retires SUPERSEDED PRs: a MERGED PR whose body carries a WHOLE LINE that
#           is exactly `Supersedes #N[, #M…]` (same-repo, case-insensitive, nothing else on the line)
#           closes a still-OPEN #N with an explanatory comment. The authorizing event is the
#           SUPERSEDER'S MERGE — already human-clicked (or, armed, three-gate-checked) — so
#           retirement runs even while DISARMED: a close is reversible (reopen button) and never
#           touches main; arming (#96) gates the MERGE boundary only. Fail-closed to NO-OP: an issue
#           number, a cross-repo ref, prose, a backticked/blockquoted/fenced/code-indented example,
#           a malformed list, or an already-closed target never acts; a transient API failure degrades to the
#           status quo (the PR stays open for a human) — never to a wrong close; a human REOPEN is
#           durable (a PR carrying a prior retire comment is never re-closed, even after local state
#           loss). WHY THE POLLER: the interactive agent is classifier-DENIED `gh pr close` on PRs
#           it didn't create (run-003 lesson b), so this deterministic verb is the sanctioned
#           retirement path.
#
# SAFE BY DEFAULT — DISARMED: the GREEN→merge path calls auto-merge.sh in --dry-run (prints the
# DECISION, merges nothing) UNLESS POLLER_ARMED=1. Arming (flipping to --commit) is the LAST step and a
# Tier-A change gated on Arthur's click (#96) — disarmed, the MERGE boundary stays untouched. And
# auto-merge.sh itself re-checks all three gates fail-closed, so a stale plan can never mis-merge.
#
# The poller has NO merge credential of its own: it OBSERVES, spawns a feature-branch fixer, retires
# superseded PRs (a reversible close — see RETIRE above; the one non-merge write it performs even
# disarmed, alongside its surface/fitness comments), and delegates the merge to the dumb, gate-checked
# auto-merge.sh. It cannot be prompt-injected — it runs no model; the only model it spawns is the
# disposable fixer, whose prompt forbids merge/main.
#
# Usage:
#   pr-poller.sh --once                # one sweep of all open PRs, then exit (cron / manual / testing)
#   pr-poller.sh --watch               # supervised loop (singleton via flock), sweeps every $POLL_INTERVAL
#   pr-poller.sh --selftest            # exercise the pure plan()/verdict extractors (no network/model)
#
# Config (env):
#   POLLER_REPO       repo to watch (default: fedora-dev — the poller watches its OWN repo's PRs)
#   LG_HOST_LOGIN     host bot login whose verdict is trusted (default: oso-gato-erebus-claudebox[bot])
#   FITNESS_LOGIN     fitness bot login (passed through to fitness-review.sh + auto-merge.sh)
#   POLLER_ARMED      1 → GREEN+B/C+PASS actually merges (auto-merge --commit). Default 0 (dry-run).
#   POLL_INTERVAL     seconds between --watch sweeps (default 10, matching the host watcher cadence).
#                     Cost at 10s (fetch-BATCHED sweep): steady state ≈ 360×(2+N)/h — the open-PR
#                     list (TSV: number+ref+sha in ONE call), the retire merged-list, and ONE
#                     sha-bound comments call per open PR. A PARKED GREEN PR (already acted:
#                     PRESENT posted / dry-run decided / merge attempted) is terminal-state-skipped
#                     on its acted marker, so it too costs exactly 1 comments call/sweep; only a
#                     GREEN PR whose routing is PENDING (fitness verdict not yet posted, or
#                     fitness-RETURN driving the fixer) costs +2 (files + fitness comments) per
#                     sweep until it parks — short-lived, and bounded by the fitness/fixer
#                     turnaround. Against the dev App's 5k/h REST budget (SHARED with the fixer,
#                     fitness reviewer and auto-merge): N=10 open PRs ≈ 4.3k/h — the ceiling is
#                     ~10 sustained open PRs (was 2-3 unbatched). On exhaustion gh calls fail and
#                     sweeps degrade to NOOP until the window resets — fail-closed,
#                     self-recovering; GREEN-moment fetch failures skip that PR for that sweep
#                     (retry next), never a misroute. Escalation if ever needed: one GraphQL
#                     sweep query for ALL open PRs (N-independent) — designed, not built.
#   POLLER_FIXER      headless fixer command (default: claude -p). Overridable for testing.
#   FIXER_TIMEOUT     max seconds for ONE fixer run (default 1800). Bounds a single iteration, not the
#                     count of iterations.
#   FRESH_TREE        the isolator (default: bin/fresh-tree.sh). Every fix runs in a throwaway worktree
#                     off the PR's own head — NEVER the shared clone (#152). Overridable for testing.
#   STALL_SWEEPS      consecutive sweeps a PR may show the SAME observed state (head sha, both
#                     verdicts, mergeability, routed action) before the poller SURFACES it as stuck
#                     (default 360 ≈ 1h at the 10s cadence; 0 disables). The backstop behind every
#                     fail-closed "wait" above — a loop that cannot progress and does not say so is
#                     the failure mode R13 exists to prevent (#150 req 4).
#   RETIRE_LOOKBACK   how many of the most recently UPDATED merged PRs each sweep scans for
#                     `Supersedes #N` declarations (default 15; sorted by update recency so a
#                     long-parked PR that merges late still enters the window; each merged PR is
#                     scanned only once — state marker). Residual: if the poller is DOWN while more
#                     than this many merged PRs receive updates, older declarations fall out of the
#                     window unscanned — degrades to status quo (the PR stays open for a human).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ===================================================================================================
# PURE decision core — no I/O, exercised by --selftest.
# ===================================================================================================

# extract the newest host live-gate verdict (GREEN|RED) from header lines on stdin. LINE-START
# anchored: a verdict string quoted mid-line (embedded candidate log, prose) never matches — the
# same G2 discipline as bin/auto-merge.sh, applied to ROUTING so forged strings can't even misroute.
host_verdict(){ grep -oE '^\**Host live-gate \(Gate B\): VERDICT (GREEN|RED)' | grep -oE '(GREEN|RED)$' | tail -1; }
# extract the newest fitness verdict (PASS|RETURN|ESCALATE) from header lines on stdin (line-start
# anchored, same rationale).
fitness_verdict(){ grep -oE '^Fitness review: VERDICT (PASS|RETURN|ESCALATE)' | grep -oE '(PASS|RETURN|ESCALATE)$' | tail -1; }
# extract same-repo supersession targets (PR numbers, one per line, deduped) from a PR body on stdin.
# STRICT WHOLE-LINE grammar — a line that is EXACTLY `Supersedes #N[, #M…]` (case-insensitive, up to
# 3 leading spaces, trailing whitespace ok, CRLF stripped) and NOTHING else. ALL-OR-NOTHING: a line
# with any other text — backticks, a blockquote `>`, mid-sentence prose, trailing words, a
# space-separated list — matches NOTHING (never a partial list), so quoted examples with a live
# number, negations, cross-repo refs and unrelated `#N` can never act. MARKDOWN-AWARE: fenced code
# blocks (``` / ~~~ toggles) are stripped before matching and a ≥4-space/tab indent is markdown code
# — so DOCUMENTING the grammar in a fence or code-indent can never act either (belt: still write
# `#N` — letters — in prose examples). The superseding PR carries the declaration as its own line.
supersede_targets(){ tr -d '\r' | awk '/^ {0,3}(```|~~~)/{f=!f; next} !f' | grep -ioE '^ {0,3}supersedes:?[[:space:]]+#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*[[:space:]]*$' | grep -oE '#[0-9]+' | tr -d '#' | sort -un; }

# plan <host:GREEN|RED|NONE> <tier:A|B|C|""> <fitness:PASS|RETURN|ESCALATE|NONE> <armed:0|1>
#      <mergeable:MERGEABLE|CONFLICTING|UNKNOWN>
#   -> NOOP | FIX | REVIEW | MERGE | MERGE_DRYRUN | PRESENT
# The single source of truth for "given the gates, what does the poller DO". Fail-closed toward the
# human: any ambiguity (unknown tier, no host verdict, unreadable mergeability) resolves to NOOP or
# PRESENT, never to a merge.
plan(){
  local host="$1" tier="$2" fit="$3" armed="$4" mrg="${5:-UNKNOWN}"
  case "$host" in
    RED)  echo FIX; return;;                          # host says broken → iterate a fix
    GREEN) : ;;                                        # fall through to the merge decision
    *)    echo NOOP; return;;                          # no host verdict yet (NONE) → wait
  esac
  # MERGEABILITY IS A GATE-INDEPENDENT AXIS (#150). Both gates judge the PR's OWN head in isolation, so
  # a PR whose base moved under it is GREEN + PASS and STILL unmergeable. Decide it BEFORE fitness:
  #   * CONFLICTING → FIX (never MERGE — the merge is mechanically impossible; and never REVIEW either:
  #     the reconcile rewrites the head, which invalidates any verdict a review would have posted, so a
  #     review here is a wasted model run whose PASS dies on arrival).
  #   * UNKNOWN → NOOP. GitHub computes `mergeable` LAZILY (the first read of a fresh head returns
  #     UNKNOWN and kicks off the computation; the next sweep, 10s later, has the answer). Waiting is
  #     fail-closed — we never merge a PR whose mergeability we could not read — and self-resolving. A
  #     mergeability that NEVER resolves is a stall, and stall_state() surfaces it rather than spinning.
  case "$mrg" in
    CONFLICTING) echo FIX;  return;;
    MERGEABLE)   : ;;
    *)           echo NOOP; return;;
  esac
  # ZERO-GATE (2026-07-10, Arthur's decision): tier NO LONGER routes to a human PRESENT. Every GREEN
  # PR flows by its fitness verdict alone (host-GREEN + fitness-PASS auto-merges ANY tier, control-
  # plane included). The old Tier-A→click was misrepresented-requirement harness; recoverability is
  # kept automatic (host rollback + git revert + fitness's standing "preserve recoverability" rule),
  # not a tier gate. `tier` is retained for the log line only. ESCALATE still surfaces (below) — that
  # is the REVIEWER deferring on genuine ambiguity, not a tier gate.
  case "$fit" in
    NONE)     echo REVIEW;   return;;                  # GREEN but not yet fitness-reviewed → review it
    PASS)     [ "$armed" = 1 ] && echo MERGE || echo MERGE_DRYRUN; return;;
    RETURN)   echo FIX;      return;;                  # fitness wants rework → back to the developer
    ESCALATE) echo PRESENT;  return;;                  # fitness defers to Arthur
    *)        echo PRESENT;  return;;                  # unknown fitness token → human (fail-closed)
  esac
}

# fix_outcome <blocked:0|1> <gated-sha> <worktree-head> <push-rc> <origin-head>
#   -> BLOCKED | NO_COMMIT | PUSH_FAILED | NOT_LANDED | LANDED
# The fixer's TRUTHFUL outcome — this retires the old `new head (if pushed) will re-gate` shrug, which
# never checked anything: a fixer that pushed NOTHING was indistinguishable from one that succeeded, so
# the next sweep's no-progress stop parked the PR on a FALSE 'blocked' (and, on 2026-07-12, cost a human
# an hour concluding the fixer had landed nothing when it had landed correctly twice).
# A push rc of 0 is NOT proof of landing (a no-op push, a swallowed rejection, a hook that ate it) — a
# local commit that never reached origin is not progress. So LANDED requires ORIGIN's ref to actually
# hold the commit we made: origin-head == worktree-head, and the worktree-head moved past the gated sha.
fix_outcome(){
  local blocked="$1" base="$2" head="$3" prc="$4" remote="$5"
  [ "$blocked" = 1 ] && { printf 'BLOCKED'; return; }                     # model declared it cannot fix
  [ -n "$head" ] && [ "$head" != "$base" ] || { printf 'NO_COMMIT'; return; }  # nothing to push
  [ "$prc" = 0 ] || { printf 'PUSH_FAILED'; return; }                     # push itself errored
  [ "$remote" = "$head" ] || { printf 'NOT_LANDED'; return; }             # rc 0 but origin never moved
  printf 'LANDED'
}

# fix_cause <host> <fitness> <mergeable> -> HOST | CONFLICT | FITNESS | UNKNOWN
# WHICH gate sent this PR to the fixer. plan() returns FIX from THREE different routes — host RED,
# an unmergeable base (#150), and fitness RETURN — and the fixer is a bounded `claude -p` that can only
# fix what it is TOLD. Feeding a fitness RETURN the canned "host live-gate RED" line made it chase a
# build failure that never happened (the build is GREEN on a RETURN), so it could never make progress
# and the PR parked on a FALSE "blocked — host live-gate RED" surface. This is R6: "findings are
# generative — RETURN reasons feed the fixer's next iteration". PURE + selftested, so a future plan()
# route cannot silently inherit the wrong prompt: an unrecognised pairing is UNKNOWN, and the caller
# then refuses to guess.
# ORDER MIRRORS plan(): host RED first (a broken build is fixed on whatever base it sits on — a
# reconcile cannot make a RED candidate GREEN), then CONFLICTING (decided before fitness there too).
fix_cause(){
  local host="$1" fit="$2" mrg="${3:-UNKNOWN}"
  [ "$host" = RED ]       && { printf 'HOST';     return; }  # host verdict RED (fitness is not even read yet)
  [ "$mrg" = CONFLICTING ] && { printf 'CONFLICT'; return; }  # host GREEN, but the base moved under it
  [ "$fit" = RETURN ]     && { printf 'FITNESS';  return; }  # host GREEN, reviewer wants rework
  printf 'UNKNOWN'                                           # not a FIX route → never guess a reason
}

# stall_state <fingerprint> <prev-fingerprint> <prev-count> <limit> -> "<count> OK|STALL"
# NO SILENT SPINNING, EVER (#150 requirement 4 / R13). Every gate above is fail-closed toward "wait",
# and waiting forever is indistinguishable — from the outside — from working. So the sweep fingerprints
# each PR's whole observed state (head sha + both verdicts + mergeability + the action it routed to)
# and counts CONSECUTIVE sweeps that changed NOTHING. Past the limit the PR is not progressing and the
# poller SAYS SO (one idempotent surface per head) instead of re-deciding the same non-decision every
# 10s. Any state change — a new head, a verdict, a mergeability that finally computes — resets it, so a
# PR moving through the pipeline normally never trips it. PURE: the count arithmetic is the whole
# mechanism, so it is selftested rather than trusted.
stall_state(){
  local fp="$1" prev="$2" n="${3:-0}" limit="$4"
  case "$n" in ''|*[!0-9]*) n=0;; esac                 # unreadable/absent counter → start over
  if [ "$fp" = "$prev" ]; then n=$((n+1)); else n=1; fi
  if [ "$limit" -gt 0 ] 2>/dev/null && [ "$n" -ge "$limit" ]; then printf '%s STALL' "$n"
  else printf '%s OK' "$n"; fi
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  ck(){ local got; got="$(plan "$2" "$3" "$4" "$5" "$6")"; [ "$got" = "$7" ] && echo "ok: $1" || { echo "FAIL: $1 — plan($2,$3,$4,$5,$6)=$got want $7"; fail=1; }; }
  ck "no verdict"         NONE  B   NONE 0 MERGEABLE NOOP
  ck "red"                RED   B   NONE 0 MERGEABLE FIX
  ck "red ignores tier"   RED   A   PASS 1 MERGEABLE FIX
  ck "green tierA merges" GREEN A   PASS 1 MERGEABLE MERGE          # ZERO-GATE: A now merges like B/C
  ck "green tierA disarm" GREEN A   PASS 0 MERGEABLE MERGE_DRYRUN   # ZERO-GATE: A routes by fitness, not tier
  ck "green B unreviewed" GREEN B   NONE 0 MERGEABLE REVIEW
  ck "green C unreviewed" GREEN C   NONE 0 MERGEABLE REVIEW
  ck "green B pass armed" GREEN B   PASS 1 MERGEABLE MERGE
  ck "green B pass disarm" GREEN B  PASS 0 MERGEABLE MERGE_DRYRUN
  ck "green C pass armed" GREEN C   PASS 1 MERGEABLE MERGE
  ck "green B return"     GREEN B   RETURN 1 MERGEABLE FIX
  ck "green B escalate"   GREEN B   ESCALATE 1 MERGEABLE PRESENT
  ck "green unknown tier" GREEN ""  PASS 1 MERGEABLE MERGE          # ZERO-GATE: unknown tier no longer gates
  ck "green unknown fit"  GREEN B   WAT  1 MERGEABLE PRESENT
  # #150 — UNMERGEABLE IS A FIRST-CLASS STATE. The headline claim: a CONFLICTING PR can NEVER reach a
  # MERGE, however green and however passed — it goes to the fixer to be reconciled with current main.
  ck "conflict never merges"    GREEN B PASS   1 CONFLICTING FIX
  ck "conflict disarmed too"    GREEN B PASS   0 CONFLICTING FIX
  ck "conflict tierA too"       GREEN A PASS   1 CONFLICTING FIX
  ck "conflict beats review"    GREEN B NONE   1 CONFLICTING FIX   # reconcile first — a review of a doomed head is wasted
  ck "conflict beats escalate"  GREEN B ESCALATE 1 CONFLICTING FIX
  ck "conflict+return → FIX"    GREEN B RETURN 1 CONFLICTING FIX
  ck "RED+conflict still FIX"   RED   B NONE   1 CONFLICTING FIX
  ck "unknown mergeability waits" GREEN B PASS 1 UNKNOWN     NOOP  # fail-closed: never merge what we could not read
  ck "unreadable mergeability"  GREEN B PASS   1 ""          NOOP
  # a caller that OMITS the axis entirely must fail closed too (the arg defaults to UNKNOWN, not to
  # "mergeable") — so a future call site that forgets it can never merge blind.
  got4="$(plan GREEN B PASS 1)"
  [ "$got4" = NOOP ] && echo "ok: omitting the mergeability arg fails closed" \
    || { echo "FAIL: plan() with no mergeability arg = $got4 — want NOOP (fail-closed)"; fail=1; }
  # R6 — the fixer must be told WHICH gate failed. plan() returns FIX from three routes; fix_cause pins
  # the mapping so a fitness RETURN can never again be handed a canned "host live-gate RED" prompt, and
  # a CONFLICTING PR is never told to hunt a build failure that does not exist.
  fc(){ local got; got="$(fix_cause "$2" "$3" "$4")"; [ "$got" = "$5" ] && echo "ok: $1" || { echo "FAIL: $1 — fix_cause($2,$3,$4)=$got want $5"; fail=1; }; }
  fc "RED → HOST"                  RED   NONE   MERGEABLE   HOST
  fc "RED before fitness is read"  RED   ""     MERGEABLE   HOST
  fc "RED wins over a conflict"    RED   NONE   CONFLICTING HOST
  fc "GREEN+CONFLICTING → CONFLICT" GREEN NONE  CONFLICTING CONFLICT
  fc "conflict wins over RETURN"   GREEN RETURN CONFLICTING CONFLICT
  fc "GREEN+RETURN → FITNESS"      GREEN RETURN MERGEABLE   FITNESS
  fc "GREEN+PASS → never a FIX"    GREEN PASS   MERGEABLE   UNKNOWN
  fc "GREEN+NONE → never a FIX"    GREEN NONE   MERGEABLE   UNKNOWN
  # every plan()=FIX route must map to a KNOWN cause — the guard against a future route silently
  # inheriting the wrong prompt (the exact defect this fixes). The axes span the UNKNOWN/absent tokens
  # too (NONE = no verdict yet, WAT = an unrecognised one), so the claim the loop prints is the claim it
  # actually tests: no state whatsoever can reach the fixer without a truthful cause.
  for h in RED GREEN NONE WAT ""; do for f in NONE PASS RETURN ESCALATE WAT ""; do
    for m in MERGEABLE CONFLICTING UNKNOWN WAT ""; do
      if [ "$(plan "$h" B "$f" 1 "$m")" = FIX ] && [ "$(fix_cause "$h" "$f" "$m")" = UNKNOWN ]; then
        echo "FAIL: plan($h,$f,$m)=FIX but fix_cause=UNKNOWN — the fixer would get no truthful reason"; fail=1
      fi
    done
  done; done
  echo "ok: every FIX route has a known cause"
  # #150 requirement 4 — a PR whose state never changes must SURFACE, not spin. The count resets on ANY
  # observed change, so the normal pipeline (which changes state constantly) never trips it.
  ss(){ local got; got="$(stall_state "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — stall_state($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  ss "first sight"              'a|GREEN' ''        ''  3  '1 OK'
  ss "state changed → reset"    'b|GREEN' 'a|GREEN' 9   3  '1 OK'
  ss "unchanged → increments"   'a|GREEN' 'a|GREEN' 1   3  '2 OK'
  ss "reaching the limit stalls" 'a|GREEN' 'a|GREEN' 2  3  '3 STALL'
  ss "past the limit stays stalled" 'a|GREEN' 'a|GREEN' 7 3 '8 STALL'
  ss "garbage counter is safe"  'a|GREEN' 'a|GREEN' 'x' 3  '1 OK'
  ss "limit 0 disables"         'a|GREEN' 'a|GREEN' 99  0  '100 OK'
  # #152 — the fixer's outcome is DETERMINED, never assumed. The landing is verified against ORIGIN, so
  # rc-0-but-nothing-landed ("push lied") and origin-unreadable are FAILURES, not silent successes.
  fo(){ local got; got="$(fix_outcome "$2" "$3" "$4" "$5" "$6")"; [ "$got" = "$7" ] && echo "ok: $1" || { echo "FAIL: $1 — fix_outcome($2,$3,$4,$5,$6)=$got want $7"; fail=1; }; }
  fo "blocked beats everything"  1 aaa bbb 0 bbb  BLOCKED
  fo "no commit (head unmoved)"  0 aaa aaa 0 aaa  NO_COMMIT
  fo "no commit (no head)"       0 aaa ""  0 ""   NO_COMMIT
  fo "push errored"              0 aaa bbb 1 aaa  PUSH_FAILED
  fo "push rc0 but origin stale" 0 aaa bbb 0 aaa  NOT_LANDED
  fo "origin unreadable"         0 aaa bbb 0 ""   NOT_LANDED
  fo "landed (origin holds it)"  0 aaa bbb 0 bbb  LANDED
  vg(){ local got; got="$(printf '%s' "$2" | host_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  vg "host green"  'Host live-gate (Gate B): VERDICT GREEN'                                 GREEN
  vg "host latest" $'…VERDICT RED\nHost live-gate (Gate B): VERDICT GREEN'                   GREEN
  vg "host none"   'some unrelated comment'                                                 ""
  fv(){ local got; got="$(printf '%s' "$2" | fitness_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  fv "fit pass"    'Fitness review: VERDICT PASS'                                           PASS
  fv "fit latest"  $'Fitness review: VERDICT RETURN\nFitness review: VERDICT PASS'          PASS
  st(){ local got; got="$(printf '%s' "$2" | supersede_targets | tr '\n' ' ')"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  st "retire one"        'Supersedes #97'                                                   '97 '
  st "retire colon list" $'Body text.\nsupersedes: #12, #13\nMore.'                         '12 13 '
  st "retire crlf+indent" $'  Supersedes #42\r\nother\r\n'                                  '42 '
  st "retire dedup"      $'Supersedes #7\nSupersedes #7'                                    '7 '
  st "retire cross-repo" 'Supersedes oso-gato/fedora-desktop#97'                            ''
  st "retire prose only" 'this supersedes the old approach entirely'                        ''
  st "retire unrelated"  'relates to #4; fixes #5'                                          ''
  st "retire mid-line"   'note: this PR supersedes #12 in spirit'                           ''
  st "retire backticked" '`Supersedes #97`'                                                 ''
  st "retire blockquote" '> Supersedes #97'                                                 ''
  st "retire trailing"   'Supersedes #12 — replaced by the new approach'                    ''
  st "retire space list" 'Supersedes #12 #13'                                               ''
  st "retire fenced"     $'```\nSupersedes #55\n```'                                        ''
  st "retire tilde fence" $'~~~\nSupersedes #56\n~~~'                                       ''
  st "retire code indent" '    Supersedes #55'                                              ''
  st "retire post-fence" $'```\ndoc example\n```\nSupersedes #57'                           '57 '
  # tier-classify --stdin regression harness (the sibling script IS a dependency of sweep routing):
  # the gather loop must keep a FINAL UNTERMINATED line — a command-substituted variable loses its
  # trailing newline, and dropping that line classified a one-file PR from ZERO paths (round-2
  # review blocker). Empty stdin must stay "no files" — asserted here as EMPTY OUTPUT (the property
  # the sweep's ${tier:-A} consumes; the script also exits 2, not asserted).
  tc(){ local got; got="$(printf '%s' "$2" | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; got="${got:-NONE}"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  tc "tier unterminated one"  'README.md'                    'C'
  tc "tier unterminated last" $'README.md\npolicy/CLAUDE.md' 'A'
  tc "tier terminated parity" $'README.md\n'                 'C'
  tc "tier empty stdin"       ''                             'NONE'
  [ "$fail" = 0 ] && echo "ALL POLLER SELFTESTS PASS" || echo "POLLER SELFTESTS FAILED"
  exit "$fail"
fi

# ===================================================================================================
# I/O layer — the real sweep.
# ===================================================================================================
POLLER_REPO="${POLLER_REPO:-fedora-dev}"
SLUG="oso-gato/$POLLER_REPO"
# ORG-WIDE (P0 uniform loop): the poller sweeps EVERY fleet repo, not just its own — so a
# fedora-bootstrap or fedora-desktop PR auto-merges through the SAME harness as a fedora-dev one
# (Arthur's "same harness for the host"). fedora-desktop joined for the fleet-wide unshackle parity
# port (managed-settings.json must stay byte-identical across all three — fleet-guard-parity CHECK 1 —
# so its port PR needs the same zero-click path). Space-separated; sweep() re-sets POLLER_REPO/SLUG
# per repo each tick.
POLLER_REPOS="${POLLER_REPOS:-fedora-dev fedora-bootstrap fedora-desktop}"
# login MUST be the GraphQL form (no `[bot]` suffix) — that is what `gh pr view --json comments`
# returns and what auto-merge.sh matches against. REST's `.user.login` adds `[bot]`; do NOT use it.
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
# MAKE-IT-WORK DEFAULT: same-identity fitness (no separate App / ferry). FITNESS_SAME_IDENTITY=1 makes
# fitness-review.sh post the verdict — and auto-merge.sh accept it — under the DEV identity (the PR
# author, oso-gato-nox-claudebox); the review is still an independent agent-context (fresh `claude -p`).
# Cross-identity independence stays with the host live-gate (erebus). EXPORTED so both sub-scripts see it.
# To restore strict separation-of-duties later: FITNESS_SAME_IDENTITY=0 + FITNESS_LOGIN=<real fitness App>.
export FITNESS_SAME_IDENTITY="${FITNESS_SAME_IDENTITY:-1}"
FITNESS_LOGIN="${FITNESS_LOGIN:-oso-gato-nox-claudebox}"
POLLER_ARMED="${POLLER_ARMED:-0}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
POLLER_FIXER="${POLLER_FIXER:-claude -p}"
FIXER_TIMEOUT="${FIXER_TIMEOUT:-1800}"
RETIRE_LOOKBACK="${RETIRE_LOOKBACK:-15}"
# NO SILENT SPINNING (#150 req 4): consecutive no-state-change sweeps on one PR before it SURFACES.
# 360 × the 10s cadence ≈ 1h — long enough that every legitimate wait (a host build, a fitness run,
# GitHub computing `mergeable`) completes inside it, short enough that a genuinely stuck PR reaches a
# human the same hour. 0 disables the detector.
STALL_SWEEPS="${STALL_SWEEPS:-360}"
# the isolator the fixer runs in (#152). Overridable so poller-fixer.test.sh can drive the REAL sweep.
FRESH_TREE="${FRESH_TREE:-$HERE/fresh-tree.sh}"
STATE="$HOME/.local/state/pr-poller"; mkdir -p "$STATE"
LOG="$STATE/poller.log"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }

# Surface a decision to Arthur WITHOUT merging: a single idempotent comment per (pr,sha,kind). The
# poller never clicks — it makes the human touchpoint visible and stops churning.
surface(){ # <pr> <sha> <kind> <message>
  # NB: two `local` statements ON PURPOSE. Bash expands ALL words of a declaration builtin BEFORE
  # executing it, so `${kind}` inside a `m=…` word on the SAME line would be expanded before
  # kind="$3" is assigned → `set -u` abort. Proven live: the first real sweep died here (#116).
  local pr="$1" sha="$2" kind="$3" msg="$4"
  local m="$STATE/surfaced-${pr}-${sha}-${kind}.done"
  [ -f "$m" ] && return 0
  log "SURFACE $SLUG#$pr @ ${sha:0:7} [$kind]: $msg"
  gh pr comment "$pr" --repo "$SLUG" --body "**Poller → Arthur [$kind]:** $msg"$'\n\n<sub>dev-side poller (Step 5); no merge taken — needs your decision.</sub>' >/dev/null 2>&1 && : > "$m"
}

# Resolve the PERSISTENT clone a throwaway worktree bolts off. `~/repos/<repo>` is the fleet convention
# (what fresh-tree.sh + dev-author.sh use); `~/.local/share/<repo>` is fedora-dev's LIVE spec clone, kept
# as a fallback so a box carrying only that clone still fixes. FAIL-CLOSED (rc 1) when neither exists —
# never a cwd guess. NB the pre-#152 code hard-coded `cd $HOME/.local/share/$POLLER_REPO`, which exists
# ONLY for fedora-dev: on the other two swept repos the cd failed, the `&&` short-circuited, the fixer
# NEVER RAN — and the poller still logged its cheerful "new head (if pushed)".
clone_for(){ # <repo> → clone path on stdout, or rc 1
  local c
  for c in "$HOME/repos/$1" "$HOME/.local/share/$1"; do
    [ -d "$c/.git" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Reap a throwaway fixer worktree — Principle 10: the tree is DISPOSABLE and EVERY path reaps it.
# A kill -9 can still leak one; fresh-tree.sh force-removes a stale same-named worktree before
# recreating it (its path is deterministic per repo+branch), so the next fix on that branch self-heals.
reap_tree(){ # <clone> <worktree>
  [ -n "${2:-}" ] || return 0
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || rm -rf "$2"
  git -C "$1" worktree prune >/dev/null 2>&1 || true
}

# Spawn ONE bounded fixer iteration on a RED (or fitness-RETURN) PR. Feature-branch only, no merge.
# <cause> is HOST|FITNESS (from fix_cause) and <reason> is that gate's OWN text — the fixer is told the
# truth about which gate failed and is given the findings it must actually address (R6).
#
# #152 — ISOLATION IS GUARANTEED, NOT HOPED FOR, AND THE HARNESS OWNS GIT. The model gets a FRESH
# WORKTREE checked out on the PR's own gated head; it COMMITS and does nothing else. The SHELL pushes
# (scoped explicitly to the feature ref) and VERIFIES the landing against ORIGIN. Previously the model
# was handed the SHARED LIVE CLONE (checked out on main — the very tree the poller executes from) and
# was told to push: `policy/CLAUDE.md` forbids exactly that ("MUST NOT run PR git in a working tree
# another box or process may be mutating concurrently… use a dedicated git worktree/clone" — the
# 2026-06-28 incident, where a commit in the shared clone landed on a parallel box's branch and merged
# to main). Two live fixers happened to make their own scratch worktrees, but that was the MODEL'S
# discretion; a run that instead did `git checkout -b` in the shared clone would move the live clone's
# HEAD off main underneath the running poller. Now the harness guarantees it — mirroring dev-author.sh,
# the proven pattern (isolate via fresh-tree.sh → model commits, never pushes → harness owns git).
run_fixer(){ # <pr> <headref> <sha> <cause:HOST|FITNESS> <reason>
  local pr="$1" ref="$2" sha="$3" cause="$4" reason="$5"
  # Signature spans BOTH cause and reason: a host RED and a fitness RETURN on the same head are
  # DIFFERENT failures and must not collide onto one no-progress signature.
  local sig; sig="$(printf '%s%s' "$cause" "$reason" | tr -cd '[:alnum:]' | tail -c 40)"
  local sigfile="$STATE/fixsig-${pr}.last" prev=""; [ -f "$sigfile" ] && prev="$(cat "$sigfile")"
  # PROGRESS-BASED STOP (not a count cap): if we already ran a fixer for THIS exact failure signature
  # and the head has NOT advanced past what we fixed, we are not making progress → surface, don't churn.
  local lastfixed="$STATE/fixed-${pr}.sha"; local lf=""; [ -f "$lastfixed" ] && lf="$(cat "$lastfixed")"
  if [ "$sig" = "$prev" ] && [ "$sha" = "$lf" ]; then
    surface "$pr" "$sha" "blocked" "the same failure persists after a fix attempt (no progress) — a human decision is needed. Failing gate: ${cause}. Detail: ${reason:0:400}"
    return 0
  fi

  # 1) ISOLATE — FAIL-CLOSED. No clone / no worktree ⇒ NO fix is attempted. There is deliberately NO
  # shared-clone fallback: running the model in a tree the poller itself executes from is the hazard
  # this exists to remove, so "could not isolate" must surface, never degrade into it.
  local clone wt
  clone="$(clone_for "$POLLER_REPO")" || {
    log "FIX $SLUG#$pr @ ${sha:0:7} — NO CLONE of $POLLER_REPO to isolate from (fail-closed: no fix attempted)"
    surface "$pr" "$sha" "blocked" "the fixer cannot run: no local clone of \`$POLLER_REPO\` to bolt an isolated worktree off. No fix was attempted — the fixer never runs in a shared tree."
    return 0
  }
  # the worktree is checked out on the PR's OWN head (FD_BASE_REF=origin/<ref>), not origin/main:
  # a fix iterates the PR's branch, so its base is that branch as ORIGIN currently holds it.
  wt="$(FD_BASE_REF="origin/$ref" "$FRESH_TREE" "$clone" "$ref" 2>>"$LOG")"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    log "FIX $SLUG#$pr @ ${sha:0:7} — FRESH-TREE FAILED for origin/$ref (fail-closed: no fix attempted)"
    surface "$pr" "$sha" "blocked" "could not create an isolated worktree on \`$ref\` — no fix was attempted (the fixer must never run in the shared clone). A maintainer should check the repo clone."
    return 0
  fi

  # 2) DO NOT FIX AN UN-GATED HEAD. fresh-tree.sh just fetched origin; if the branch moved between the
  # sweep reading $sha and this checkout, the findings we hold describe a head that no longer exists.
  # Skip — the new head carries no verdict yet and re-gates on its own.
  local base; base="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  if [ "$base" != "$sha" ]; then
    log "FIX $SLUG#$pr — BRANCH MOVED (gated ${sha:0:7} ≠ origin/$ref ${base:0:7}) — skipping; the new head re-gates itself"
    reap_tree "$clone" "$wt"
    return 0
  fi

  # markers are written only HERE — once a fix is genuinely being ATTEMPTED on this head. Writing them
  # before the isolation would park a NEVER-ATTEMPTED fix on a false "no progress" on the next sweep.
  printf '%s' "$sig" > "$sigfile"; printf '%s' "$sha" > "$lastfixed"
  log "FIX $SLUG#$pr @ ${sha:0:7} ref=$ref cause=$cause — isolated worktree $wt; spawning bounded fixer (timeout ${FIXER_TIMEOUT}s)"
  fix_in_tree "$pr" "$ref" "$sha" "$cause" "$reason" "$wt"
  # 6) THROWAWAY DISCIPLINE — every path through fix_in_tree returns here, so the tree is always reaped.
  reap_tree "$clone" "$wt"
}

# The bounded fix ITSELF, inside the isolated worktree: model commits → harness pushes → harness verifies
# the landing at ORIGIN → reports the TRUTH. Split out so run_fixer's single reap_tree covers every exit.
fix_in_tree(){ # <pr> <ref> <sha> <cause> <reason> <worktree>
  local pr="$1" ref="$2" sha="$3" cause="$4" reason="$5" wt="$6"
  # The prompt must be TRUTHFUL about which gate failed. Telling a fitness-RETURNed PR that "the host
  # live-gate returned a problem" sent the fixer hunting a build failure that does not exist (the build
  # is GREEN on a RETURN) — it could not progress, and the PR parked on a false 'blocked'.
  local what
  if [ "$cause" = FITNESS ]; then
    what="The build is GREEN. The INDEPENDENT FITNESS REVIEWER returned this head for rework — do NOT go
looking for a build or live-gate failure; there isn't one. Address the reviewer's findings below. They are
the reviewer's PROSE (advisory, not a machine signal): treat them as the requirements to satisfy, use your
own judgment on HOW, and if you believe a finding is wrong, say so via FIXER_BLOCKED rather than
half-fixing it."
  elif [ "$cause" = CONFLICT ]; then
    # The ONE mechanical instruction that matters: MERGE main IN, do not rebase. The harness pushes
    # 'HEAD:refs/heads/<ref>' WITHOUT --force (by design — a push that can only fast-forward can never
    # rewrite or destroy a branch), so a rebase would rewrite this branch's history and the push would
    # be REJECTED as non-fast-forward: the fix would be perfect and land nothing. A merge commit is a
    # descendant of the current head, so it fast-forwards — and the PR is squash-merged at the end, so
    # the merge commit never reaches main's history anyway.
    what="Nothing is broken with your code: the build is GREEN and there are no review findings. This branch
is simply STALE — 'main' moved after it was cut, and GitHub reports it as CONFLICTING, so this PR can never
be merged in its current shape.

Your job is to RECONCILE this branch with CURRENT main, preserving BOTH sides' intent:
  1. 'git fetch origin' then 'git merge origin/main' in this worktree.
  2. Resolve every conflict by KEEPING BOTH intents — the change that landed on main AND this PR's change.
     Read what main's commits actually did before you resolve; never delete another PR's work to make the
     conflict go away, and never revert main.
  3. Commit the merge. Sanity-check the merged tree still does what this PR set out to do.
DO NOT rebase, and do not force anything: the harness pushes this branch fast-forward-only, so a rewritten
history would land NOTHING. A merge commit is what makes it mergeable. If the conflict cannot be resolved
without losing one side's intent, that is a real decision — say so via FIXER_BLOCKED."
  else
    what="The HOST LIVE-GATE returned RED — the candidate failed to build or failed its live probes.
Address the failure below."
  fi
  local prompt
  read -r -d '' prompt <<FIX_EOF || true
You are the fedora-dev fix iteration for PR $SLUG#$pr. You are working ONLY in the current directory: an
ISOLATED git worktree, already checked out on the PR's own branch '$ref' at exactly the head the gate
judged. $what

Your ONE job: make a MINIMAL, correct fix and COMMIT it here, so the gates re-run on the new head.
HARD RULES: the HARNESS owns git — you COMMIT (one or more commits, clear messages) and nothing more.
Do NOT 'git push': the harness pushes '$ref' for you and verifies it landed at origin. Do NOT open a PR,
do NOT merge, NEVER touch main or the merge gate, and never work outside this worktree. If you cannot fix
it (need a decision, missing access, or the approach is wrong), do NOT guess or commit half-work — end
your reply with a line 'FIXER_BLOCKED: <one-line reason>' and commit nothing.

The findings you must address (from the ${cause} gate):

$reason
FIX_EOF
  local out; out="$(cd "$wt" && timeout "$FIXER_TIMEOUT" $POLLER_FIXER "$prompt" 2>&1)"
  local blocked bflag=0
  blocked="$(printf '%s' "$out" | grep -aoE '^FIXER_BLOCKED:.*' | head -1)"; [ -n "$blocked" ] && bflag=1

  # 3) THE HARNESS PUSHES — and only when the model actually committed and did not declare BLOCKED. The
  # refspec is EXPLICIT (HEAD:refs/heads/<ref>): this push can name no destination but the feature ref,
  # least of all main. Then VERIFY AT ORIGIN — the push's exit code is not evidence the fix landed.
  local head prc=0 remote=""
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  if [ "$bflag" = 0 ] && [ -n "$head" ] && [ "$head" != "$sha" ]; then
    git -C "$wt" push -q origin "HEAD:refs/heads/$ref" >/dev/null 2>&1 || prc=1
    remote="$(git -C "$wt" ls-remote origin "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
  fi

  # 4) REPORT THE TRUTH — every outcome is distinct in the log, and every NON-landing one surfaces
  # honestly and pushed nothing. No more "(if pushed)".
  case "$(fix_outcome "$bflag" "$sha" "$head" "$prc" "$remote")" in
    BLOCKED)
      log "FIXER BLOCKED $SLUG#$pr @ ${sha:0:7} — model declared it cannot fix this; nothing pushed"
      surface "$pr" "$sha" "blocked" "fixer reported BLOCKED — ${blocked#FIXER_BLOCKED:}" ;;
    NO_COMMIT)
      log "FIXER NO-COMMIT $SLUG#$pr @ ${sha:0:7} — the fixer committed nothing (timeout / no progress); nothing pushed"
      surface "$pr" "$sha" "blocked" "the fixer run finished without committing anything (it timed out, or could not make progress) — nothing was pushed and the head is unchanged. Failing gate: ${cause}. A human decision is needed." ;;
    PUSH_FAILED)
      log "FIXER PUSH FAILED $SLUG#$pr — committed ${head:0:7} but the push to $ref errored; the fix did NOT land"
      surface "$pr" "$sha" "blocked" "the fixer committed a fix but \`git push\` to \`$ref\` FAILED — the fix did NOT land (check credentials / branch protection). Nothing was merged." ;;
    NOT_LANDED)
      log "FIXER DID NOT LAND $SLUG#$pr — push reported success but origin/$ref holds ${remote:0:7}, not the fix ${head:0:7}"
      surface "$pr" "$sha" "blocked" "the fixer committed \`${head:0:7}\` and the push reported SUCCESS, but \`origin/$ref\` did not advance to it — the fix did NOT land. A human should check the remote / branch protection." ;;
    LANDED)
      log "FIXER LANDED $SLUG#$pr — ${sha:0:7} → ${head:0:7} pushed to $ref and VERIFIED at origin; the new head re-gates on the host's next sweep" ;;
  esac
}

# Retire superseded PRs (see header RETIRE). Trust anchor: only MERGED superseders are scanned (their
# body AS READ AT SCAN TIME — merged = it passed the click; post-merge body edits are trusted under
# the single-operator + App-token threat model, bounded by the scan-once marker and a reversible,
# audited close), and every declared target must still be an OPEN PR in the SAME repo. The list is
# sorted by UPDATE recency (`sort:updated-desc` — a merge updates the PR), so a long-parked PR that
# merges late still enters the window; plain `gh pr list` would order by CREATION date and miss it.
# Each merged PR is scanned exactly once — the marker is written only after a SUCCESSFUL body fetch,
# so a transient list/body failure retries next sweep. Per-target probes/closes are deliberately
# single-shot (no retry machinery): a transient failure there degrades to the status quo — the
# superseded PR stays open for a human, and the log says RETIRE FAILED, never a false success. An
# issue number or an already-closed target fails the OPEN probe → no-op. REOPEN IS DURABLE: a target
# already carrying a `Poller [retire]:` comment is never closed again (GitHub is the durable record,
# so a human reopen survives even total local-state loss), only re-marked locally.
retire_superseded(){
  local merged m
  merged="$(gh pr list --repo "$SLUG" --state merged --search 'sort:updated-desc' --limit "$RETIRE_LOOKBACK" --json number -q '.[].number' 2>/dev/null)"
  [ -n "$merged" ] || return 0
  for m in $merged; do
    local scanned="$STATE/retire-scan-${m}.done"
    [ -f "$scanned" ] && continue
    local body targets t
    body="$(gh pr view "$m" --repo "$SLUG" --json body -q .body 2>/dev/null)" || continue
    targets="$(printf '%s' "$body" | supersede_targets)"
    : > "$scanned"
    [ -n "$targets" ] || continue
    for t in $targets; do
      [ "$t" = "$m" ] && continue                     # never the superseder itself
      local rmark="$STATE/retired-${t}.done" tstate
      [ -f "$rmark" ] && continue
      tstate="$(gh pr view "$t" --repo "$SLUG" --json state -q .state 2>/dev/null)" || continue
      [ "$tstate" = "OPEN" ] || continue              # not an open PR (issue / closed / merged) → no-op
      # reopen guard: a prior poller retirement on this PR means a HUMAN reopened it — never re-close.
      # FAIL-CLOSED: the comments fetch is rc-checked into a variable — a transient fetch failure
      # SKIPS the close (status quo), it must never bypass the guard. grep reads to EOF (no -q) so a
      # large comment blob can't SIGPIPE the pipeline under pipefail.
      local tcomments
      tcomments="$(gh pr view "$t" --repo "$SLUG" --json comments -q '.comments[].body' 2>/dev/null)" || continue
      if printf '%s' "$tcomments" | grep 'Poller \[retire\]:' >/dev/null; then
        : > "$rmark"; continue
      fi
      if gh pr close "$t" --repo "$SLUG" \
           --comment "**Poller [retire]:** #$m (merged) declares \`Supersedes #$t\` — closing this superseded PR. Deterministic retirement (Step 5); reopen if this was wrong (a reopen is durable — the poller never re-closes a PR carrying this comment)." \
           >/dev/null 2>&1; then
        log "RETIRE $SLUG#$t — closed (superseded by merged #$m)"
        : > "$rmark"
      else
        log "RETIRE FAILED $SLUG#$t (superseded by merged #$m) — close error; single-shot, left open for a human"
      fi
    done
  done
}

# ORG-WIDE wrapper (P0 uniform loop): one tick sweeps EVERY apparatus repo through the SAME harness,
# re-setting POLLER_REPO/SLUG per repo. sweep_repo() is the original single-repo body unchanged.
sweep(){ local _r; for _r in $POLLER_REPOS; do POLLER_REPO="$_r"; SLUG="oso-gato/$_r"; sweep_repo; done; }
sweep_repo(){
  log "sweep: $SLUG open PRs (armed=$POLLER_ARMED)"
  retire_superseded
  # BATCHED list: ONE call yields number+ref+sha as TSV — the old per-PR headRefName/headRefOid
  # re-fetches duplicated fields this same list already carried (2 calls/PR saved). Branch names
  # cannot contain tabs, so TSV framing is safe; ref+sha come from the SAME list snapshot as the
  # number (no torn read across a mid-sweep push).
  # `mergeable` rides the SAME list call — a free axis, no extra API cost (#150). It is GitHub's own
  # verdict on whether the PR can merge AT ALL (MERGEABLE|CONFLICTING|UNKNOWN), which neither gate
  # answers: both judge the PR's own head in isolation. Deliberately NOT `mergeStateStatus` — it adds
  # nothing to this routing axis and its GraphQL field requires push access, so a permission hiccup on
  # ANY swept repo would fail the WHOLE list query and take every sweep down with it. One axis, the
  # cheapest one that answers the question.
  local rows
  rows="$(gh pr list --repo "$SLUG" --state open --json number,headRefName,headRefOid,mergeable \
          -q '.[] | "\(.number)\t\(.headRefName)\t\(.headRefOid)\t\(.mergeable)"' 2>/dev/null)" \
    || { log "pr list failed — skipping sweep"; return 0; }
  [ -n "$rows" ] || return 0                       # zero open PRs — quiet (rc 0 distinguishes it)
  # The rows ride FD 3, NOT stdin: loop-body children (the fixer's `claude -p`, fitness-review.sh)
  # may read stdin — off FD 0 they would EAT the remaining rows / hang the sweep. FD 9 is the
  # --watch flock; FD 3 is free.
  local pr ref sha mrg comments host tier fit action files fitraw amrc fp sfile scount sprev sres
  while IFS=$'\t' read -r -u 3 pr ref sha mrg; do
    [ -n "$pr" ] || continue
    [ -n "$sha" ] || { log "#$pr: no head sha — skip"; continue; }
    mrg="${mrg:-UNKNOWN}"                          # absent/blank ⇒ UNKNOWN ⇒ plan() waits (fail-closed)
    # newest host verdict authored by the trusted host bot ONLY (ignore anyone else) — bound to THIS
    # head's FULL sha, and read from the comment's FIRST LINE only (the machine-owned header carries
    # "<repo> @ <full-sha>"): a fresh, ungated head must never inherit a previous head's GREEN
    # (proven live: #117 read stale GREEN across two pushes), a 7-hex prefix would be grindable, and
    # embedded candidate-log prose must never select or decide (G2, mirrored from auto-merge.sh).
    comments="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body | split(\"\n\")[0] | select(contains(\"@ $sha\"))" 2>/dev/null)"
    host="$(printf '%s' "$comments" | host_verdict)"; host="${host:-NONE}"
    # dedup: act on each (pr,sha,host-verdict) at most once for the terminal actions; REVIEW/FIX manage
    # their own re-entry (fitness marker; progress signature), so only gate the whole sweep-action here.
    # the marker key spans MERGEABILITY too (#150): a PR parked on a GREEN decision whose base then
    # moves under it is a DIFFERENT state (MERGEABLE → CONFLICTING), and must re-route to the fixer
    # rather than stay parked on a decision that can no longer be executed.
    local done="$STATE/acted-${pr}-${sha}-${host}-${mrg}.done"
    # TERMINAL-STATE SKIP: once (pr,sha,GREEN) has ACTED (PRESENT posted / dry-run decided / merge
    # attempted), no further action exists for this tuple — the case arms below would only hit
    # their own `[ -f "$done" ] && continue`. Skip the GREEN-moment fetches too, so a PARKED GREEN
    # PR (awaiting the click; dry-run while disarmed) costs ONE comments call per sweep — this is
    # what makes the cost formula above true. A new head sha or verdict keys a NEW marker; a
    # REVIEW-pending PR never holds this marker (fitness re-entry unaffected); FIX never writes it.
    # NB (pre-existing semantics, unchanged): a dry-run marker also blocks a later ARMED merge of
    # the same (pr,sha) — arming re-routes only new heads; part of the #96 flip discussion.
    [ -f "$done" ] && { log "#$pr ${sha:0:7} host=$host mergeable=$mrg — acted, parked"; continue; }
    # BATCHED gate reads: plan() consults tier + fitness ONLY on GREEN — so fetch them ONLY then
    # (a NOOP/RED PR costs exactly one comments call per sweep). Both GREEN-moment fetches are
    # rc-checked and SKIP this PR for THIS sweep on a transient failure (retry next sweep) — they
    # must never misroute: a failed files fetch defaulting to tier=A would PRESENT an
    # auto-mergeable PR and stick via the acted marker; a failed fitness fetch reading as NONE
    # would spuriously re-run the review harness. rc is only distinguishable on an UNPIPED
    # capture, hence the fetch-to-var-then-filter shape.
    # …and ONLY while the PR is actually MERGEABLE: a CONFLICTING PR routes to the reconcile-fixer on
    # the mergeability axis alone (plan()/fix_cause() ignore tier + fitness there), so fetching them
    # would be two API calls per sweep spent on a decision they cannot influence — and a fitness verdict
    # posted against a head the reconcile is about to rewrite dies with it anyway.
    tier=""; fit="NONE"
    if [ "$host" = "GREEN" ] && [ "$mrg" = "MERGEABLE" ]; then
      files="$(gh pr view "$pr" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null)" \
        || { log "#$pr: files fetch failed — skip this sweep, retry next"; continue; }
      # newline-TERMINATE the captured paths ($(…) strips the final newline; an unterminated last
      # line would be dropped by a plain while-read gather — the single-file PR would classify
      # from ZERO paths). The [ -n ] guard keeps a zero-file PR fail-closed to A: a bare
      # printf '%s\n' "" would feed one EMPTY line and flip it to all-docs → C.
      tier="$([ -n "$files" ] && printf '%s\n' "$files" | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"
      if [ -n "$FITNESS_LOGIN" ]; then
        # fitness verdicts are also per-head — LINE 1 of the fitness comment carries
        # "… VERDICT X — head <full-sha>" (bin/fitness-review.sh); bind to THIS head's FULL sha on
        # that machine-owned line only, so a stale PASS/RETURN from a previous head — or an anchor
        # planted in the reviewer's rationale prose — never routes the new one.
        fitraw="$(gh pr view "$pr" --repo "$SLUG" --json comments \
               -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body | split(\"\n\")[0] | select(contains(\"head $sha\"))" 2>/dev/null)" \
          || { log "#$pr: fitness-comments fetch failed — skip this sweep, retry next"; continue; }
        fit="$(printf '%s' "$fitraw" | fitness_verdict)"; fit="${fit:-NONE}"
      fi
    fi
    action="$(plan "$host" "$tier" "$fit" "$POLLER_ARMED" "$mrg")"
    log "#$pr ${sha:0:7} host=$host tier=$tier fitness=$fit mergeable=$mrg ⇒ $action"

    # NO SILENT SPINNING (#150 req 4 / R13). Fingerprint everything we observed + what we decided; if
    # that has not changed for $STALL_SWEEPS consecutive sweeps, this PR is not moving and the poller
    # SAYS SO (once per head — surface() is idempotent). It keeps routing normally afterwards: the point
    # is that a stuck PR is never silent, not that the loop stops. Any change — a new head, a verdict, a
    # mergeability that finally computes — resets the count, so a healthy PR never trips it.
    fp="$sha|$host|$fit|$mrg|$action"
    sfile="$STATE/stall-${POLLER_REPO}-${pr}"
    scount=0; sprev=""
    [ -f "$sfile" ] && read -r scount sprev < "$sfile"
    sres="$(stall_state "$fp" "$sprev" "$scount" "$STALL_SWEEPS")"
    printf '%s %s\n' "${sres% *}" "$fp" > "$sfile"
    if [ "${sres#* }" = STALL ]; then
      log "#$pr ${sha:0:7} STALLED — ${sres% *} consecutive sweeps with no state change ($fp)"
      surface "$pr" "$sha" "stalled" "this PR has not changed state for ${sres% *} consecutive poller sweeps (host=$host, fitness=$fit, mergeable=$mrg ⇒ $action). The loop is re-examining it and getting nowhere — it cannot make progress on its own. A human decision is needed."
    fi

    case "$action" in
      NOOP) : ;;
      FIX)
        # R6 — FINDINGS ARE GENERATIVE. plan() routes FIX from THREE causes; derive the reason from the
        # one that ACTUALLY fired — for the two GATE causes from that gate's OWN COMMENT BODY, and for
        # CONFLICT (#150) from GitHub's own mergeability verdict, which no gate ever comments on.
        #
        # TRUST BOUNDARY (G2), and it holds for both gate arms: the VERDICT is read from LINE 1 ONLY (the
        # machine-owned header, sha-bound — that is what routed us here and what $comments holds). The
        # fetches below pull the gate's FULL comment body purely as PROMPT material for the fixer, bound
        # to THIS head's sha + that gate's own login, so prose can never flip a gate — it can only say
        # what to fix, and a stale verdict's text can never drive a fresh head.
        #
        # NB the reason CANNOT come from $comments: that stream is line-1-only (see the sha-binding
        # fetch above), so grepping it yields the verdict HEADER and never the failure detail. That was
        # the whole defect — a fitness RETURN found no host 'VERDICT RED' line at all and fell back to a
        # canned "host live-gate RED" (sending the fixer after a build failure that never happened),
        # while a host RED handed the fixer its own verdict token and called it "the findings".
        local cause reason; cause="$(fix_cause "$host" "$fit" "$mrg")"
        case "$cause" in
          CONFLICT)
            # The one FIX cause with NO gate comment to quote: the finding is GitHub's own mergeability
            # verdict, and the poller states it itself rather than inventing a gate failure. Truthful by
            # construction — no fetch, nothing to forge.
            reason="GitHub reports this PR as **mergeable = CONFLICTING**: the branch conflicts with \`main\` as
origin currently holds it. Both gates are satisfied — the host live-gate is GREEN and there are no review
findings — because both judge THIS HEAD IN ISOLATION, where nothing is wrong. The MERGE is what is
impossible: \`main\` moved after this branch was cut, so this PR can never merge in its current shape.
Reconcile it with current \`main\`, preserving both sides' intent (see the instructions above)." ;;
          HOST)
            # `contains`, NOT `startswith`: the host header is markdown-bold (`**Host live-gate …**`),
            # so a startswith("Host live-gate") match silently returns EMPTY. Verified against the live
            # comment. The candidate log's failure detail sits at the END of the body → tail, not head.
            reason="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                       -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body
                           | select(split(\"\n\")[0] | contains(\"@ $sha\") and contains(\"VERDICT RED\"))" \
                       2>/dev/null | tail -c 6000)"
            reason="${reason:-the host live-gate reported RED; see the host verdict comment on the PR}" ;;
          FITNESS)
            reason="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                       -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body
                           | select(startswith(\"Fitness review: VERDICT RETURN\")) | select(contains(\"head $sha\"))" \
                       2>/dev/null | head -c 6000)"
            reason="${reason:-the independent fitness review RETURNed this head; see its verdict comment on the PR}" ;;
          *)
            log "#$pr: FIX routed with no known cause (host=$host fitness=$fit mergeable=$mrg) — refusing to invent a reason"
            surface "$pr" "$sha" "blocked" "the poller routed this PR to the fixer but cannot tell what failed (host=$host, fitness=$fit, mergeable=$mrg) — a human decision is needed."
            continue ;;
        esac
        run_fixer "$pr" "$ref" "$sha" "$cause" "$reason"
        ;;
      REVIEW)
        [ -f "$done" ] && continue
        log "#$pr GREEN + unreviewed → running fitness harness"
        FITNESS_LOGIN="$FITNESS_LOGIN" LG_HOST_LOGIN="$LG_HOST_LOGIN" "$HERE/fitness-review.sh" --post "$POLLER_REPO" "$pr" \
          && log "#$pr fitness posted — next sweep routes on it" \
          || log "#$pr fitness harness declined/failed (fail-closed: no PASS ⇒ no merge)"
        ;;
      MERGE|MERGE_DRYRUN)
        [ -f "$done" ] && continue
        local flag=""; [ "$action" = MERGE ] && flag="--commit"
        log "#$pr GREEN+PASS+MERGEABLE → auto-merge.sh $flag"
        # a REFUSE here (rc 1) despite GREEN+PASS routing means the MERGER disagrees with the
        # poller's reads — misconfigured anchors, same-identity while armed, or a gate its stricter
        # parse rejects. SURFACE it (idempotent) so a quietly dead merge path reaches Arthur instead
        # of sitting parked in poller.log; the marker lands only once surfacing succeeded.
        LG_HOST_LOGIN="$LG_HOST_LOGIN" FITNESS_LOGIN="$FITNESS_LOGIN" "$HERE/auto-merge.sh" $flag "$POLLER_REPO" "$pr" | tee -a "$LOG"
        amrc=$?     # pipefail is on: auto-merge's rc survives the tee
        case "$amrc" in
          0) : > "$done" ;;
          3)
            # UNMERGEABLE (#150) — categorically NOT a gate refusal: the gates said yes and the merge is
            # mechanically impossible (the base moved between this sweep's read and the merge attempt).
            # DELIBERATELY NOT PARKED: parking it here would re-create the exact silent spin this fixes —
            # a PR that can never merge, sitting on a terminal marker with no fixer and no question. The
            # next sweep reads mergeable=CONFLICTING from GitHub and routes it to the reconcile-fixer.
            log "#$pr UNMERGEABLE — auto-merge refused a MECHANICALLY IMPOSSIBLE merge; the next sweep routes it to the reconcile-fixer"
            surface "$pr" "$sha" "unmergeable" "both gates PASS but the merge is MECHANICALLY IMPOSSIBLE (GitHub reports the branch unmergeable against \`main\`) — the base moved under this PR. No merge was attempted; the poller is routing it to the reconcile-fixer, and will say so again if that cannot make progress." ;;
          *)
            surface "$pr" "$sha" "refused" "auto-merge REFUSED despite GREEN+PASS routing — trust-anchor/SoD config mismatch or a gate its stricter parse rejects (see poller.log)." \
              && : > "$done" ;;
        esac
        ;;
      PRESENT)
        # the acted marker is gated on surface()'s rc: a FAILED comment POST must NOT park the
        # tuple (the terminal-state skip would otherwise silence the human touchpoint forever
        # after one throttled POST — comment CREATION rate-limits while reads still succeed).
        # surface() returns 0 on its already-surfaced early-exit, so idempotence is preserved.
        surface "$pr" "$sha" "review" "GREEN PR needs your decision (tier=$tier, fitness=$fit). Present for a clickable merge — the poller does not auto-merge this." \
          && : > "$done"
        ;;
    esac
  done 3<<< "$rows"
}

case "${1:-}" in
  --once) sweep;;
  --watch)
    exec 9>"$STATE/poller.lock"
    flock -n 9 || { echo "another pr-poller --watch holds the lock; exiting" >&2; exit 0; }
    trap 'log "poller stopping (signal)"; exit 0' TERM INT HUP
    log "pr-poller --watch up (repo=$SLUG interval=${POLL_INTERVAL}s armed=$POLLER_ARMED)"
    while :; do sweep || log "sweep error (continuing)"; sleep "$POLL_INTERVAL"; done
    ;;
  *) echo "usage: pr-poller.sh --once | --watch | --selftest" >&2; exit 2;;
esac
