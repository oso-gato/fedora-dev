#!/usr/bin/env bash
# fedora-desktop — PROMOTION-GATE PreToolUse hook  (Bash matcher)
# ============================================================================
# Stamped into the claudebox at /etc/claude-code/hooks/gate-push.sh by
# claudebox-assemble.sh, alongside managed-settings.json which wires it as a
# MANAGED PreToolUse hook on the Bash tool. Because it is a *managed* hook and
# the box runs with `allowManagedHooksOnly: true`, the agent cannot remove,
# shadow, or disable it from project/user settings.
#
# JOB (see policy/CLAUDE.md "THE PROMOTION GATE → MECHANICAL ENFORCEMENT"):
#   A blocking hook is the BUILT backstop behind the clickable promotion gate.
#   It DENIES any push / merge that would mutate a remote `main` or merge a PR,
#   UNLESS a fresh one-shot approval marker — written by the clickable decision
#   flow on Arthur's explicit approval — is present. It overrides even an allow
#   permission rule (a blocking hook fires regardless of the permission verdict),
#   so a pre-allowlisted `git push` cannot walk around it.
#
# FAIL CLOSED — the load-bearing property. Claude Code does NOT bundle `jq`, and
#   the docs say a hook that errors on a missing tool FAILS OPEN (non-zero exit
#   other than 2 → tool proceeds). So this hook must NOT depend on jq for its
#   decision: it reads the raw stdin payload as TEXT and scans it (jq is used
#   only as an optional fast-path to isolate the command; if jq is absent we
#   scan the whole payload, which still contains the command string). The deny
#   verdict is emitted as a hand-written JSON string AND as exit 2, neither of
#   which needs jq. Any parse uncertainty resolves toward BLOCKING.
#
# WHY exit 2 AND structured deny JSON: per the Claude Code hook contract, exit 2
#   is the unconditional hard-stop (stderr shown to Claude, tool blocked, JSON
#   ignored). We ALSO print a `permissionDecision: "deny"` block so the reason
#   renders cleanly on harnesses that parse stdout first. Either path blocks.
#
# SCOPE — what it blocks (any of these in the candidate Bash command):
#   * git push                         (any remote/branch — pushing a `main`)
#   * gh pr merge                      (merging a PR)
#   * gh pr create ... --merge|--auto  (auto-merge on create)
#   * gh api .../merges  | .../merge   (REST merge: PR merge & branch merge)
#   * a wrapper invocation (`bash X` / `sh X` / `source X` / `. X`) whose target
#     SCRIPT CONTAINS a push/merge — so a push can't hide inside a one-off
#     script to dodge the matcher.
#
# EXEMPT (never blocked, no marker needed):
#   * the vault git-sync push — `git -C <vaultpath> push ...` — the automatic,
#     history-preserving vault mirror (policy/CLAUDE.md "VAULT & WIKI" +
#     "EXCEPTIONS"). Narrowly recognised by the `-C <vault>` form, so the
#     exemption can't be reused as a blanket `git push` allow.
#
# APPROVAL MARKER (one-shot, freshness-gated):
#   ~/.local/state/claudebox/merge-approved
#   The clickable promotion-gate flow `touch`es it immediately before performing
#   the approved push; the hook CONSUMES it (deletes it) so it authorises exactly
#   one push/merge. Markers older than $MARKER_TTL are ignored and removed — a
#   leftover from a past approval can't authorise a new push.
# ============================================================================
set -uo pipefail

# --- state dir + one-shot approval marker -----------------------------------
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claudebox"
MARKER="$STATE_DIR/merge-approved"
MARKER_TTL=120          # seconds; an approval older than this is stale

# --- the vault clone path the git-sync pushes (exempt). Override via env. -----
VAULT_DIR="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"

# ----------------------------------------------------------------------------
# read the hook stdin payload (raw text — NO jq dependency)
# ----------------------------------------------------------------------------
payload="$(cat 2>/dev/null || true)"

# Empty payload → nothing to gate; fall through.
[ -n "$payload" ] || exit 0

