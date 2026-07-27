#!/usr/bin/env bash
# e2e-suite.sh — the R14 END-TO-END ACCEPTANCE harness (00-REQUIREMENTS.md:63-64), modeled on the
# recoverability-drill.sh idiom (GREEN|RED|STAGED verdicts, a pure --selftest core, a table runner, a
# guard arm-gate). R14 acceptance is FIVE proofs — E2E-A (clean Scenario-A objective in a virgin repo),
# E2E-B (systemd-PID-1, every iteration host-run), E2E-KILL (both boxes killed mid-work, resume from the
# bus alone), E2E-ISO (>=2 concurrent disjoint sessions, exclusive routing, undeclared-scope fails
# closed), E2E-SELF (an apparatus change merges and the pair staggers its own refresh) — each PASS
# audited to human-interaction-count == 1.
#
# WHAT FIRES vs WHAT IS STAGED (honest, per R37 — a STAGED proof is DISCLOSED, never a fake GREEN; the
# ANTI-THEATER doctrine: a drill that pretends to prove what it never ran is worse than none):
#   * E2E-ISO fires FAITHFUL-OFFLINE here: it drives the REAL bin/session-registry.sh with live holder
#     processes to prove the ISOLATION PRIMITIVE — disjoint registration, exclusive resolve-routing,
#     overlap DENY (R28), and undeclared-scope-resolves-to-nothing (fail-closed). No network/engine.
#   * E2E-A/B/KILL/SELF are STAGED (rc 3): each needs a live App-installed repo / the host live-gate /
#     a real dual-box kill / the staggered refresh — none fakeable offline. Each names what it needs.
#   * THE INTERACTION AUDIT is COMPUTED ONLY by the `audit` subcommand against a REAL GitHub event
#     stream; the offline `all` run records it STAGED (there is no event stream to audit — emitting a
#     "1 -> PASS" offline would be a fabricated proof).
#
# METRIC HONESTY: `audit` counts HUMAN-authored EVENTS. That equals R14's "human interaction count"
# ONLY when the intake had no discussion; R31 collapses a discussed intake (many human comment events)
# to ONE interaction. That collapse is NOT implemented here (STAGED); the metric is reported as a
# "human EVENT count" so a discussed intake is never silently mislabeled as an interaction count.
#
#   e2e-suite.sh [all]            run every scenario → a table + overall verdict (+ a ledger). rc 0
#                                 unless a scenario RED (iso GREEN, the rest STAGED → overall PARTIAL).
#   e2e-suite.sh <a|b|iso|kill|self>   run ONE scenario. rc 0 GREEN · 1 RED · 3 STAGED.
#   e2e-suite.sh guard <s>        the ARM GATE: rc 0 IFF that scenario FIRES GREEN (RED + STAGED block).
#   e2e-suite.sh audit <owner/repo> [--since <iso8601>]   the LIVE human-EVENT-count auditor (read-only gh).
#   e2e-suite.sh --selftest       exercise the pure core (actor_class / interaction_verdict / folds).
#
# ENV: DEV_LOGIN LG_HOST_LOGIN FITNESS_LOGIN (the 3 App identities the auditor treats as APPARATUS),
#      AUTONOMY_RUNS_DIR (~/autonomy-runs — where the dated ledger lands), E2E_SUITE_LIVE (reserved).
# Covered by e2e-suite.test.sh. Control-plane (the acceptance prover). MUST be tracked 100755.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- PURE CORE (--selftest covers exactly this — no git/gh/network) ---------------------------------

# The fleet's three App identities: the auditor treats a comment/event by any of them (or any Bot) as
# APPARATUS, everything else as HUMAN. Kept in sync with dev-loop.sh / reconcile.sh / fitness-review.sh.
DEV_LOGIN="${DEV_LOGIN:-oso-gato-nox-claudebox}"
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
FITNESS_LOGIN="${FITNESS_LOGIN:-oso-gato-fitness-claudebox}"
APPARATUS_LOGINS="$DEV_LOGIN $LG_HOST_LOGIN $FITNESS_LOGIN"

