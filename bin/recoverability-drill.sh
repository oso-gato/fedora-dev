#!/usr/bin/env bash
# recoverability-drill.sh — R38 UNIVERSAL RECOVERABILITY, the per-action reversibility DRILLS
# (fedora-dev#207; the R10 model GENERALIZED). The requirement:
#
#   "Every autonomous mutation the apparatus makes is reversible … per-action recoverability DRILLS
#    (a proven-fired revert/reopen/rollback before each such actuator arms, the R10 model generalized)."
#
# R10 already proves this for ONE mutation: "Autonomous deploys arm only after a rollback drill has
# demonstrably FIRED GREEN." Everywhere else, recoverability was only ASSERTED (the NFR) and
# REVIEW-enforced (fitness's standing preserve-recoverability rule) — never DRILLED. This harness
# closes that gap by drilling the reverse operation of each autonomous mutation the way R10 drills the
# digest rollback: it actually PERFORMS the reverse against a DISPOSABLE fixture and asserts it restores
# the pre-mutation state. A GREEN is a PROOF, not a claim.
#
# THE FOUR MUTATIONS ↔ THEIR REVERSE OPERATIONS (R38):
#   merge   → git revert           (auto-merge.sh does `gh pr merge --squash`; the reverse is a
#                                    `git revert` of the squash commit on main)
#   scope   → transcribe-narrow    (repo-scope.sh `transcribe` registers a session scope; the reverse is
#                                    re-declaring/narrowing it — a re-transcribe against a narrowed authority)
#   close   → reopen               (reconcile.sh / poller retire close issues+PRs REVERSIBLY — a `close`
#                                    with a comment, never a destructive delete; the reverse is `gh … reopen`)
#   rebuild → restore-from-registry (rebuild-request.sh drives the R17 KILL→REBUILD→RESTORE lifecycle; the
#                                    reverse is restoring the retained last-known-good image digest)
#
# WHAT FIRES OFFLINE vs. WHAT IS STAGED (honest, per R37 — no silent degradation):
#   * merge + scope drills are FAITHFUL and OFFLINE: they run the REAL reverse operation (real `git
#     revert`; the real `repo-scope.sh transcribe` + session registry) against a throwaway git/registry
#     fixture, with NO network, engine, model, or external side effect. They FIRE GREEN here and in the
#     unit test — genuinely proven, not modelled.
#   * close + rebuild drills need a live boundary the reverse operation actually touches (GitHub for a
#     reopen round-trip; the container engine for a digest restore). By default they report **STAGED**
#     — a DISCLOSED, surfaced not-yet-fired state (never a fake GREEN — the ANTI-THEATER doctrine: a
#     drill that pretends to prove a reverse op it never ran is worse than none). Opt in with
#     RECOVERY_DRILL_LIVE=1 (+ RECOVERY_DRILL_REPO=<scratch repo> for close) to fire the real round-trip.
#
# EXIT / VERDICT CONTRACT (the "arm only after GREEN" primitive):
#   recoverability-drill.sh <mutation>   run ONE drill → line 1 the verdict; rc 0 GREEN · 1 RED · 3 STAGED.
#   recoverability-drill.sh all          run all four → a table + overall verdict; rc 0 unless a drill RED
#                                        (GREEN=all fired, PARTIAL=fired where runnable + N staged, RED=a
#                                        reverse op FAILED). STAGED is surfaced, never a silent pass (R37).
#   recoverability-drill.sh guard <m>    the ARM GATE: rc 0 IFF that mutation's drill FIRES GREEN — the
#                                        R10 "arms only after the drill fires GREEN" contract, callable by
#                                        an arming step. RED and STAGED both BLOCK (an unproven reverse op
#                                        must not arm). Neither this file nor #207 wires it into an
#                                        actuator's arm — per-actuator arm-wiring is the disclosed
#                                        follow-on (R38 keeps the drills backlogged; #207 lands the drills
#                                        + the guard primitive, NOT the merge-gate/hot-path wiring).
#   recoverability-drill.sh --selftest   exercise the pure verdict core (no git/registry/network).
#
# ENV: RECOVERY_DRILL_LIVE (0/1 — fire the close+rebuild live round-trips) · RECOVERY_DRILL_REPO (the
#      scratch owner/repo the close drill creates+reopens+closes an issue in) · TMPDIR.
#
# Covered by recoverability-drill.test.sh (real git revert + real transcribe rollback + the STAGED
# reports + a mutation on the verdict fold). Control-plane (the recoverability boundary's prover).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
SELF="$HERE/$(basename "$0")"

