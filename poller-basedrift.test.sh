#!/usr/bin/env bash
# poller-basedrift.test.sh — R25 VERDICT BASE-DRIFT VOIDING acceptance (00-REQUIREMENTS.md:96-97).
# Drives the REAL bin/auto-merge.sh with a stubbed gh: a GREEN+PASS verdict bound to base B_OLD must
# NOT merge once main has advanced to B_NEW (the verdict is VOID); the SAME verdict merges when its
# base equals the current base. Plus the pure verdict_base_void core via the poller --selftest.
# No network / no model. bash poller-basedrift.test.sh → 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AM="$HERE/bin/auto-merge.sh"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$AM" ] || { echo "FATAL: bin/auto-merge.sh not found"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee   # the (unchanged) head sha under review
B_OLD=1111111111111111111111111111111111111111  # the base the verdict was computed against
B_NEW=2222222222222222222222222222222222222222  # main after it advanced past B_OLD
HOST=oso-gato-erebus-claudebox; FIT=oso-gato-fitness-claudebox

BIN="$TMP/bin"; mkdir -p "$BIN"
# stub gh: the verdict comments always carry base=B_OLD; the CURRENT base (baseRefOid) is $CURBASE.
# A `pr merge` records to $TMP/merged so we can assert whether the merge actually fired.
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
q="\$*"
case "\$1 \$2" in
  "pr view")
    case "\$q" in
      *"--json author"*)     echo "someone-else";;
      *"--json headRefOid"*) echo "$SHA";;
      *"--json baseRefOid"*) echo "\${CURBASE}";;
      *"--json files"*)      echo "bin/x.sh";;
      *"--json comments"*)
        # Emulate gh's own -q 'select(contains("<anchor>"))': the verdict comment (base B_OLD) is only
        # "found" when auto-merge's query anchor carries that SAME base. A drifted anchor (base B_NEW)
        # matches nothing → the gate reads NONE → REFUSE. This is exactly the server-side filter R25 uses.
        case "\$q" in *"$HOST"*) case "\$q" in *"base $B_OLD"*) echo "**Host live-gate (Gate B): VERDICT GREEN** — fedora-dev @ $SHA base $B_OLD (targets: main)";; esac;; esac
        case "\$q" in *"$FIT"*)  case "\$q" in *"base $B_OLD"*) echo "Fitness review: VERDICT PASS — head $SHA base $B_OLD";; esac;; esac
        ;;
    esac;;
  "pr merge") echo "merged" >> "$TMP/merged";;
esac
exit 0
STUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tier-classify.sh"; chmod +x "$BIN/tier-classify.sh"  # tier=(empty)→A? no:
# tier-classify must yield a non-A tier so decide()=MERGE on GREEN+PASS. Emit 'B'.
printf '#!/usr/bin/env bash\necho B\n' > "$BIN/tier-classify.sh"; chmod +x "$BIN/tier-classify.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/repo-scope.sh"; chmod +x "$BIN/repo-scope.sh"

run_am(){ # <curbase> — drive auto-merge --commit; RC + whether it merged
  : > "$TMP/merged"
  OUT="$(env PATH="$BIN:$PATH" HERE="$BIN" REPO_SCOPE="$BIN/repo-scope.sh" CURBASE="$1" \
      LG_HOST_LOGIN="$HOST" FITNESS_LOGIN="$FIT" \
      bash "$AM" --commit fedora-dev 42 2>&1)"; RC=$?
  MERGED=0; [ -s "$TMP/merged" ] && MERGED=1
}

echo "== R25 acceptance: a verdict bound to B_OLD must NOT merge once main advanced to B_NEW =="
run_am "$B_NEW"
{ [ "$MERGED" = 0 ] && printf '%s' "$OUT" | grep -q 'REFUSE'; } \
  && ok "drifted base (verdict B_OLD, current B_NEW) → REFUSE, no merge" \
  || bad "a stale-base GREEN merged (MERGED=$MERGED rc=$RC): $(printf '%s' "$OUT" | tail -1)"

echo "== R25: the SAME verdict merges when its base equals the current base (no drift) =="
run_am "$B_OLD"
{ [ "$MERGED" = 1 ] && printf '%s' "$OUT" | grep -q 'MERGED'; } \
  && ok "matching base (verdict B_OLD == current B_OLD) → MERGE" \
  || bad "a matching-base GREEN+PASS did NOT merge (MERGED=$MERGED rc=$RC): $(printf '%s' "$OUT" | tail -1)"

echo "== the pure verdict_base_void core (via the poller --selftest) =="
if bash "$POLLER" --selftest >/dev/null 2>&1; then ok "pr-poller --selftest (incl. R25 verdict_base_void rows) passes"
else bad "pr-poller --selftest FAILED"; fi

echo
echo "poller-basedrift: $pass passed, $fail failed"
[ "$fail" = 0 ]
