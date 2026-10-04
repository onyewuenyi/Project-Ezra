---
name: interrogate
description: Adversarial review of an iOS diff through independent lenses (concurrency, persistence and data safety, lifecycle and state, UI at the extremes, accessibility, privacy and App Review, performance, slop), one reviewer agent per lens and a second Claude model on the riskiest, with every finding verified before it is reported. Use for /interrogate, "tear this apart", "stress test this change", or before shipping a contested design.
argument-hint: "[diff target: branch, commit range, or paths] [lenses]"
disable-model-invocation: true
---

# Interrogate

**Job:** find the ways this diff fails the person using the app, and report only the findings that survive verification.

**Not my job:** applying fixes unless asked · style nits · reviewing beyond the diff and what it touches · using any model outside Claude.

**When there is nothing to report:** "No verified findings", with the lenses run and the two riskiest spots each one checked.

The signal comes from three places: independent lenses, each looking for one class of failure; model diversity, the same lens asked of a second Claude model; and verification, where a finding that cannot name a concrete input producing a wrong result is dropped.

## 1. Scope and intent

- Diff: the argument if given, else `git diff` of uncommitted work, else `git diff $(git merge-base HEAD origin/HEAD)...HEAD` (the branch's work).
- Write one paragraph of intent from the user's words, the commits and the code. Reviewers judge the change against it.

## 2. Pick the lenses

Choose the 3–5 that the diff can actually fail on. All eight on a one-file copy change is noise.

| Lens | Looks for |
|---|---|
| `concurrency` | Actor isolation and `Sendable` violations, tasks outliving their view, missing or ignored cancellation, an `await` that re-enters on stale state, main-actor blocking I/O, races between two async writers |
| `persistence` | Context/thread affinity, object lifetime after deletes, faults in loops, unsaved or unchecked saves, migrations that are not supersets, destructive paths without backup, CloudKit/sync assumptions |
| `lifecycle` | `scenePhase` and background transitions, state lost or duplicated on relaunch, sheets presented from the wrong context, navigation state after a pop, work started in `onAppear` that re-runs |
| `ui-extremes` | Truncation and clipping at accessibility sizes, iPad and small-device layout, keyboard overlap, fixed sizes, animations on first layout, Reduce Motion |
| `accessibility` | Unlabelled controls, gestures without spoken actions, content hidden for the eyes but read aloud (and the reverse), announcements, transient UI that disappears before it is spoken |
| `privacy-review` | Usage strings, privacy manifest agreement, data leaving the device beyond what the app says, launch seams escaping DEBUG, in-process pickers, App Review guideline risks |
| `performance` | Work in `body`, O(n²) per render, main-thread decoding, over-broad observation invalidating whole trees, unbounded caches |
| `slop` | Dead code and unused helpers or scripts left behind, debug residue (prints, temporary flags, commented-out code), comments that narrate the diff instead of the why, tests weakened or deleted to pass, a new pattern beside an existing one that does the same job |

## 3. Spawn one reviewer per lens

In one message, one `Agent` call per lens, `subagent_type: "review-lens"`, run in parallel. Each prompt contains: the lens name, the intent paragraph, the diff command to run (not the diff inlined), and the project's rules file path (CLAUDE.md) so project invariants count. Ask each for at most 5 findings.

**Second opinion.** For the one or two lenses where a miss would hurt most (usually `persistence` or `concurrency`), send the SAME prompt a second time in the same message with the Agent tool's `model` set to a different Claude model from the reviewer's default (`sonnet` or `fable` beside the default `opus`). Different models miss different things; a defect both find independently is the strongest signal this skill produces, and one only a single model finds still gets verified in step 4 like any other.

## 4. Verify before reporting

For each returned finding, confirm it yourself: read the cited lines, and where cheap, reproduce (a unit test, a seam run, a grep). Classify:
- **Confirmed:** you reproduced it or the code unambiguously produces the failure.
- **Plausible:** the mechanism is real but you could not trigger it; say what would.
- **Rejected:** the concrete scenario does not hold. Drop it, and say why in one line.

Two lenses finding the same defect independently is strong signal; say so.

## 5. Verdict

Findings ranked by harm to the person using the app: file:line, the failure scenario, Confirmed/Plausible, the suggested fix. Then the rejected ones in one line each. Do not apply fixes unless asked.
