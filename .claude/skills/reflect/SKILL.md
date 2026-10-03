---
name: reflect
description: Mine the current session for durable lessons (a correction, a trap, a wrong assumption, a slow path) and route each to the strongest mechanism that would have prevented it: a type, a test, a hook, a script, an ios-screens line, a playbook step, or a project rule. Proposes, never applies without approval. Use for /reflect, "capture what we learned", or after a long or painful task.
disable-model-invocation: true
---

# Reflect

**Job:** turn this session's lessons into structure, so the next session cannot repeat them.

**Not my job:** applying anything the owner did not pick · writing rules into memory (memory is for facts about the owner and the work) · lessons that will not recur · what the repo already enforces.

**When there is nothing to report:** "Nothing durable to encode from this session", with the one candidate that came closest and why it was dropped.

## 1. Collect candidates

From this conversation, list every moment where:
- the user corrected you, or rejected an approach
- something you believed turned out false (an environment fault read as an app bug, a metric that lied, a stale install)
- a check caught a defect late that an earlier check could have caught
- you spent more than a few steps on something a script would do in one
- a rule in CLAUDE.md or a skill was missing, wrong, or ignored
- a subagent (`ui-verify`, `build-verify`, `review-lens`) returned something wrong or wasteful
- a line in `.claude/ios-screens.txt` turned out stale (re-date its `#seen:` or retire it)

Drop one-offs: a lesson must plausibly recur. Drop what the repo already enforces.

For a long session, spawn one `general-purpose` agent with the transcript path (`~/.claude/projects/<project>/<session>.jsonl`, the newest for this project whose first user message matches) and ask for the same list independently; merge the two lists. Two independent sightings are high signal.

## 2. Route each lesson

Use the ladder in `.claude/skills/ios-loop/principles.md` (Encode lessons in structure). For each lesson pick the STRONGEST rung that fits:

| Rung | Mechanism | Lands in |
|---|---|---|
| 1 | Type / API shape | the app's source |
| 2 | Test (including a grep test for an absence) | the app's test target |
| 3 | Hook | `.claude/settings.json` (this app), or ios-ai-kit's `template/.claude/hooks/guard.py` if it applies to every iOS project |
| 4 | Script / doctor check | ios-ai-kit's `template/scripts/ai/` (with a case in its `tests/`) |
| 5 | Screen line / playbook step | `.claude/ios-screens.txt` (an `expect:`/`absent:` that would have caught it, dated `#seen:<date>`), or ios-ai-kit's `ios-loop/playbooks/` |
| 5b | Agent definition | the agent that made the mistake (ios-ai-kit's `template/.claude/agents/`, or the project's own): refine its job and anti-jobs so the next one does not |
| 6 | Rule text | the project's CLAUDE.md (and its long-form doc if the project keeps one) |
| 7 | Memory | only for facts about the user or the work, not rules |

Decide app vs kit: a lesson true of any iOS app goes to ios-ai-kit (installed files here are overwritten on upgrade, so a kit fix made only in this repo is lost); one true of this app only goes to the project.

## 3. Propose

Present a table: lesson (one sentence, with the moment it happened), rung, exact target file, the proposed edit (a diff for text, a sketch for a test or hook). Then a short "rejected" list with reasons. Wait for the user to pick which to apply.

## 4. Apply

Apply the approved items on a branch. A new test or hook is run once to prove it fires on the failure and passes on the fix. When a structural fix replaces prose, delete the prose. Commit, then `scripts/ai/pr.sh`; kit changes go to the ios-ai-kit repo as their own PR.
