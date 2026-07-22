#!/usr/bin/env bash
# claudebox-reassemble.test.sh — proves the REASSEMBLE-ON-IMAGE-CHANGE freshness gate
# (claudebox-assemble.sh --if-stale). The incident (2026-07-19, ticket #198): an R17 rebuild
# recreated the fedora-dev CONTAINER onto a new image, but the persistent home-volume claudebox +
# its `.assembled` marker OUTLIVE the container, so the entrypoint's first-boot assemble skipped and
# the box stayed FROZEN at its last assembly (claude-code + policy stamp days stale).
#
# Drives the REAL claudebox-assemble.sh --if-stale with:
#   * a fixture STATE dir (markers we control),
#   * a fixture /run/.containerenv (FD_CONTAINERENV seam → the "running image id"),
#   * ASSEMBLE_LIVE = a throwaway dir (never the real live clone),
#   * STUB podman/distrobox/git on PATH (so it NEVER touches the real engine; a call is logged).
# The gate runs BEFORE any engine call, so its stdout + the .assembled clear are the deterministic
# signals asserted here; whether the downstream assemble then succeeds is irrelevant to this test.
#
#   bash claudebox-reassemble.test.sh  → exit 0 = all rows pass. No GitHub/network/model/real engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASM="$HERE/claudebox-assemble.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# --- stub engine (log every call; podman/distrobox FAIL so a proceeding assemble aborts fast) ------
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/podman"    <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >> "${CALLLOG:-/dev/null}"; exit 1
EOF
cat > "$BIN/distrobox" <<'EOF'
#!/usr/bin/env bash
printf 'distrobox %s\n' "$*" >> "${CALLLOG:-/dev/null}"; exit 1
EOF
cat > "$BIN/git"       <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${CALLLOG:-/dev/null}"; exit 0
EOF
chmod +x "$BIN/podman" "$BIN/distrobox" "$BIN/git"

CUR=aaaaaaaaaaaa000000000000000000000000000000000000000000000000cafe   # a plausible imageid
OLD=bbbbbbbbbbbb111111111111111111111111111111111111111111111111beef

# run --if-stale under a fresh fixture; sets: OUT (stdout), RC, and CALLLOG at $HOME/calls.log
# args: <script> <cur-imageid> [make-assembled] [assembled-image] [make-failed]
run_ifstale(){ # <script> <cur> <assembled:y|n> <recorded-img|-> <failed:y|n>
  local script="$1" cur="$2" mk_asm="$3" rec="$4" mk_fail="$5"
  HOME="$ROOT/home-$RANDOM$RANDOM"; export HOME; local st="$HOME/.local/state/claudebox"
  mkdir -p "$st"
  local live="$HOME/live"; mkdir -p "$live"                    # ASSEMBLE_LIVE throwaway
  local env="$HOME/containerenv"; printf 'imageid="%s"\n' "$cur" > "$env"
  [ "$mk_asm" = y ] && : > "$st/.assembled"
  [ "$rec" != - ] && printf '%s\n' "$rec" > "$st/.assembled-image"
  [ "$mk_fail" = y ] && echo "prior failure" > "$st/.assemble-failed"
  export CALLLOG="$HOME/calls.log"; : > "$CALLLOG"
  OUT="$(PATH="$BIN:$PATH" ASSEMBLE_LIVE="$live" FD_CONTAINERENV="$env" \
         bash "$script" --if-stale 2>&1)"; RC=$?
  ST="$st"
}

echo "== --selftest: the pure reassemble_needed decision =="
if bash "$ASM" --selftest >/dev/null 2>&1; then ok "claudebox-assemble --selftest PASS (pure decision rows)"
else no "selftest" "claudebox-assemble.sh --selftest did not pass"; fi

echo "== FRESH: assembled for the CURRENT image ⇒ no-op skip (no engine call, marker intact) =="
run_ifstale "$ASM" "$CUR" y "$CUR" n
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'skipping' \
   && [ -e "$ST/.assembled" ] && [ ! -s "$CALLLOG" ]; then ok "fresh box → skip: rc0, .assembled intact, ZERO engine calls"
else no "fresh skip" "rc=$RC out='$OUT' assembled=$([ -e "$ST/.assembled" ] && echo y||echo n) calls=$(wc -l <"$CALLLOG")"; fi

echo "== IMAGE-CHANGED: recreated on a NEW image ⇒ .assembled CLEARED + assemble PROCEEDS =="
run_ifstale "$ASM" "$CUR" y "$OLD" n
if printf '%s' "$OUT" | grep -q 'image-changed' && [ ! -e "$ST/.assembled" ] && [ -s "$CALLLOG" ]; then ok "image change → .assembled cleared (box-ready gate WAITS) + engine assemble attempted"
else no "image-changed" "out='$OUT' assembled-still=$([ -e "$ST/.assembled" ] && echo y||echo n) calls=$(wc -l <"$CALLLOG")"; fi

echo "== ABSENT: never assembled ⇒ proceeds (first-boot) =="
run_ifstale "$ASM" "$CUR" n - n
if printf '%s' "$OUT" | grep -q 'absent' && ! printf '%s' "$OUT" | grep -q 'skipping'; then ok "no .assembled → proceeds (absent), never skips"
else no "absent" "out='$OUT'"; fi

echo "== FAILED: a prior assemble FAILED (same image) ⇒ still reassembles (self-heal #115) =="
run_ifstale "$ASM" "$CUR" y "$CUR" y
if printf '%s' "$OUT" | grep -q 'failed' && ! printf '%s' "$OUT" | grep -q 'skipping'; then ok "prior .assemble-failed → reassembles even for the same image"
else no "failed self-heal" "out='$OUT'"; fi

echo "== MUTATION: neutralize the image-change branch ⇒ a stale box is NOT refreshed (the gate bites) =="
MUT="$ROOT/mut-assemble.sh"
sed 's/echo image-changed; return 0/echo fresh; return 1/' "$ASM" > "$MUT"
if cmp -s "$ASM" "$MUT"; then no "M vacuous" "sed did not change the image-change branch"; else
  run_ifstale "$MUT" "$CUR" y "$OLD" n
  if printf '%s' "$OUT" | grep -q 'skipping' && [ -e "$ST/.assembled" ] && [ ! -s "$CALLLOG" ]; then ok "M: image-change neutralized → the NEW-image box wrongly SKIPS (frozen-stale, the #198 bug) — the branch discriminates"
  else no "M" "mutant should SKIP the image-changed fixture — out='$OUT' assembled=$([ -e "$ST/.assembled" ] && echo y||echo n)"; fi
fi

echo
echo "claudebox-reassemble: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
