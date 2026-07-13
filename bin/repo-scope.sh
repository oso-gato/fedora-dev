#!/usr/bin/env bash
# repo-scope.sh — the R16 OPERATING-SCOPE reader (#167): the apparatus acts ONLY on a
# maintainer-confirmed repo set — scope expansion is UNSAFE without it.
#
# THE INCIDENT THIS FORMALIZES (2026-07-13): a one-line PR (#165) enrolled a repo the maintainer had
# explicitly scoped away from this apparatus into the poller's default sweep — and NO layer stopped
# it, because the concept of an operating scope existed nowhere in the machinery or the law. The
# host gate passed it (it builds), the fitness gate passed it (nothing in Q1/Q2/Q3 encoded WHICH
# repos the apparatus may act on), the poller zero-click merged it into its own control plane, then
# swept the foreign repo, pushed a bot commit onto its feature branch and squash-merged its PR — all
# out of scope, all "working as built".
#
# THE AUTHORITY is the versioned config `policy/scope.conf` (R15 config-as-code — never a hardcoded
# default buried in a script): one bare repo name per line, comments/#/blank stripped, invalid lines
# IGNORED (they can narrow the effective scope, never widen it). Scope is PER-OBJECTIVE, not
# permanent; ADDING a repo is maintainer-gated structurally (bin/fitness-review.sh RETURNs an
# unconfirmed addition — R16 rule 3), REMOVING one needs no ceremony (narrowing is always safe).
#
# FAIL DIRECTION (R16 rule 4): an UNREADABLE config means NO action on anything but the apparatus's
# OWN repos ($SCOPE_OWN — fedora-dev, the dev box's repo, + fedora-bootstrap, the control repo): the
# loop can still fix/ship itself and reach its control issue, but can never wander. A READABLE but
# EMPTY scope denies EVERYTHING (a maintainer who empties the file means it). A MISSING READER is
# stricter still: every caller treats a non-zero rc — 127 included — as "no action" (the
# bin/fleet-halt.sh contract), so a broken install freezes all scoped action by construction.
#
# CONTRACT (what every caller relies on):
#   repo-scope.sh check <repo>   rc 0 = IN scope (the ONLY "act") · rc 3 = OUT of scope ·
#                                rc 4 = out of scope under the unreadable-config fallback ·
#                                rc 2 = usage. Detail rides stderr; callers emit their OWN single
#                                loud skip line and act on the rc alone.
#   repo-scope.sh list           the actionable set, one per line (unreadable config → $SCOPE_OWN,
#                                warned on stderr; rc 0 either way — the fallback IS the answer).
#   repo-scope.sh diff-adds      unified diff on stdin → the repo names NET-ADDED to the scope
#                                config by that diff (added minus removed — a moved/reordered line
#                                is not an expansion), one per line. Empty = no expansion. Used by
#                                bin/fitness-review.sh's deterministic R16 gate.
#   repo-scope.sh --selftest     exercise the pure helpers (no gh / network / clone).
#
# CALLERS (R16 rule 4 — every actuator): bin/pr-poller.sh (sweep list + the fixer belt),
# bin/fitness-review.sh (before reviewing + the diff-adds gate), bin/auto-merge.sh (before merging),
# bin/dev-plan.sh / dev-loop.sh / dev-author.sh (before planning/authoring), bin/host-ticket.sh
# (before filing) and bin/host-refresh.sh (per scanned repo). The host's live-gate discovers
# `live-validate` PRs ORG-WIDE — the same leak from the other end (R16 rule 5): this file is
# CANONICAL here and meant to be MIRRORED into fedora-bootstrap with the control repo's copy of
# scope.conf (the bin/fleet-halt.sh / gh-app-provision.sh precedent; keep in lockstep). Until that
# lands, the host half remains org-wide — a DISCLOSED residual, not a silent one.
#
# COST: a local file read — zero API calls, safe at the poller's 10 s cadence.
#
# ENV: SCOPE_FILE (default <this repo>/policy/scope.conf); SCOPE_OWN (default
#      "fedora-dev fedora-bootstrap" — the apparatus's own two repos, the unreadable-config
#      fallback); SCOPE_CONF_REL (default policy/scope.conf — the repo-relative path diff-adds
#      watches).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

SCOPE_FILE="${SCOPE_FILE:-$HERE/../policy/scope.conf}"
SCOPE_OWN="${SCOPE_OWN:-fedora-dev fedora-bootstrap}"
SCOPE_CONF_REL="${SCOPE_CONF_REL:-policy/scope.conf}"