# ---- PURE CORE (--selftest covers exactly these) ---------------------------------------------------

# reverse_op <mutation> → the concise name of that mutation's reverse operation (the R38 pairing).
# Unknown mutation → empty + rc 1 (fail-closed: an unnamed mutation has no proven reverse).
reverse_op(){
  case "$1" in
    merge)   printf 'git revert';;
    scope)   printf 'transcribe-narrow (re-declare)';;
    close)   printf 'reopen (gh issue/pr reopen)';;
    rebuild) printf 'restore-from-registry (R17)';;
    *)       return 1;;
  esac
}

# overall_verdict <outcome…> → fold per-drill outcomes into GREEN | PARTIAL | RED.
#   any RED           → RED     (a reverse operation demonstrably FAILED — recoverability is broken)
#   else any STAGED   → PARTIAL (fired GREEN where runnable; ≥1 drill disclosed as not-yet-fired)
#   else              → GREEN   (every drill fired GREEN)
# This is the mutation anchor the test neutralizes: break it and a RED drill stops surfacing as RED.
overall_verdict(){
  local o red=0 staged=0
  for o in "$@"; do
    case "$o" in RED) red=1;; STAGED) staged=1;; esac
  done
  if [ "$red" = 1 ]; then printf 'RED'
  elif [ "$staged" = 1 ]; then printf 'PARTIAL'
  else printf 'GREEN'; fi
}

# guard_ok <outcome> → rc 0 IFF the drill FIRED GREEN. The strict arm gate: RED and STAGED both block,
# because "arm only after the drill fires GREEN" (R10) means a not-yet-fired reverse op does not arm.
guard_ok(){ [ "${1:-}" = GREEN ]; }

# ---- DRILLS — each PERFORMS the reverse op against a DISPOSABLE fixture, echoes `<OUTCOME>\t<detail>` --

# merge → git revert (FAITHFUL, offline): a throwaway repo, a real squash-merge onto main (auto-merge.sh's
# actual verb), then `git revert` the merge — GREEN iff the reverted tree EQUALS the pre-merge tree AND
# the merge had actually changed it (a vacuous revert of a no-op is not a proof).
drill_merge(){
  local d lkg merged rev
  d="$(mktemp -d "${TMPDIR:-/tmp}/recdrill-merge.XXXXXX")" || { printf 'RED\tcannot mktemp\n'; return; }
  (
    set -e
    cd "$d"
    git -c init.defaultBranch=main init -q .
    git config user.email drill@fedora-dev.local
    git config user.name  recovery-drill
    printf 'last-known-good\n' > f.txt
    git add f.txt; git commit -q -m 'LKG (pre-merge main)'
    git rev-parse 'HEAD^{tree}' > .lkg
    git switch -q -c feature
    printf 'feature change\n' >> f.txt
    git add f.txt; git commit -q -m 'feature work'
    git switch -q main
    git merge -q --squash feature          # the autonomous merge: gh pr merge --squash → one commit
    git commit -q -m 'autonomous squash-merge (#207)'
    git rev-parse 'HEAD^{tree}' > .merged
    git revert --no-edit HEAD >/dev/null   # THE REVERSE OPERATION
    git rev-parse 'HEAD^{tree}' > .rev
  ) >/dev/null 2>&1
  if [ ! -s "$d/.lkg" ] || [ ! -s "$d/.merged" ] || [ ! -s "$d/.rev" ]; then
    rm -rf "$d"; printf 'RED\tgit revert drill did not complete (git error)\n'; return
  fi
  lkg="$(cat "$d/.lkg")"; merged="$(cat "$d/.merged")"; rev="$(cat "$d/.rev")"
  rm -rf "$d"
  if [ "$merged" != "$lkg" ] && [ "$rev" = "$lkg" ]; then
    printf 'GREEN\tgit revert restored the pre-merge tree exactly (%s)\n' "${lkg:0:12}"
  else
    printf 'RED\trevert did NOT restore the pre-merge tree (lkg=%s merged=%s rev=%s)\n' \
      "${lkg:0:12}" "${merged:0:12}" "${rev:0:12}"
  fi
}

