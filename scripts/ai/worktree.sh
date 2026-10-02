#!/usr/bin/env bash
# Parallel work: one git worktree per session, each with its own DerivedData (.build/dd) and its
# own simulator (created on first build). Native `claude --worktree` works too; this adds the
# cleanup that deletes the worktree's simulator.
# usage: worktree.sh new <name> [base=HEAD] | remove <path> | list
source "$(dirname "$0")/lib.sh"
case ${1:-} in
new)
  name=${2:?name}; dir="$(dirname "$AI_ROOT")/$(basename "$AI_ROOT")-$name"
  git -C "$AI_ROOT" worktree add "$dir" -b "feat/$name" "${3:-HEAD}"
  if [[ -f $AI_ROOT/.worktreeinclude ]]; then  # copy gitignored files the build needs (secrets plists, local config)
    while IFS= read -r pat; do [[ -z $pat || $pat == \#* ]] && continue
      for f in $AI_ROOT/$pat; do [[ -e $f ]] && mkdir -p "$dir/$(dirname "${f#$AI_ROOT/}")" && cp -R "$f" "$dir/${f#$AI_ROOT/}"; done
    done < "$AI_ROOT/.worktreeinclude"
  fi
  grep -v '^SIM_UDID=' "$dir/.claude/ios.local.env" 2>/dev/null > "$dir/.claude/ios.local.env.tmp" && mv "$dir/.claude/ios.local.env.tmp" "$dir/.claude/ios.local.env" || true
  echo "worktree: $dir (branch feat/$name). Start a session there: cd \"$dir\" && claude" ;;
remove)
  dir=$(cd "${2:?path}" && pwd)
  # Clean environment: this script's own SIM_UDID must never reach the worktree's sim.sh.
  [[ -x $dir/scripts/ai/sim.sh ]] && (cd "$dir" && env -u SIM_UDID -u SIM_OWNER /bin/bash scripts/ai/sim.sh destroy) || true
  git -C "$AI_ROOT" worktree remove "$dir" && echo "removed $dir" ;;
list) git -C "$AI_ROOT" worktree list ;;
*) sed -n '2,6p' "$0"; exit 2 ;;
esac
