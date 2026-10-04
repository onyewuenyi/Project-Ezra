#!/usr/bin/env bash
# The full gate (/verify). Runs every gate, keeps going after a failure so the report is complete,
# writes .build/verify/report.md, exits non-zero if any gate failed. Every gate (and every failing
# test) is also appended to the repo's verify history, $STATE_DIR/verify.tsv, shared by all worktrees:
#   ts  run_id  sha  branch  dirty  gate  result  secs  summary      (read it with history.py)
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
rows=(); fail=0; judge=0
sha=$(git rev-parse HEAD 2>/dev/null || echo none); branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)
# dirty = an uncommitted change that could alter the build or the tests. Markdown cannot, and a
# shared checkout often holds another session's notes (a TODO.md), which must not void every run.
# Untracked files count: a new .swift in a synchronized folder is in the build but not in HEAD.
dirty=$([[ -n $(git status --porcelain 2>/dev/null | grep -vE '\.md"?$') ]] && echo 1 || echo 0)
run_id=$(date +%Y%m%d%H%M%S)-$$; hist="$(state_dir)/verify.tsv"
record() {  # record <gate> <result> <secs> <summary>: one line, one append, safe beside other worktrees
  local summary=${4//$'\t'/ }; summary=${summary//$'\n'/ }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$run_id" "$sha" "$branch" "$dirty" "$1" "$2" "$3" "${summary:0:200}" >> "$hist"
}
gate() {  # gate <n> <name> <command…>; output to $rep/<name>.txt, last line is the summary
  local n=$1 name=$2; shift 2
  local start; start=$(date +%s)
  if "$@" > "$rep/$name.txt" 2>&1; then st=PASS; else st=FAIL; fail=1; fi
  local last; last=$(grep -v '^[[:space:]]*$' "$rep/$name.txt" | tail -1 | cut -c1-140 || true)
  local secs=$(( $(date +%s) - start ))
  rows+=("| $n | $name | $st | ${secs}s | ${last//|//} |")
  record "$name" "$st" "$secs" "$last"
  printf '%-2s %-7s %-5s %s\n' "$n" "$name" "$st" "$last"
}
skipped() { rows+=("| $1 | $2 | SKIPPED | | $3 |"); record "$2" SKIPPED 0 "$3"; echo "$1  $2  SKIPPED ($3)"; }
seams() { python3 "$AI_DIR/debug-fences.py" $SOURCE_DIRS; }
reach() { python3 "$AI_DIR/blast-radius.py" --diff "$(base_commit)" --src "${SOURCE_DIRS%% *}"; }
gate 1 format "$AI_DIR/format.sh" --lint
gate 2 build "$AI_DIR/build.sh"
if [[ $notests == 1 ]]; then skipped 3 tests --no-tests; else
  gate 3 tests "$AI_DIR/test.sh"
  # each failing test gets its own row, so history can tell a flake from a regression
  grep -E '^fail ' "$rep/tests.txt" 2>/dev/null | while IFS= read -r l; do t=${l#fail }; record "fail:${t%%: *}" FAIL 0 "${t#*: }"; done || true
fi
gate 4 seams seams
gate 5 reach reach
if [[ $novisual == 1 || ! -f .claude/ios-screens.txt ]]; then
  why=$([[ $novisual == 1 ]] && echo "--no-visual" || echo "no .claude/ios-screens.txt"); skipped 6 visual "$why"
else
  # The sheets are captured here and JUDGED by eye or by the ui-verify agent; a capture nobody looked
  # at is not a pass. `history.py judge PASS|FAIL` records the verdict and completes the run.
  gate 6 visual "$AI_DIR/visual.sh" ${names[@]+"${names[@]}"}
  last=$(( ${#rows[@]} - 1 ))  # bash 3.2: no negative subscripts
  if [[ ${rows[$last]} == *"| visual | PASS |"* ]]; then
    rows[$last]=${rows[$last]/| visual | PASS |/| visual | JUDGE |}
    sed -i '' '$d' "$hist" 2>/dev/null || true  # replace the PASS row this gate just recorded
    record visual JUDGE 0 "sheets captured, not yet judged: scripts/ai/history.py judge PASS|FAIL"
    judge=1
  fi
fi
if [[ $release == 1 ]]; then gate 7 release "$AI_DIR/release.sh"; fi
{
  echo "<!-- ios-ai-kit verify sha=$sha dirty=$dirty result=$([[ $fail == 1 ]] && echo FAIL || { [[ $judge == 1 ]] && echo JUDGE || echo PASS; }) -->"
  echo "## Verification (${sha:0:7}$([[ $dirty == 1 ]] && echo ' + uncommitted changes'), $(date '+%Y-%m-%d %H:%M'))"
  echo; echo "| # | Gate | Result | Time | Summary |"; echo "|---|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  if grep -q '^JUDGE ' "$rep/visual.txt" 2>/dev/null; then
    echo; echo "**Visual sheets to judge** (default · dark · AX5):"; grep '^JUDGE ' "$rep/visual.txt" | sed 's/^JUDGE /- /'
  fi
  echo; echo "**Not verified here:** <list device-only behavior: real notifications, push, CloudKit between accounts, camera, performance on older hardware>"
} > "$rep/report.md"
if [[ $fail == 0 && $judge == 1 ]]; then
  echo "verify: gates PASSED · the visual sheets await a judge: look at each JUDGE sheet (or run the ui-verify agent), then scripts/ai/history.py judge PASS|FAIL \"<what you saw>\" · report: ${rep#$AI_ROOT/}/report.md"
else echo "verify: $([[ $fail == 0 ]] && echo PASSED || echo FAILED) · report: ${rep#$AI_ROOT/}/report.md"; fi
exit $fail
