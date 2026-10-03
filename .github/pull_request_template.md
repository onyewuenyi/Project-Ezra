## What changed and why

## Verification (`/verify`)
<!-- paste the gate table and visual verdicts from .build/verify/report.md -->

| # | Gate | Result |
|---|---|---|
| 1 | format | |
| 2 | build (no new warnings) | |
| 3 | tests | |
| 4 | launch-argument safety | |
| 5 | reach (screens affected) | |
| 6 | visual: default · dark · AX5 | |

**Not verified here** (device-only behavior, skipped gates):
-

- [ ] New files are in the right target (synchronized folder or explicit membership)
- [ ] Empty, loading, error and success states exercised for any new screen
- [ ] Animation changes checked with Reduce Motion
- [ ] `cloud-authored`: this branch came from a cloud session and passed `/verify` on a Mac
