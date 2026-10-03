#!/usr/bin/env bash
# The server-side lock behind the cloud gate. Run once per GitHub repo, by its owner.
#
# The cloud gate (.claude/hooks/cloud-gate.py) is a best-effort rule inside Claude Code; GitHub's
# proxy for cloud sessions does not limit which branches a push can update. This adds a repository
# ruleset on the DEFAULT branch, enforced by GitHub for everyone, including any agent and the owner:
#   no force push, no deletion, and every change arrives through a pull request (scripts/ai/pr.sh
#   opens one; review count 0, so a solo owner merges their own)
#   --allow-direct-push: drop the pull-request rule (keeps no-force and no-delete)
# Idempotent: updates the kit's ruleset in place. --dry-run prints the request and changes nothing.
# Rulesets need a public repo, or GitHub Pro/Team for a private one; the script says so if not.
set -euo pipefail
require_pr=1; dry=0
for a in "$@"; do case $a in --allow-direct-push) require_pr=0 ;; --require-pr) require_pr=1 ;; --dry-run) dry=1 ;;
  *) echo "usage: $0 [--allow-direct-push] [--dry-run]"; exit 2 ;; esac; done
command -v gh >/dev/null || { echo "protect-main: needs the GitHub CLI (brew install gh; gh auth login)"; exit 1; }
repo=$(gh repo view --json nameWithOwner,defaultBranchRef -q '.nameWithOwner + " " + .defaultBranchRef.name') \
  || { echo "protect-main: this checkout has no GitHub remote gh can see"; exit 1; }
name=${repo% *}; branch=${repo#* }
title="ios-ai-kit: protect the default branch"
body=$(REQUIRE_PR=$require_pr TITLE="$title" python3 -c '
import json, os
rules = [{"type": "deletion"}, {"type": "non_fast_forward"}]
if os.environ["REQUIRE_PR"] == "1":
    rules.append({"type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": False,
        "require_code_owner_review": False, "require_last_push_approval": False,
        "required_review_thread_resolution": False}})
print(json.dumps({"name": os.environ["TITLE"], "target": "branch", "enforcement": "active",
                  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
                  "rules": rules}))')
echo "protect-main: $name · default branch '$branch' · no force push, no deletion$([[ $require_pr == 1 ]] && echo ', pull requests required')"
if [[ $dry == 1 ]]; then echo "$body"; exit 0; fi
id=$(gh api "repos/$name/rulesets" -q ".[] | select(.name == \"$title\") | .id" 2>/dev/null || true)
if [[ -n $id ]]; then
  out=$(gh api -X PUT "repos/$name/rulesets/$id" --input - <<< "$body" 2>&1) && echo "protect-main: updated ruleset $id" && exit 0
else
  out=$(gh api -X POST "repos/$name/rulesets" --input - <<< "$body" 2>&1) && echo "protect-main: created ruleset $(jq -r .id <<< "$out" 2>/dev/null || true)" && exit 0
fi
if [[ $out == *"Upgrade to GitHub Pro"* || $out == *"403"* ]]; then
  echo "protect-main: GitHub refused ($out). Rulesets on a private repo need GitHub Pro or Team;"
  echo "  the cloud gate still refuses these pushes inside Claude Code, it just is not enforced by GitHub."
else echo "protect-main: failed: $out"; fi
exit 1
