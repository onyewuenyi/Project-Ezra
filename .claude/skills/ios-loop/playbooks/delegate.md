# Delegate: split work across sessions without losing any of it

Use when a request is bigger than one change, or the owner wants several things done at once.

1. **Split into verifiable units.** Each unit is one PR with one success check stated up front ("the empty state shows 'No plants yet' at AX5", "README install section matches install.py"). Give each a short id. A unit you cannot state a check for is not ready to delegate.
2. **Never fan out coupled code.** Two units touching the same types, files or schema go to ONE session, in sequence. Parallelism is for independent units only.
3. **Route each unit:**
   - **Cloud** (`scripts/ai/cloud.sh "<task + check>"`): needs no Xcode: docs, scripts, String Catalogs, audits, mechanical refactors that a local build will check, Foundation-only logic. It asks before launching.
   - **Local worktree** (`scripts/ai/worktree.sh new <id>`, or `claude --worktree <id>`): needs the simulator or a build. Its own branch, DerivedData and simulator.
   - **This session:** the unit everything else depends on, done first.
4. **Write each prompt as a contract:** the goal, the success check, the files in scope, what is out of scope, and how to report (gate results, "Not verified here").
5. **Track to done, not to started.** `/lead` (or `/loop /lead`) follows every unit: cloud ones by their session link and branch, local ones by their PR. A unit is done when its PR is merged or the owner abandons it. A follow-up goes to the same unit (`cloud.sh --branch <head>`, `worktree.sh pr <n>`), never to a fresh session.

**Reply:** the units, their route, their check, and the session links or worktree paths.