# scope → transcribe-narrow (FAITHFUL, offline): a throwaway objective clone + session registry. Transcribe
# an EXPANDED scope {keep, added}, then perform the reverse — a re-transcribe against a NARROWED objective
# {keep} — via the REAL bin/repo-scope.sh + bin/session-registry.sh. GREEN iff the added repo was present
# before and is GONE after, while the kept repo survives (a faithful rollback, not a wipe).
drill_scope(){
  local d reg objdir sha1 sha2 sid before after
  d="$(mktemp -d "${TMPDIR:-/tmp}/recdrill-scope.XXXXXX")" || { printf 'RED\tcannot mktemp\n'; return; }
  reg="$d/registry"; objdir="$d/objective"; mkdir -p "$objdir"
  (
    set -e
    cd "$objdir"
    git -c init.defaultBranch=main init -q .
    git config user.email drill@fedora-dev.local
    git config user.name  recovery-drill
    cat > 00-OBJECTIVES.md <<'MD'
# Objective

## Repositories this objective operates on

| Repository | Role |
|---|---|
| `oso-gato/recovery-drill-keep`  | kept |
| `oso-gato/recovery-drill-added` | to be rolled back |
MD
    git add 00-OBJECTIVES.md; git commit -q -m 'scope: keep + added'
    git rev-parse HEAD > .sha1
    cat > 00-OBJECTIVES.md <<'MD'
# Objective

## Repositories this objective operates on

| Repository | Role |
|---|---|
| `oso-gato/recovery-drill-keep`  | kept |
MD
    git add 00-OBJECTIVES.md; git commit -q -m 'scope: narrowed (rollback)'
    git rev-parse HEAD > .sha2
  ) >/dev/null 2>&1
  sha1="$(cat "$objdir/.sha1" 2>/dev/null)"; sha2="$(cat "$objdir/.sha2" 2>/dev/null)"
  if [ -z "$sha1" ] || [ -z "$sha2" ]; then rm -rf "$d"; printf 'RED\tobjective fixture git setup failed\n'; return; fi
  sid="recovery-drill-scope-$$"
  SCOPE_REGISTRY_DIR="$reg" SCOPE_OBJECTIVE_CLONE="$objdir" SESSION_HOLDER_PID="$$" \
    "$HERE/repo-scope.sh" transcribe --backing "objective 00-OBJECTIVES.md $sha1" "$sid" >/dev/null 2>&1
  before="$(SCOPE_REGISTRY_DIR="$reg" "$HERE/session-registry.sh" resolve "$sid" 2>/dev/null)"
  # THE REVERSE OPERATION: re-declare/narrow the scope by re-transcribing the narrowed authority.
  SCOPE_REGISTRY_DIR="$reg" SCOPE_OBJECTIVE_CLONE="$objdir" SESSION_HOLDER_PID="$$" \
    "$HERE/repo-scope.sh" transcribe --backing "objective 00-OBJECTIVES.md $sha2" "$sid" >/dev/null 2>&1
  after="$(SCOPE_REGISTRY_DIR="$reg" "$HERE/session-registry.sh" resolve "$sid" 2>/dev/null)"
  rm -rf "$d"
  local had_added kept_after has_added_after
  printf '%s\n' $before | grep -qx 'recovery-drill-added' && had_added=1 || had_added=0
  printf '%s\n' $after  | grep -qx 'recovery-drill-keep'  && kept_after=1 || kept_after=0
  printf '%s\n' $after  | grep -qx 'recovery-drill-added' && has_added_after=1 || has_added_after=0
  if [ "$had_added" = 1 ] && [ "$has_added_after" = 0 ] && [ "$kept_after" = 1 ]; then
    printf 'GREEN\ttranscribe-narrow rolled the scope back (added repo removed; kept repo retained)\n'
  else
    printf 'RED\tnarrowing re-transcribe did not roll the scope back (before=[%s] after=[%s])\n' \
      "$(echo $before)" "$(echo $after)"
  fi
}

