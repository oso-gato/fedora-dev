#!/usr/bin/env bash
# dev-author.sh — the AUTONOMOUS FEATURE-AUTHOR (apparatus spec fedora-dev#135 R3 / work-plan P3).
#
# The keystone of the dev engine: turn a numbered BACKLOG FEATURE ISSUE into a validated, live-gated,
# auto-merging PR with NO human in the loop. It is the symmetric partner of the poller's RED-fixer —
# the poller FIXES an existing PR; this AUTHORS a new one — and it hands its result straight into the
# proven pipeline (host live-gate → fitness → poller auto-merge), so it writes no merge logic itself.
#
# CONTROL FLOW (deterministic plain shell; the model runs ONLY the bounded judgment step):
#   1. Guard: the issue is an open, `backlog`-shaped feature ticket; not already authored (idempotent
#      replay via a per-(repo,issue) marker + an "is there already an open PR for this issue" check).
#   2. Isolate: `bin/fresh-tree.sh <repo> <branch>` → a fresh git worktree off CURRENT origin/main
#      (never the shared clone — the 2026-06-28 cross-branch-leak incident makes this mandatory).
#   3. Author: ONE bounded `claude -p` run implements the feature IN that worktree and commits. It is
#      told to NEVER push, NEVER merge, NEVER touch main/the merge gate — the harness owns git plumbing.
#      Promptlessness is 100% ambient (the box's managed-settings: Bash(*) + defaultMode default); NO
#      permission flags are passed. Bounded by `timeout` (R13).
#   4. Gate the author's own work IN-BOX before spending a host build: `bin/validate.sh` (build +
#      assembly + lint, the nested-engine ceiling). RED in-box → surface BLOCKED, do not push noise.
#   5. Hand off: push the branch, open the PR (draft at first push per R3, then mark ready), label it
#      `live-validate`, and confirm the ship with ONE best-effort comment on the backlog issue (R5
#      audit loop — the ticket shows its own outcome, symmetric with the BLOCKED question below).
#      The host live-gate + fitness + poller take it from there — zero human.
#   6. BLOCKED (R13): if the model can't implement it (needs a decision / missing access / wrong
#      approach) it ends with `AUTHOR_BLOCKED: <reason>`; the harness posts that as a dev-task QUESTION
#      comment on the ISSUE (never an approval request) and exits non-zero. No-progress (no commit and
#      not explicitly blocked) is treated the same way — surfaced, never silently retried into noise.
#
# STATE lives only in GitHub + a tiny local marker dir (idempotent replay), per R5.
#
#   dev-author.sh <repo> <issue#>     author one backlog feature (repo = bare name under ~/repos or a path)
#   dev-author.sh --selftest          exercise the pure helpers (no gh / claude / git / network)
#
# ENV knobs (all defaulted):
#   ORG               GitHub org (default oso-gato)
#   AUTHOR_CLAUDE     the bounded author command (default "claude -p"); overridable for --selftest/CI
#   AUTHOR_TIMEOUT    max seconds for the ONE author run (default 3600; authoring is heavier than a fix)
#   AUTHOR_LABEL      the label that enrolls the PR in the host live-gate (default live-validate)
#   BACKLOG_LABEL     the label that marks an issue an actionable feature (default backlog)
#   DEV_AUTHOR_STATE  marker dir (default $HOME/.local/state/dev-author)
set -uo pipefail

ORG="${ORG:-oso-gato}"
AUTHOR_CLAUDE="${AUTHOR_CLAUDE:-claude -p}"
AUTHOR_TIMEOUT="${AUTHOR_TIMEOUT:-3600}"
AUTHOR_LABEL="${AUTHOR_LABEL:-live-validate}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
STATE="${DEV_AUTHOR_STATE:-$HOME/.local/state/dev-author}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# The two sibling tools this harness drives — overridable so the mock dry-run can exercise the REAL
# control flow with stubs (validate at the execution boundary, not just the pure helpers).
FRESH_TREE="${FRESH_TREE:-$HERE/fresh-tree.sh}"
VALIDATE="${VALIDATE:-$HERE/validate.sh}"

