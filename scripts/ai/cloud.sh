#!/usr/bin/env bash
# Delegate one unit of work that needs no Xcode to a Claude Code cloud session, and track it.
#
# Cloud sessions have no Xcode: give them docs, scripts, String Catalogs, audits, mechanical
# refactors, Foundation-only logic. The prompt gets a fixed footer (no xcodebuild, push your own
# branch, open a PR with a "Not verified here" list, never touch the default branch), the session URL
# is recorded in $STATE_DIR/cloud.tsv, and /lead follows it until its PR is merged or abandoned
# (a task with no PR after LEAD_NO_PR_HOURS shows up under "needs you").
#   --branch <b>   continue an existing PR's branch (a follow-up lands on that PR, not a new one)
#   --dry-run      print the prompt, launch nothing
# usage: cloud.sh [--branch <b>] [--dry-run] "<task>"
source "$(dirname "$0")/lib.sh"
set +e -uo pipefail
branch=""; dry=0; task=""
while (( $# )); do case $1 in
  --branch) branch=${2:-}; shift ;; --dry-run) dry=1 ;; -*) echo "usage: cloud.sh [--branch <b>] [--dry-run] \"<task>\""; exit 2 ;;
  *) task=$1 ;; esac; shift; done
die() { echo "cloud: $*"; exit 1; }
[[ -n $task ]] || die "say what the session should do: cloud.sh \"<task>\""
[[ ${CLAUDE_CODE_REMOTE:-} == true ]] && die "already in a cloud session: do the work here instead"
if [[ $task =~ (xcodebuild|simctl|[Ss]imulator|screenshot|UI\ test|XCUITest|Instruments|on\ device) ]]; then
  echo "cloud: warning: the task mentions ${BASH_REMATCH[1]}, which needs a Mac; the session will report it as not done"
fi
prefix=${BRANCH_PREFIX:-${CLOUD_BRANCH_PREFIX:-claude/}}
slug=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -d- -f1-6 | sed -E 's/^-+//; s/-+$//')
id="t$(date +%y%m%d%H%M%S)"
branch=${branch:-$prefix${slug:-task}-$id}
prompt="$task

---
Delegated by ios-ai-kit (task $id). This is a cloud session: there is no Xcode here.
- Never run xcodebuild or simctl. Say \"not compiled with Xcode\" in your report.
- Work on branch $branch: if it exists on origin, check it out and continue it; otherwise create it from the default branch. Push it with: git push -u origin $branch
- Open a pull request against the default branch with gh pr create, unless one is already open for this branch (then the push updates it). Its body includes \"Task: $id\", this session's link, and a \"Not verified here\" list. Add the label cloud-authored if the repository has it.
- Never push to the default branch and never merge: the owner runs /verify on a Mac and merges."
if (( dry )); then printf '%s\n' "$prompt"; exit 0; fi
claude --help 2>/dev/null | grep -q -- '--cloud' || die "this Claude Code has no --cloud: update it (claude update), and connect GitHub once with /web-setup"
# --cloud refuses without a terminal; script(1) gives it one and returns once the session is created.
out=$(script -q /dev/null claude --cloud "$prompt" </dev/null 2>&1)
url=$(printf '%s' "$out" | grep -aoE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1)
[[ -n $url ]] || die "no session was created: $(printf '%s' "$out" | tr -d '\033' | tail -3)"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$branch" "$url" "${task//$'\n'/ }" >> "$(state_dir)/cloud.tsv"
echo "cloud: $url (branch $branch, task $id); /lead follows it to a merged PR"
