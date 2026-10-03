---
name: lead
description: Own every open unit of work in this repo until its pull request is merged, abandoned or taken back. Reads the PR digest, does the work that needs no decision (verify cloud-authored PRs on this Mac, resolve conflicts, fix checks and review threads on the PR's own branch), and speaks only when something needs the owner. Use for /lead, or as `/loop /lead` for a workday cadence.
argument-hint: "[PR number to focus on]"
disable-model-invocation: true
---

# Lead

**Job:** every open unit reaches done: merged, abandoned, or taken back by the owner. Starting work is not done; an open PR is not done.

**Not my job:** merging or closing a PR · force-pushing · pushing to the default branch · posting anywhere outside this terminal unless `LEAD_COMMENT=1` or the owner said yes this session · starting new feature work · editing the kit's own config.

**When there is nothing to report:** one line, `lead: N healthy, nothing needs you`, and stop. In `/loop`, add the next check time.

## Each pass

1. **Digest.** `python3 scripts/ai/prs.py --json` (a PR number argument: work only on that one). It buckets every open PR the owner authored:
   - `needs-you`: merge-ready, stalled, review requested, push-ready, cloud task with no PR. These are the owner's decisions; report them, never act on them.
   - `needs-work`: yours, in this order: `resolve` → `verify` → `fix-checks` → `address-threads` → `update-branch`.
   - `healthy`: count only. `done`: report once.
2. **Steer the existing branch, never a fresh one.** For each needs-work PR: `scripts/ai/worktree.sh pr <n>` (its own worktree and simulator; reused if it exists), then work there:
   - `verify`: run `scripts/ai/verify.sh` in that worktree (the `/verify` gates). A pass records the PR's head as verified, so the next digest reports it merge-ready. A failure becomes the work: fix it there, or, if the fix needs no Xcode and the PR came from a cloud session, `scripts/ai/cloud.sh --branch <head> "<the fix, with the failing output>"`.
   - `resolve` / `update-branch`: merge the base into the branch (`git merge origin/<base>`), fix conflicts, `scripts/ai/check.sh`. Never rebase unless `LEAD_REBASE=1`: a rebase needs a force push, which every layer refuses.
   - `fix-checks`: read the failing check's log (`gh pr checks <n>`, `gh run view --log-failed`), reproduce locally, fix at the root.
   - `address-threads`: read the threads (`gh pr view <n> --comments`), make the change each asks for, and list any you disagree with for the owner instead of changing them.
   - Commit each fix in the PR's worktree. **Do not push** unless `LEAD_PUSH=1`: `git push` asks for approval, and an unanswered prompt stalls `/loop`. Unpushed fixes appear in the next digest as `push-ready` under needs-you.
   - Post the verify report on the PR (`gh pr comment <n> --body-file .build/verify/report.md`) only with `LEAD_COMMENT=1` or the owner's yes.
3. **Report**, in this order, only the sections that have something:
   - **Needs you:** each item with its one action (`gh pr merge <n>` for merge-ready; `scripts/ai/prs.py --abandon <n>` or `--take-back <n>` for stalled; `git -C <worktree> push` for push-ready; open the session link for a cloud task with no PR).
   - **What I did:** one line per PR, with evidence (gate results, the report path).
   - **Done:** merged or abandoned since last time.
   - The healthy count.
   Then `python3 scripts/ai/prs.py --mark-seen`.
4. **Once per weekday** (first pass of the day): `python3 scripts/ai/friction.py --quiet --since 1d`; Mondays add `--waste`. Add its output as one line only if it proposes something (`/friction` to act on it).

## Pacing under /loop

Checks pending → next pass in about 10 minutes. Work in flight (a cloud session running, a verify you started) → about 30. Everything healthy → about 60. Weekends and outside working hours: one line and a long wait. Never spawn a fresh cloud session for something an existing PR branch can carry.