# scenario_desc <s> → a one-line description. Unknown → rc 1 (fail-closed: an unnamed scenario is not a proof).
scenario_desc(){
  case "$1" in
    a)    printf 'E2E-A: clean Scenario-A objective shipped in a virgin repo (interaction-count=1)';;
    b)    printf 'E2E-B: systemd-PID-1 image, every iteration host-run (Scenario B)';;
    iso)  printf 'E2E-ISO: >=2 concurrent disjoint sessions, exclusive routing, fail-closed undeclared';;
    kill) printf 'E2E-KILL: both boxes killed mid-work, resume from the bus alone';;
    self) printf 'E2E-SELF: an apparatus change merges and the pair staggers its own refresh';;
    *)    return 1;;
  esac
}

# actor_class <login> <type> → APPARATUS | HUMAN. Strip a trailing `[bot]` (the REST .user.login form)
# and a leading `app/` (the gh --json author form — auto-merge.sh:84), then APPARATUS iff the stripped
# login word-matches an apparatus App OR type==Bot. An EMPTY/unreadable login|type → HUMAN (fail-closed:
# an unclassifiable actor INFLATES the human count so a run is never FALSELY certified as interaction=1).
actor_class(){
  local login="${1:-}" type="${2:-}"
  login="${login%\[bot\]}"; login="${login#app/}"
  [ -z "$login" ] && { printf 'HUMAN'; return; }
  [ "$type" = Bot ] && { printf 'APPARATUS'; return; }
  case " $APPARATUS_LOGINS " in *" $login "*) printf 'APPARATUS'; return;; esac
  printf 'HUMAN'
}

# interaction_verdict <human-event-count> → PASS iff exactly 1, else FAIL. NB this is a human-EVENT
# count; it equals R14's interaction count ONLY for a no-discussion intake (see the header METRIC note).
interaction_verdict(){
  case "${1:-}" in ''|*[!0-9]*) printf 'FAIL'; return;; esac
  [ "$1" -eq 1 ] && printf 'PASS' || printf 'FAIL'
}

# overall_verdict <outcome…> → GREEN | PARTIAL | RED (RED dominates; else any STAGED → PARTIAL; else GREEN).
overall_verdict(){
  local o red=0 staged=0
  for o in "$@"; do case "$o" in RED) red=1;; STAGED) staged=1;; esac; done
  if [ "$red" = 1 ]; then printf 'RED'
  elif [ "$staged" = 1 ]; then printf 'PARTIAL'
  else printf 'GREEN'; fi
}

# guard_ok <outcome> → rc 0 IFF GREEN (the strict arm gate: RED and STAGED both block).
guard_ok(){ [ "${1:-}" = GREEN ]; }

# ---- SCENARIO DRILLS — each echoes `<OUTCOME>\t<detail>` --------------------------------------------

