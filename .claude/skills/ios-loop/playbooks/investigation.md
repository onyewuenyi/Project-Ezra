# Investigation (scout)

A read-only question: how does X work, why does Y behave this way, is Z safe to change, which of two approaches. The deliverable is a report, not a change. A report may recommend implementation; it never authorizes it.

1. **State the question and the decision it serves** in one sentence each. If the answer would not change a decision, say so and stop.
2. **Gather evidence, cheapest first:** the code (callers, types, tests), the history (`git log -S`, `git log -L`, blame), the project's docs and decision records, then the running app (a seam, a log, a measured number) when behavior is the question. Delegate wide sweeps to an `Explore` agent and keep only its conclusions.
3. **Label every claim** measured, read-in-code (with file:line), or inferred. Where the code and the docs disagree, the running app decides.
4. **Write the report** to `.build/reports/<yyyy-mm-dd>-<slug>.md` (gitignored unless the owner wants it kept):
   - the question and the one-paragraph answer
   - the evidence, each item with its label and location
   - what is still unknown and the check that would settle it
   - options with a recommendation, if a decision is pending
5. If implementation follows, it starts as a new task in the matching playbook from a clean base; scratch edits and debug logging from the investigation do not ride along. A reproduced bug becomes that task's failing check.

**Reply:** the answer first, then the report path, the strongest evidence, and the open unknowns.
