#!/usr/bin/env bash
# seam-audit.sh — find the test-suite blind spot: a PRODUCTION PATH NO TEST EVER RUNS.
#
# THE DEFECT CLASS THIS EXISTS FOR. Every script here exposes env SEAMS so its tests can stand in for
# something expensive — `${APPLY_VERIFY_CMD:-<the real verify>}`, `${CC_TOKEN_CMD:-<the real minter>}`,
# `${RECONCILE_MAX_AGE:-172800}`. That is sound. It becomes a blind spot the moment EVERY row of a suite
# overrides the same seam: the default — the thing that actually runs on the box — is then never executed
# by anything, and the suite reports green over code that has never run once.
#
# MEASURED 2026-07-29. Four defects shipped or nearly shipped through exactly this hole, each invisible
# to a passing suite:
#   * host-apply's health gate ran `runuser` with no user session, so apply-bootstrap failed 45/45 for
#     seven days. Every test row set $APPLY_VERIFY_CMD, so that line had never been executed by a test.
#   * container-config authenticated with a minter whose key path exists only inside a container. Every
#     row set $CC_TOKEN_CMD, so the default auth path — the only one production uses — never ran.
#   * reconcile's 48h age window was the sole thing preventing a false close, and every row ran with
#     RECONCILE_MAX_AGE=99999999999, i.e. with that guard disabled.
#   * reconcile's `gh --arg` call was rejected outright by real gh; the stub accepted it, so 31/31 passed
#     over a reconciler that could not close anything at all.
#
# WHAT IT CHECKS (mechanical, no annotation required):
#   (1) ALWAYS-OVERRIDDEN SEAMS — a seam the SUT defines with a default, which the suite sets on EVERY
#       invocation of that SUT. The default path is unexercised. This is the hole above.
#   (2) VACUOUS MUTATIONS — a suite that builds a mutant with `sed` but never asserts the copy actually
#       CHANGED. A sed that matches nothing yields an identical file, the row passes, and it proves
#       nothing. Observed live: poller-anomaly-repair's enrol mutation silently stopped biting when the
#       call site it targeted was reshaped.
#
# It is a LINTER, not a test: it reports where confidence is unearned. Findings are advisory unless
# listed as MUST in seam-audit-allow.txt — see that file for the accepted-exception contract.
#
#   seam-audit.sh              audit this repo; rc 1 if any UNALLOWED finding
#   seam-audit.sh --list       print every finding, including allowlisted ones
#   seam-audit.sh --selftest   exercise the pure core (no repo scan)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="${SEAM_AUDIT_ROOT:-$(cd "$HERE/.." && pwd)}"
ALLOW="${SEAM_AUDIT_ALLOW:-$ROOT/seam-audit-allow.txt}"

# ---- PURE CORE (--selftest covers exactly this) -----------------------------------------------------

# seam_verdict <total-invocations> <invocations-that-override> → COVERED | BLIND | NONE
#   NONE    — the suite never invokes the SUT (nothing to say).
#   BLIND   — every invocation overrides the seam ⇒ the DEFAULT path is never executed.
#   COVERED — at least one invocation leaves the default in place.
# A suite with exactly ONE invocation that overrides is still BLIND: one row is the whole corpus.
seam_verdict(){
  local total="${1:-0}" overridden="${2:-0}"
  case "$total$overridden" in *[!0-9]*) echo NONE; return;; esac
  [ "$total" -gt 0 ] 2>/dev/null || { echo NONE; return; }
  [ "$overridden" -ge "$total" ] 2>/dev/null && { echo BLIND; return; }
  echo COVERED
}

# mutation_verdict <has-sed:0|1> <has-vacuity-guard:0|1> → OK | VACUOUS | NA
#   A mutation with no guard cannot distinguish "the mutant failed as intended" from "sed matched
#   nothing, so I re-ran the original and it passed".
mutation_verdict(){
  local sed_present="${1:-0}" guard="${2:-0}"
  [ "$sed_present" = 1 ] || { echo NA; return; }
  [ "$guard" = 1 ] && echo OK || echo VACUOUS
}

