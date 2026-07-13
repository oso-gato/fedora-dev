#!/usr/bin/env bash
# assemble-stamp.test.sh — the #175 STAMP-LOADABILITY suite.
#
# The incident (2026-07-13, live): claudebox-assemble.sh assembled the law into a
# mktemp file (mode 0600) and the in-box `cp` carried that mode onto
# /etc/claude-code/CLAUDE.md — root-owned 0600, so the session user (core) could not
# read it. The stamp existed, its mtime said fresh, and it was completely INERT.
# This suite proves the fix and keeps it dead: the stamp lands 644, and the assemble
# VERIFIES the stamp is readable AND current AS core before declaring READY.
#
# It drives the REAL claudebox-assemble.sh (via its ASSEMBLE_LIVE test seam) against
# a fixture live-spec + a fake box rootfs ($BOX), stubbing ONLY podman + distrobox.
# The stub is faithful where it counts: `podman exec claudebox cp` runs REAL cp (so
# the incident's mode-carry semantics are reproduced, never asserted), and a
# `--user core` read enforces the other-read bit exactly as the real box's root:root
# files do for uid 1000.
#
# Run after touching the assemble stamp or its verify:
#   bash assemble-stamp.test.sh   -> exit 0 = all rows pass
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1 ($2)"; pass=$((pass+1)); else echo "FAIL: $1 (got=$2 want=$3)"; fail=$((fail+1)); fi; }

law_leaks() { ls /tmp/assembled-law-* 2>/dev/null | wc -l; }