# E2E-ISO — FAITHFUL-OFFLINE: drive the REAL session-registry.sh with live holder processes to prove the
# multi-session ISOLATION PRIMITIVE (R28/R20). The concurrent-live-SHIPPING sub-part of E2E-ISO (two
# sessions each shipping an objective with interaction-count=1) is a LIVE property → STAGED (noted below).
scn_iso(){
  local reg="$HERE/session-registry.sh"
  [ -x "$reg" ] || { printf 'RED\tbin/session-registry.sh missing/non-exec — cannot drive the isolation primitive'; return; }
  local dir; dir="$(mktemp -d)" || { printf 'RED\tcannot mktemp a throwaway registry'; return; }
  local hpa hpb fails=0
  sleep 60 </dev/null >/dev/null 2>&1 & hpa=$!
  sleep 60 </dev/null >/dev/null 2>&1 & hpb=$!
  # reg_run <holder-pid> <args…> : register/act AS a live holder; reg_ro <args…> : read-only (resolve).
  reg_run(){ local h="$1"; shift; env SCOPE_REGISTRY_DIR="$dir" SESSION_HOLDER_PID="$h" bash "$reg" "$@"; }
  reg_ro(){ env SCOPE_REGISTRY_DIR="$dir" bash "$reg" "$@"; }
  # disjoint registration both succeed
  reg_run "$hpa" register sidA repo-one >/dev/null 2>&1 || fails=$((fails+1))
  reg_run "$hpb" register sidB repo-two >/dev/null 2>&1 || fails=$((fails+1))
  # exclusive resolve-routing: each session sees ONLY its own scope
  [ "$(reg_ro resolve sidA 2>/dev/null)" = repo-one ] || fails=$((fails+1))
  [ "$(reg_ro resolve sidB 2>/dev/null)" = repo-two ] || fails=$((fails+1))
  # R28 DENY: sidB cannot claim repo-one while live sidA holds it
  if reg_run "$hpb" register sidB repo-one >/dev/null 2>&1; then fails=$((fails+1)); fi
  # a denied register must not have mutated sidB's scope
  [ "$(reg_ro resolve sidB 2>/dev/null)" = repo-two ] || fails=$((fails+1))
  # undeclared session (never registered) resolves to NOTHING (fail-closed to zero)
  [ -z "$(reg_ro resolve sidUNDECLARED 2>/dev/null)" ] || fails=$((fails+1))
  kill "$hpa" "$hpb" 2>/dev/null; wait "$hpa" "$hpb" 2>/dev/null || true
  rm -rf "$dir"
  if [ "$fails" -eq 0 ]; then
    printf 'GREEN\tisolation primitive proven on the real registry: disjoint routing, R28 overlap-DENY, undeclared→empty. (concurrent-live-shipping sub-part STAGED)'
  else
    printf 'RED\t%d isolation-primitive invariant(s) FAILED against the real session-registry.sh' "$fails"
  fi
}

# The four host/live scenarios: STAGED by default (disclosed, never a fake GREEN), each naming its need.
scn_a(){    printf 'STAGED\tneeds a disposable App-installed scratch repo + a full live plan→author→host-gate→fitness→poller cycle with real merges, then `audit <owner/repo>` scores interaction=1'; }
scn_b(){    printf 'STAGED\tneeds the host live-validate round-trip for a systemd-PID-1 image, every iteration host-run (Tier-2; the nested engine cannot boot it)'; }
scn_kill(){ printf 'STAGED\tneeds a real dual-box KILL mid-work + resume-from-bus (Tier-2; the offline resume primitive is covered by dev-loop.test.sh / dev-plan.test.sh)'; }
scn_self(){ printf 'STAGED\tneeds the R17 staggered-refresh lifecycle (host rebuilds the dev box; dev tickets the host) with a live read-back matching merged source (Tier-2)'; }

