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
# stripped, invalid lines IGNORED (narrow-only). ADDING a repo (to the objective repo-list OR the
# transitional scope.conf) is maintainer-gated structurally AND name-bound: bin/fitness-review.sh RETURNs
# an addition no maintainer CONFIRMED **by name** (R16 rule 3), via `objective-adds` (primary) + `diff-adds`
# (transitional). Scope is PER-OBJECTIVE, not permanent; REMOVING a repo needs no ceremony (narrowing is
# always safe).
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
#                                is not an expansion), one per line. Empty = no expansion.
#                                HUNK-STATEFUL: `+++ `/`--- ` count as file headers only OUTSIDE a
#                                hunk (inside one they are diff CONTENT — an added line whose text
#                                is `++ b/README.md` arrives byte-identical to a header), and the
#                                file state resets only on a column-0 `diff --git`, which no content
#                                line can ever occupy — so a crafted added line can neither escape
#                                the scope file mid-hunk (hiding the adds that follow) nor forge an
#                                entry into it. Used by bin/fitness-review.sh's deterministic R16 gate.
#   repo-scope.sh confirm-names <line1>
#                                a PR comment's FIRST line → the repo names it CONFIRMs, one per
#                                line, normalized. STRICT + ALL-OR-NOTHING: line 1 must be
#                                `CONFIRMED <repo> [<repo>…]` (optionally `CONFIRMED:`; comma or
#                                space separated) and NOTHING else — a bare CONFIRMED or any
#                                non-name token voids the whole line. Empty output = confirms
#                                nothing. The fitness R16 gate's NAME BINDING: a confirmation
#                                covers the names a maintainer wrote, never "this PR" — a later
#                                head that swaps the adds re-gates unconfirmed.
#   repo-scope.sh --selftest     exercise the pure helpers (no gh / network / clone).
#
# PER-SESSION LAYER (R27/R28) — an OPTIONAL narrowing layer bolted ON TOP of the ceiling, gated ENTIRELY
# by the env var SCOPE_SESSION (the caller's SID):
#   * SCOPE_SESSION UNSET → this reader behaves BYTE-IDENTICALLY to the ceiling-only version above (the
#     session registry is not even consulted or sourced). This is the load-bearing inertness: the running
#     poller sets nothing, so enabling this file changes NOTHING until a caller opts in per-session.
#   * SCOPE_SESSION SET → the session's GIT-VERIFIED scope (session_scope_verified <sid>) NARROWS the
#     ceiling: effective set = verified ∩ ceiling. The session's cached repos are TRUSTED only when they
#     still SET-EQUAL the confirmed-objective repo-list at the session's backing ref — otherwise the
#     session fails CLOSED with the cause named (SESSION_UNBACKED: no/old backing · bad ref · MISMATCH =
#     a hand-edited cache tried to widen). On OK, `check` ALLOWs iff the repo is in the verified set AND
#     not held by another LIVE session (disjointness, R28); an UNDECLARED session (SCOPE_SESSION set but
#     unregistered) acts on NOTHING (fail-closed, F6). A session can only ever NARROW the ceiling, never
#     exceed it. `list` mirrors: the verified effective set, or empty when unverified/undeclared. The
#     ceiling's fail direction is untouched and layered under (an unreadable config still falls back to
#     SCOPE_OWN, and the session narrows within it). `transcribe`/`union`/`owner` support the objective-
#     backed model + the (deferred) poller cutover; see the CLI contract below.
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
#      watches); SCOPE_SESSION (OPTIONAL — the caller's SID; unset ⇒ the session layer is inert and
#      the reader is byte-identical to the ceiling-only version); SCOPE_REGISTRY_DIR (the
#      session-registry store, honoured via the sourced bin/session-registry.sh — only read when
#      SCOPE_SESSION is set).
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
#
# HUNK-STATEFUL (fitness finding 1 on 98e1194 — the crafted-hunk escape): every diff CONTENT line
# rides a +/-/space/\ prefix, so an ADDED line whose text is `++ b/README.md` arrives as
# `+++ b/README.md` — byte-identical to a target-file header. A stateless parser read that as
# "left the scope file" and went blind to every add after it in the same hunk, while the runtime
# parser dropped the invalid line (narrow-only) and GRANTED the adds. So: `+++ `/`--- ` are honored
# as headers ONLY outside a hunk; a hunk opens at a column-0 `@@` and the file/hunk state resets
# ONLY at a column-0 `diff --git` — two shapes no content line can ever occupy (content is always
# prefixed). Inside a scope-file hunk the crafted line is CONTENT: it fails the name grammar and
# counts as nothing — exactly what the runtime parser does with it.
scope_diff_adds(){
  awk -v sf="$1" '
    /^diff --git /  { infile = 0; inhunk = 0; next } # unforgeable file boundary: content is prefixed
    /^@@/           { inhunk = 1; next }             # hunk opens; only diff --git closes it
    inhunk == 0 && /^\+\+\+ / { infile = ($2 == "b/" sf); next }  # header, only OUTSIDE a hunk
    inhunk == 0     { next }                         # ---/index/mode/rename metadata, never content
    !infile         { next }
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

# scope_confirm_names <line1> → the repo names a maintainer's line-1 CONFIRMED covers, one per line,
# normalized — or NOTHING. NAME-BOUND (fitness finding 2 on 98e1194): a confirmation covers exactly
# the repos it NAMES, never "this PR" — nothing else bounds WHAT was confirmed, so an unbound
# CONFIRMED would let a post-confirmation head swap the confirmed add for any other repo and sail
# through. STRICT + ALL-OR-NOTHING: line 1 must be `CONFIRMED <repo> [<repo>…]` (optionally
# `CONFIRMED:`; comma/space/tab separated; an owner/ prefix is normalized off) and NOTHING else — a
# bare CONFIRMED confirms nothing, and ANY non-name token voids the WHOLE line. Prose must never
# mint confirmable names, because the ADDED name is attacker-chosen: a maintainer's
# `CONFIRMED — looks fine` must not confirm repos named `looks`/`fine` (the em-dash voids it).
# RESIDUAL (disclosed): a prose line whose EVERY word fits the name grammar (`CONFIRMED go ahead`)
# does confirm those words as names; the gate still fails closed unless the added repo is literally
# so named, and the RETURN remediation prints the exact line to paste.
scope_confirm_names(){
  local line rest t out=""
  line="${1%$'\r'}"
  case "$line" in
    CONFIRMED) return 0;;
    'CONFIRMED:'*|'CONFIRMED '*|CONFIRMED$'\t'*) rest="${line#CONFIRMED}"; rest="${rest#:}";;
    *) return 0;;
  esac
  local -a toks=()
  IFS=$' \t,' read -r -a toks <<< "$rest"
  for t in "${toks[@]}"; do
    [ -n "$t" ] || continue
    [[ "$t" =~ ^([A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$ ]] || return 0   # all-or-nothing: prose voids it
    out+="$(scope_norm "$t")"$'\n'
  done
  printf '%s' "$out"
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
# `owner/repo` shape and is normalized off its `owner/` prefix (lockstep with scope_norm /
# scope_confirm_names). Fail-closed to EMPTY on no-heading / no-table / zero valid rows.
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

# scope_objective_adds <objective-doc-path> — a unified diff on stdin → the repo names NET-ADDED to the
# objective's repo-list table, one per line, sorted. The R16 "agent never authorizes" DOC boundary once
# the authority moved from scope.conf to 00-OBJECTIVES.md. The hunk-state machine (the crafted
# `+++`-header / `diff --git`-reset defence, 98e1194 finding 1) is PORTED VERBATIM from scope_diff_adds;
# ONLY the per-line extraction differs — a markdown table cell-1 held to the backticked `owner/repo`
# grammar (scope_norm'd), no `#`-comment strip. NOT section-confined within the doc: a stray backticked
# `owner/repo` table row added anywhere in the objective doc triggers a safe RETURN, never a silent widen
# (a strict-grammar SUPERSET — over-gates, never under-gates; section-confinement is a follow-up NOTE).
scope_objective_adds(){
  awk -v sf="$1" '
    /^diff --git /  { infile = 0; inhunk = 0; next }        # unforgeable file boundary (content is prefixed)
    /^@@/           { inhunk = 1; next }                     # hunk opens; only diff --git closes it
    inhunk == 0 && /^\+\+\+ / { infile = ($2 == "b/" sf); next }  # header, only OUTSIDE a hunk
    inhunk == 0     { next }                                 # ---/index/mode metadata, never content
    !infile         { next }
    /^[+-]/ {
      sign = substr($0, 1, 1); l = substr($0, 2)
      sub(/\r$/, "", l)
      if (l !~ /^[ \t]*\|/) next                             # only a markdown table row can carry a name
      sub(/^[ \t]*\|[ \t]*/, "", l)
      sub(/[ \t]*\|.*$/, "", l)
      gsub(/`/, "", l)
      gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (l !~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/) next    # require owner/repo (drops header/separator)
      n = split(l, a, "/"); name = a[n]
      if (sign == "+") add[name] = 1; else del[name] = 1
    }
    END { for (r in add) if (!(r in del)) print r }
  ' | sort
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
  echo "== scope_diff_adds is HUNK-STATEFUL (the crafted-hunk escape is dead — 98e1194 finding 1) =="
  D9=$'diff --git a/policy/scope.conf b/policy/scope.conf\n--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1,2 +1,4 @@\n fedora-dev\n fedora-bootstrap\n+++ b/README.md\n+evil-repo\n'
  ck "an added '++ b/…' line cannot ESCAPE the scope hunk — the add after it is still seen" \
     "$(printf '%s' "$D9" | scope_diff_adds policy/scope.conf)" "evil-repo"
  D10=$'--- a/README.md\n+++ b/README.md\n@@ -1 +1,3 @@\n line\n+++ b/policy/scope.conf\n+knowledge-desktop\n'
  ck "an added '++ b/policy/scope.conf' line in ANOTHER file's hunk cannot forge an ENTRY either" \
     "$(printf '%s' "$D10" | scope_diff_adds policy/scope.conf)" ""
  D11=$'diff --git a/policy/scope.conf b/policy/scope.conf\n--- a/policy/scope.conf\n+++ b/policy/scope.conf\n@@ -1 +1,2 @@\n fedora-dev\n+new-repo\ndiff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n x\n+not-a-scope-add\n'
  ck "state recovers at the next diff --git — a later file's adds never count" \
     "$(printf '%s' "$D11" | scope_diff_adds policy/scope.conf)" "new-repo"
  echo "== scope_confirm_names (98e1194 finding 2 — NAME binding: strict line-1 grammar, all-or-nothing) =="
  ck "one name"                    "$(scope_confirm_names 'CONFIRMED knowledge-desktop')" "knowledge-desktop"
  ck "colon + comma + several"     "$(scope_confirm_names 'CONFIRMED: a-repo, b.repo' | tr '\n' ' ')" "a-repo b.repo "
  ck "owner/ prefix normalized"    "$(scope_confirm_names 'CONFIRMED oso-gato/wl-two')" "wl-two"
  ck "bare CONFIRMED confirms NOTHING (nothing bounds what it would cover)" "$(scope_confirm_names 'CONFIRMED')" ""
  ck "prose voids the WHOLE line (all-or-nothing — words must not become names)" \
     "$(scope_confirm_names 'CONFIRMED — expand the scope for this objective')" ""
  ck "one non-name token voids valid names beside it" "$(scope_confirm_names 'CONFIRMED a-repo (for now)')" ""
  ck "CONFIRMED must OPEN the line" "$(scope_confirm_names 'Sounds good — CONFIRMED a-repo')" ""
  ck "CRLF tolerated"              "$(scope_confirm_names $'CONFIRMED wl-two\r')" "wl-two"
  echo "== objective_row_names (heading-anchored table parse — the git-anchored R16 authority) =="
  OBJ=$'# T\n\n## Objective\n\n| `oso-gato/before-section` | x |\n\n## Repositories this objective operates on\n\nThis objective operates on exactly these repositories:\n\n| Repository | Role |\n|---|---|\n| `oso-gato/fedora-dev` | the DEV |\n| `oso-gato/fedora-bootstrap` | the HOST |\n\nThis list is the authorization.\n\n## Document authority\n\n| `oso-gato/after-section` | w |\n'
  ck "extracts the two scoped repos; header+separator dropped; owner/ normalized; OTHER sections ignored" \
     "$(printf '%s' "$OBJ" | objective_row_names | tr '\n' ' ')" "fedora-dev fedora-bootstrap "
  ck "no Repositories heading → EMPTY (fail-closed)" "$(printf '## Other\n| `oso-gato/x` | y |\n' | objective_row_names)" ""
  ck "a non-backticked/no-slash cell-1 is dropped" "$(printf '## Repositories this objective operates on\n| plainword | y |\n' | objective_row_names)" ""
  echo "== scope_objective_adds (NET adds to the objective repo-list table — the DOC-boundary detector) =="
  OA1=$'diff --git a/00-OBJECTIVES.md b/00-OBJECTIVES.md\n--- a/00-OBJECTIVES.md\n+++ b/00-OBJECTIVES.md\n@@ -1,2 +1,3 @@\n | `oso-gato/fedora-dev` | y |\n | `oso-gato/fedora-bootstrap` | z |\n+| `oso-gato/knowledge-desktop` | new |\n'
  ck "a net-added table row is detected"            "$(printf '%s' "$OA1" | scope_objective_adds 00-OBJECTIVES.md)" "knowledge-desktop"
  OA2=$'--- a/00-OBJECTIVES.md\n+++ b/00-OBJECTIVES.md\n@@ -1 +1,3 @@\n x\n+| Repository | Role |\n+|---|---|\n'
  ck "added header/separator rows are NOT scope names" "$(printf '%s' "$OA2" | scope_objective_adds 00-OBJECTIVES.md)" ""
  OA3=$'--- a/00-OBJECTIVES.md\n+++ b/00-OBJECTIVES.md\n@@ -1,2 +1,1 @@\n | `oso-gato/fedora-dev` | y |\n-| `oso-gato/e2e-alpha` | z |\n'
  ck "a removal-only diff is NOT an expansion"      "$(printf '%s' "$OA3" | scope_objective_adds 00-OBJECTIVES.md)" ""
  OA4=$'--- a/00-OBJECTIVES.md\n+++ b/00-OBJECTIVES.md\n@@ -1,2 +1,2 @@\n-| `oso-gato/x` | a |\n | `oso-gato/y` | b |\n+| `oso-gato/x` | a |\n'
  ck "a MOVED row is net zero"                      "$(printf '%s' "$OA4" | scope_objective_adds 00-OBJECTIVES.md)" ""
  OA5=$'--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n line\n+| `oso-gato/knowledge-desktop` | x |\n'
  ck "the same row added to ANOTHER file never trips (path-scoped)" "$(printf '%s' "$OA5" | scope_objective_adds 00-OBJECTIVES.md)" ""
  OA6=$'diff --git a/00-OBJECTIVES.md b/00-OBJECTIVES.md\n--- a/00-OBJECTIVES.md\n+++ b/00-OBJECTIVES.md\n@@ -1,2 +1,4 @@\n | `oso-gato/fedora-dev` | y |\n+++ b/README.md\n+| `oso-gato/evil` | x |\n'
  ck "a crafted +++ line cannot ESCAPE the hunk (the add after it is still seen)" "$(printf '%s' "$OA6" | scope_objective_adds 00-OBJECTIVES.md)" "evil"
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

read_scope(){ # → parsed list on stdout; rc 0 = the config was READABLE (even if it parsed empty)
  [ -f "$SCOPE_FILE" ] && [ -r "$SCOPE_FILE" ] || return 1
  scope_parse < "$SCOPE_FILE"
  return 0
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
# objective_clone_dir <repo> → where the repo's clone lives locally (test seam: $SCOPE_OBJECTIVE_CLONE).
objective_clone_dir(){ printf '%s' "${SCOPE_OBJECTIVE_CLONE:-$HOME/.local/share/$1}"; }

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

# session_scope_verified <sid> → LINE 1 = the verification STATE, then (on OK only) the verified repos:
#   OK           — the session is registered, backed, AND its cached line-3 repos SET-EQUAL the objective
#                  repo-list at its backing ref → lines 2..N are those repos (the verified scope to act on).
#   UNREGISTERED — no registry entry (or empty scope).
#   UNBACKED     — registered but line 4 is absent/'-' or malformed (a pre-backing entry, or a hand-forge).
#   UNREADABLE   — the backing ref (repo/path/sha) can't be read/parsed to a non-empty repo-list.
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
        log "SCOPE CONFIG UNREADABLE ($SCOPE_FILE) — falling back to the apparatus's OWN repos ONLY: $SCOPE_OWN (R16 fail-closed; everything else is frozen until the config is readable)"
        printf '%s\n' $SCOPE_OWN
      fi
      exit 0
    fi
    # ── SCOPE_SESSION SET → the effective set = session declared scope ∩ ceiling ──
    if scope="$(read_scope)"; then
      ceiling_list="$(printf '%s\n' "$scope" | grep . || true)"
    else
      log "SCOPE CONFIG UNREADABLE ($SCOPE_FILE) — falling back to the apparatus's OWN repos ONLY: $SCOPE_OWN (R16 fail-closed; everything else is frozen until the config is readable)"
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
          # UNBACKED | UNREADABLE | MISMATCH → the session's git backing is broken/forged; act on NOTHING.
          # A ceiling DENY/FALLBACK_DENY still stands (preserves its own rc/log); otherwise SESSION_UNBACKED.
          sbacking_cause="$sstate"
          case "$ceiling" in DENY|FALLBACK_DENY) verdict="$ceiling";; *) verdict="SESSION_UNBACKED";; esac;;
      esac
    fi
    case "$verdict" in
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
        log "DENY: session '$SCOPE_SESSION' scope is not git-verified ($sbacking_cause) — R16: the registry cache does not match the confirmed-objective repo-list at its backing ref (UNBACKED=no/old backing, UNREADABLE=bad ref, MISMATCH=hand-edited to widen); fail-closed to nothing. Re-transcribe: bin/repo-scope.sh transcribe --backing '<repo> <path> <sha>' <sid>"
        exit 3;;
    esac;;
  diff-adds)
    scope_diff_adds "${2:-$SCOPE_CONF_REL}"
    exit 0;;
  confirm-names)
    scope_confirm_names "${2:-}"
    exit 0;;
  objective-adds)
    # the DOC-boundary detector (R16): net-adds to the objective repo-list table (default 00-OBJECTIVES.md).
    scope_objective_adds "${2:-00-OBJECTIVES.md}"
    exit 0;;
  transcribe)
    # transcribe --backing '<repo> <objective-path> <sha>' <sid> — DERIVE the repos from the confirmed
    # objective at that ref and register them for the session (the agent transcribes, never authorizes, R16).
    shift
    tbacking=""
    if [ "${1:-}" = "--backing" ]; then tbacking="${2:-}"; shift 2 2>/dev/null || shift "$#"; fi
    tsid="${1:-}"
    { [ -n "$tbacking" ] && [ -n "$tsid" ]; } || { log "usage: repo-scope.sh transcribe --backing '<repo> <objective-path> <sha>' <sid>"; exit 2; }
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
    echo "usage: repo-scope.sh check <repo> | list | diff-adds [path] | objective-adds [path] | confirm-names <line1> | transcribe --backing '<repo> <path> <sha>' <sid> | union | owner <repo> | --selftest" >&2
    exit 2;;
esac