log(){ printf '[%s] dev-author: %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo --:--:--)" "$*" >&2; }

# ---- PURE HELPERS (no side effects; --selftest exercises exactly these) ----------------------------

# branch_for <issue#> <title> → a safe feature-branch name, deterministic per issue.
branch_for(){
  local n="$1" title="$2" slug
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
          | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40 | sed 's/-$//')"
  [ -n "$slug" ] || slug="feature"
  printf 'feat/%s-%s' "$n" "$slug"
}

# extract_sentinel <text> → the LAST anchored AUTHOR_DONE:/AUTHOR_BLOCKED: line (both-end rigor so the
# model quoting the instruction template cannot self-trigger a false token; matches fitness-review's
# discipline). Prints "DONE <rest>" or "BLOCKED <rest>" or nothing.
extract_sentinel(){
  printf '%s' "$1" | grep -aoE '^AUTHOR_(DONE|BLOCKED):.*$' | tail -1 \
    | sed -E 's/^AUTHOR_(DONE|BLOCKED): */\1 /'
}

# should_author <issue-state> <has-open-pr:0|1> <marker-exists:0|1> <has-backlog-label:0|1>
#   → prints ACT | SKIP:<why>. Fail-closed: only a genuinely-open, BACKLOG-labelled, not-yet-authored,
#   no-existing-PR issue is actioned. The backlog-label gate is what makes the author pick up ONLY the
#   planner's actionable feature tickets (R2) — never an arbitrary open issue.
should_author(){
  local st="$1" haspr="$2" marked="$3" backlog="$4"
  [ "$st" = OPEN ]    || { printf 'SKIP:issue-not-open(%s)' "$st"; return; }
  [ "$backlog" = 1 ]  || { printf 'SKIP:not-backlog-labelled'; return; }
  [ "$marked" = 0 ]   || { printf 'SKIP:already-authored'; return; }
  [ "$haspr" = 0 ]    || { printf 'SKIP:open-pr-exists'; return; }
  printf 'ACT'
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== branch_for =="
  ck "slugifies + prefixes"      "$(branch_for 42 'Add the WebP probe!')" "feat/42-add-the-webp-probe"
  ck "collapses + trims dashes"  "$(branch_for 7 '  Fix::  the   gate  ')" "feat/7-fix-the-gate"
  ck "empty title → feature"     "$(branch_for 9 '')" "feat/9-feature"
  ck "caps length"               "$(branch_for 1 "$(printf 'x%.0s' {1..80})")" "feat/1-$(printf 'x%.0s' {1..40})"
  echo "== extract_sentinel (both-end anchored; last wins; template-quote inert) =="
  ck "done token"                "$(extract_sentinel $'blah\nAUTHOR_DONE: shipped it')" "DONE shipped it"
  ck "blocked token"             "$(extract_sentinel $'AUTHOR_BLOCKED: need a decision')" "BLOCKED need a decision"
  ck "last wins"                 "$(extract_sentinel $'AUTHOR_BLOCKED: early\nAUTHOR_DONE: final')" "DONE final"
  ck "mid-line quote is inert"   "$(extract_sentinel 'the rule says end with AUTHOR_DONE: <x>')" ""
  ck "indented quote is inert"   "$(extract_sentinel $'  AUTHOR_DONE: indented')" ""
  ck "no token → empty"          "$(extract_sentinel 'just prose, no verdict')" ""
  echo "== should_author (fail-closed gating; backlog-labelled required) =="
  ck "open+backlog+nopr+unmarked → ACT" "$(should_author OPEN 0 0 1)" "ACT"
  ck "closed issue → SKIP"        "$(should_author CLOSED 0 0 1)" "SKIP:issue-not-open(CLOSED)"
  ck "not backlog-labelled → SKIP" "$(should_author OPEN 0 0 0)" "SKIP:not-backlog-labelled"
  ck "already authored → SKIP"    "$(should_author OPEN 0 1 1)" "SKIP:already-authored"
  ck "existing PR → SKIP"         "$(should_author OPEN 1 0 1)" "SKIP:open-pr-exists"
  echo; echo "dev-author selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- LIVE PATH -------------------------------------------------------------------------------------
REPO="${1:?usage: dev-author.sh <repo> <issue#>   |   dev-author.sh --selftest}"
ISSUE="${2:?usage: dev-author.sh <repo> <issue#>}"
SLUG="$ORG/$REPO"

# R16 OPERATING SCOPE (#167): authoring cuts a worktree, spawns a model and pushes a branch AGAINST
# a repo — an out-of-scope repo gets NONE of that: nothing read, nothing posted (not even the
# BLOCKED question — that too is an action on the foreign repo), one loud log line. rc 2, the same
# posts-nothing class as an unreadable issue (dev-loop's run_class treats it as RETRY, but its own
# scope gate refuses the whole pass first — this is the belt for a direct invocation). Any non-zero
# reader rc (127 included) refuses (fail-closed).
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
"$REPO_SCOPE" check "$REPO" 2>/dev/null \
  || { log "R16 SCOPE: repo '$REPO' is outside the maintainer-confirmed operating scope — refusing to author (nothing read, nothing posted)"; exit 2; }

mkdir -p "$STATE"
marker="$STATE/${REPO}-${ISSUE}.done"

# surface a dev-task QUESTION on the ISSUE — a request for a decision, NEVER an approval/merge button.
surface_blocked(){ # <reason>
  local body="**dev-author → needs a decision (BLOCKED):** $1"$'\n\n<sub>autonomous feature-author (R3). No PR opened / no merge taken — this is a dev-task question, not an approval request.</sub>'
  gh issue comment "$ISSUE" --repo "$SLUG" --body "$body" >/dev/null 2>&1 || log "WARN: could not post BLOCKED comment"
}

# 1) GUARD — read issue state + whether a PR already references it; decide fail-closed.
# ONE structured read of state + backlog-label + title, each on its OWN line (jq comma operator; a
# GitHub issue title carries no newline, so line-framing is safe), plus one read of the multi-line
# body — parsed by gh's own jq, never by grep. The backlog-label gate resolves from BACKLOG_LABEL
# (no dead knob) and is fail-closed.
meta="$(gh issue view "$ISSUE" --repo "$SLUG" --json state,labels,title \
  -q '.state, (if any(.labels[].name; . == "'"$BACKLOG_LABEL"'") then "1" else "0" end), .title' 2>/dev/null)" \
  || { log "cannot read $SLUG#$ISSUE (fail-closed) — aborting"; exit 2; }
{ read -r state; read -r hasbacklog; read -r title; } <<<"$meta"
body="$(gh issue view "$ISSUE" --repo "$SLUG" --json body -q .body 2>/dev/null)"
haspr=0
if gh pr list --repo "$SLUG" --state open --search "$ISSUE in:body" --json number -q '.[].number' 2>/dev/null | grep -q .; then haspr=1; fi
marked=0; [ -f "$marker" ] && marked=1
decision="$(should_author "${state:-UNKNOWN}" "$haspr" "$marked" "${hasbacklog:-0}")"
case "$decision" in
  ACT) : ;;
  *) log "not authoring $SLUG#$ISSUE — $decision"; exit 0 ;;
