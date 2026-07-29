#!/usr/bin/env bash
# merge-conflict-signal.test.sh — proves the merge core no longer cries "trust boundary broke" at a
# benign serialized merge-CONFLICT. Drives the REAL bin/auto-merge.sh --commit through the post-gate
# merge path against a stub gh (all THREE gates GREEN+PASS+in-scope, then the `gh pr merge` command
# controlled to succeed/fail and the mergeability controlled), asserting the EXIT-CODE CONTRACT:
#   0 = merged · 1 = gate REFUSE (trust boundary) · 2 = MERGE_CONFLICT (rebase needed) · 3 = other.
# Plus an in-suite MUTATION (restore the old `exit 1` on a merge-command failure → the conflict case
# wrongly exits 1, which the poller surfaces as the trust-boundary alarm) and a poller drift-guard that
# the routing distinguishes rc 2 (rebase) from the rc-1 (refused) alarm. No real GitHub/network.
#
# ALSO (STEP 5 of #274): the TIER-RETIREMENT rows. decide() must return the SAME verdict for every tier
# value — the executable form of "the tier gated nothing" — while a RED host or a non-PASS fitness must
# still REFUSE, so the removal is proven to have loosened nothing. Those rows pass against the pre-removal
# script BY DESIGN (the change must not alter what may be merged); the rows that BITE are the changed-file
# call-site COUNTS, which were 3 (auto-merge) and 2 (poller) before the classifier was deleted.
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
# rc 2 still routes to the 'rebase' KIND — what changed in R39/#278 is the ROAD, not the destination:
# it now goes through surface_or_repair, which tries bounded self-repair on a genuine conflict and falls
# back to the same 'rebase' surface when repair is inapplicable or spent. The guard's intent is unchanged
# (rc 2 must never be mistaken for the 'refused' trust-boundary alarm), so it tracks the new call shape.
grep -qF 'surface_or_repair "$pr" "$ref" "$sha" "rebase"' "$POLLER" && ok "poller routes auto-merge rc 2 → the 'rebase' kind (via bounded repair, then surface)" || bad "poller lost the rc-2 rebase arm"
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

echo "== STEP 5 of #274: the TIER is retired — it gated nothing, so removing it decides nothing differently =="
# The issue's own acceptance is `--decide A GREEN PASS` → MERGE. Asserted here across EVERY tier value
# (and a garbage one) so the claim is proven, not sampled: no value of the first positional can move the
# decision. These rows pass against the PRE-removal script too — deliberately. That is the POINT: this
# change must not alter what may be merged, so the decision rows are the CONTROL, and the two rows that
# actually bite are the call-site counts below.
dec(){ bash "$AM" --decide "$1" "$2" "$3" 2>/dev/null; }
tier_indep=1
for t in A B C '' Z; do [ "$(dec "$t" GREEN PASS)" = MERGE ] || tier_indep=0; done
[ "$tier_indep" = 1 ] && ok "every tier value (A/B/C/empty/garbage) + GREEN + PASS ⇒ MERGE — the tier decides nothing" \
                      || bad "a tier value changed the decision — the tier WAS load-bearing; STOP"
{ [ "$(dec A RED PASS)" = REFUSE ] && [ "$(dec A GREEN RETURN)" = REFUSE ] && [ "$(dec A NONE NONE)" = REFUSE ]; } \
  && ok "the two REAL gates still decide: a RED host or a non-PASS fitness still REFUSEs on any tier" \
  || bad "removing the tier loosened a gate — a RED/RETURN no longer REFUSEs"

# THE ROWS THAT BITE: the call sites are gone, counted at the source. Pre-removal these were 3 and 2
# (auto-merge: trinity + SKIPPED re-check + tier; poller: SKIPPED re-check + tier), so this section
# FAILS against the pre-fix scripts — which is what makes it a test rather than a restatement.
amf="$(grep -c -- '--json files' "$AM")"
[ "$amf" = 2 ] && ok "auto-merge fetches the changed-file list twice (Trinity guard + the SKIPPED re-check) — the tier fetch is gone" \
               || bad "auto-merge has $amf changed-file fetches (want 2: Trinity + SKIPPED re-check)"
plf="$(grep -c -- '--json files' "$POLLER")"
[ "$plf" = 1 ] && ok "the poller fetches the changed-file list once (only the host=SKIPPED gate-relevance read) — the GREEN-moment tier fetch is gone" \
               || bad "the poller has $plf changed-file fetches (want 1: the SKIPPED gate-relevance read)"
if grep -rqF 'tier-classify' "$HERE/bin"; then bad "a tier-classifier reference survives under bin/"; else ok "no tier-classifier reference survives under bin/"; fi
[ -e "$HERE/bin/tier-classify.sh" ] && bad "bin/tier-classify.sh still exists" || ok "bin/tier-classify.sh is deleted"

echo; echo "merge-conflict-signal: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
