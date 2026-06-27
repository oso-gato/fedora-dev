#!/usr/bin/env bash
# gate-push.test.sh — full-matrix harness for the REFSPEC-AWARE promotion gate.
#
# Pipes a {"tool_input":{"command":"<cmd>"}} payload to gate-push.sh and classifies
# the verdict:
#   ALLOW = exit 0 AND stdout has NO permissionDecision   (autonomous fall-through)
#   ASK   = stdout contains "permissionDecision":"ask"     (Arthur's clickable prompt)
#   DENY  = exit 2 OR stdout contains "permissionDecision":"deny"  (hard stop)
#
# Run:  bash policy/hooks/gate-push.test.sh   (exit 0 = all rows pass)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/gate-push.sh"

pass=0
fail=0

# json_escape: minimal escaping for embedding a command in a JSON string.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # \ → \\
    s="${s//\"/\\\"}"   # " → \"
    printf '%s' "$s"
}

# classify "<command>" → prints ALLOW | ASK | DENY
classify() {
    local cmd="$1" payload out rc
    payload="$(printf '{"tool_input":{"command":"%s"}}' "$(json_escape "$cmd")")"
    out="$(printf '%s' "$payload" | bash "$GATE" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 2 ] || printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
        printf 'DENY'
    elif printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then
        printf 'ASK'
    elif [ "$rc" -eq 0 ]; then
        printf 'ALLOW'
    else
        printf 'UNKNOWN(rc=%s)' "$rc"
    fi
}

# check "<expected>" "<command>"
check() {
    local want="$1" cmd="$2" got
    got="$(classify "$cmd")"
    if [ "$got" = "$want" ]; then
        printf 'PASS  %-5s  %s\n' "$got" "$cmd"
        pass=$((pass + 1))
    else
        printf 'FAIL  want=%-5s got=%-5s  %s\n' "$want" "$got" "$cmd"
        fail=$((fail + 1))
    fi
}

echo "== ALLOW (autonomous feature-branch work) =="
check ALLOW 'git push -u origin feat/x'
check ALLOW 'git push origin feat/x'
check ALLOW 'git push --force origin feat/x'
check ALLOW 'git push -f origin feat/x'
check ALLOW 'git push origin +feat/x'
check ALLOW 'git push origin --delete feat/x'
check ALLOW 'git push origin :feat/x'
check ALLOW 'git push origin HEAD:feat/x'
check ALLOW 'git push origin feat/x:feat/x'
check ALLOW 'gh pr create -t a -b b'
check ALLOW 'gh pr edit 5 --add-label live-validate'
check ALLOW 'gh pr close 5'
check ALLOW 'gh pr comment 5 -b hi'
check ALLOW 'git -C /tmp/x push origin feat/x'

echo
echo "== ASK (could touch main / merge / ambiguous) =="
check ASK 'git push origin main'
check ASK 'git push origin HEAD:main'
check ASK 'git push origin feat/x:main'
check ASK 'git push --force origin main'
check ASK 'git push origin +main'
check ASK 'git push origin --delete main'
check ASK 'git push'
check ASK 'git push origin'
check ASK 'git push origin HEAD'
check ASK 'git push --all origin'
check ASK 'git push --mirror origin'
check ASK 'git push --tags origin'
check ASK 'git push origin refs/tags/v1'
check ASK 'gh pr merge 5'
check ASK 'gh pr create --squash'
check ASK 'gh api repos/o/r/merges -f base=main'

echo "== ASK (adversarial: chained / quoted / escaped / variable evasions to main) =="
check ASK 'git push origin main && git push origin feat/x'
check ASK 'git push origin main ; git push origin feat/x'
check ASK 'git push origin "main"'
check ASK "git push origin ma''in"
check ASK 'git push origin ma\in'
check ASK 'X=main git push origin $X'

echo
echo "== TOTAL: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