# Optional fast-path: if jq exists, isolate just the command for tighter
# matching. If not, fall back to a lightly-unescaped form of the WHOLE payload
# (still contains the command string verbatim). Either way `scan_text` runs over
# text that includes the command, so the decision never depends on jq.
cmd=""
if command -v jq >/dev/null 2>&1; then
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
if [ -z "$cmd" ]; then
    # jq absent OR not the expected shape: unescape common JSON sequences so a
    # `\"` / `\\` / `\n` inside the embedded command doesn't hide a verb, then
    # scan the whole payload. (Over-broad on purpose: fail toward blocking.)
    cmd="$(printf '%s' "$payload" \
        | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\n/ /g' -e 's/\\t/ /g')"
fi

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# deny(reason): structured deny JSON (exit-0 path) + hard-stop (exit 2).
# JSON is hand-written (no jq) so the block holds even with jq absent. The
# reason is escaped minimally for JSON safety.
deny() {
    local reason="$1" esc
    esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
    printf 'PROMOTION GATE: %s\n' "$reason" >&2
    exit 2
}

# marker_fresh(): true iff the one-shot approval marker exists, is ROOT-OWNED, AND
# is younger than MARKER_TTL. CONSUMES (deletes) the marker either way → one-shot.
#
# ROOT-OWNED is the load-bearing GATE-01 fix: the in-box agent runs as uid 1000, so
# it CAN `touch` this path — but a marker it writes is owned by uid 1000 and is
# REJECTED here. Only the clickable approval flow, writing the marker from OUTSIDE
# the box as root (`podman exec -u 0 … touch "$MARKER"`), produces a uid-0 marker
# the gate will honor. So the agent cannot forge its own approval. (The home-volume
# dir stays core-owned, so consuming/`rm` of the root file still works — unlink
# depends on the directory's write bit, not the file's owner.)
marker_fresh() {
    [ -f "$MARKER" ] || return 1
    local now mtime age owner
    owner="$(stat -c %u "$MARKER" 2>/dev/null || echo -1)"
    if [ "$owner" != "0" ]; then                # not root-owned → forged/untrusted
        rm -f "$MARKER" 2>/dev/null || true     # consume so it can't linger
        return 1
    fi
    now="$(date +%s 2>/dev/null || echo 0)"
    mtime="$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    rm -f "$MARKER" 2>/dev/null || true        # consume regardless of freshness
    [ "$age" -ge 0 ] && [ "$age" -le "$MARKER_TTL" ]
}

# is_vault_sync_push(): true iff the command is the narrow, exempt vault push —
# `git -C <VAULT_DIR> … push …` AND NOTHING ELSE. HARDENED (GATE-03): rejects any
# compound / multi-command payload (`;` `&&` `||` `|` backtick `$(`) and any payload
# carrying a SECOND git or push, so the exemption can't be reused to smuggle an
# arbitrary `git push origin main` after a legit vault push. (The automatic vault
# git-sync is entrypoint-launched and never traverses this hook; this exemption only
# covers an agent running the single sync push by hand — so the narrowing is safe.)
is_vault_sync_push() {
    local c vesc gits pushes
    c="$(printf '%s' "$cmd" | tr '\n' ' ')"
    # any shell compounding / command substitution → not the lone sync push
    printf '%s' "$c" | grep -Eq '[;&|`]|\$\(' && return 1
    # exactly ONE git invocation and ONE push token, or it isn't the sole sync push
    gits="$(printf '%s' "$c" | grep -oE '(^|[^[:alnum:]_./-])git([[:space:]]|$)' | wc -l)"
    pushes="$(printf '%s' "$c" | grep -oE '(^|[^[:alnum:]_])push([[:space:]"}]|$)' | wc -l)"
    [ "$gits" -eq 1 ] && [ "$pushes" -eq 1 ] || return 1
    # escape regex metacharacters in VAULT_DIR (NOT '/').
    vesc="$(printf '%s' "$VAULT_DIR" | sed 's/[][\.*^$]/\\&/g')"
    printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+-C[[:space:]]+'"$vesc"'([[:space:]/"]|$)' \
        && printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])push([[:space:]"}]|$)'
}

# normalize_cmd(text): strip git/gh OPTION noise so the SUBCOMMAND verb becomes
# adjacent to the tool name. Defeats the adjacency-evasion (GATE-02) where a flag
# VALUE token (`git -c key=val push`, `gh --repo o/r pr merge`) pushed the verb out
# of reach of the old anchored regex. Over-stripping AFTER the verb is harmless — we
# only need verb adjacency to fire, and the scan fails CLOSED.
normalize_cmd() {
    printf '%s' "$1" | sed -E '
        s/[[:space:]]+-(c|C|R|f|F|H|X|o)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--(repo|git-dir|work-tree|field|raw-field|method|header|hostname|jq|template|cache)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--[A-Za-z0-9-]+=[^[:space:]]+/ /g
        s/[[:space:]]+-[A-Za-z0-9-]+/ /g
        s/[[:space:]]+/ /g'
}

