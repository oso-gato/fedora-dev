#!/usr/bin/env bash
# Fleet guard-parity check — the single source of truth for "what must stay IDENTICAL across every
# claudebox repo", and the alarm that makes guard drift impossible to miss.
#
# WHY THIS EXISTS: each box's claudebox spec is necessarily SELF-CONTAINED — fedora-dev bakes its spec
# into the image AND clones it at runtime with an OFFLINE seeded fallback, so a git submodule / shared
# clone would break that offline path. That forces the shared guard payload to be DUPLICATED per repo:
#   * policy/managed-settings.json — the agent deny-list + the claude-code self-update `env` lockout +
#     bypass/mode/allowManaged + the gate-push hook wiring;
#   * claudebox-init.sh — the claude-code self-update lockout (/etc/profile.d/20-claude-no-selfupdate.sh)
#     + the native-build-shadow self-heal (fedora-dev PR #45);
#   * distrobox.ini — the claude-code PROVENANCE (official `latest` channel, gpgcheck, signing key).
# Duplication invites SILENT drift: PR #45 added the self-update lockout to fedora-dev, but it was
# MISSING from BOTH fedora-bootstrap AND fedora-desktop — found only by a manual cross-repo audit.
#
# This check makes that drift LOUD and AUTOMATIC: a guard fix that lands in one repo FAILS this check
# for every repo that has not caught up, so it can never again be silently forgotten. It is the
# pragmatic "one source of truth" for a self-contained-repo fleet — it does not PHYSICALLY merge the
# copies (that would break the offline path); it ENFORCES that they stay identical, achieving the same
# end ("drift can't recur") at far lower blast radius than a cross-repo auto-sync.
#
# Run by .github/workflows/fleet-guard-parity.yml (daily + on push/PR + manual dispatch); also runnable
# locally. All fleet repos are PUBLIC → raw fetch, no auth, built-in token only.
set -uo pipefail

# fedora-dev is the CANONICAL anchor (the develop·build·merge hub); the others must match it.
REPOS=(fedora-dev fedora-bootstrap fedora-desktop)
RAW="https://raw.githubusercontent.com/oso-gato"
REF="${PARITY_REF:-main}"
# PRE-MERGE self-overlay: on `pull_request` the CI checks out the PR HEAD, but every repo (including
# the one being changed) was fetched from raw@main — so a PR that DRIFTS its OWN guard payload was
# compared main-vs-main and passed, catching drift only AFTER merge (post-merge alarm, not a gate).
# Set PARITY_SELF=<repo> (+ optional PARITY_SELF_DIR, default .) to read THAT repo's payload from the
# local checkout (the PR head) instead of raw@main, so the PR's own drift fails the check pre-merge.
# Unset (push / schedule) => pure raw@main across all repos, unchanged.
SELF="${PARITY_SELF:-}"; SELF_DIR="${PARITY_SELF_DIR:-.}"
fail=0
hr(){ printf '\n== %s ==\n' "$*"; }
bad(){ printf '  \342\234\227 %s\n' "$*"; fail=1; }
ok(){  printf '  \342\234\223 %s\n' "$*"; }
fetch(){
  if [ -n "$SELF" ] && [ "$1" = "$SELF" ]; then cat "$SELF_DIR/$2" 2>/dev/null   # PR head, local
  else curl -fsSL "$RAW/$1/$REF/$2" 2>/dev/null; fi                              # others, raw@REF
}

# Participation: a repo is in scope iff it actually ships the claudebox guard payload.
parts=()
for r in "${REPOS[@]}"; do
  if fetch "$r" claudebox-init.sh >/dev/null && fetch "$r" policy/managed-settings.json >/dev/null; then
    parts+=("$r")
  else
    printf 'skip %s — no claudebox payload (no claudebox-init.sh / managed-settings.json)\n' "$r"
  fi
done
printf 'participating claudebox repos @ %s%s: %s\n' "$REF" "${SELF:+ (self=$SELF from PR head)}" "${parts[*]}"
[ "${#parts[@]}" -ge 2 ] || { echo "fewer than 2 claudebox repos — nothing to compare"; exit 0; }
canon="${parts[0]}"

