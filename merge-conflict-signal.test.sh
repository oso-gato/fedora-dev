#!/usr/bin/env bash
# merge-conflict-signal.test.sh — proves the merge core no longer cries "trust boundary broke" at a
# benign serialized merge-CONFLICT. Drives the REAL bin/auto-merge.sh --commit through the post-gate
# merge path against a stub gh (all THREE gates GREEN+PASS+in-scope, then the `gh pr merge` command
# controlled to succeed/fail and the mergeability controlled), asserting the EXIT-CODE CONTRACT:
#   0 = merged · 1 = gate REFUSE (trust boundary) · 2 = MERGE_CONFLICT (rebase needed) · 3 = other.
# Plus an in-suite MUTATION (restore the old `exit 1` on a merge-command failure → the conflict case
# wrongly exits 1, which the poller surfaces as the trust-boundary alarm) and a poller drift-guard that
# the routing distinguishes rc 2 (rebase) from the rc-1 (refused) alarm. No real GitHub/network.
set -uo pipefail
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SCOPE_SESSION 2>/dev/null || true
HERE="$(cd "$(dirname "$0")" && pwd)"
AM="$HERE/bin/auto-merge.sh"; POLLER="$HERE/bin/pr-poller.sh"; SCOPE="$HERE/bin/repo-scope.sh"
for f in "$AM" "$POLLER" "$SCOPE"; do [ -f "$f" ] || { echo "FATAL: $f not found"; exit 2; }; done
pass=0; fail=0; ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }; bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee
HOST=oso-gato-erebus-claudebox; FIT=oso-gato-fitness-claudebox
printf 'fedora-dev\n' > "$TMP/scope.conf"

# stub gh: answers auto-merge's MERGE-path reads (author/head/comments/files), and lets MERGE_FAIL +
# MS drive the `pr merge` command result + mergeability classification. GATE=RED flips the host verdict.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
sub="\$1 \$2"; q="\$*"
case "\$sub" in
  "pr view")
    case "\$q" in
      *"--json author"*)      echo "someone-else";;
      *"--json headRefOid"*)  echo "$SHA";;
      *"--json mergeable"*)   echo "\${MS:-MERGEABLE CLEAN}";;   # my new classification read
      *"--json files"*)       echo "bin/x.sh";;
      *"--json comments"*)
        # hdr_verdict passes the queried login in the -q string; return that login's verdict line only.
        case "\$q" in *"$HOST"*) [ "\${GATE:-GREEN}" = RED ] && echo "**Host live-gate (Gate B): VERDICT RED** — fedora-dev @ $SHA" || echo "**Host live-gate (Gate B): VERDICT GREEN** — fedora-dev @ $SHA";; esac
        case "\$q" in *"$FIT"*)  echo "Fitness review: VERDICT PASS — head $SHA";; esac
        ;;
    esac;;
  "pr merge") [ "\${MERGE_FAIL:-0}" = 1 ] && { echo "gh: merge failed" >&2; exit 1; } || { echo merged; exit 0; };;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# run the REAL auto-merge --commit; returns its rc. <mergeable-status> <merge-fail:0|1> [GATE]
run_am(){ MS="$1" MERGE_FAIL="$2" GATE="${3:-GREEN}" PATH="$BIN:$PATH" \
  LG_HOST_LOGIN="$HOST" FITNESS_LOGIN="$FIT" REPO_SCOPE="$SCOPE" SCOPE_FILE="$TMP/scope.conf" \
  bash "$AM" --commit fedora-dev 1 >/dev/null 2>&1; echo $?; }

echo "== auto-merge EXIT-CODE CONTRACT =="
[ "$(run_am 'MERGEABLE CLEAN' 0)" = 0 ]        && ok "merge succeeds → rc 0"                         || bad "merge success rc != 0"
[ "$(run_am 'CONFLICTING DIRTY' 1)" = 2 ]      && ok "merge fails + CONFLICTING → rc 2 (rebase, not refuse)" || bad "conflict rc != 2 (got $(run_am 'CONFLICTING DIRTY' 1))"
[ "$(run_am 'MERGEABLE BEHIND' 1)" = 2 ]       && ok "merge fails + BEHIND → rc 2 (rebase)"          || bad "behind rc != 2"
[ "$(run_am 'UNKNOWN UNKNOWN' 1)" = 3 ]        && ok "merge fails + non-conflict → rc 3 (other, not refuse)" || bad "other-fail rc != 3"
[ "$(run_am 'MERGEABLE CLEAN' 0 RED)" = 1 ]    && ok "a gate RED → rc 1 (REFUSE — the trust-boundary rc, reserved)" || bad "gate refuse rc != 1"

echo "== MUTATION: restore the old 'exit 1 on any merge-command failure' → conflict is MISLABELLED rc 1 =="
MUT="$TMP/am-mut.sh"
sed 's/echo "\[auto-merge\] MERGE_CONFLICT.*exit 2;;/echo "[auto-merge] merge command failed"; exit 1;;/' "$AM" > "$MUT"
if cmp -s "$AM" "$MUT"; then bad "mutation VACUOUS (sed changed nothing)"; else
  ok "mutation: the conflict→rc2 branch reverted to the old rc1"
  mrc="$(MS='CONFLICTING DIRTY' MERGE_FAIL=1 PATH="$BIN:$PATH" LG_HOST_LOGIN="$HOST" FITNESS_LOGIN="$FIT" REPO_SCOPE="$SCOPE" SCOPE_FILE="$TMP/scope.conf" bash "$MUT" --commit fedora-dev 1 >/dev/null 2>&1; echo $?)"
  [ "$mrc" = 1 ] && ok "mutant: a merge CONFLICT wrongly exits 1 (the poller would cry 'refused' — the bug)" || bad "mutant conflict rc=$mrc (want the wrongful 1)"
fi

echo "== POLLER routing drift-guard: rc 2 → 'rebase', rc 3 → 'merge-failed' (NO park), rc 1/other → 'refused' =="
grep -qF 'surface "$pr" "$sha" "rebase"' "$POLLER" && ok "poller routes auto-merge rc 2 → a 'rebase' surface" || bad "poller lost the rc-2 rebase arm"
grep -qE '\*\) surface .* "refused"' "$POLLER" && ok "poller keeps rc-1/other → the 'refused' trust-boundary surface" || bad "poller lost the refused arm"
grep -qF 'amrc=${PIPESTATUS[0]}' "$POLLER" && ok "poller captures auto-merge's real exit code (PIPESTATUS)" || bad "poller does not capture the distinct rc"
# rc 3 must NOT write the acted marker: that marker is the MERGE arm's terminal-state skip, so parking
# on it strands a host-GREEN + fitness-PASS PR on one transient blip (#156's class) under a comment
# claiming it retries — the #211 fitness RETURN. The pre-fix arm carried `&& : > "$done"`, so this row
# fails against it by construction (the discriminator).
rc3="$(awk '/^[[:space:]]*3\) surface/{f=1} f{print; if (/;;/) exit}' "$POLLER")"
if [ -z "$rc3" ]; then bad "poller lost the rc-3 merge-failed arm"; else
  case "$rc3" in *'"merge-failed"'*) ok "poller routes auto-merge rc 3 → a 'merge-failed' surface";; *) bad "rc-3 arm no longer surfaces 'merge-failed'";; esac
  case "$rc3" in *'$done'*) bad "rc-3 arm writes the acted marker — parks a GREEN PR on a transient (#156 class; the retry claim would be false)";; *) ok "rc-3 arm does NOT park: no acted-marker write, the promised retry is real";; esac
fi

echo; echo "merge-conflict-signal: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
