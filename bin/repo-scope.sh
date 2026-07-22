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
# THE AUTHORITY (R16, amended 2026-07-16) is the CONFIRMED-OBJECTIVE repo-list — the "Repositories this
# objective operates on" table in 00-OBJECTIVES.md, maintainer-confirmed ONCE (R1). A per-session scope
# is the session's TRANSCRIPTION of that list into the R27 registry, GIT-VERIFIED at read time against the
# objective doc at the session's backing ref (session_scope_verified): the local .session file is only a
# cache, so a hand-forged one can never widen scope past what the maintainer confirmed. `policy/scope.conf`
# is RETIRED as the enrollment authority; it survives ONLY as the TRANSITIONAL CEILING the SCOPE_SESSION-
# unset path (the poller) still reads until the cutover — one bare repo name per line, comments/blank
# stripped, invalid lines IGNORED (narrow-only). NOTE (#239): the operating scope is now the App
# INSTALLATION (read via read_scope/scope_enumerate below); the confirm-to-add fitness gate + its
# `diff-adds`/`objective-adds` detectors are RETIRED, so this header's scope.conf/objective-list
# narrative survives only for the session-layer (objective-backed) path. Scope is PER-OBJECTIVE, not
# permanent; REMOVING a repo needs no ceremony (narrowing is always safe).
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
#   repo-scope.sh list           the actionable set, one per line (unreadable enumeration → $SCOPE_OWN,
#                                warned on stderr; rc 0 either way — the fallback IS the answer).
#   repo-scope.sh --selftest     exercise the pure helpers (no gh / network / clone).
#
# PER-SESSION LAYER (R27/R28) — an OPTIONAL narrowing layer bolted ON TOP of the ceiling, gated ENTIRELY
# by the env var SCOPE_SESSION (the caller's SID):
#   * SCOPE_SESSION UNSET → this reader behaves BYTE-IDENTICALLY to the ceiling-only version above (the
#     session registry is not even consulted or sourced). This is the load-bearing inertness: the running
#     poller sets nothing, so enabling this file changes NOTHING until a caller opts in per-session.
#   * SCOPE_SESSION SET → the session's GIT-VERIFIED scope (session_scope_verified <sid>) NARROWS the
#     ceiling: effective set = verified ∩ ceiling. The session's cached repos are TRUSTED only when they
#     still SET-EQUAL the confirmed-objective repo-list at the session's backing ref, AND that ref is a
#     GATED-REMOTE (origin/main-ancestor) sha — otherwise the session fails CLOSED with the cause named
#     (SESSION_UNBACKED: no/old backing · bad ref · MISMATCH = a hand-edited cache tried to widen · UNGATED
#     = an off-main, agent-committed backing sha, R34/#210). On OK, `check` ALLOWs iff the repo is in the verified set AND
#     not held by another LIVE session (disjointness, R28); an UNDECLARED session (SCOPE_SESSION set but
#     unregistered) acts on NOTHING (fail-closed, F6). A session can only ever NARROW the ceiling, never
#     exceed it. `list` mirrors: the verified effective set, or empty when unverified/undeclared. The
#     ceiling's fail direction is untouched and layered under (an unreadable config still falls back to
#     SCOPE_OWN, and the session narrows within it). `transcribe`/`union`/`owner` support the objective-
#     backed model + the (deferred) poller cutover; see the CLI contract below.
#
# CALLERS (R16 rule 4 — every actuator): bin/pr-poller.sh (sweep list + the fixer belt),
# bin/fitness-review.sh (the in-scope check before reviewing), bin/auto-merge.sh (before merging),
# bin/dev-plan.sh / dev-loop.sh / dev-author.sh (before planning/authoring), bin/host-ticket.sh
# (before filing) and bin/host-refresh.sh (per scanned repo). The host's live-gate discovers
# `live-validate` PRs ORG-WIDE — the same leak from the other end (R16 rule 5): this file is
# CANONICAL here and meant to be MIRRORED into fedora-bootstrap with the control repo's copy of
# scope.conf (the bin/fleet-halt.sh / gh-app-provision.sh precedent; keep in lockstep). Until that
# lands, the host half remains org-wide — a DISCLOSED residual, not a silent one.
#
# COST: one App-install enumeration API call per TTL window (cached), safe at the poller's cadence.
#
# ENV: SCOPE_CACHE (default ~/.local/state/repo-scope/install.cache — the enumeration cache);
#      SCOPE_CACHE_TTL (default 300s; 0 disables the cache — tests re-stub each call); SCOPE_OWN
#      (default "fedora-dev fedora-bootstrap" — the apparatus's own two repos, the unreadable-enum
#      fallback); SCOPE_SESSION (OPTIONAL — the caller's SID; unset ⇒ the session layer is inert and
#      the reader is byte-identical to the ceiling-only version); SCOPE_REGISTRY_DIR (the
#      session-registry store, honoured via the sourced bin/session-registry.sh — only read when
#      SCOPE_SESSION is set).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# R16 (rebuilt 2026-07-21): the operating scope IS the App installation — the apparatus operates on
# every repo its GitHub App is installed on. WHICH repos is the maintainer's App-access config, NOT
# hardcoded here (no allowlist, no denylist, no specific repo set baked in — the maintainer can never
# be second-guessed on which repos he opens the App to). Enumerated from the App's OWN installation,
# cached (TTL) so per-sweep check/list calls don't each hit the API. Fail-closed to SCOPE_OWN when the
# enumeration is unreadable (the loop can still fix/ship itself). policy/scope.conf is RETIRED (deleted).
SCOPE_OWN="${SCOPE_OWN:-fedora-dev fedora-bootstrap}"
SCOPE_CACHE="${SCOPE_CACHE:-$HOME/.local/state/repo-scope/install.cache}"
SCOPE_CACHE_TTL="${SCOPE_CACHE_TTL:-300}"     # 0 disables the cache (tests use 0 to re-stub each call)

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

