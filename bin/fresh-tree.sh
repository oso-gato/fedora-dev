#!/usr/bin/env bash
# fresh-tree.sh — start task work on a GUARANTEED-fresh tree: a git WORKTREE checked out on a new
# branch off the LATEST origin/main, isolated from the persistent clone. Kills the recurring
# stale-clone hazard — a long-lived ~/repos/<repo> clone silently trails origin/main, so editing it
# bases the work on stale code (near-misses observed this session: editing a deny-all gate-push.sh
# that origin had already replaced; branching off a HEAD several merges behind). A worktree shares
# the clone's object store (cheap) but has its OWN HEAD + index + working dir, so the persistent
# clone is never disturbed and the branch is always off current origin/main.
#
# Usage:  fresh-tree.sh <repo-name-or-path> <branch>
#   Prints the worktree PATH on stdout (everything else on stderr) so callers can:
#       WT="$(fresh-tree.sh fedora-desktop feat/x)" && cd "$WT"
#   Idempotent: a pre-existing worktree/branch of the same name is removed and recreated fresh.
set -uo pipefail
REPO="${1:?usage: fresh-tree.sh <repo-name-or-path> <branch>}"
BRANCH="${2:?usage: fresh-tree.sh <repo-name-or-path> <branch>}"
BASE="${FD_BASE_REF:-origin/main}"

# resolve the persistent clone (accept a path OR a bare repo name under ~/repos)
SRC="$REPO"; [ -d "$SRC/.git" ] || SRC="$HOME/repos/$REPO"
[ -d "$SRC/.git" ] || { echo "fresh-tree: no git clone at '$REPO' or '$HOME/repos/$REPO'" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"

git -C "$SRC" fetch -q origin || { echo "fresh-tree: 'git fetch origin' failed in $SRC" >&2; exit 2; }
git -C "$SRC" rev-parse --verify -q "$BASE" >/dev/null || { echo "fresh-tree: $BASE not found in $SRC" >&2; exit 2; }

WT="${FD_WORKTREES:-$HOME/.cache/fd-worktrees}/$(basename "$SRC")__$(printf '%s' "$BRANCH" | tr '/' '-')"
# reap any stale worktree/branch of the same name, then create fresh off current origin/main
git -C "$SRC" worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT"
git -C "$SRC" worktree prune 2>/dev/null || true
git -C "$SRC" worktree add -q -B "$BRANCH" "$WT" "$BASE" \
  || { echo "fresh-tree: worktree add failed (is branch '$BRANCH' checked out elsewhere? prune first)" >&2; exit 2; }

echo "fresh-tree: $WT  (branch '$BRANCH' off $BASE @ $(git -C "$WT" rev-parse --short HEAD))" >&2
echo "fresh-tree: cd there to work; commit + BARE push from it; remove with: git -C $SRC worktree remove $WT" >&2
printf '%s\n' "$WT"