# gh_flag_verdict <flag> <space-separated-accepted-flags> → OK | UNKNOWN-FLAG
# The judgment-free check, and the one that matters most. A flag `gh` does not accept makes cobra reject
# the command BEFORE any network call, so the call returns nothing — and a stubbed `gh` in a test will
# happily accept it, so the suite passes over a call production can never make.
# MEASURED 2026-07-29: reconcile.sh passed `-q --arg pr "$3"`. `gh` has no `--arg` (it takes ONE
# positional jq program and supports no jq variables), so every field came back empty, every ref became
# SKIP:unreadable, and the reconciler would have closed NOTHING in any repo. reconcile.test.sh reported
# 31/31 over it, because its fake gh accepted the flag real gh refuses.
gh_flag_verdict(){
  local flag="${1:-}" accepted=" ${2:-} "
  case "$flag" in --*) : ;; *) echo OK; return;; esac      # only long flags are checked
  case "$accepted" in *" $flag "*) echo OK;; *) echo UNKNOWN-FLAG;; esac
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== seam_verdict — is the DEFAULT path ever executed? =="
  ck "never invoked → NONE"          "$(seam_verdict 0 0)" "NONE"
  ck "some rows leave default → OK"  "$(seam_verdict 5 3)" "COVERED"
  ck "one row leaves default → OK"   "$(seam_verdict 5 4)" "COVERED"
  # THE MEASURED CASE: container-config had 8 rows and every one set CC_TOKEN_CMD.
  ck "every row overrides → BLIND"   "$(seam_verdict 8 8)" "BLIND"
  ck "single row, overridden → BLIND" "$(seam_verdict 1 1)" "BLIND"
  ck "single row, default → COVERED" "$(seam_verdict 1 0)" "COVERED"
  ck "garbage → NONE"                "$(seam_verdict x 1)" "NONE"
  echo "== mutation_verdict — does the mutant actually differ? =="
  ck "no sed at all → NA"            "$(mutation_verdict 0 0)" "NA"
  ck "sed + guard → OK"              "$(mutation_verdict 1 1)" "OK"
  # THE MEASURED CASE: poller-anomaly-repair's enrol mutation stopped matching and proved nothing.
  ck "sed, no guard → VACUOUS"       "$(mutation_verdict 1 0)" "VACUOUS"
  echo "== gh_flag_verdict — a flag gh does not accept makes the whole call a no-op =="
  ck "accepted flag → OK"        "$(gh_flag_verdict --json '--json --jq --repo')" "OK"
  # THE MEASURED CASE: gh issue view accepts --comments --help --jq --json --repo --template --web.
  ck "--arg is NOT a gh flag"    "$(gh_flag_verdict --arg '--json --jq --repo --template --web')" "UNKNOWN-FLAG"
  ck "short flags not checked"   "$(gh_flag_verdict -q '--json')" "OK"
  ck "non-flag token ignored"    "$(gh_flag_verdict state,labels '--json')" "OK"
  echo; echo "seam-audit selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi


# ---- SCAN -------------------------------------------------------------------------------------------
LIST=0; [ "${1:-}" = "--list" ] && LIST=1

allowed(){ # <kind> <file> <seam>
  [ -r "$ALLOW" ] || return 1
  grep -qxF "$1 $2 $3" "$ALLOW" 2>/dev/null
}

findings=0; advisory=0; allowed_n=0
printf '== seam-audit: production paths no test executes ==\n'

