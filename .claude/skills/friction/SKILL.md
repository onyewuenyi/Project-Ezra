---
name: friction
description: The friction and waste healthcheck. Scans this repo's recent Claude Code sessions and verify history for what keeps going wrong (prompts for commands no rule allows, rejected calls, repeated hook refusals, Stop-hook build failures, recurring compiler errors, flaky tests, slowing gates, oversized outputs) and turns the proposals the owner accepts into a tested PR. Quiet when there is nothing to propose. Use for /friction, weekly, or when sessions feel slow.
argument-hint: "[--since 7d] [--waste]"
disable-model-invocation: true
---

# Friction

**Job:** find what keeps costing this repo's sessions time, and fix the parts the owner accepts, each with a test, through a PR.

**Not my job:** user-level settings (`~/.claude/settings.json`) or `settings.local.json` · allow rules for anything that writes, deletes, merges or reaches the network beyond reading · applying a proposal the owner did not pick · weakening a hook to make its refusals go away.

**When there is nothing to report:** `friction: nothing to propose (N sessions since <since>)`.

1. **Scan.** `python3 scripts/ai/friction.py $ARGUMENTS` (default the last 7 days; `--waste` adds the token and output audit, automatic on Mondays). No output means nothing to propose: say the quiet line and stop.
2. **Show the proposals** as a table: kind, evidence, proposed change, target. Then ask once (one multi-select question) which to apply. Recommend first the ones with the most evidence.
3. **Apply the accepted ones** on a branch (`git switch -c claude/friction-$(date +%Y%m%d)`):
   - `allow`: add the exact rule to `.claude/settings.json`, never a broader one. For the read-only utilities line, run Claude Code's own `/fewer-permission-prompts` instead.
   - `guard` / `stop` / `rejected`: fix whatever keeps walking into the refusal (the script, the playbook step, the doc that suggests the command), never the hook itself. A lesson true of every iOS repo goes to ios-ai-kit (`/reflect` routes it).
   - `build-error`: a line in the matching `.claude/rules/` file, or better a type or test that makes it impossible.
   - `flaky`: reproduce the test in isolation (`scripts/ai/test.sh -only-testing:…` several times) and fix the race; never retry it green or skip it.
   - `slow-gate` / `waste`: find what grew, with the numbers before and after.
4. **Prove each change** the cheapest real way: run the command the new rule allows, run the fixed test N times, rerun the gate and compare its time.
5. **Commit and propose:** `scripts/ai/pr.sh`. Rerun `friction.py` and report which proposals are gone.