# CHECK 1 — policy/managed-settings.json byte-identical fleet-wide. The deny-list, the env lockout,
# disableBypassPermissionsMode/defaultMode/allowManaged*, and the gate-push hook WIRING are fleet
# INVARIANTS. (Per-box policy divergence lives in CLAUDE.md role docs + gate-push.sh's ask-vs-deny
# terminal verb — NOT in managed-settings.json.)
hr "CHECK 1: policy/managed-settings.json byte-parity (canonical: $canon)"
csum="$(fetch "$canon" policy/managed-settings.json | sha256sum | cut -d' ' -f1)"
for r in "${parts[@]}"; do
  s="$(fetch "$r" policy/managed-settings.json | sha256sum | cut -d' ' -f1)"
  [ "$s" = "$csum" ] && ok "$r matches $canon" || bad "$r managed-settings.json DIFFERS from $canon"
done

# CHECK 2 — claude-code self-update LOCKOUT present in every box (the PR #45 invariant). Semantic
# grep, so it is robust to each box's legitimate comment/channel divergence.
hr "CHECK 2: claude-code self-update lockout (#45) present in every box"
for r in "${parts[@]}"; do
  init="$(fetch "$r" claudebox-init.sh)"; ms="$(fetch "$r" policy/managed-settings.json)"
  miss=()
  grep -q '20-claude-no-selfupdate'                  <<<"$init" || miss+=("profile.d writer")
  grep -q 'DISABLE_UPDATES=1'                        <<<"$init" || miss+=("DISABLE_UPDATES export")
  grep -q 'DISABLE_AUTOUPDATER=1'                    <<<"$init" || miss+=("DISABLE_AUTOUPDATER export")
  grep -q 'self-healed a stale native claude shadow' <<<"$init" || miss+=("native-shadow self-heal")
  grep -q '"DISABLE_UPDATES"'                        <<<"$ms"   || miss+=("managed-settings env leg")
  [ "${#miss[@]}" -eq 0 ] && ok "$r has the full #45 lockout + self-heal" \
                          || bad "$r MISSING #45 leg(s): ${miss[*]}"
done

# CHECK 3 — claude-code PROVENANCE parity: every box installs from the SAME official Anthropic `latest`
# channel with gpgcheck on and the SAME signing key. A box drifting to a different/insecure channel is
# a supply-chain risk.
hr "CHECK 3: claude-code provenance (channel + gpgcheck + signing key) parity"
prov(){ grep -oE 'downloads\.claude\.ai/claude-code/rpm/latest|downloads\.claude\.ai/keys/claude-code\.asc|gpgcheck=1' <<<"$1" | sort -u | tr '\n' '|'; }
cprov="$(prov "$(fetch "$canon" distrobox.ini)")"
for r in "${parts[@]}"; do
  ini="$(fetch "$r" distrobox.ini)"; p="$(prov "$ini")"
  grep -q 'gpgcheck=1'             <<<"$ini" || bad "$r distrobox.ini: claude-code repo not gpgcheck=1"
  grep -q 'claude-code/rpm/latest' <<<"$ini" || bad "$r distrobox.ini: not on the official latest channel"
  [ "$p" = "$cprov" ] && ok "$r provenance matches $canon" || bad "$r provenance DIFFERS from $canon ($p)"
done

# CHECK 4 — B-mode assembly in effect fleet-wide: fleet-core.md present in $canon (the master);
# per-box policy/CLAUDE.md deltas carry the <!--FLEET-CORE--> marker and NO stale THE FLEET
# section heading. A repo missing the marker or still carrying the section is drifted back to
# the old vendored-identical model (A), which means its stamp will not assemble correctly.
hr "CHECK 4: fleet-core.md in $canon; per-box deltas carry marker + no stale THE FLEET section"
fc="$(fetch "$canon" policy/fleet-core.md)"
[ -n "$fc" ] && ok "$canon policy/fleet-core.md present ($(printf '%s' "$fc" | wc -c) bytes)" \
             || bad "$canon policy/fleet-core.md MISSING or empty — fleet-core.md must live in $canon"
for r in "${parts[@]}"; do
  delta="$(fetch "$r" policy/CLAUDE.md)"
  printf '%s\n' "$delta" | grep -q '<!--FLEET-CORE-->' \
      && ok  "$r policy/CLAUDE.md has <!--FLEET-CORE--> marker" \
      || bad "$r policy/CLAUDE.md MISSING <!--FLEET-CORE--> marker"
  printf '%s\n' "$delta" | grep -q '^## THE FLEET' \
      && bad "$r policy/CLAUDE.md still has THE FLEET section heading (should be in fleet-core.md only)" \
      || ok  "$r policy/CLAUDE.md delta: no stale THE FLEET section"
done

