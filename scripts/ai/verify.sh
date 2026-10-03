#!/usr/bin/env bash
# The full gate (/verify). Runs every gate, keeps going after a failure so the report is complete,
# writes .build/verify/report.md, exits non-zero if any gate failed.
#   1 format   swift-format lint on changed Swift files
#   2 build    no errors, no NEW warnings (baseline: .claude/ios-warnings.txt)
#   3 tests    the scheme's tests, read from the .xcresult
#   4 seams    no launch-argument read outside #if DEBUG (Release safety)
#   5 reach    every app file/screen the change can affect (blast radius), to choose what to look at
#   6 visual   each screen in .claude/ios-screens.txt at default, dark and AX5 (captured here, JUDGED by eye/agent)
#   7 release  (with --release) the Release build audited for submission blockers (release.sh)
# usage: verify.sh [--no-visual] [--no-tests] [--release] [screen names…]
source "$(dirname "$0")/lib.sh"
cd "$AI_ROOT"
novisual=0; notests=0; release=0; names=()
for a in "$@"; do case $a in --no-visual) novisual=1;; --no-tests) notests=1;; --release) release=1;; *) names+=("$a");; esac; done
rep="$BUILD_DIR/verify"; rm -rf "$rep"; mkdir -p "$rep"
rows=(); fail=0
gate() {  # gate <n> <name> <command…>; output to $rep/<name>.txt, last line is the summary
  local n=$1 name=$2; shift 2
  local start; start=$(date +%s)
  if "$@" > "$rep/$name.txt" 2>&1; then st=PASS; else st=FAIL; fail=1; fi
  local last; last=$(grep -v '^\s*$' "$rep/$name.txt" | tail -1 | cut -c1-140)
  rows+=("| $n | $name | $st | $(( $(date +%s) - start ))s | ${last//|//} |")
  printf '%-2s %-7s %-5s %s\n' "$n" "$name" "$st" "$last"
}
seams() { python3 "$AI_DIR/debug-fences.py" $SOURCE_DIRS; }
reach() { python3 "$AI_DIR/blast-radius.py" --src "${SOURCE_DIRS%% *}"; }
gate 1 format "$AI_DIR/format.sh" --lint
gate 2 build "$AI_DIR/build.sh"
if [[ $notests == 1 ]]; then rows+=("| 3 | tests | SKIPPED | | --no-tests |"); echo "3  tests   SKIPPED"; else gate 3 tests "$AI_DIR/test.sh"; fi
gate 4 seams seams
gate 5 reach reach
if [[ $novisual == 1 || ! -f .claude/ios-screens.txt ]]; then
  why=$([[ $novisual == 1 ]] && echo "--no-visual" || echo "no .claude/ios-screens.txt"); rows+=("| 6 | visual | SKIPPED | | $why |"); echo "6  visual  SKIPPED ($why)"
else gate 6 visual "$AI_DIR/visual.sh" ${names[@]+"${names[@]}"}; fi
if [[ $release == 1 ]]; then gate 7 release "$AI_DIR/release.sh"; fi
{
  echo "## Verification ($(git rev-parse --short HEAD 2>/dev/null) + working tree, $(date '+%Y-%m-%d %H:%M'))"
  echo; echo "| # | Gate | Result | Time | Summary |"; echo "|---|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  if grep -q '^JUDGE ' "$rep/visual.txt" 2>/dev/null; then
    echo; echo "**Visual sheets to judge** (default · dark · AX5):"; grep '^JUDGE ' "$rep/visual.txt" | sed 's/^JUDGE /- /'
  fi
  echo; echo "**Not verified here:** <list device-only behavior: real notifications, push, CloudKit between accounts, camera, performance on older hardware>"
} > "$rep/report.md"
echo "verify: $([[ $fail == 0 ]] && echo PASSED || echo FAILED) · report: ${rep#$AI_ROOT/}/report.md"
exit $fail
