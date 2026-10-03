# Handoff

Work that outlives a session: pausing cleanly, or picking up someone else's.

## Pausing

1. Get to a state that builds. If that is not possible, say exactly what does not compile and why.
2. Commit or stash what is yours, by path. Never sweep another session's uncommitted files into your commit.
3. Write the handoff where the next session will look (the project's TODO or a note file it names): the goal, what is done with its evidence, what is in progress, the next step, the traps you hit, and the exact commands to resume (simulator UDID, DerivedData path, seams).
4. Shut down simulators and processes you started. Keep the evidence.

## Picking up

1. `git fetch && git status && git log --oneline -10`. The session-start bearings already name uncommitted work, an unverified HEAD and PRs that need the owner. Read the handoff note and the recent commits.
2. Rebuild and re-verify the last claimed state before building on it. A "done" in a handoff is a claim, not evidence.
3. Continue from the handoff's next step, in the matching playbook.

**Reply:** where it stands, the evidence for it, and the next step.