# Every suite in the repo root and validation/.
for t in "$ROOT"/*.test.sh "$ROOT"/validation/*.test.sh; do
  [ -f "$t" ] || continue
  tb="${t#"$ROOT"/}"
  # Which script does it drive? The suites all name it in one of these.
  sut="$(grep -hoE '^(SUT|EXEC|SCRIPT|POLLER|WATCH)="[^"]+"' "$t" 2>/dev/null | head -1 | sed -E 's/^[A-Z]+="//; s/"$//')"
  sut="$(printf '%s' "$sut" | sed -e "s|\$HERE|$ROOT|g" -e 's|/\.\./|/|g')"
  [ -f "$sut" ] || continue
  sutb="${sut#"$ROOT"/}"

  # (1) ALWAYS-OVERRIDDEN SEAMS.
  # Lines that INVOKE the SUT are the population. A seam set on every one of them is blind.
  inv_total="$(grep -cE 'bash "\$(SUT|EXEC|SCRIPT|POLLER|WATCH)"|"\$(SUT|EXEC|SCRIPT|POLLER|WATCH)" ' "$t" 2>/dev/null || echo 0)"
  [ "${inv_total:-0}" -gt 0 ] || continue
  # Seams the SUT itself defines with a default.
  while IFS= read -r seam; do
    [ -n "$seam" ] || continue
    # How many invocation lines carry this seam? (env prefix or a run() helper that always sets it)
    ov="$(grep -E 'bash "\$(SUT|EXEC|SCRIPT|POLLER|WATCH)"|"\$(SUT|EXEC|SCRIPT|POLLER|WATCH)" ' "$t" 2>/dev/null | grep -c "\\b$seam=" || echo 0)"
    # A run()/helper wrapper sets it once for every row: count that as covering all invocations.
    if grep -qE "^[a-z_]+\(\)\{?.*\b$seam=" "$t" 2>/dev/null || grep -qE "^\s+(env |)[A-Z_]*\s*\b$seam=.*\\\\$" "$t" 2>/dev/null; then
      ov="$inv_total"
    fi
    v="$(seam_verdict "$inv_total" "$ov")"
    [ "$v" = BLIND ] || continue
    if allowed SEAM "$tb" "$seam"; then
      allowed_n=$((allowed_n+1))
      [ "$LIST" = 1 ] && printf '  allow SEAM     %-34s %-26s (accepted)\n' "$tb" "$seam"
      continue
    fi
    advisory=$((advisory+1))
    printf '  blind seam     %-34s %-26s %s\n' "$tb" "$seam" "every invocation overrides it — ${sutb}'s default never runs"
  done < <(grep -hoE "^[A-Z_]+=\"\\\$\{[A-Z_]+:-" "$sut" 2>/dev/null | grep -oE '\{[A-Z_]+' | tr -d '{' | sort -u)

  # (2) VACUOUS MUTATIONS.
  if grep -qE "sed .*(\"\\\$SUT\"|\"\\\$EXEC\"|\"\\\$SCRIPT\"|\"\\\$POLLER\") *>" "$t" 2>/dev/null; then
    # A guard is any assertion that the mutant differs from the original, or that the sed changed it.
    g=0
    grep -qE 'VACUOUS|vacuous|cmp -s|! *cmp|grep -q .*"\$MUT|sed did not change' "$t" 2>/dev/null && g=1
    if [ "$(mutation_verdict 1 "$g")" = VACUOUS ]; then
      if allowed MUTATION "$tb" '-'; then
        allowed_n=$((allowed_n+1))
        [ "$LIST" = 1 ] && printf '  allow MUTATION %-34s %-26s (accepted)\n' "$tb" '-'
      else
        advisory=$((advisory+1))
        printf '  vacuous mut    %-34s %-26s %s\n' "$tb" '-' 'builds a sed mutant but never asserts the copy changed'
      fi
    fi
  fi
done

# (3) UNKNOWN gh FLAGS — every long flag the production code passes to a gh subcommand must exist in
# that subcommand's own --help. Needs no allowlist and no judgment: a flag gh rejects is always a bug.
if command -v gh >/dev/null 2>&1; then
  while IFS= read -r call; do
    sub="$(printf '%s' "$call" | sed -E 's/^.*\bgh +//; s/ .*//')"
    sub2="$(printf '%s' "$call" | sed -E 's/^.*\bgh +[a-z-]+ +//; s/ .*//')"
    case "$sub" in api|auth|""|-*) continue;; esac        # `gh api` flags vary; skip
    case "$sub2" in -*|"") cmd="$sub";; *) cmd="$sub $sub2";; esac
    # shellcheck disable=SC2086
    acc="$(gh $cmd --help 2>/dev/null | grep -oE '^\s+(-[a-zA-Z], )?--[a-z-]+' | grep -oE '\--[a-z-]+' | sort -u | tr '\n' ' ')"
    [ -n "$acc" ] || continue
    for fl in $(printf '%s' "$call" | grep -oE ' --[a-z-]+' | tr -d ' ' | sort -u); do
      [ "$(gh_flag_verdict "$fl" "$acc")" = UNKNOWN-FLAG ] || continue
      findings=$((findings+1))
      printf '  UNKNOWN FLAG   %-34s %-26s %s\n' "gh $cmd" "$fl" 'gh rejects this — the call returns nothing'
    done
    # JOIN BACKSLASH CONTINUATIONS FIRST. Real calls wrap across lines — reconcile's was
    #     gh issue view "$2" --repo "$1" --json state,labels,comments \
    #         -q --arg pr "$3" '<jq>'
    # so a line-at-a-time grep never sees the offending flag at all. Reading one line at a time is how
    # this check would have missed the very defect it exists for.
    # THE EXTRACTION MUST SEE ONLY CODE. Two false-positive classes bit the first cut, and a gate that
    # cries wolf is worse than none:
    #   * COMMENTS — reconcile.sh's own comment explaining "there is no `--arg`" was read as a call.
    #   * STRING LITERALS — an issue title reading "poller: --watch has deferred …" was read as a flag.
    # So: drop comment lines, JOIN backslash continuations (a real call wraps, and reading one line at a
    # time is precisely how this check would have missed the defect it exists for), blank the CONTENTS of
    # quoted strings, and cut anything after ` -- ` (pass-through args belong to the wrapped tool).
  done < <(for f in "$ROOT"/bin/*.sh; do
             grep -v '^[[:space:]]*#' "$f" 2>/dev/null | sed -e :a -e '/\\$/N; s/\\\n//; ta'
           done \
           | sed -e 's/"[^"]*"/""/g' -e "s/'[^']*'/''/g" -e 's/ -- .*//' \
           | grep -oE '\bgh [a-z-]+( [a-z-]+)?[^|;&)]*' | sort -u)
fi

# GATING vs ADVISORY. A flag gh rejects is always a bug — no judgment, so it gates. A stubbed seam may
# be entirely correct (you cannot run a model or a real host in a unit test), so it is REPORTED and left
# to a human. Gating on the advisory class would just mean allowlisting 20-odd legitimate stubs, which is
# rubber-stamping, not checking.
printf '\nseam-audit: %d GATING finding(s), %d advisory, %d allowlisted\n' "$findings" "$advisory" "$allowed_n"
[ "$findings" -eq 0 ]
