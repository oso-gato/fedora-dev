#!/usr/bin/env bash
# seed-trust.test.sh — covers the D4/D5 launch changes in bin/claude + bin/seed-claude-trust.py:
#   PART A  the trust pre-seed (D5): seeds a cwd, is idempotent (no write when already set), never
#           corrupts ~/.claude.json, preserves other projects/keys, degrades on a garbage file.
#   PART B  the --session-id assignment case (D4) in bin/claude: a FRESH launch mints a sid; a launch
#           that already names a session (--resume/--continue/--session-id/-r/-c — incl. the R17 restore
#           path `claude --resume <sid>`) does NOT, so a second id can never conflict. Replicated here
#           with a DRIFT GUARD that fails if bin/claude's case pattern changes.
#   bash seed-trust.test.sh → exit 0 = all pass. No GitHub/network/model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SEED="$HERE/bin/seed-claude-trust.py"
CLAUDE="$HERE/bin/claude"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
no(){ fail=$((fail+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not present (Part A needs it)"; }

jget(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
p=d.get("projects",{}).get(sys.argv[2],{}); print(p.get(sys.argv[3]))' "$1" "$2" "$3" 2>/dev/null; }

echo "== PART A: trust pre-seed (D5) =="
H="$TMP/a"; mkdir -p "$H"
# a1: fresh file absent → seeds the cwd
HOME="$H" python3 "$SEED" /home/core >/dev/null 2>&1
[ "$(jget "$H/.claude.json" /home/core hasTrustDialogAccepted)" = True ] && ok "seeds trust for a cwd (file created)" || no "seed create"
[ "$(jget "$H/.claude.json" /home/core hasCompletedProjectOnboarding)" = True ] && ok "seeds onboarding too" || no "seed onboarding"
# a2: idempotent — a second run writes NOTHING (mtime unchanged) since the flag is already set
touch -d '2020-01-01' "$H/.claude.json"; before="$(stat -c %Y "$H/.claude.json")"
HOME="$H" python3 "$SEED" /home/core >/dev/null 2>&1
[ "$(stat -c %Y "$H/.claude.json")" = "$before" ] && ok "idempotent: no write when already trusted (mtime unchanged)" || no "idempotent write" "the file was rewritten though nothing changed — races claude's own writes"
# a3: preserves OTHER projects + top-level keys (never clobbers claude's state)
printf '%s' '{"numStartups":42,"projects":{"/other":{"hasTrustDialogAccepted":true,"foo":9}}}' > "$H/.claude.json"
HOME="$H" python3 "$SEED" /home/core >/dev/null 2>&1
[ "$(jget "$H/.claude.json" /other foo)" = 9 ] && ok "preserves an unrelated project's data" || no "preserve other project"
[ "$(python3 -c 'import json;print(json.load(open("'"$H"'/.claude.json")).get("numStartups"))')" = 42 ] && ok "preserves a top-level key" || no "preserve top-level key"
[ "$(jget "$H/.claude.json" /home/core hasTrustDialogAccepted)" = True ] && ok "still seeds the new cwd alongside" || no "seed alongside"
# a4: garbage file → degrades (no crash, no corruption of a fresh seed)
printf 'not json {{{' > "$H/.claude.json"
HOME="$H" python3 "$SEED" /home/core >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && python3 -c 'import json;json.load(open("'"$H"'/.claude.json"))' 2>/dev/null && ok "garbage file → recovered to valid JSON, no crash" || no "garbage degrade" "rc=$rc"
# a5: a relative/empty cwd arg is ignored (only absolute paths seeded)
printf '%s' '{}' > "$H/.claude.json"; HOME="$H" python3 "$SEED" "rel/path" "" >/dev/null 2>&1
[ "$(python3 -c 'import json;print(len(json.load(open("'"$H"'/.claude.json")).get("projects",{})))')" = 0 ] && ok "relative/empty cwd ignored" || no "relative cwd guard"

echo "== PART B: --session-id assignment case (D4) — mint on fresh, skip when a session is named =="
# DRIFT GUARD: the replica below must match bin/claude's real case, or this suite is lying.
grep -qF "*' --resume '*|*' --resume='*|*' -r '*|*' --continue '*|*' -c '*|*' --session-id '*|*' --session-id='*)" "$CLAUDE" \
  && ok "drift guard: bin/claude carries the exact case pattern" \
  || no "drift guard" "bin/claude's --session-id case changed — update this replica"
sid_for(){ local sid=""
  case " $* " in
    *' --resume '*|*' --resume='*|*' -r '*|*' --continue '*|*' -c '*|*' --session-id '*|*' --session-id='*) : ;;
    *) sid="MINT" ;;
  esac
  printf '%s' "$sid"; }
chk(){ [ "$(sid_for $2)" = "$3" ] && ok "$1" || no "$1" "args '$2' → sid '$(sid_for $2)' want '$3'"; }
chk "fresh launch (no args) → mint"          ""                    MINT
chk "an unrelated flag → mint"               "--foo bar"           MINT
chk "restore path: --resume <sid> → NO mint" "--resume abcd-1234"  ""
chk "--resume=X → NO mint"                    "--resume=abcd"       ""
chk "-r X → NO mint"                          "-r abcd"             ""
chk "--continue → NO mint"                    "--continue"          ""
chk "-c → NO mint"                            "-c"                  ""
chk "--session-id Y → NO mint"               "--session-id zzzz"   ""

echo; echo "seed-trust.test.sh: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