# scan_text(text): true iff TEXT contains a blocked push/merge verb. Normalizes
# option-noise FIRST so leading flags can't break verb adjacency. The flag-bearing
# checks (gh pr create --merge; gh api … merge) read the RAW text, since normalize
# strips the very flags they look for. Used on the command/payload AND on
# wrapper-script contents.
scan_text() {
    local raw="$1" text
    text="$(normalize_cmd "$raw")"
    # git push
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]"};&|]|$)' && return 0
    # gh pr merge
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]"};&|]|$)' && return 0
    # gh pr create … --merge|--squash|--rebase|--auto  (auto-merge on create)
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eq -- '--(merge|squash|rebase|auto)([[:space:]="};&|]|$)' && return 0
    # gh api … ANY merge — REST (/merges, /pulls/<n>/merge) AND GraphQL
    # (mergePullRequest / mergeBranch). Broad on purpose; fail closed.
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+api([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eqi 'merge' && return 0
    return 1
}

# ----------------------------------------------------------------------------
# 1) VAULT SYNC EXEMPTION — allow the narrow `git -C <vault> push`, no marker.
#    (Only meaningful when jq isolated a real command; on the payload-scan
#    fallback the `-C <vault>` form is still matched if present.)
# ----------------------------------------------------------------------------
if is_vault_sync_push; then
    exit 0
fi

# ----------------------------------------------------------------------------
# 2) DIRECT push/merge in the candidate command/payload?
# ----------------------------------------------------------------------------
blocked=0
scan_text "$cmd" && blocked=1

# ----------------------------------------------------------------------------
# 3) WRAPPER evasion: `bash X` / `sh X` / `source X` / `. X` whose target script
#    contains a push/merge. Extract candidate script paths and scan contents.
# ----------------------------------------------------------------------------
if [ "$blocked" -eq 0 ]; then
    # Extract the token following each interpreter/source invocation, then strip
    # surrounding quotes AND any trailing JSON/shell punctuation (`"`, `}`, `,`,
    # `;`, `)`). The trailing-trim matters on the no-jq fallback, where `cmd` is
    # the raw payload and the captured token would otherwise be e.g.
    # `/tmp/ship.sh"}}` and fail the `-r` readability test — silently disabling
    # wrapper-evasion detection. Trimming makes the path resolve so we can scan
    # the target script's contents.
    # Leading anchor accepts start-of-line, a shell separator (`;&|`), whitespace,
    # OR a quote (`"`/`'`) — the quote case is the no-jq fallback, where the
    # interpreter token sits right after the JSON `"command":"` opening quote.
    scripts="$(printf '%s' "$cmd" \
        | grep -Eo '(^|[;&|"'"'"'[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[^;&|[:space:]]+' \
        | sed -E 's/.*(bash|sh|zsh|source|\.)[[:space:]]+//' \
        | tr -d '"'"'"'' \
        | sed -E 's/[]},;)`]+$//' 2>/dev/null || true)"
    if [ -n "$scripts" ]; then
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            if [ -r "$s" ] && [ -f "$s" ]; then
                if scan_text "$(cat "$s" 2>/dev/null || true)"; then
                    blocked=1
                    break
                fi
            fi
        done <<EOF
$scripts
EOF
    fi
fi

# ----------------------------------------------------------------------------
# 4) Not a push/merge → normal permission flow.
# ----------------------------------------------------------------------------
[ "$blocked" -eq 0 ] && exit 0

# ----------------------------------------------------------------------------
# 5) It IS a push/merge. Allow ONLY with a fresh one-shot approval marker.
# ----------------------------------------------------------------------------
if marker_fresh; then
    exit 0
fi

deny "Push/merge blocked by the promotion gate. This mutates a remote branch or merges a PR, which requires Arthur's explicit clickable approval. Present the change as a discrete decision; on approval the flow writes a one-shot marker at $MARKER (fresh < ${MARKER_TTL}s) and re-runs. (The vault git-sync 'git -C <vault> push' is exempt and needs no marker.)"