# ---- LIVE INTERACTION AUDITOR (read-only gh; the ONLY path that computes a real count) --------------
# audit <owner/repo> [--since <iso8601>] — enumerate the run's event stream (issue+PR comments) and count
# HUMAN-authored events. Read-only. Prints the count + the human-EVENT-count verdict (see the METRIC note).
audit(){
  local slug="${1:?usage: e2e-suite.sh audit <owner/repo> [--since <iso8601>]}"; shift || true
  local since=""; [ "${1:-}" = "--since" ] && { since="${2:-}"; shift 2 || true; }
  command -v gh >/dev/null 2>&1 || { echo "e2e-suite audit: gh not available (read-only auditor needs it)" >&2; return 3; }
  local humans=0 total=0 login type klass stream rc
  # READ the event stream FIRST and check the read succeeded. An UNREADABLE stream (deleted repo, App
  # not installed, API error) MUST NOT be reported as a count of zero: that is a measurement never made,
  # presented as a clean result — the exact "satisfied by a proxy" failure the objective forbids and an
  # R37 silent-degradation. Caught live 2026-07-27: e2e-alpha 404s (App not installed) and the auditor
  # announced "0 human EVENT(s) of 0 total", which reads as PERFECT autonomy for a repo it cannot see.
  stream="$(gh api --paginate "repos/$slug/issues/comments${since:+?since=$since}" \
              -q '.[] | "\(.user.login)\t\(.user.type)"' 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'e2e-suite audit %s: UNREADABLE — the event stream could not be read (gh rc %s: repo missing/renamed, App not installed on it, or an API error). NO measurement was made; this is NOT a count of zero.\n' "$slug" "$rc"
    return 3
  fi
  while IFS=$'\t' read -r login type; do
    [ -n "$login$type" ] || continue
    total=$((total+1)); klass="$(actor_class "$login" "$type")"
    [ "$klass" = HUMAN ] && humans=$((humans+1))
  done <<< "$stream"
  local v; v="$(interaction_verdict "$humans")"
  printf 'e2e-suite audit %s: %d human EVENT(s) of %d total → %s\n' "$slug" "$humans" "$total" "$v"
  printf '  NOTE: human-EVENT count; == R14 interaction count only for a no-discussion intake (R31 collapse is STAGED).\n'
  [ "$v" = PASS ]
}

# ---- LEDGER (dated markdown to ~/autonomy-runs; never clobbers the hand-written run-00N ledgers) -----
AUTONOMY_RUNS_DIR="${AUTONOMY_RUNS_DIR:-$HOME/autonomy-runs}"
write_ledger(){ # <overall-verdict> <scenario-table-text>
  local verdict="$1" table="$2" stamp f
  stamp="$(date -u +%Y-%m-%d-%H%M%S 2>/dev/null)" || stamp="unknown"
  mkdir -p "$AUTONOMY_RUNS_DIR" 2>/dev/null || { echo "e2e-suite: cannot write ledger to $AUTONOMY_RUNS_DIR (skipped)" >&2; return 0; }
  f="$AUTONOMY_RUNS_DIR/e2e-$stamp.md"
  { printf '# E2E acceptance run — %s UTC\n\n' "$(date -u +%FT%TZ 2>/dev/null || echo "$stamp")"
    printf '| scenario | verdict | detail |\n|---|---|---|\n%s\n' "$table"
    printf '\n**overall: %s**\n\n' "$verdict"
    printf 'Human interaction count: **STAGED / NOT COMPUTED** — the offline suite has NO event stream to audit; run `bin/e2e-suite.sh audit <owner/repo>` against a live run to compute the human-EVENT count (== R14 interaction count only for a no-discussion intake).\n\n'
    printf '## STAGED (not run this pass — R37 disclosure)\n'
    printf -- '- E2E-A/B/KILL/SELF: %s\n' 'host/live proofs (App-installed scratch repo, host live-gate, dual-box kill, staggered refresh); see each row.'
  } > "$f" 2>/dev/null || { echo "e2e-suite: ledger write failed (non-fatal)" >&2; return 0; }
  echo "e2e-suite: ledger → $f" >&2
}

# ---- RUNNERS ---------------------------------------------------------------------------------------
one(){
  local s="$1" outcome detail
  scenario_desc "$s" >/dev/null || { echo "usage: e2e-suite.sh <a|b|iso|kill|self>" >&2; return 2; }
  IFS=$'\t' read -r outcome detail < <("scn_$s")
  printf '%-5s → %-6s %s\n' "$s" "$outcome" "$detail"
  case "$outcome" in GREEN) return 0;; STAGED) return 3;; *) return 1;; esac
}

