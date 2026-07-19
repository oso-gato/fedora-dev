#!/usr/bin/env bash
# doc-dry-audit.test.sh — drives the REAL bin/doc-dry-audit.sh against fixture docs (BP8: the real
# execution boundary — actual awk/sed/sort/coreutils text semantics, not a stub that asserts what a mock
# was told), and MUTATION-CHECKS the two load-bearing guards in-suite: restoring the pre-fix behaviour on
# a copy must flip the corresponding row, so no row can pass vacuously.
#
# Rows: a cross-doc duplicated clause -> RED naming both docs / allowlisting it -> GREEN / no duplication
# -> GREEN / a shared phrase BELOW the word floor -> GREEN (noise floor) / a clause shared only inside
# ```fenced code``` -> GREEN (code stripped) / a clause duplicated WITHIN one doc only -> GREEN (cross-
# DOCUMENT is the target) / --selftest passes. MUTATIONS: (M1) the FILENAME allowlist guard reverted to
# the empty-first-file NR==FNR bug must FALSE-GREEN a real duplication; (M2) the min-word floor defeated
# must FALSE-RED a below-floor shared phrase.
#
# bash doc-dry-audit.test.sh  → exit 0 = all rows pass. No GitHub/network/model.
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT="$PWD/bin/doc-dry-audit.sh"
p=0 f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
      else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
ckc(){ case "$2" in *"$3"*) p=$((p+1)); printf '  ok   %s\n' "$1";;
       *) f=$((f+1)); printf '  FAIL %s\n       output missing: [%s]\n       got: %s\n' "$1" "$3" "$2";; esac; }

# run <root> <docs> [allowfile] -> sets $OUT (combined stdout+stderr) and $RC. Never inherits a stray
# doc-dry-allow.txt: the allow file is passed explicitly (or /dev/null for "no allowlist").
run(){ local root="$1" docs="$2" allow="${3:-/dev/null}"
       OUT="$(DRY_ROOT="$root" DRY_DOCS="$docs" DRY_ALLOW="$allow" bash "$SCRIPT" 2>&1)"; RC=$?; }

fixdir(){ mktemp -d; }
CLAUSE="the quick brown fox jumps over the lazy sleeping dog today"   # 11 words, >= floor

echo "== a cross-document duplicated clause is RED, naming both docs =="
d="$(fixdir)"
printf 'Alpha beta gamma. %s.\n' "$CLAUSE" > "$d/a.md"
printf 'Delta epsilon zeta. %s.\n' "$CLAUSE" > "$d/b.md"
printf 'This third doc shares nothing substantial with the others at all here.\n' > "$d/c.md"
run "$d" "a.md b.md c.md"
ck  "duplication -> exit 1 (RED)" "$RC" "1"
ckc "names the clause"            "$OUT" "the quick brown fox jumps over the lazy sleeping dog today"
ckc "names doc a.md"             "$OUT" "a.md"
ckc "names doc b.md"             "$OUT" "b.md"

echo "== allowlisting that clause -> GREEN =="
printf '# reason: intentional shared wording\n%s\n' "$CLAUSE" > "$d/allow.txt"
run "$d" "a.md b.md c.md" "$d/allow.txt"
ck  "allowlisted -> exit 0 (GREEN)" "$RC" "0"
ckc "says GREEN"                    "$OUT" "GREEN"

echo "== no cross-document duplication -> GREEN =="
d2="$(fixdir)"
printf 'The first unique sentence concerns apples and oranges in a bowl.\n' > "$d2/a.md"
printf 'A second entirely different sentence concerns bicycles beside a river.\n' > "$d2/b.md"
run "$d2" "a.md b.md"
ck "no dup -> exit 0 (GREEN)" "$RC" "0"

echo "== a shared phrase BELOW the word floor is NOT flagged (noise floor) =="
d3="$(fixdir)"
printf 'one two three four five. Alpha unique alpha alpha content sentence one here.\n' > "$d3/a.md"
printf 'one two three four five. Beta unique beta beta content sentence two there.\n' > "$d3/b.md"
run "$d3" "a.md b.md"
ck "5-word shared phrase < floor -> GREEN" "$RC" "0"

echo "== a clause shared only inside a fenced code block is NOT flagged (code stripped) =="
d4="$(fixdir)"
printf 'Prose about apples only.\n```\n%s\n```\n' "$CLAUSE" > "$d4/a.md"
printf 'Prose about oranges only.\n```\n%s\n```\n' "$CLAUSE" > "$d4/b.md"
run "$d4" "a.md b.md"
ck "fenced-code shared clause -> GREEN" "$RC" "0"

echo "== a clause duplicated WITHIN one doc only is NOT flagged (cross-DOCUMENT is the target) =="
d5="$(fixdir)"
printf '%s. And again: %s.\n' "$CLAUSE" "$CLAUSE" > "$d5/a.md"
printf 'This other doc is entirely about unrelated matters of state and weather.\n' > "$d5/b.md"
run "$d5" "a.md b.md"
ck "within-doc-only dup -> GREEN" "$RC" "0"

echo "== --selftest passes =="
so="$(bash "$SCRIPT" --selftest 2>&1)"; src=$?
ck  "selftest exit 0" "$src" "0"
ckc "selftest all pass" "$so" "0 failed"

echo "== MUTATION M1: the FILENAME allowlist guard is load-bearing (empty-first-file NR==FNR bug) =="
# The real script uses `FILENAME==af` because the NR==FNR two-file idiom FALSE-GREENs a real duplication
# whenever the allowlist (first file) is EMPTY. Restore NR==FNR on a copy; the RED fixture (no allowlist)
# must then go GREEN — proving the guard is what makes an un-allowlisted duplication detectable.
m1="$(fixdir)/mutant.sh"
sed 's/FILENAME==af { allow/NR==FNR { allow/' "$SCRIPT" > "$m1"
if grep -q 'NR==FNR { allow' "$m1" && ! grep -q 'FILENAME==af { allow' "$m1"; then
  MOUT="$(DRY_ROOT="$d" DRY_DOCS="a.md b.md c.md" DRY_ALLOW="/dev/null" bash "$m1" 2>&1)"; MRC=$?
  ck "M1 mutant FALSE-GREENs the duplication (bug restored)" "$MRC" "0"
else
  f=$((f+1)); echo "  FAIL M1 sed did not change the copy (vacuous mutation)"
fi

echo "== MUTATION M2: the min-word floor is load-bearing =="
# Defeat the floor (NF>=m -> NF>=1); the below-floor shared phrase fixture must then go RED — proving the
# floor is what suppresses shared terminology / short phrases.
m2="$(fixdir)/mutant.sh"
sed "s/NF>=m/NF>=1/" "$SCRIPT" > "$m2"
if grep -q "NF>=1'" "$m2" && ! grep -q "NF>=m'" "$m2"; then
  MOUT="$(DRY_ROOT="$d3" DRY_DOCS="a.md b.md" DRY_ALLOW="/dev/null" bash "$m2" 2>&1)"; MRC=$?
  ck "M2 mutant FALSE-REDs the below-floor phrase (floor defeated)" "$MRC" "1"
else
  f=$((f+1)); echo "  FAIL M2 sed did not change the copy (vacuous mutation)"
fi

echo; echo "doc-dry-audit.test: $p passed, $f failed"
[ "$f" -eq 0 ]