# ---- OBJECTIVE REPO-LIST — the git-anchored authority (R16, 2026-07-16) ----------------------------
# The confirmed objective's "Repositories this objective operates on" markdown table REPLACES
# policy/scope.conf as the maintainer-confirmed authority: scope.conf was a standing allowlist to edit;
# the objective repo-list is confirmed ONCE (R1) and any net-add is fitness-gated exactly like a
# scope.conf add was. The session registry only CACHES a session's transcription of this list; the
# read path re-verifies the cache against it (session_scope_verified).

# objective_row_names — an 00-OBJECTIVES.md doc on stdin → the bare repo names its "Repositories this
# objective operates on" table lists, one per line. HEADING-ANCHORED (rows only under that `##` section,
# until the next `##`); the table's HEADER row (`| Repository | Role |`) and separator (`|---|`) carry no
# `owner/repo` cell-1 and are dropped by the grammar; each kept cell-1 must match the backticked
# `owner/repo` shape and is normalized off its `owner/` prefix (lockstep with scope_norm). Fail-closed
# to EMPTY on no-heading / no-table / zero valid rows. Still used by the session-layer objective_repos.
objective_row_names(){
  awk '
    /^##[[:space:]]/ { insec = ($0 ~ /^##[[:space:]]+Repositories this objective operates on[[:space:]]*$/); next }
    !insec           { next }
    /^[[:space:]]*\|/ {
      l = $0; sub(/\r$/, "", l)
      sub(/^[[:space:]]*\|[[:space:]]*/, "", l)      # strip leading pipe + ws
      sub(/[[:space:]]*\|.*$/, "", l)                # keep only table cell 1
      gsub(/`/, "", l)                                # strip backticks
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
      if (l ~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/) { n = split(l, a, "/"); print a[n] }
    }
  '
}

# ---- PER-SESSION LAYER — pure helpers (R27/R28; --selftest covers exactly these) -------------------
# A per-session NARROWING layer bolted ON TOP of the ceiling (scope_decide). It NEVER widens: a session
# can only ever narrow the maintainer-confirmed ceiling to the subset it declared, and it acts on
# NOTHING until it registers. The whole layer is INERT unless the caller sets $SCOPE_SESSION — with it
# unset the ceiling verdict IS the answer, byte-for-byte as before (the running poller sets nothing).

# scope_session_decide <ceiling-verdict> <declared:0|1> <smember:0|1> <held:0|1>
#   → the FINAL verdict once the session layer is applied over the ceiling. <ceiling-verdict> is exactly
#   what scope_decide returned (ALLOW|DENY|FALLBACK_ALLOW|FALLBACK_DENY); <declared> = the session has a
#   non-empty registered scope; <smember> = the repo is in that declared scope; <held> = the repo is
#   currently held by ANOTHER live session (registry cross-check). The fold, in order:
#     * ceiling DENY / FALLBACK_DENY → returned UNCHANGED. The repo is OUTSIDE the ceiling; a session can
#       only narrow, never widen it back in — and the ceiling's own rc/log (incl. the unreadable-config
#       FALLBACK_DENY, rc 4) is preserved intact.
#     * ceiling ALLOW / FALLBACK_ALLOW → the repo is WITHIN the ceiling, so the session decides:
#         undeclared               → SESSION_UNDECLARED (fail-closed to nothing — it must register first;
#                                     this OUTRANKS held, so an unregistered SCOPE_SESSION acts on nothing
#                                     even when the repo is one of the apparatus's own fallback repos).
#         declared, NOT a member   → SESSION_DENY (the session narrows the ceiling out).
#         declared, member, HELD   → SESSION_HELD (disjointness — another live session owns it, R28).
#         declared, member, free   → the ceiling verdict UNCHANGED (ALLOW, or FALLBACK_ALLOW so the
#                                     unreadable-config own-only fallback + its WARN survive under a session).
scope_session_decide(){
  local ceiling="$1" declared="$2" smember="$3" held="$4"
  case "$ceiling" in
    DENY|FALLBACK_DENY) printf '%s' "$ceiling"; return 0;;   # outside the ceiling — a session can't widen
  esac
  [ "$declared" = 1 ] || { printf 'SESSION_UNDECLARED'; return 0; }
  [ "$smember" = 1 ] || { printf 'SESSION_DENY'; return 0; }   # narrows: declared but not this repo
  [ "$held" != 1 ]   || { printf 'SESSION_HELD'; return 0; }   # disjointness cross-check (R28)
  printf '%s' "$ceiling"                                        # ALLOW / FALLBACK_ALLOW stands
}

# scope_effective <session-list> <ceiling-list> → the effective set = the names in BOTH, one per line,
# in CEILING order (mirrors what `list` prints today). Newline-separated inputs; a session name absent
# from the ceiling is DROPPED (a session can never exceed the ceiling); either side empty → empty.
scope_effective(){
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    printf '%s\n' "$1" | grep -qxF -- "$r" && printf '%s\n' "$r"
  done <<< "$2"
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
  echo "== objective_row_names (heading-anchored table parse — the git-anchored R16 authority) =="
  OBJ=$'# T\n\n## Objective\n\n| `oso-gato/before-section` | x |\n\n## Repositories this objective operates on\n\nThis objective operates on exactly these repositories:\n\n| Repository | Role |\n|---|---|\n| `oso-gato/fedora-dev` | the DEV |\n| `oso-gato/fedora-bootstrap` | the HOST |\n\nThis list is the authorization.\n\n## Document authority\n\n| `oso-gato/after-section` | w |\n'
  ck "extracts the two scoped repos; header+separator dropped; owner/ normalized; OTHER sections ignored" \
     "$(printf '%s' "$OBJ" | objective_row_names | tr '\n' ' ')" "fedora-dev fedora-bootstrap "
  ck "no Repositories heading → EMPTY (fail-closed)" "$(printf '## Other\n| `oso-gato/x` | y |\n' | objective_row_names)" ""
  ck "a non-backticked/no-slash cell-1 is dropped" "$(printf '## Repositories this objective operates on\n| plainword | y |\n' | objective_row_names)" ""
  echo "== scope_session_decide (the per-session LAYER — narrows the ceiling, NEVER widens it) =="
  ck "ceiling DENY stands (a session can never widen a repo back into the ceiling)" "$(scope_session_decide DENY 1 1 0)" "DENY"
  ck "ceiling FALLBACK_DENY stands (unreadable-config rc-4 freeze preserved)"       "$(scope_session_decide FALLBACK_DENY 1 1 0)" "FALLBACK_DENY"
  ck "in-ceiling + declared member + free → ALLOW"                                  "$(scope_session_decide ALLOW 1 1 0)" "ALLOW"
  ck "in-ceiling + declared NON-member → SESSION_DENY (narrows the ceiling)"        "$(scope_session_decide ALLOW 1 0 0)" "SESSION_DENY"
  ck "in-ceiling + UNDECLARED → SESSION_UNDECLARED (fail-closed to nothing)"        "$(scope_session_decide ALLOW 0 0 0)" "SESSION_UNDECLARED"
  ck "in-ceiling + declared member but HELD by another live session → SESSION_HELD" "$(scope_session_decide ALLOW 1 1 1)" "SESSION_HELD"
  ck "FALLBACK_ALLOW + declared member + free → FALLBACK_ALLOW (own-only fallback survives the session)" "$(scope_session_decide FALLBACK_ALLOW 1 1 0)" "FALLBACK_ALLOW"
  ck "FALLBACK_ALLOW + declared NON-member → SESSION_DENY (session narrows even the own-only fallback)"   "$(scope_session_decide FALLBACK_ALLOW 1 0 0)" "SESSION_DENY"
  ck "FALLBACK_ALLOW + UNDECLARED → SESSION_UNDECLARED (undeclared acts on nothing, own repos included)"  "$(scope_session_decide FALLBACK_ALLOW 0 0 0)" "SESSION_UNDECLARED"
  ck "UNDECLARED outranks HELD (never even reaches the cross-check)"                "$(scope_session_decide ALLOW 0 0 1)" "SESSION_UNDECLARED"
  echo "== scope_effective (the effective set = session ∩ ceiling, in ceiling order) =="
  ck "intersection keeps only shared names"                     "$(scope_effective "$(printf 'a\nb')" "$(printf 'a\nc')")" "a"
  ck "a session name NOT in the ceiling is DROPPED (cannot exceed the ceiling)" "$(scope_effective "$(printf 'a\nz')" "$(printf 'a\nb')")" "a"
  ck "empty session → empty effective set"                      "$(scope_effective "" "$(printf 'a\nb')")" ""
  ck "empty ceiling → empty effective set"                      "$(scope_effective "$(printf 'a\nb')" "")" ""
  ck "ceiling ORDER is preserved (not session order)"           "$(scope_effective "$(printf 'a\nb')" "$(printf 'b\na\nc')" | tr '\n' ' ')" "b a "
  echo; echo "repo-scope selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- I/O — the real read ---------------------------------------------------------------------------

# scope_enumerate — the repos the App is installed on (whatever access the maintainer set), with
# archived/forks/templates excluded (hygiene — the apparatus never drives an upstream or a frozen repo).
# The ONE I/O seam; the test suite stubs `gh` to drive read_scope without the real API.
scope_enumerate(){ gh api /installation/repositories --paginate \
  -q '.repositories[] | select(.archived==false and .fork==false and ((.is_template // false)==false)) | .name' 2>/dev/null; }
read_scope(){ # → the in-scope repo names on stdout; rc 0 = enumeration READABLE, rc 1 = unreadable (→ SCOPE_OWN)
  if [ "${SCOPE_CACHE_TTL:-0}" -gt 0 ] 2>/dev/null && [ -s "$SCOPE_CACHE" ]; then
    local age; age=$(( $(date +%s) - $(stat -c %Y "$SCOPE_CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$SCOPE_CACHE_TTL" ] && { cat "$SCOPE_CACHE"; return 0; }
  fi
  local out; out="$(scope_enumerate)" || return 1
  out="$(printf '%s\n' "$out" | scope_parse)"          # bare-name normalize (defensive; jq .name is already bare)
  [ -n "$out" ] || return 1                              # empty enumeration ⇒ unreadable ⇒ fail-closed to OWN
  { mkdir -p "$(dirname "$SCOPE_CACHE")" && printf '%s\n' "$out" > "$SCOPE_CACHE"; } 2>/dev/null || true
  printf '%s\n' "$out"; return 0
}

is_own(){ # <repo> → rc 0 iff one of the apparatus's own repos
  local o; for o in $SCOPE_OWN; do [ "$o" = "$1" ] && return 0; done
  return 1
}

# ---- PER-SESSION LAYER — the registry reads (only reached when $SCOPE_SESSION is set) ---------------
# Lazily source the session registry ONCE. Deliberately NOT sourced at file top: with $SCOPE_SESSION
# unset (the running poller) this file must not even depend on the registry — the layer is inert. The
# sourced libs guard their own `set`/CLI on direct-execution only, so sourcing just defines functions.
session_layer_init(){
  [ -n "${_SESSION_LAYER_LOADED:-}" ] && return 0
  # shellcheck source=session-registry.sh
  . "$HERE/session-registry.sh"    # → _run_locked / _resolve_impl / _list_impl (+ session-id + lock-lib)
  _SESSION_LAYER_LOADED=1
}

# session_declared_scope <sid> → the session's declared repos, one per line (empty ⇒ UNDECLARED: either
# not registered, or registered with no repos — which register forbids, so empty ⟺ not registered).
session_declared_scope(){
  local raw; raw="$(_run_locked _resolve_impl "$1" 2>/dev/null)" || raw=""
  printf '%s' "$raw" | tr ' ' '\n' | grep . || true
}

# repo_held_by_other <repo> <my-sid> → the sid of a LIVE session other than <my-sid> that holds <repo>
# (registry `list` is liveness-filtered), or empty. The disjointness cross-check behind SESSION_HELD.
repo_held_by_other(){
  local repo="$1" mysid="$2" sid repos
  while IFS=$'\t' read -r sid repos; do
    [ -n "$sid" ] || continue
    [ "$sid" = "$mysid" ] && continue
    printf '%s\n' $repos | grep -qxF -- "$repo" && { printf '%s' "$sid"; return 0; }
  done < <(_run_locked _list_impl 2>/dev/null)
  return 0
}

# ---- BACKING VERIFICATION (R16 actuator boundary) — the cache is checked against git ----------------
# objective_clone_dir <repo> → the repo's LOCAL clone. $SCOPE_OBJECTIVE_CLONE overrides outright (test
# seam); else the first of $SCOPE_CLONE_ROOTS/<repo> that is a git checkout — so a WORKLOAD objective
# whose clone lives in ~/work or ~/repos (not the apparatus's ~/.local/share) is readable without a
# gh-api cross-repo backend. Falls back to ~/.local/share/<repo> when none exists (objective_repos then
# fails closed on the missing dir). The apparatus's own repos are always at ~/.local/share.
objective_clone_dir(){
  local repo="$1" root d
  [ -n "${SCOPE_OBJECTIVE_CLONE:-}" ] && { printf '%s' "$SCOPE_OBJECTIVE_CLONE"; return 0; }
  local roots="${SCOPE_CLONE_ROOTS:-$HOME/.local/share $HOME/work $HOME/repos}"
  for root in $roots; do
    d="$root/$repo"; [ -d "$d/.git" ] && { printf '%s' "$d"; return 0; }
  done
  printf '%s' "$HOME/.local/share/$repo"
}

# objective_repos <repo> <objective-path> <sha> → the objective's repo-list AT THAT GIT REF, one per line
# (via objective_row_names). Local backend: `git -C <clone> show <sha>:<path>`. rc 1 (empty) on any
# unreadable/unparseable ref — the read path fails such a session CLOSED. A cross-repo (gh-api) backend
# for an absent clone is a recorded follow-up NOTE (the apparatus objective's backing repo is always local).
objective_repos(){
  local repo="$1" path="$2" sha="$3" dir out
  dir="$(objective_clone_dir "$repo")"
  [ -d "$dir" ] || return 1
  out="$(git -C "$dir" show "$sha:$path" 2>/dev/null | objective_row_names | grep . )" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# objective_sha_gated <repo> <sha> → rc 0 iff <sha> is an ANCESTOR of the clone's origin/main — i.e. it
# sits on the maintainer-GATED remote line, not an off-main AGENT-committed sha (R34/#210). The read path
# calls this before trusting a cached backing: a hand-forged .session line-4 that points at a LOCAL widening
# commit is reachable from HEAD but NOT from origin/main, so it fails CLOSED. `merge-base --is-ancestor`
# returns rc 0 iff <sha> is reachable from origin/main (a sha is its own ancestor, so origin/main itself
# passes). A missing origin/main (no gated remote) or an unknown sha ⇒ rc≠0 ⇒ fail closed. RESIDUAL
# (disclosed — a 00-DESIGN.md NOTE): a locally-forged refs/remotes/origin/main is the same home-volume-write
# trust level as editing .session directly — this gate RAISES THE BAR, it is not a hard boundary against that.
objective_sha_gated(){
  local repo="$1" sha="$2" dir
  dir="$(objective_clone_dir "$repo")"
  [ -d "$dir" ] || return 1
  git -C "$dir" merge-base --is-ancestor "$sha" origin/main 2>/dev/null
}

# session_scope_verified <sid> → LINE 1 = the verification STATE, then (on OK only) the verified repos:
#   OK           — the session is registered, backed, AND its cached line-3 repos SET-EQUAL the objective
#                  repo-list at its backing ref → lines 2..N are those repos (the verified scope to act on).
#   UNREGISTERED — no registry entry (or empty scope).
#   UNBACKED     — registered but line 4 is absent/'-' or malformed (a pre-backing entry, or a hand-forge).
#   UNREADABLE   — the backing ref (repo/path/sha) can't be read/parsed to a non-empty repo-list.
#   UNGATED      — the backing sha is READABLE but is NOT an ancestor of origin/main (an off-main,
#                  agent-committed sha — a self-authored provenance forge; R34/#210).
#   MISMATCH     — cached repos ≠ objective repo-list at the ref (a hand-edited line 3 tried to widen).
# The cache is thereby only ever TRUSTED when it still equals the git-anchored, maintainer-confirmed fact;
# any drift/forgery/breakage fails the session CLOSED (the caller maps everything but OK to no-action).
# No globals (command-sub safe): the state rides stdout line 1.
session_scope_verified(){
  local sid="$1" repos backing brepo bpath bsha objlist
  repos="$(_run_locked _resolve_impl "$sid" 2>/dev/null)" || repos=""
  [ -n "$repos" ] || { printf 'UNREGISTERED\n'; return 0; }
  backing="$(_run_locked _resolve_backing_impl "$sid" 2>/dev/null)" || backing=""
  [ -n "$backing" ] || { printf 'UNBACKED\n'; return 0; }
  read -r brepo bpath bsha _ <<< "$backing"
  [ -n "$brepo" ] && [ -n "$bpath" ] && [ -n "$bsha" ] || { printf 'UNBACKED\n'; return 0; }
  objlist="$(objective_repos "$brepo" "$bpath" "$bsha")" || objlist=""
  [ -n "$objlist" ] || { printf 'UNREADABLE\n'; return 0; }
  # R34/#210 PROVENANCE: the backing sha must sit on the GATED-REMOTE main line (an ancestor of
  # origin/main), never an off-main AGENT-committed sha. A readable doc at a locally-forged off-main sha
  # (a hand-edited .session line 4 pointing at a local widening commit) fails CLOSED here — separate from
  # UNREADABLE (bad ref) so the cause is named. Checked BEFORE the set-equal so a forged sha whose doc
  # merely matches the cache cannot pass.
  objective_sha_gated "$brepo" "$bsha" || { printf 'UNGATED\n'; return 0; }
  # The cache is TRUSTED only when its line-3 repos SET-EQUAL the git-anchored objective repo-list; any
  # drift/forgery ⇒ MISMATCH ⇒ fail closed. `verified_ok` is the single gating line (the mutation anchor).
  local verified_ok=0
  [ "$(printf '%s\n' $repos | grep . | sort -u)" = "$(printf '%s\n' "$objlist" | sort -u)" ] && verified_ok=1
  if [ "$verified_ok" = 1 ]; then printf 'OK\n'; printf '%s\n' $repos; else printf 'MISMATCH\n'; fi
}

case "${1:-}" in
  list)
    if [ -z "${SCOPE_SESSION:-}" ]; then
      # ── SCOPE_SESSION UNSET → byte-identical to the pre-session reader (the ceiling IS the answer) ──
      if scope="$(read_scope)"; then
        printf '%s\n' "$scope" | grep . || true
      else
        log "APP-INSTALL ENUMERATION UNREADABLE — falling back to the apparatus's OWN repos ONLY: $SCOPE_OWN (R16 fail-closed; everything else is frozen until the App install is readable again)"
        printf '%s\n' $SCOPE_OWN
      fi
      exit 0
    fi
    # ── SCOPE_SESSION SET → the effective set = session declared scope ∩ ceiling ──
    if scope="$(read_scope)"; then
      ceiling_list="$(printf '%s\n' "$scope" | grep . || true)"
    else
      log "APP-INSTALL ENUMERATION UNREADABLE — falling back to the apparatus's OWN repos ONLY: $SCOPE_OWN (R16 fail-closed; everything else is frozen until the App install is readable again)"
      ceiling_list="$(printf '%s\n' $SCOPE_OWN)"
    fi
    session_layer_init
    sv="$(session_scope_verified "$SCOPE_SESSION")"
    sstate="$(printf '%s\n' "$sv" | sed -n '1p')"
    if [ "$sstate" != OK ]; then
      log "session '$SCOPE_SESSION' has no VERIFIED objective-backed scope ($sstate) — empty effective set; transcribe it: bin/repo-scope.sh transcribe --backing '<repo> <path> <sha>' <sid> (R16)"
      exit 0
    fi
    sscope="$(printf '%s\n' "$sv" | sed -n '2,$p')"
    scope_effective "$sscope" "$ceiling_list"
    exit 0;;
  check)
    repo="$(scope_norm "${2:-}")"
    [ -n "$repo" ] || { log "usage: repo-scope.sh check <repo>"; exit 2; }
    if scope="$(read_scope)"; then readable=1; else readable=0; scope=""; fi
    own=0; is_own "$repo" && own=1
    member="$(scope_member "$repo" "$scope")"
    ceiling="$(scope_decide "$member" "$readable" "$own")"
    if [ -z "${SCOPE_SESSION:-}" ]; then
      # ── SCOPE_SESSION UNSET → the ceiling verdict IS the answer, byte-identical to the pre-session reader ──
      verdict="$ceiling"
    else
      # ── SCOPE_SESSION SET → apply the per-session narrowing LAYER on top of the ceiling. The session's
      #    scope is the objective-BACKED, git-VERIFIED set (session_scope_verified) — never the raw cache. ──
      session_layer_init
      sv="$(session_scope_verified "$SCOPE_SESSION")"
      sstate="$(printf '%s\n' "$sv" | sed -n '1p')"
      sbacking_cause=""
      case "$sstate" in
        OK)
          sscope="$(printf '%s\n' "$sv" | sed -n '2,$p')"
          smember="$(scope_member "$repo" "$sscope")"
          held_sid="$(repo_held_by_other "$repo" "$SCOPE_SESSION")"
          held=0; [ -n "$held_sid" ] && held=1
          verdict="$(scope_session_decide "$ceiling" 1 "$smember" "$held")";;
        UNREGISTERED)
          # undeclared within the ceiling → SESSION_UNDECLARED; outside it → the ceiling DENY stands.
          verdict="$(scope_session_decide "$ceiling" 0 0 0)";;
        *)
          # UNBACKED | UNREADABLE | MISMATCH | UNGATED → the session's git backing is broken/forged/off-main;
          # act on NOTHING. A ceiling DENY/FALLBACK_DENY still stands (preserves its own rc/log); else SESSION_UNBACKED.
          sbacking_cause="$sstate"
          case "$ceiling" in DENY|FALLBACK_DENY) verdict="$ceiling";; *) verdict="SESSION_UNBACKED";; esac;;
      esac
    fi
    case "$verdict" in
      ALLOW) exit 0;;
      DENY)
        log "DENY: repo '$repo' is NOT in the apparatus's operating scope — R16: the App is not installed on it (no action; the maintainer brings it in scope by installing the App on it)"
        exit 3;;
      FALLBACK_ALLOW)
        log "WARN: App-install enumeration UNREADABLE — '$repo' allowed ONLY as one of the apparatus's own repos ($SCOPE_OWN); every other repo is frozen (R16 fail-closed)"
        exit 0;;
      FALLBACK_DENY)
        log "DENY: App-install enumeration UNREADABLE and '$repo' is not one of the apparatus's own repos ($SCOPE_OWN) — R16 fail-closed: no action"
        exit 4;;
      SESSION_UNDECLARED)
        log "DENY: session '$SCOPE_SESSION' has declared NO operating scope — register it first (bin/session-registry.sh register <sid> <repo…>); fail-closed to nothing (R16/F6)"
        exit 3;;
      SESSION_DENY)
        log "DENY: repo '$repo' is within the ceiling but OUTSIDE session '$SCOPE_SESSION' declared scope [$sscope] — a session only NARROWS the ceiling (R28)"
        exit 3;;
      SESSION_HELD)
        log "DENY: repo '$repo' is held by another LIVE session '$held_sid' — R28 disjoint-scope: no action while another session holds it"
        exit 3;;
      SESSION_UNBACKED)
        log "DENY: session '$SCOPE_SESSION' scope is not git-verified ($sbacking_cause) — R16: the registry cache does not match the confirmed-objective repo-list at its backing ref (UNBACKED=no/old backing, UNREADABLE=bad ref, MISMATCH=hand-edited to widen, UNGATED=backing sha not on origin/main — R34/#210); fail-closed to nothing. Re-transcribe: bin/repo-scope.sh transcribe --backing '<repo> <path> <sha>' <sid>"
        exit 3;;
    esac;;
  transcribe)
    # transcribe (--backing '<repo> <path> <sha>' | --objective '<repo> <path>') <sid> — DERIVE the repos
    # from the confirmed objective and register them for the session (the agent transcribes, never
    # authorizes, R16). --objective resolves the backing sha ONLY from the clone's origin/main (a
    # maintainer-gated remote-tracking ref; NO local-HEAD fallback — R34/#210) — the self-seed path
    # (session-scope-seed.sh), which knows the objective doc but not a pinned sha.
    shift
    tbacking=""; tobjective=""
    if [ "${1:-}" = "--backing" ]; then tbacking="${2:-}"; shift 2 2>/dev/null || shift "$#"; fi
    if [ "${1:-}" = "--objective" ]; then tobjective="${2:-}"; shift 2 2>/dev/null || shift "$#"; fi
    tsid="${1:-}"
    if [ -n "$tobjective" ] && [ -z "$tbacking" ]; then
      read -r torepo topath _ <<< "$tobjective"
      { [ -n "$torepo" ] && [ -n "$topath" ]; } || { log "transcribe: --objective needs '<repo> <objective-path>'"; exit 2; }
      todir="$(objective_clone_dir "$torepo")"
      # R34/#210: resolve the backing sha ONLY from origin/main — a REMOTE-TRACKING, maintainer-gated ref.
      # The old `|| rev-parse HEAD` fallback let a self-authored local clone with NO gated remote main (a
      # fabricated ~/work/<repo>) back a session's scope off an AGENT-COMMITTED local HEAD; once the ceiling
      # is gone at the STEP-10 cutover that scope becomes DIRECTLY actionable, so the fallback is DROPPED —
      # a clone with no origin/main now fails CLOSED here rather than trusting agent-controllable local
      # state. `--verify` fails clean (no stdout) on a missing ref (a plain rev-parse would ECHO the ref).
      tosha="$(git -C "$todir" rev-parse --verify -q origin/main 2>/dev/null || true)"
      [ -n "$tosha" ] || { log "transcribe: cannot resolve origin/main for $torepo:$topath (no gated-remote clone at $todir?) — fail-closed, registering nothing (R34/#210)"; exit 3; }
      tbacking="$torepo $topath $tosha"
    fi
    { [ -n "$tbacking" ] && [ -n "$tsid" ]; } || { log "usage: repo-scope.sh transcribe (--backing '<repo> <path> <sha>' | --objective '<repo> <path>') <sid>"; exit 2; }
    read -r tbrepo tbpath tbsha _ <<< "$tbacking"
    { [ -n "$tbrepo" ] && [ -n "$tbpath" ] && [ -n "$tbsha" ]; } || { log "transcribe: --backing needs '<repo> <objective-path> <sha>'"; exit 2; }
    tderived="$(objective_repos "$tbrepo" "$tbpath" "$tbsha")" || tderived=""
    [ -n "$tderived" ] || { log "transcribe: could not read a non-empty objective repo-list at $tbrepo:$tbpath@$tbsha — fail-closed, registering nothing (R16)"; exit 3; }
    "$HERE/session-registry.sh" register --backing "$tbacking" "$tsid" $tderived
    exit $?;;
  union)
    # ∪ of every LIVE session's git-VERIFIED scope — the shared-service actionable set (poller cutover, STEP 10).
    session_layer_init
    { while IFS=$'\t' read -r usid _; do
        [ -n "$usid" ] || continue
        usv="$(session_scope_verified "$usid")"
        [ "$(printf '%s\n' "$usv" | sed -n '1p')" = OK ] || continue
        printf '%s\n' "$usv" | sed -n '2,$p'
      done < <(_run_locked _list_impl 2>/dev/null); } | grep . | sort -u
    exit 0;;
  owner)
    # owner <repo> → the SID of the unique LIVE, verified session whose scope holds <repo> (or empty).
    orepo="$(scope_norm "${2:-}")"
    [ -n "$orepo" ] || { log "usage: repo-scope.sh owner <repo>"; exit 2; }
    session_layer_init
    while IFS=$'\t' read -r osid _; do
      [ -n "$osid" ] || continue
      osv="$(session_scope_verified "$osid")"
      [ "$(printf '%s\n' "$osv" | sed -n '1p')" = OK ] || continue
      printf '%s\n' "$osv" | sed -n '2,$p' | grep -qxF -- "$orepo" && { printf '%s\n' "$osid"; exit 0; }
    done < <(_run_locked _list_impl 2>/dev/null)
    exit 0;;
  *)
    echo "usage: repo-scope.sh check <repo> | list | transcribe (--backing '<repo> <path> <sha>' | --objective '<repo> <path>') <sid> | union | owner <repo> | --selftest" >&2
    exit 2;;
esac