# ---- fixture: live spec + fake box rootfs + stub podman/distrobox --------------
new_fixture() {
    FIX=$(mktemp -d)
    BOX="$FIX/box"; HOMEDIR="$FIX/home"; LIVEDIR="$FIX/live"; BIN="$FIX/bin"
    mkdir -p "$BOX" "$HOMEDIR" "$LIVEDIR/policy" "$BIN"
    PODMAN_LOG="$FIX/podman.log"; DISTROBOX_LOG="$FIX/distrobox.log"
    : > "$PODMAN_LOG"; : > "$DISTROBOX_LOG"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$LIVEDIR/claudebox-init.sh"
    printf '[claudebox]\nimage=fixture\n'  > "$LIVEDIR/distrobox.ini"
    printf '# TEST LAW v2 header\n<!--FLEET-CORE-->\ntail line\n' > "$LIVEDIR/policy/CLAUDE.md"
    printf 'FLEET CORE BODY\n'             > "$LIVEDIR/policy/fleet-core.md"
    printf '{"fixture":true}\n'            > "$LIVEDIR/policy/managed-settings.json"
    # what the script's own sed must produce (header + fleet-core spliced in place)
    sed -e "/<!--FLEET-CORE-->/r $LIVEDIR/policy/fleet-core.md" \
        -e "/<!--FLEET-CORE-->/d" "$LIVEDIR/policy/CLAUDE.md" > "$FIX/expected.law"

    # stub podman: path model = /run/host/X -> X (the distrobox bind), /X -> $BOX/X.
    # A --user <non-root> read models the real box's root:root ownership: the reader
    # sees a file iff its other-read bit is set (core is uid 1000, group != root).
    cat > "$BIN/podman" <<'STUB'
#!/usr/bin/env bash
set -u
umask 022
printf '%s\n' "$*" >> "$PODMAN_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
  rm|inspect) exit 0 ;;
  container)
    [ "${1:-}" = exists ] && exit 1   # no leftover box
    exit 0 ;;
  exec)
    user=root
    if [ "${1:-}" = --user ] || [ "${1:-}" = -u ]; then user="$2"; shift 2; fi
    [ "${1:-}" = claudebox ] || { echo "podman-stub: unexpected container '${1:-}'" >&2; exit 64; }
    shift
    verb="${1:-}"; shift
    mapped=()
    for a in "$@"; do
      case "$a" in
        /run/host/*) mapped+=("${a#/run/host}") ;;
        /*)          mapped+=("$BOX$a") ;;
        *)           mapped+=("$a") ;;
      esac
    done
    if [ "$user" != root ] && [ "$user" != 0 ]; then
      for a in "${mapped[@]}"; do
        case "$a" in -*) continue ;; esac
        [ -f "$a" ] || continue
        m=$(stat -c %a "$a"); o="${m: -1}"
        case "$o" in
          [4-7]) ;;
          *) echo "$verb: $a: Permission denied (stub: mode $m, reader $user)" >&2; exit 1 ;;
        esac
      done
    fi
    case "$verb" in
      bash) exit 0 ;;   # claudebox-init.sh bridges — out of scope for this suite
      *)    exec "$verb" "${mapped[@]}" ;;
    esac ;;
esac
exit 0
STUB
    cat > "$BIN/distrobox" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISTROBOX_LOG"
exit 0
STUB
    chmod +x "$BIN/podman" "$BIN/distrobox"
    LAW="$BOX/etc/claude-code/CLAUDE.md"
    MS="$BOX/etc/claude-code/managed-settings.json"
}

run_assemble() {  # $1 = script under test; echoes its rc, log at $FIX/run.log
    ( export ASSEMBLE_LIVE="$LIVEDIR" HOME="$HOMEDIR" BOX PODMAN_LOG DISTROBOX_LOG
      export PATH="$BIN:$PATH"
      bash "$1" ) > "$FIX/run.log" 2>&1
    echo $?
}

marker() { [ -e "$HOMEDIR/.local/state/claudebox/$1" ] && echo present || echo absent; }

# ---- 1. normal assemble: stamps 644, verifies AS core, then READY --------------
new_fixture; leaks0=$(law_leaks)
rc=$(run_assemble "$REPO/claudebox-assemble.sh")
ck "normal assemble exits 0"                          "$rc" 0
ck "law stamped into the box"                         "$([ -f "$LAW" ] && echo yes || echo no)" yes
ck "law mode is 644 (world-readable)"                 "$(stat -c %a "$LAW" 2>/dev/null)" 644
ck "law content == the assembled law (spliced)"       "$(cmp -s "$LAW" "$FIX/expected.law" && echo same || echo differ)" same
ck "managed-settings mode is 644"                     "$(stat -c %a "$MS" 2>/dev/null)" 644
ck "law verify read ran AS the session user"          "$(grep -c -- '^exec --user core claudebox cat /etc/claude-code/CLAUDE.md$' "$PODMAN_LOG")" 1
ck "managed-settings checked readable AS core"        "$(grep -c -- '^exec --user core claudebox test -r /etc/claude-code/managed-settings.json$' "$PODMAN_LOG")" 1
ck ".assembled marker present"                        "$(marker .assembled)" present
ck "no .assemble-failed"                              "$(marker .assemble-failed)" absent
ck "temp law reaped on success"                       "$(law_leaks)" "$leaks0"
rm -rf "$FIX"

# ---- 2. a pre-existing 0600 stamp (every already-deployed box) converges -------
# In-box cp KEEPS an existing dest's mode, so fixing only the mktemp mode would
# never heal a deployed box — the explicit chmod is what converges it.
new_fixture
mkdir -p "$BOX/etc/claude-code"
printf '# STALE OLD LAW\n' > "$LAW"; chmod 600 "$LAW"
rc=$(run_assemble "$REPO/claudebox-assemble.sh")
ck "re-assemble over a 0600 stamp exits 0"            "$rc" 0
ck "0600 stamp converged to 644"                      "$(stat -c %a "$LAW")" 644
ck "stale content replaced by the CURRENT law"        "$(cmp -s "$LAW" "$FIX/expected.law" && echo same || echo differ)" same
rm -rf "$FIX"

# ---- 3. a 0600 SOURCE managed-settings still lands readable --------------------
# 'anything else it stamps' (issue req 1): the chmod covers both stamped files.
new_fixture
chmod 600 "$LIVEDIR/policy/managed-settings.json"
rc=$(run_assemble "$REPO/claudebox-assemble.sh")
ck "assemble with a 0600 source managed-settings exits 0" "$rc" 0
ck "managed-settings still lands 644"                 "$(stat -c %a "$MS" 2>/dev/null)" 644
rm -rf "$FIX"

# ---- 4. MUTATION (issue req 3): drop the chmod -> the verify must FAIL ---------
# Mechanically restore the incident: delete the chmod (the sed must genuinely change
# the copy, else the row fails as vacuous). mktemp's 0600 then rides cp onto the
# stamp, and the AS-core read-back must refuse to declare READY.
new_fixture; leaks0=$(law_leaks)
MUT="$FIX/assemble.chmod-dropped.sh"
sed '/podman exec claudebox chmod 644/,+1d' "$REPO/claudebox-assemble.sh" > "$MUT"
ck "mutation genuinely changed the copy"              "$(cmp -s "$MUT" "$REPO/claudebox-assemble.sh" && echo same || echo differ)" differ
rc=$(run_assemble "$MUT")
ck "assemble WITHOUT the chmod FAILS"                 "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
ck "…the incident artifact reproduced (0600 stamp)"   "$(stat -c %a "$LAW" 2>/dev/null)" 600
ck "…the failure names the verify (INERT #175)"       "$(grep -q 'INERT (#175)' "$FIX/run.log" && echo yes || echo no)" yes
ck "…no .assembled marker (not READY)"                "$(marker .assembled)" absent
ck "….assemble-failed written (health honesty, #11)"  "$(marker .assemble-failed)" present
ck "…temp law reaped on the failure path too"         "$(law_leaks)" "$leaks0"
rm -rf "$FIX"

# ---- 5. MUTATION: drop the law cp -> a READABLE-but-STALE stamp must fail ------
# Proves the verify checks CURRENT, not merely readable: 'stamped' means readable
# AND current, never 'a file exists'.
new_fixture
MUT="$FIX/assemble.cp-dropped.sh"
sed '\|podman exec claudebox cp "/run/host${_law}"|d' "$REPO/claudebox-assemble.sh" > "$MUT"
ck "mutation genuinely changed the copy"              "$(cmp -s "$MUT" "$REPO/claudebox-assemble.sh" && echo same || echo differ)" differ
mkdir -p "$BOX/etc/claude-code"
printf '# STALE OLD LAW\n' > "$LAW"; chmod 644 "$LAW"
rc=$(run_assemble "$MUT")
ck "readable-but-STALE stamp FAILS the verify"        "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
ck "…the failure names the verify (INERT #175)"       "$(grep -q 'INERT (#175)' "$FIX/run.log" && echo yes || echo no)" yes
ck "…no .assembled marker (not READY)"                "$(marker .assembled)" absent
rm -rf "$FIX"

echo "-----"; echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
