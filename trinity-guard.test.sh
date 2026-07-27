#!/usr/bin/env bash
# trinity-guard.test.sh — a PR touching the CONFIRMED SPEC (Trinity) or 00-GOVERNANCE.md is held for the
# MAINTAINER (R1): auto-merge.sh REFUSES to autonomously merge it (exit 4), assigns the maintainer, and
# labels it — while a normal PR is unaffected. Drives the REAL bin/auto-merge.sh with a stub gh. No net.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AM="$HERE/bin/auto-merge.sh"
[ -f "$AM" ] || { echo "FATAL: bin/auto-merge.sh not found"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }; bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/repo-scope.sh"; chmod +x "$BIN/repo-scope.sh"   # in-scope

# stub gh: serve the PR's file list from $FILES; record `pr edit` (assign/label) + `pr merge`.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
q="\$*"
case "\$1 \$2" in
  "pr view")
    case "\$q" in
      *"--json author"*) echo "someone-else";;
      *"--json files"*)  cat "\${FILES:-/dev/null}";;
      *) : ;;
    esac;;
  "pr edit")  echo "\$q" >> "$TMP/edit.log";;
  "pr merge") echo merged >> "$TMP/merged.log";;
esac
exit 0
EOF
chmod +x "$BIN/gh"

run(){ # <files-content>
  : > "$TMP/edit.log"; : > "$TMP/merged.log"
  printf '%s\n' "$1" > "$TMP/files.txt"
  OUT="$(env PATH="$BIN:$PATH" REPO_SCOPE="$BIN/repo-scope.sh" FILES="$TMP/files.txt" \
      LG_HOST_LOGIN=oso-gato-erebus-claudebox FITNESS_LOGIN=oso-gato-fitness-claudebox \
      bash "$AM" --commit fedora-dev 1 2>&1)"; RC=$?
}

echo "== a PR touching the confirmed spec is HELD for the maintainer (exit 4 + assign + label) =="
run "00-REQUIREMENTS.md"
[ "$RC" = 4 ] && ok "00-REQUIREMENTS.md → exit 4 (MAINTAINER-MERGE hold)" || bad "confirmed-spec PR not held (rc=$RC): $OUT"
grep -q -- '--add-assignee oso-gato' "$TMP/edit.log" && ok "assigned to the maintainer (oso-gato)" || bad "not assigned to the maintainer"
grep -q -- '--add-label maintainer-merge' "$TMP/edit.log" && ok "labelled maintainer-merge" || bad "not labelled"
[ ! -s "$TMP/merged.log" ] && ok "did NOT merge the confirmed-spec PR" || bad "auto-merged a Trinity PR"

echo "== 00-GOVERNANCE.md is also held =="
run "00-GOVERNANCE.md"
[ "$RC" = 4 ] && ok "00-GOVERNANCE.md → exit 4" || bad "00-GOVERNANCE.md not held (rc=$RC)"

echo "== a normal (non-Trinity) PR is NOT held by this guard (proceeds past it) =="
run "bin/some-feature.sh"
[ "$RC" != 4 ] && ok "a code PR is not caught by the Trinity guard (rc=$RC, not 4)" || bad "a normal PR was wrongly held"
[ ! -s "$TMP/edit.log" ] && ok "a normal PR is not assigned/labelled by the guard" || bad "a normal PR was assigned by the guard"

echo "== a Trinity file ALONGSIDE product code still holds (a mixed PR is maintainer-merge) =="
run "$(printf '00-OBJECTIVES.md\nbin/x.sh')"
[ "$RC" = 4 ] && ok "mixed PR (spec + code) → held (exit 4)" || bad "mixed PR not held (rc=$RC)"

echo; echo "trinity-guard: $pass passed, $fail failed"; [ "$fail" = 0 ]