run_all(){
  local s outcome detail; local -a outcomes=(); local table=""
  printf 'R14 end-to-end acceptance suite — five proofs (E2E-ISO faithful-offline; A/B/KILL/SELF staged)\n\n'
  for s in a b iso kill self; do
    IFS=$'\t' read -r outcome detail < <("scn_$s")
    outcomes+=("$outcome")
    printf '  %-5s %-6s %s\n' "$s" "$outcome" "$detail"
    table="${table}| ${s} | ${outcome} | ${detail} |"$'\n'
  done
  local v; v="$(overall_verdict "${outcomes[@]}")"
  printf '\ninteraction audit: STAGED — run `e2e-suite.sh audit <owner/repo>` against a live event stream (offline has none)\n'
  printf 'overall: %s\n' "$v"
  write_ledger "$v" "${table%$'\n'}"
  [ "$v" != RED ]
}

guard(){
  local s="$1" outcome detail
  scenario_desc "$s" >/dev/null || { echo "guard: unknown scenario $s" >&2; return 2; }
  IFS=$'\t' read -r outcome detail < <("scn_$s")
  printf 'guard %s: %s — %s\n' "$s" "$outcome" "$detail" >&2
  guard_ok "$outcome"
}

# ---- DISPATCH (sourcing exposes the pure helpers to the test) --------------------------------------
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || true; fi

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== actor_class (APPARATUS vs HUMAN; fail-closed to HUMAN) =="
  ck "nox App → APPARATUS"           "$(actor_class oso-gato-nox-claudebox User)" "APPARATUS"
  ck "[bot] REST form → APPARATUS"   "$(actor_class 'oso-gato-fitness-claudebox[bot]' User)" "APPARATUS"
  ck "app/ author form → APPARATUS"  "$(actor_class app/oso-gato-erebus-claudebox User)" "APPARATUS"
  ck "Bot type → APPARATUS"          "$(actor_class some-bot Bot)" "APPARATUS"
  ck "a human login → HUMAN"         "$(actor_class oso-gato User)" "HUMAN"
  ck "empty login → HUMAN (closed)"  "$(actor_class '' '')" "HUMAN"
  echo "== interaction_verdict (human-EVENT count; PASS iff 1) =="
  ck "1 → PASS"  "$(interaction_verdict 1)" "PASS"
  ck "0 → FAIL"  "$(interaction_verdict 0)" "FAIL"
  ck "2 → FAIL"  "$(interaction_verdict 2)" "FAIL"
  ck "junk → FAIL" "$(interaction_verdict x)" "FAIL"
  echo "== overall_verdict fold (RED dominates; STAGED→PARTIAL; else GREEN) =="
  ck "all green → GREEN"     "$(overall_verdict GREEN GREEN)" "GREEN"
  ck "a staged → PARTIAL"    "$(overall_verdict GREEN STAGED STAGED)" "PARTIAL"
  ck "a RED dominates"       "$(overall_verdict GREEN STAGED RED)" "RED"
  echo "== scenario_desc (unknown fails closed) =="
  scenario_desc iso >/dev/null; ck "iso is known (rc 0)" "$?" "0"
  scenario_desc bogus >/dev/null 2>&1; ck "bogus → rc 1" "$?" "1"
  echo "== guard_ok (only a fired GREEN arms) =="
  guard_ok GREEN;  ck "GREEN arms"    "$?" "0"
  guard_ok STAGED; ck "STAGED blocks" "$?" "1"
  echo; echo "e2e-suite selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

case "${1:-all}" in
  all)                 run_all;;
  a|b|iso|kill|self)   one "$1";;
  guard)               shift; [ -n "${1:-}" ] || { echo "usage: e2e-suite.sh guard <a|b|iso|kill|self>" >&2; exit 2; }; guard "$1";;
  audit)               shift; audit "$@";;
  *) echo "usage: e2e-suite.sh [all | a|b|iso|kill|self | guard <s> | audit <owner/repo> | --selftest]" >&2; exit 2;;
esac
