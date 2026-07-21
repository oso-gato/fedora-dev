#!/usr/bin/env bash
# g7-poller-persist.test.sh — the G7 poller ARMING-DURABILITY safe-parse (entrypoint.sh).
#
# A rebuild-to-spec drops the poller's out-of-band env, so the entrypoint PERSISTS the operator's arming on
# the home volume and RESTORES it on a later boot. That file is CORE-writable and the entrypoint restores it
# AS ROOT — so it MUST be PARSED (known keys, value-validated), never SOURCED (which would let `core` inject
# code that root executes: a privilege escalation). This proves the parse honours valid values, REJECTS
# malicious ones, and NEVER executes file content — plus a DRIFT GUARD pinning the replica to the real code.
#
#   bash g7-poller-persist.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EP="$HERE/entrypoint.sh"
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (got='$2' want='$3')"; fail=$((fail+1)); fi; }

# REPLICA of the entrypoint's safe-parse restore (byte-faithful; the drift guards below pin it to the real
# entrypoint so the two cannot silently diverge).
restore_from(){  # $1 = persist file
    POLLER_ARMED=''; FITNESS_LOGIN=''; FITNESS_SAME_IDENTITY=''
    while IFS='=' read -r _k _v; do
        case "$_k" in
            POLLER_ARMED)          case "$_v" in 0|1) POLLER_ARMED="$_v" ;; esac ;;
            FITNESS_LOGIN)         case "$_v" in ''|*[!A-Za-z0-9._-]*) : ;; *) FITNESS_LOGIN="$_v" ;; esac ;;
            FITNESS_SAME_IDENTITY) case "$_v" in 0|1) FITNESS_SAME_IDENTITY="$_v" ;; esac ;;
        esac
    done < "$1"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1. a VALID persist file → the operator's arming is restored
printf 'POLLER_ARMED=1\nFITNESS_LOGIN=oso-gato-fitness-claudebox\nFITNESS_SAME_IDENTITY=0\n' > "$TMP/ok.env"
restore_from "$TMP/ok.env"
ck "valid POLLER_ARMED=1 restored"                  "$POLLER_ARMED" 1
ck "valid FITNESS_LOGIN restored"                   "$FITNESS_LOGIN" oso-gato-fitness-claudebox
ck "valid FITNESS_SAME_IDENTITY=0 restored"         "$FITNESS_SAME_IDENTITY" 0

# 2. INJECTION: a malicious value is NEITHER honoured NOR executed (the escalation the parse exists to stop)
CANARY="$TMP/canary"; rm -f "$CANARY"
printf 'POLLER_ARMED=1 && touch %s\nFITNESS_LOGIN=evil;touch %s\n' "$CANARY" "$CANARY" > "$TMP/evil.env"
restore_from "$TMP/evil.env"
ck "malicious POLLER_ARMED rejected (not 0|1)"      "$POLLER_ARMED" ''
ck "malicious FITNESS_LOGIN rejected (bad chars)"   "$FITNESS_LOGIN" ''
ck "NO code executed from the file (canary absent)" "$([ -e "$CANARY" ] && echo RAN || echo safe)" safe

# 3. a command-substitution value is inert text, never evaluated
printf 'POLLER_ARMED=$(touch %s)\n' "$CANARY" > "$TMP/sub.env"
restore_from "$TMP/sub.env"
ck "command-sub value rejected"                     "$POLLER_ARMED" ''
ck "command-sub NOT evaluated (canary absent)"      "$([ -e "$CANARY" ] && echo RAN || echo safe)" safe

# 4. DRIFT GUARDS: the real entrypoint carries THIS safe-parse (read+case, value-validated), never a source,
#    and defaults POLLER_ENABLED ON.
ck "entrypoint READS the file (parse), not sources" "$(grep -Fc 'done < "$poller_persist"' "$EP")" 1
ck "entrypoint never sources poller_persist"        "$(grep -Ec '(^|[^[:alnum:]_])(source|\.)[[:space:]]+"?\$poller_persist' "$EP")" 0
ck "entrypoint case-validates POLLER_ARMED to 0|1"  "$(grep -Ec 'POLLER_ARMED\)[[:space:]]+case .* in 0\|1\)' "$EP")" 1
ck "entrypoint validates FITNESS_LOGIN charset"     "$(grep -Fc '[!A-Za-z0-9._-]' "$EP")" 1
ck "entrypoint defaults POLLER_ENABLED ON (:-1)"    "$(grep -Fc 'POLLER_ENABLED:-1' "$EP")" 1

echo "-----"; echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