# CHECK 6 — the PROBLEM-SOLVING DOCTRINE is present, delimited, and un-diluted in the canon fleet-core.md
# (the single source every box fetches + stamps FIRST into /etc/claude-code/CLAUDE.md). Because
# fleet-core.md is single-source, there is no per-box copy to drift — but a silent deletion / dilution
# of the doctrine block itself is exactly what this catches. Assert: the <!--DOCTRINE-->…<!--/DOCTRINE-->
# block exists, is closed, carries the heading + all SIX numbered mandates, and stays SHORT (brevity is
# the anti-dilution property — the doctrine is a creed, not an essay; padding it out is dilution).
hr "CHECK 6: PROBLEM-SOLVING DOCTRINE present + delimited + all 6 mandates + not bloated (canon: $canon)"
open_n="$(printf '%s\n' "$fc" | grep -c '<!--DOCTRINE-->')"
close_n="$(printf '%s\n' "$fc" | grep -c '<!--/DOCTRINE-->')"
if [ "$open_n" = 1 ] && [ "$close_n" = 1 ]; then ok "doctrine block delimited (one <!--DOCTRINE-->/<!--/DOCTRINE--> pair)"
else bad "doctrine block markers wrong (open=$open_n close=$close_n) — must be exactly one delimited block"; fi
block="$(printf '%s\n' "$fc" | awk '/<!--DOCTRINE-->/{f=1} f{print} /<!--\/DOCTRINE-->/{f=0}')"
printf '%s\n' "$block" | grep -q 'PROBLEM-SOLVING DOCTRINE' \
  && ok "doctrine heading present" || bad "doctrine heading MISSING"
mand_n="$(printf '%s\n' "$block" | grep -cE '^[0-9]+\. ')"
[ "$mand_n" -ge 6 ] && ok "doctrine carries $mand_n mandates (>=6)" \
                    || bad "doctrine has only $mand_n mandates — the six mandates must all be present (dilution/deletion?)"
blk_lines="$(printf '%s\n' "$block" | wc -l | tr -d ' ')"
[ "$blk_lines" -le 40 ] && ok "doctrine is lean ($blk_lines lines <= 40 — stays salient)" \
                        || bad "doctrine bloated to $blk_lines lines (>40) — brevity is the anti-dilution rule; tighten it"

# CHECK 5 — gate-push.sh terminal-verb invariant for PR-only boxes.
# fedora-dev's gate routes main-touching pushes to `ask` (Arthur's click); the PR-only boxes
# (fedora-bootstrap, fedora-desktop) must route them to `deny` — they never merge, so `ask`
# has nothing to approve and would produce confusing prompts Arthur can't safely action.
# A PR that silently promotes a PR-only box's deny() to ask() passes managed-settings.json
# parity (CHECK 1) and all other checks — this catch makes that promotion LOUD.
hr "CHECK 5: gate-push.sh terminal verb — PR-only boxes must deny, not ask"
pr_only_repos=()
for r in "${parts[@]}"; do
  [ "$r" = "fedora-dev" ] && continue
  pr_only_repos+=("$r")
done
if [ "${#pr_only_repos[@]}" -eq 0 ]; then
  ok "no PR-only boxes in participating set — skip"
else
  for r in "${pr_only_repos[@]}"; do
    gate="$(fetch "$r" policy/hooks/gate-push.sh)"
    if [ -z "$gate" ]; then
      bad "$r policy/hooks/gate-push.sh: fetch failed or empty"
      continue
    fi
    has_deny=0; has_ask=0
    printf '%s\n' "$gate" | grep -q 'permissionDecision.*deny' && has_deny=1
    printf '%s\n' "$gate" | grep -q 'permissionDecision.*ask'  && has_ask=1
    if [ "$has_deny" -eq 1 ] && [ "$has_ask" -eq 0 ]; then
      ok "$r gate-push.sh: deny present, ask absent (correct for a PR-only box)"
    elif [ "$has_deny" -eq 0 ]; then
      bad "$r gate-push.sh: deny MISSING — a PR-only box must use deny() not ask()"
    else
      bad "$r gate-push.sh: ask present — a PR-only box must use deny(), not ask(); a PR may have silently promoted the terminal verb"
    fi
  done
fi

hr "VERDICT"
if [ "$fail" = 0 ]; then
  echo "GREEN — shared claude-code guard payload is consistent across: ${parts[*]}"
else
  echo "RED — guard DRIFT detected (see the failures above). A guard fix landed in one repo but not"
  echo "the flagged one(s). Port the missing/diverged guard to each flagged repo, then re-run."
fi
exit "$fail"
