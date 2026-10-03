# Autonomous run

A long task the user steps away from ("run until it's done", "I'm going to bed"). The bar is higher, not lower: nobody is watching, so every claim must be checkable when they return.

1. **Write the contract first,** as the first todo items: the goal, the predicate that means done (a test passes, a screenshot shows X, an eval reaches N with the gate held), what you will NOT do without the user (Autonomy, in `principles.md`), and where the decision log lives (`.build/reports/<date>-<slug>.md`).
2. **Pace with the harness, not with sleep:**
   - `/loop` (or `ScheduleWakeup` inside a loop) for work that waits on something slow; pick the delay from what you are waiting for, and never poll a build you started in the background, since its completion wakes you.
   - Long builds, test runs and evals run with `run_in_background`; a `Monitor` watches a log for the line that matters (`BUILD SUCCEEDED|error:`) instead of re-reading it.
   - Independent slices go to their own worktrees or cloud sessions (`playbooks/delegate.md`), each with its own simulator and derived data; `/lead` tracks them.
3. **Log every decision** as one line in the report: time, decision, evidence, reversible or not. A default you chose for a call only the user can make is logged with the one word that reverses it.
4. **Verify each unit before the next,** exactly as the matching playbook says. The Stop hook will not let a turn end on a broken build: answer it with a fix, not a disclaimer.
5. **When blocked on a genuine product decision,** do not stop the run: park that branch of work, log the decision with options and a recommendation, and continue with everything that does not depend on it.
6. **At the end,** put each unit's gate results (`python3 scripts/ai/history.py last <sha>`) and evidence paths in the report, and open each unit's PR with `scripts/ai/pr.sh`.

**Reply (when the user returns):** outcome against the predicate, the decisions made for them (each with its reverse word), the parked decisions (one at a time, per Decisions in `principles.md`), and the evidence report path.