esac

# 2) ISOLATE — a fresh worktree off current origin/main (mandatory; never the shared clone).
branch="$(branch_for "$ISSUE" "$title")"
log "authoring $SLUG#$ISSUE '$title' on $branch"
WT="$("$FRESH_TREE" "$REPO" "$branch" 2>/dev/null)" \
  || { log "fresh-tree failed for $REPO/$branch (fail-closed)"; surface_blocked "could not create an isolated worktree — a maintainer should check the repo clone."; exit 3; }
base_sha="$(git -C "$WT" rev-parse HEAD)"

# 3) AUTHOR — ONE bounded claude -p run implements the feature and COMMITS (no push, no PR, no merge).
read -r -d '' prompt <<AUTHOR_EOF || true
You are the fedora-dev autonomous FEATURE-AUTHOR. Implement the feature described by GitHub issue
$SLUG#$ISSUE, working ONLY in the current directory (an isolated git worktree on branch '$branch').

FEATURE (issue #$ISSUE): $title

$body

RULES (hard):
- Implement the SMALLEST correct change that satisfies the issue. Follow the repo's CLAUDE.md build
  principles and existing conventions. Add/adjust tests or a --selftest where the repo expects them.
- COMMIT your work in this worktree (one or more commits, clear messages). Do NOT 'git push'. Do NOT
  open a PR. Do NOT merge, and NEVER touch main or the merge gate — the harness owns all of that.
- Validate what you can locally (bash -n, a --selftest, a scratch build) before finishing.
- If you genuinely cannot implement it — it needs a human decision, missing access, or the issue's
  approach is wrong — do NOT guess or commit half-work. End your reply with exactly:
      AUTHOR_BLOCKED: <one concise reason>
  and commit nothing. Otherwise, when the implementation is committed, end with exactly:
      AUTHOR_DONE: <one-line PR title>
AUTHOR_EOF

log "spawning bounded author (timeout ${AUTHOR_TIMEOUT}s, prompt ${#prompt} bytes)"
# THE PROMPT RIDES STDIN, NEVER ARGV (#155). The kernel caps a SINGLE argv argument at MAX_ARG_STRLEN
# (32 pages = 131072 bytes) independently of the far larger total ARG_MAX, so an argv prompt is a latent
# E2BIG — and this one embeds an ISSUE BODY, which no one bounds: a long spec would simply fail to EXEC
# and the author would never run (that is exactly how the fitness reviewer died on #154). stdin has no
# such ceiling. It also SUBSUMES the old `</dev/null`: `claude -p` drains whatever stdin it inherits to
# EOF, and dev-loop drives this script per-issue — off FD 0 the first author would swallow the rest of
# the backlog. Now the model's stdin IS the prompt pipe, so there is nothing else there to swallow.
# (dev-loop still feeds its list on FD 3 and closes stdin: both ends of that hole stay shut.)
# `set +o pipefail` inside the subshell (it cannot leak out) keeps $rc the MODEL's own — with pipefail
# on, a model that exits 0 without draining its prompt would make printf die of SIGPIPE and report 141.
#
# THE ISOLATION IS FAIL-CLOSED, AND THE `cd` IS PART OF IT — the model runs in its OWN worktree or it
# does NOT run. `cd "$WT" && set +o pipefail; <pipe>` does NOT say that: `&&` binds to `set` alone and
# the `;` ends the list, so the pipeline runs ANYWAY in the CALLER'S cwd — under dev-loop, the shared
# clone — with a prompt telling it to implement and commit. That is the 2026-06-28 cross-branch-leak
# hazard `policy/CLAUDE.md` names by date. The BRACE GROUP binds the whole body to the cd. And a cd that
# fails must SAY SO rather than be read downstream as a model that ran and committed nothing (the
# no-progress surface below) — the author never STARTED, which is an infrastructure fault, not a stuck
# feature. Same rc 3 as a failed fresh-tree: an unusable worktree, a question posted, no PR opened.
# `( cd )` tests what the real cd does (a directory can exist and still be unenterable).
if ! ( cd "$WT" ) 2>/dev/null; then
  log "cannot enter isolated worktree '$WT' (fail-closed) — the author was NOT run"
  surface_blocked "the isolated worktree for this feature could not be entered (\`$WT\`), so the author was **never run** — no code was written and no PR was opened. A maintainer should check the repo clone on the dev box. (Fail-closed by design: the author is NEVER run outside its own worktree.)"
  exit 3
fi
out="$(cd "$WT" && { set +o pipefail; printf '%s' "$prompt" | timeout "$AUTHOR_TIMEOUT" $AUTHOR_CLAUDE 2>&1; })"; rc=$?
[ "$rc" = 124 ] && log "author run hit the ${AUTHOR_TIMEOUT}s timeout"
sentinel="$(extract_sentinel "$out")"
head_sha="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
committed=0; [ -n "$head_sha" ] && [ "$head_sha" != "$base_sha" ] && committed=1

# 4) DECIDE on the author's outcome — BLOCKED / no-progress surface as a dev-task question.
case "$sentinel" in
  BLOCKED*)
    log "author reported BLOCKED"
    surface_blocked "${sentinel#BLOCKED }"
    # leave the worktree — fresh-tree.sh reaps a stale same-named worktree on the next attempt.
    exit 4 ;;
