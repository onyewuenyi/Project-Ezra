#!/usr/bin/env bash
# Every change reaches the default branch through a pull request. This turns local commits into one.
#
#   on the default branch with commits ahead of origin: moves them onto a new branch
#     (<BRANCH_PREFIX><slug of the first commit>) and puts the default branch back on origin's tip;
#     nothing is lost, the commits live on the new branch
#   on any other branch: uses it
#   then pushes it (-u origin) and opens the PR (or reports the existing one, now updated)
#
# The body is /verify's report when it is fresh for this commit, else the commit list and a line
# saying /verify has not run on it. Uncommitted files are named and left alone (a shared checkout
# may hold another session's work); only commits go into the PR.
# usage: pr.sh [--title "…"] [--draft] [--dry-run]
source "$(dirname "$0")/lib.sh"
set +e -uo pipefail  # every failure below is handled and named
title=""; draft=(); dry=0
while (( $# )); do case $1 in
  --title) title=${2:-}; shift ;; --draft) draft=(--draft) ;; --dry-run) dry=1 ;;
  *) echo "usage: pr.sh [--title \"…\"] [--draft] [--dry-run]"; exit 2 ;; esac; shift; done
cd "$AI_ROOT" || exit 1
die() { echo "pr: $*"; exit 1; }
command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || die "the GitHub CLI is not signed in: gh auth login"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote"
dirty=$(git status --porcelain --untracked-files=no | cut -c4-)
[[ -z $dirty ]] || echo "pr: not in this PR (uncommitted, left as they are): $(echo $dirty)"
git fetch -q origin || die "could not fetch origin"
base=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); base=${base##*/}
[[ -n $base ]] || { git remote set-head origin --auto >/dev/null 2>&1; base=$(git symbolic-ref --quiet refs/remotes/origin/HEAD); base=${base##*/}; }
[[ -n $base ]] || die "cannot tell origin's default branch: git remote set-head origin --auto"
branch=$(git rev-parse --abbrev-ref HEAD)
ahead=$(git rev-list --count "origin/$base..HEAD")
(( ahead > 0 )) || die "nothing to propose: HEAD has no commits that origin/$base lacks"
first=$(git log --reverse --format=%s "origin/$base..HEAD" | head -1)

if [[ $branch == "$base" || $branch == HEAD ]]; then
  prefix=${BRANCH_PREFIX:-${CLOUD_BRANCH_PREFIX:-claude/}}
  slug=$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')
  new="${prefix}${slug:-change}-$(git rev-parse --short HEAD)"
  echo "pr: $ahead commit(s) on $base move to $new; $base goes back to origin/$base"
  if (( dry )); then echo "pr: --dry-run, nothing changed"; exit 0; fi
  git switch -q -c "$new" || die "could not create $new"
  git branch -q -f "$base" "origin/$base" || die "could not move $base back to origin/$base (your commits are safe on $new)"
  branch=$new
fi
(( dry )) && { echo "pr: would push $branch and open a PR against $base"; exit 0; }
out=$(git push -q -u origin "$branch" 2>&1) || die "push failed: $out"

report=$AI_ROOT/.build/verify/report.md
# fresh = verify.sh stamped this exact commit on a clean tree (its first line)
if [[ -f $report ]] && head -1 "$report" | grep -q "sha=$(git rev-parse HEAD) dirty=0"; then
  body=$(cat "$report"); fresh=1
else
  body=$(printf '<!-- ios-ai-kit pr -->\n## Changes\n\n%s\n\n## Verification\n\n/verify has not run on this commit: run it before merging (cloud-authored branches run it on a Mac).\n' \
    "$(git log --reverse --format='- %s' "origin/$base..HEAD")"); fresh=0
fi
[[ -n ${CLAUDECODE:-} ]] && body+=$'\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'

if url=$(gh pr view "$branch" --json url,state -q 'select(.state=="OPEN") | .url' 2>/dev/null) && [[ -n $url ]]; then
  # The description follows the code only where the kit wrote it (its hidden marker): delete the
  # marker line to keep a description you wrote. A fresh /verify report replaces a stale one or the "has not run" placeholder.
  old=$(gh pr view "$branch" --json body -q .body 2>/dev/null || true)
  if (( fresh )) && [[ $old == *"<!-- ios-ai-kit"* ]] && [[ $old != *"sha=$(git rev-parse HEAD)"* ]]; then
    gh pr edit "$branch" --body "$body" >/dev/null 2>&1 && { echo "pr: updated $url (description: the /verify report for $(git rev-parse --short HEAD))"; exit 0; }
  fi
  echo "pr: updated $url"; exit 0
fi
if (( ahead > 1 )) && [[ -z $title ]]; then title=$(printf '%s' "$branch" | sed -E "s#^[^/]*/##; s/-[0-9a-f]{7,}$//; s/-/ /g"); fi
out=$(gh pr create --base "$base" --head "$branch" --title "${title:-$first}" --body "$body" ${draft[@]+"${draft[@]}"} 2>&1) \
  || die "gh pr create failed: $out"
echo "pr: opened ${out##*$'\n'}"