# close → reopen: STAGED by default (the reverse is a live GitHub verb with no offline analog — faking it
# would be theater). Opt in with RECOVERY_DRILL_LIVE=1 + RECOVERY_DRILL_REPO to fire a real
# create→close→reopen→assert-OPEN→close round-trip (the actuators close REVERSIBLY, never delete).
drill_close(){
  if [ "${RECOVERY_DRILL_LIVE:-0}" != 1 ] || [ -z "${RECOVERY_DRILL_REPO:-}" ]; then
    printf 'STAGED\treverse=`gh issue/pr reopen`; needs live GitHub — RECOVERY_DRILL_LIVE=1 RECOVERY_DRILL_REPO=<scratch> %s close\n' "$SELF"
    return
  fi
  local repo="$RECOVERY_DRILL_REPO" url num state
  url="$(gh issue create --repo "$repo" --title "recoverability drill (reopen) — disposable" \
          --body "Transient issue created by recoverability-drill.sh to prove close→reopen. Safe to delete." 2>/dev/null)" \
    || { printf 'RED\tcould not create the disposable drill issue in %s\n' "$repo"; return; }
  num="${url##*/}"
  gh issue close  --repo "$repo" "$num" >/dev/null 2>&1 || { printf 'RED\tclose failed on drill issue #%s\n' "$num"; return; }
  gh issue reopen --repo "$repo" "$num" >/dev/null 2>&1 || { printf 'RED\treopen (the reverse op) failed on drill issue #%s\n' "$num"; return; }
  state="$(gh issue view --repo "$repo" "$num" --json state -q .state 2>/dev/null)"
  gh issue close --repo "$repo" "$num" >/dev/null 2>&1 || true   # leave it closed (cleanup)
  if [ "$state" = OPEN ]; then
    printf 'GREEN\treopen restored the closed issue to OPEN (#%s in %s)\n' "$num" "$repo"
  else
    printf 'RED\treopen did not restore OPEN (state=%s, #%s)\n' "$state" "$num"
  fi
}

# rebuild → restore-from-registry (R17): STAGED by default (the reverse restores a retained image digest —
# it needs the container engine). Opt in with RECOVERY_DRILL_LIVE=1 to fire a real digest-restore round-trip
# in the LOCAL image store (a faithful stand-in for the registry): build LKG → "rebuild" a new image →
# restore the retained LKG reference → assert the restored digest equals the LKG digest.
drill_rebuild(){
  if [ "${RECOVERY_DRILL_LIVE:-0}" != 1 ]; then
    printf 'STAGED\treverse=restore-from-registry (R17); needs the container engine — RECOVERY_DRILL_LIVE=1 %s rebuild\n' "$SELF"
    return
  fi
  command -v podman >/dev/null 2>&1 || { printf 'RED\tRECOVERY_DRILL_LIVE=1 but no container engine (podman) to drill restore-from-registry\n'; return; }
  local d lkg cur lkg_id cur_id restored_id tag="localhost/recovery-drill"
  d="$(mktemp -d "${TMPDIR:-/tmp}/recdrill-rebuild.XXXXXX")" || { printf 'RED\tcannot mktemp\n'; return; }
  cleanup_rebuild(){ podman rmi -f "$tag:lkg" "$tag:current" "$tag:rebuilt" >/dev/null 2>&1 || true; rm -rf "$d"; }
  printf 'FROM scratch\nLABEL recovery-drill=lkg\n'     > "$d/Containerfile.lkg"
  printf 'FROM scratch\nLABEL recovery-drill=rebuilt\n' > "$d/Containerfile.new"
  if ! podman build -q -t "$tag:lkg"     -f "$d/Containerfile.lkg" "$d" >/dev/null 2>&1 \
    || ! podman build -q -t "$tag:rebuilt" -f "$d/Containerfile.new" "$d" >/dev/null 2>&1; then
    cleanup_rebuild; printf 'RED\tcould not build the drill images (engine error)\n'; return
  fi
  lkg_id="$(podman image inspect "$tag:lkg" --format '{{.Id}}' 2>/dev/null)"
  podman tag "$tag:rebuilt" "$tag:current" >/dev/null 2>&1     # the "rebuild" moves :current to the new image
  cur_id="$(podman image inspect "$tag:current" --format '{{.Id}}' 2>/dev/null)"
  podman tag "$tag:lkg" "$tag:current" >/dev/null 2>&1         # THE REVERSE OPERATION: restore the retained LKG
  restored_id="$(podman image inspect "$tag:current" --format '{{.Id}}' 2>/dev/null)"
  cleanup_rebuild
  if [ -n "$lkg_id" ] && [ "$cur_id" != "$lkg_id" ] && [ "$restored_id" = "$lkg_id" ]; then
    printf 'GREEN\trestore-from-registry returned :current to the retained LKG digest (%s)\n' "${lkg_id:0:19}"
  else
    printf 'RED\trestore did not return :current to the LKG digest (lkg=%s cur=%s restored=%s)\n' \
      "${lkg_id:0:12}" "${cur_id:0:12}" "${restored_id:0:12}"
  fi
}