esac
if [ "$committed" = 0 ]; then
  log "author produced no commit and no explicit block — surfacing as no-progress"
  surface_blocked "the author run finished without committing an implementation (timeout or unable to make progress). A maintainer should refine the issue or check the environment."
  exit 5
fi

# 4b) IN-BOX GATE — cheap build+assembly+lint before spending a host build. RED here → surface, no push.
log "in-box validate.sh before push…"
if ! ( cd "$WT" && DISCARD=1 "$VALIDATE" "$WT" >/dev/null 2>&1 ); then
  log "in-box validate RED — not pushing; surfacing for iteration"
  surface_blocked "the authored change failed in-box validation (build/assembly/lint). Re-run or refine the issue; the branch '$branch' holds the attempt."
  exit 6
fi
log "in-box validate GREEN"

# 5) HAND OFF — push, open the PR (draft at first push per R3 → ready), label live-validate.
git -C "$WT" push -q origin "$branch" \
  || { log "push failed (fail-closed)"; surface_blocked "authored '$branch' but the push failed — a maintainer should check credentials/network."; exit 7; }

pr_title="AUTHOR_DONE"; [ "${sentinel#DONE }" != "$sentinel" ] && pr_title="${sentinel#DONE }"
[ -n "$pr_title" ] && [ "$pr_title" != "AUTHOR_DONE" ] || pr_title="$title"
pr_body="Autonomously authored by \`dev-author.sh\` (R3) for issue #$ISSUE.

