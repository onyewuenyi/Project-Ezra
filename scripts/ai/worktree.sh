#!/usr/bin/env bash
# Parallel work: one git worktree per session, each with its own DerivedData (.build/dd) and its
# own simulator (created on first build). Native `claude --worktree` works too; this adds the
# cleanup that deletes the worktree's simulator, and PR worktrees for the lead.
# usage: worktree.sh new <name> [base=HEAD] | pr <number> | prune | remove <path> | list
#   new   a fresh branch <BRANCH_PREFIX><name> (default claude/) in <repo>-<name>
#   pr    the EXISTING branch of an open pull request in <repo>-pr<number>, tracking origin, so fixes
#         land on that PR instead of a new one; reused if it already exists (steer, don't respawn)
#   prune remove PR worktrees (and their simulators) whose PR is merged or closed, unless they hold
#         uncommitted or unpushed work
source "$(dirname "$0")/lib.sh"
prefix=${BRANCH_PREFIX:-${CLOUD_BRANCH_PREFIX:-claude/}}
copy_includes() {  # gitignored files the build needs (secrets plists, local config), then a clean sim record
  local dir=$1
  if [[ -f $AI_ROOT/.worktreeinclude ]]; then
    while IFS= read -r pat; do [[ -z $pat || $pat == \#* ]] && continue
      for f in $AI_ROOT/$pat; do [[ -e $f ]] && mkdir -p "$dir/$(dirname "${f#$AI_ROOT/}")" && cp -R "$f" "$dir/${f#$AI_ROOT/}"; done
    done < "$AI_ROOT/.worktreeinclude"
  fi
  local f="$dir/.claude/ios.local.env"  # a copied record must never point at this checkout's simulator
  if [[ -f $f ]]; then grep -v "^SIM_UDID=" "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"; fi
}
case ${1:-} in
new)
  name=${2:?name}; dir="$(dirname "$AI_ROOT")/$(basename "$AI_ROOT")-$name"
  git -C "$AI_ROOT" worktree add "$dir" -b "$prefix$name" "${3:-HEAD}"
  copy_includes "$dir"
  echo "worktree: $dir (branch $prefix$name). Start a session there: cd \"$dir\" && claude" ;;
pr)
  n=${2:?pull request number}; dir="$(dirname "$AI_ROOT")/$(basename "$AI_ROOT")-pr$n"
  if [[ -d $dir ]]; then echo "worktree: $dir (existing, PR #$n)"; exit 0; fi
  command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh && gh auth login"
  head=$(gh pr view "$n" --json headRefName,state -q 'select(.state=="OPEN") | .headRefName') || die "cannot read PR #$n"
  [[ -n $head ]] || die "PR #$n is not open"
  git -C "$AI_ROOT" fetch -q origin "$head" || die "cannot fetch $head"
  if git -C "$AI_ROOT" show-ref -q --verify "refs/heads/$head"; then
    # The branch exists locally: use it as it is. Never -B, which would reset it to origin and drop
    # unpushed commits; say so instead if it is ahead.
    ahead=$(git -C "$AI_ROOT" rev-list --count "origin/$head..$head" 2>/dev/null || echo 0)
    (( ahead == 0 )) || say "local $head is $ahead commit(s) ahead of origin; the worktree starts from it (push when ready)"
    git -C "$AI_ROOT" worktree add -q "$dir" "$head" || die "cannot add a worktree for $head (is it checked out elsewhere? git worktree list)"
  else
    git -C "$AI_ROOT" worktree add -q "$dir" -b "$head" "origin/$head" || die "cannot add a worktree for $head"
  fi
  git -C "$dir" branch -q --set-upstream-to "origin/$head" "$head"
  copy_includes "$dir"
  echo "worktree: $dir (PR #$n, branch $head, tracking origin)" ;;
remove)
  dir=$(cd "${2:?path}" && pwd)
  # git decides first (it refuses a worktree with modified or untracked files); only then the
  # simulator goes. The reverse order left a refused worktree with no device.
  udid_file="$dir/.claude/ios.local.env"; wt_udid=$(grep -m1 '^SIM_UDID=' "$udid_file" 2>/dev/null | cut -d= -f2 || true)
  git -C "$AI_ROOT" worktree remove "$dir" || die "git refused to remove $dir (uncommitted or untracked files? commit, stash or delete them, or git worktree remove --force)"
  if [[ -n $wt_udid ]]; then xcrun simctl delete "$wt_udid" >/dev/null 2>&1 && echo "deleted simulator $wt_udid" || true; fi
  echo "removed $dir" ;;
prune)
  # PR worktrees (<repo>-pr<N>) whose PR is merged or closed: each holds a simulator and a DerivedData
  # of several GB. Kept when it has uncommitted or unpushed work, and said so.
  command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh && gh auth login"
  n_removed=0
  for dir in "$(dirname "$AI_ROOT")/$(basename "$AI_ROOT")"-pr*; do
    [[ -d $dir ]] || continue
    n=${dir##*-pr}; [[ $n =~ ^[0-9]+$ ]] || continue
    state=$(gh pr view "$n" --json state -q .state 2>/dev/null || echo UNKNOWN)
    [[ $state == MERGED || $state == CLOSED ]] || continue
    if [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then echo "kept $dir: PR #$n is $state but it has uncommitted or untracked files"; continue; fi
    if [[ $(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0) != 0 ]]; then echo "kept $dir: PR #$n is $state but it has unpushed commits"; continue; fi
    "$0" remove "$dir" && n_removed=$((n_removed + 1))
  done
  echo "prune: removed $n_removed PR worktree(s)" ;;
list) git -C "$AI_ROOT" worktree list ;;
*) sed -n '2,11p' "$0"; exit 2 ;;
esac
