---
name: verify
description: Run the full definition-of-done gate for this iOS repo (format, build with no new warnings, tests, Release-safety of launch arguments, blast radius, and the visual matrix judged by eye) and write the PR-ready report. Use for /verify, "run the gate", "is this ready to merge", before opening a PR, and on every branch a cloud session produced.
disable-model-invocation: true
argument-hint: "[--no-visual] [--no-tests] [--release] [screen names…]"
---

# Verify

**Job:** run every gate on the working tree and write the PR-ready report, with the visual sheets judged by eye.

**Not my job:** merging · pushing to the default branch · fixing beyond three attempts per gate · calling a skipped gate passed · judging a sheet nobody looked at.

**When there is nothing to report:** the gate table, all PASS, and the "Not verified here" list.

1. Run `scripts/ai/verify.sh $ARGUMENTS`. It runs every gate even after a failure and writes `.build/verify/report.md`.
2. For each failed gate, read `.build/verify/<gate>.txt`.
   - **Fix it** if it is in this change's scope, and re-run.
   - **Report it** if it is not, and don't hide it.
   - **Cap: three fix attempts per gate,** then report what is left.
   - Never weaken, skip or delete a test to get a pass.
3. **Visual (gate 6).** The script only captures; judging is your job.
   - Spawn the `ui-verify` agent with the `JUDGE` sheet paths from the report, plus the screens `reach` (gate 5) named. Each sheet shows default, dark and the largest text size side by side.
   - Look for: clipped or truncated primary text, overlapping elements, controls off-screen or under the keyboard or home indicator, unreadable contrast in dark mode, and a blank screen where a state should show something.
   - Where the change touched an interaction and Xcode is open, ui-verify also drives it with device interaction and asserts the resulting UI hierarchy.
4. **Record the verdict.** The visual gate reads `JUDGE` until someone looks: once ui-verify has judged every sheet, run `python3 scripts/ai/history.py judge PASS "<one line per screen>"` (or `judge FAIL "<what is wrong>"`). Only then does this commit count as verified for `pr.sh`, the lead and the status line. Never judge sheets you did not open.
5. **Reply with:**
   - the gate table from `report.md`;
   - the visual verdict per screen, with sheet paths;
   - a filled-in **Not verified here** list (device-only behavior, anything a gate skipped).

   That text is the PR description's verification section.
6. **Propose it.** When every gate passed (or each failure was accepted) and the work is committed, run `scripts/ai/pr.sh`: it opens the PR with this report as its body, or updates the open one. Never push to the default branch and never merge; the owner does.

A change is done only when every gate passes, or each failure is explained and accepted by the person asking.