Closes #$ISSUE

<sub>Draft-opened at first push, in-box validated GREEN, then marked ready + labelled \`$AUTHOR_LABEL\` to enrol in the host live-gate → fitness → poller pipeline. No human in this loop.</sub>"
bodyfile="$(mktemp)"; printf '%s' "$pr_body" > "$bodyfile"

# draft at first push (R3: state visible in GitHub immediately, resumable), then flip to ready so the
# poller — which merges ready PRs — can act on it.
pr_url="$(gh pr create --repo "$SLUG" --head "$branch" --base main --title "$pr_title" --body-file "$bodyfile" --draft 2>/dev/null)"
rm -f "$bodyfile"
[ -n "$pr_url" ] || { log "PR create failed (fail-closed)"; surface_blocked "authored + pushed '$branch' but opening the draft PR failed — a maintainer should open it."; exit 8; }
pr_num="${pr_url##*/}"
gh pr ready "$pr_num" --repo "$SLUG" >/dev/null 2>&1 || log "WARN: could not mark #$pr_num ready"
gh pr edit "$pr_num" --repo "$SLUG" --add-label "$AUTHOR_LABEL" >/dev/null 2>&1 || log "WARN: could not add $AUTHOR_LABEL to #$pr_num"

# R5 audit loop — confirm the ship ON the backlog issue (symmetric with surface_blocked). Best-effort
# BY DESIGN: the PR is already the source of truth, so a failed comment logs a WARN, never fails the run.
ship_body="**dev-author → shipped:** authored and enrolled #$pr_num in the live-gate → fitness → poller pipeline. $pr_url"$'\n\n<sub>autonomous feature-author (R3). No merge taken — the two-gate pipeline decides.</sub>'
gh issue comment "$ISSUE" --repo "$SLUG" --body "$ship_body" >/dev/null 2>&1 || log "WARN: could not post shipped comment on #$ISSUE"

: > "$marker"   # idempotent replay guard — this issue is now authored
log "AUTHORED $SLUG#$ISSUE → $pr_url (labelled $AUTHOR_LABEL; the pipeline takes it from here)"
printf '%s\n' "$pr_url"