# ---- RUNNERS ---------------------------------------------------------------------------------------

one(){
  local m="$1" outcome detail
  IFS=$'\t' read -r outcome detail < <("drill_$m")
  printf '%-8s → %-34s : %-6s %s\n' "$m" "$(reverse_op "$m")" "$outcome" "$detail"
  case "$outcome" in GREEN) return 0;; STAGED) return 3;; *) return 1;; esac
}

run_all(){
  local m outcome detail; local -a outcomes=()
  printf 'recoverability drill — R38 per-action reversibility (the R10 deploy-rollback model generalized)\n'
  for m in merge scope close rebuild; do
    IFS=$'\t' read -r outcome detail < <("drill_$m")
    outcomes+=("$outcome")
    printf '  %-8s → %-34s : %-6s %s\n' "$m" "$(reverse_op "$m")" "$outcome" "$detail"
  done
  local v; v="$(overall_verdict "${outcomes[@]}")"
  printf 'verdict: %s\n' "$v"
  [ "$v" != RED ]
}

guard(){
  local m="$1" outcome detail
  reverse_op "$m" >/dev/null || { printf 'guard: unknown mutation %s\n' "$m" >&2; return 2; }
  IFS=$'\t' read -r outcome detail < <("drill_$m")
  printf 'guard %s: %s — %s\n' "$m" "$outcome" "$detail" >&2
  guard_ok "$outcome"
}

# ---- DISPATCH (only when executed directly; sourcing exposes the pure helpers to a caller) ----------
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || true; fi

# ---- SELFTEST ---------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== reverse_op (the R38 mutation→reverse pairing; unknown fails closed) =="
  ck "merge → git revert"         "$(reverse_op merge)"   "git revert"
  ck "scope → transcribe-narrow"  "$(reverse_op scope)"   "transcribe-narrow (re-declare)"
  ck "close → reopen"             "$(reverse_op close)"   "reopen (gh issue/pr reopen)"
  ck "rebuild → restore"          "$(reverse_op rebuild)" "restore-from-registry (R17)"
  reverse_op bogus >/dev/null; ck "unknown mutation → rc 1" "$?" "1"
  echo "== overall_verdict (RED dominates; else STAGED→PARTIAL; else GREEN) =="
  ck "all green → GREEN"          "$(overall_verdict GREEN GREEN GREEN GREEN)" "GREEN"
  ck "a staged → PARTIAL"         "$(overall_verdict GREEN GREEN STAGED STAGED)" "PARTIAL"
  ck "a RED dominates a staged"   "$(overall_verdict GREEN STAGED RED STAGED)" "RED"
  ck "a lone RED → RED"           "$(overall_verdict RED)" "RED"
  ck "empty → GREEN (vacuous)"    "$(overall_verdict)" "GREEN"
  echo "== guard_ok (the strict arm gate — only a fired GREEN arms) =="
  guard_ok GREEN;  ck "GREEN arms (rc 0)"   "$?" "0"
  guard_ok STAGED; ck "STAGED blocks (rc 1)" "$?" "1"
  guard_ok RED;    ck "RED blocks (rc 1)"    "$?" "1"
  echo; echo "recoverability-drill selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

case "${1:-all}" in
  all)                      run_all;;
  merge|scope|close|rebuild) one "$1";;
  guard)                    shift; [ -n "${1:-}" ] || { echo "usage: recoverability-drill.sh guard <merge|scope|close|rebuild>" >&2; exit 2; }; guard "$1";;
  *) echo "usage: recoverability-drill.sh [all | merge | scope | close | rebuild | guard <mutation> | --selftest]" >&2; exit 2;;
esac