log(){ printf 'repo-scope: %s\n' "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these) ------------------------------------------------

# scope_norm <name> → the bare repo name: any 'owner/' prefix stripped, so `check oso-gato/x` and
# `check x` answer identically (actuators hold both forms).
scope_norm(){ printf '%s' "${1##*/}"; }

# scope_parse — config on stdin → one clean repo name per line: CRs and comments (#…) stripped,
# edges trimmed; a line with characters outside [A-Za-z0-9._-] is INVALID and DROPPED — an invalid
# line can only ever NARROW the effective scope, never widen it (fail direction, header).
scope_parse(){
  sed -e 's/\r$//' -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -E '^[A-Za-z0-9._-]+$' || true
}

# scope_member <repo> <parsed-list> → 1|0 (exact whole-name match — no globs, no substrings).
scope_member(){
  printf '%s\n' "$2" | grep -qxF -- "$1" && printf 1 || printf 0
}

# scope_decide <member:0|1> <readable:0|1> <own:0|1> → ALLOW | DENY | FALLBACK_ALLOW | FALLBACK_DENY
# The whole fold: a readable config decides on membership ALONE (own-repo status buys nothing — an
# EMPTIED config denies even fedora-dev: narrowing is always the maintainer's right); an unreadable
# one falls back to the own-repo set and nothing else.
scope_decide(){
  local member="$1" readable="$2" own="$3"
  if [ "$readable" = 1 ]; then
    [ "$member" = 1 ] && printf 'ALLOW' || printf 'DENY'
  else
    [ "$own" = 1 ] && printf 'FALLBACK_ALLOW' || printf 'FALLBACK_DENY'
  fi
}

# scope_diff_adds <scope-conf-repo-relative-path> — unified diff on stdin → the repo names NET-ADDED
# to that file, one per line, sorted. Path-scoped by the `+++ b/<path>` target headers, so the same
# name added to any OTHER file (a README, a test fixture) never trips it; NET (added minus removed),
# so a moved/reordered/comment-reshuffled line is not an expansion and a REMOVAL-only diff yields
# nothing (narrowing needs no ceremony). Added lines are cleaned by the scope_parse grammar — a line
# the runtime parser would IGNORE cannot count as an expansion either.
scope_diff_adds(){
  awk -v sf="$1" '
    /^\+\+\+ / { infile = ($2 == "b/" sf); next }   # target-file header: enter/leave the scope file
    /^--- /    { next }                             # source-file header, never content
    !infile    { next }
    /^[+-]/ {
      sign = substr($0, 1, 1); l = substr($0, 2)
      sub(/\r$/, "", l); sub(/#.*$/, "", l)
      gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (l !~ /^[A-Za-z0-9._-]+$/) next            # the scope_parse grammar: invalid never counts
      if (sign == "+") add[l] = 1; else del[l] = 1
    }
    END { for (r in add) if (!(r in del)) print r }
  ' | sort
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== scope_norm (bare and owner/ forms answer identically) =="
  ck "bare name unchanged"    "$(scope_norm fedora-dev)" "fedora-dev"
  ck "owner/ prefix stripped" "$(scope_norm oso-gato/fedora-dev)" "fedora-dev"
  echo "== scope_parse (comments/blank/CRLF stripped; INVALID lines dropped — narrow, never widen) =="
  ck "plain names pass"       "$(printf 'a-repo\nb.repo\n' | scope_parse)" "$(printf 'a-repo\nb.repo')"
  ck "comments + blanks go"   "$(printf '# hdr\n\nx # tail\n' | scope_parse)" "x"
  ck "edges trimmed + CRLF"   "$(printf '  x  \r\n' | scope_parse)" "x"
  ck "invalid (space) dropped" "$(printf 'two words\nok\n' | scope_parse)" "ok"
  ck "invalid (slash) dropped" "$(printf 'oso-gato/x\nok\n' | scope_parse)" "ok"
  ck "empty config → empty"   "$(printf '# only comments\n' | scope_parse)" ""
  echo "== scope_member (exact whole-name only) =="
  ck "member"                 "$(scope_member x "$(printf 'w\nx\ny')")" 1
  ck "non-member"             "$(scope_member z "$(printf 'w\nx\ny')")" 0
  ck "substring never matches" "$(scope_member x "$(printf 'xx\nyx')")" 0
  ck "empty list → no"        "$(scope_member x '')" 0
  echo "== scope_decide (readable decides on membership ALONE; unreadable falls back to OWN only) =="
  ck "readable + member → ALLOW"        "$(scope_decide 1 1 0)" "ALLOW"
  ck "readable + non-member → DENY"     "$(scope_decide 0 1 0)" "DENY"
  ck "readable denies even an OWN repo emptied out" "$(scope_decide 0 1 1)" "DENY"
  ck "unreadable + own → FALLBACK_ALLOW" "$(scope_decide 0 0 1)" "FALLBACK_ALLOW"
  ck "unreadable + foreign → FALLBACK_DENY" "$(scope_decide 0 0 0)" "FALLBACK_DENY"
  ck "membership is IGNORED when unreadable (it was never read)" "$(scope_decide 1 0 0)" "FALLBACK_DENY"
  echo "== scope_diff_adds (NET adds to THE scope file only — the fitness R16 gate's detector) =="
  D1=$'diff --git a/policy/scope.conf b/policy/scope.conf\n--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1,2 +1,3 @@\n fedora-dev\n fedora-bootstrap\n+knowledge-desktop\n'
  ck "an added repo is detected"        "$(printf '%s' "$D1" | scope_diff_adds policy/scope.conf)" "knowledge-desktop"
  D2=$'--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1,3 +1,2 @@\n fedora-dev\n-e2e-alpha\n fedora-bootstrap\n'
  ck "a removal-only diff is NOT an expansion" "$(printf '%s' "$D2" | scope_diff_adds policy/scope.conf)" ""
  D3=$'--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1,3 +1,3 @@\n-e2e-alpha\n fedora-dev\n+e2e-alpha\n'
  ck "a MOVED line is NOT an expansion (net zero)" "$(printf '%s' "$D3" | scope_diff_adds policy/scope.conf)" ""
  D4=$'--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n line\n+knowledge-desktop\n'
  ck "the same name added to ANOTHER file never trips it" "$(printf '%s' "$D4" | scope_diff_adds policy/scope.conf)" ""
  D5=$'--- /dev/null\n+++ b/policy/scope.conf\n@@ -0,0 +1,2 @@\n+fedora-dev\n+# a comment\n'
  ck "file creation counts its real names (comments never)" "$(printf '%s' "$D5" | scope_diff_adds policy/scope.conf)" "fedora-dev"
  D6=$'--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1 +1,2 @@\n fedora-dev\n+two words\n'
  ck "an INVALID added line never counts (runtime would ignore it too)" "$(printf '%s' "$D6" | scope_diff_adds policy/scope.conf)" ""
  D7=$'--- a/repo-scope.test.sh\n+++ b/repo-scope.test.sh\n@@ -1 +1,3 @@\n x\n++++ b/policy/scope.conf\n+knowledge-desktop\n'
  ck "a diff-of-a-diff in a test file cannot forge the target header" "$(printf '%s' "$D7" | scope_diff_adds policy/scope.conf)" ""
  D8=$'--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1,2 +1,4 @@\n fedora-dev\n+bbb\n fedora-bootstrap\n+aaa\n'
  ck "multiple adds, sorted"            "$(printf '%s' "$D8" | scope_diff_adds policy/scope.conf | tr '\n' ' ')" "aaa bbb "
  echo; echo "repo-scope selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- I/O — the real read ---------------------------------------------------------------------------

read_scope(){ # → parsed list on stdout; rc 0 = the config was READABLE (even if it parsed empty)
  [ -f "$SCOPE_FILE" ] && [ -r "$SCOPE_FILE" ] || return 1
  scope_parse < "$SCOPE_FILE"
  return 0
}

is_own(){ # <repo> → rc 0 iff one of the apparatus's own repos
  local o; for o in $SCOPE_OWN; do [ "$o" = "$1" ] && return 0; done
  return 1
}

case "${1:-}" in
  list)
    if scope="$(read_scope)"; then
      printf '%s\n' "$scope" | grep . || true
    else
      log "SCOPE CONFIG UNREADABLE ($SCOPE_FILE) — falling back to the apparatus's OWN repos ONLY: $SCOPE_OWN (R16 fail-closed; everything else is frozen until the config is readable)"
      printf '%s\n' $SCOPE_OWN
    fi
    exit 0;;
  check)
    repo="$(scope_norm "${2:-}")"
    [ -n "$repo" ] || { log "usage: repo-scope.sh check <repo>"; exit 2; }
    if scope="$(read_scope)"; then readable=1; else readable=0; scope=""; fi
    own=0; is_own "$repo" && own=1
    member="$(scope_member "$repo" "$scope")"
    case "$(scope_decide "$member" "$readable" "$own")" in
      ALLOW) exit 0;;
      DENY)
        log "DENY: repo '$repo' is NOT in the maintainer-confirmed operating scope ($SCOPE_FILE) — R16: no action (add it via the confirmed-PR path, never a script default)"
        exit 3;;
      FALLBACK_ALLOW)
        log "WARN: scope config UNREADABLE ($SCOPE_FILE) — '$repo' allowed ONLY as one of the apparatus's own repos ($SCOPE_OWN); every other repo is frozen (R16 fail-closed)"
        exit 0;;
      FALLBACK_DENY)
        log "DENY: scope config UNREADABLE ($SCOPE_FILE) and '$repo' is not one of the apparatus's own repos ($SCOPE_OWN) — R16 fail-closed: no action"
        exit 4;;
    esac;;
  diff-adds)
    scope_diff_adds "${2:-$SCOPE_CONF_REL}"
    exit 0;;
  *)
    echo "usage: repo-scope.sh check <repo> | list | diff-adds [path] | --selftest" >&2
    exit 2;;
esac
