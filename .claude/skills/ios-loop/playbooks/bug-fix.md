# Bug fix

Every shipped line traces to runtime evidence. A change that "might help" is a hypothesis, and hypotheses do not ship. When evidence refutes one, revert what it motivated.

1. **Doctor and guard.** Run `scripts/ai/doctor.sh`, then `scripts/ai/sim.sh guard`. If a plain launch dies, the environment is broken: fix that first, and nothing measured before now counts.
2. **Reproduce on the surface the user saw.** Drive it the way `/verify` does: a launch-argument seam (`scripts/ai/sim.sh launch <args>`), a deep link (`sim.sh openurl`), or an XCUITest for a real gesture. If there is no seam to reach the state, add a DEBUG-fenced one (it stays, and a line in `.claude/ios-screens.txt` makes it the regression path). Record the rate (e.g. 4/6 launches). Ask the user to reproduce only with a stated reason the harness cannot reach it, after driving it as far as it goes. If a faithful reproduction is impossible, record the exact limitation and never present the nearest path as equivalent evidence.
3. **Separate three facts before naming a cause:**
   - the **trigger**: the input, event or transition that starts the fault
   - the **masking condition**: the independent state, timing, cache, size class, text size, locale or runtime that hides or exposes it (why it happens "sometimes")
   - the **symptom**: what the person sees, often several layers downstream
   A masking condition explains intermittency without being the cause.
4. **Compare against a proven path.** Find where the behavior is known to work (another screen, another text size, the previous commit, the other store) and locate the earliest meaningful divergence in inputs, state, timing or control flow. Read history (`git log -L`, `git blame`, `git bisect` over the seam) when it explains which invariant was intended. The most recent nearby change is not causal without evidence.
5. **Name the counterfactual and the disconfirming check.** The smallest change that should flip the outcome if the leading explanation is true, and the observation that would falsify it. Run both. Keep contradictory results; do not explain them away. Read the `.ips` (`scripts/ai/sim.sh crashes <epoch>`) before theorizing, and remember some traps write none (`scripts/ai/sim.sh alive` after the action).
6. **Write the failing check first** when it is cheap: a unit test on the pure logic, a UI test, or a scripted seam run with a pass condition. It must fail for the reported reason.
7. **Fix at the root.** No nil-guard that silences a crash, no retry that hides a race, no `asyncAfter` that outruns a timing bug. If the fix crosses a type or module boundary, sketch the call site first.
8. **Verify on the same surface, the same number of times,** with the guard between runs: 4/6 failing becomes 6/6 passing. Then run `python3 scripts/ai/blast-radius.py <changed files>` and re-capture every surface it names, at the default and the largest accessibility size: a fix to a shared view or token regresses screens you did not open. Run the full test suite. Unit tests green is not "bug absent".
9. **Commit in order:** the failing check, then the fix. The message states symptom, trigger, masking condition, fix.
10. **Ask whether the lesson belongs in structure** (`principles.md`, Encode lessons in structure): `/reflect` puts it there.

**Reply:** what the person saw; trigger, masking condition and symptom; the divergence from the proven path; the counterfactual and disconfirming check with their results; the fix; repro rate before and after with evidence paths; what now guards against a return.
