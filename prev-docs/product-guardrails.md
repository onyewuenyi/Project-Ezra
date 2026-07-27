# Product Guardrails — Managing Chaos, Effortlessly

Durable product governance for Project Ezra. Read this before changing product
behavior, adding a feature, or reviewing a change against the product thesis. These
are standing rules, not one-session context — they outrank convenience, cleverness,
and engagement metrics.

## Implementation Principles

Every change — and every review of a change — must satisfy:

- **Reduce friction.** Each feature removes steps or attention cost; never adds net interaction.
- **Preserve trust.** The AI never lies, never hides what it did, never decides what isn't its to decide.
- **Preserve momentum.** Nothing blocks the user mid-flow; animations are decorative, never required.
- **Prefer inference over questions.** Ask only when the answer is genuinely the user's (judgment-category rule).
- **Every AI action is reversible.** If it can't be undone, it can't be silent.
- **Every AI decision is explainable.** `reasoning` exists on the model; surface it, don't bury it.

## Trust Checklist (gate for every AI-touching feature)

Ship only if the user can:

- **Understand** what the AI did
- **Undo** it
- **Correct** it in one tap
- **Ignore** it without penalty
- **Recover** the original input (`rawCapture` is stored verbatim on every committed task)

## Never Optimize for Engagement

This product never optimizes for time-in-app, session count, notification opens, or
re-engagement loops (the PRD's V1 learning guardrail, promoted to a standing rule).
Optimize instead for: reduced interaction, faster completion, higher AI confidence,
lower cognitive load. A feature that increases sessions but not trust is a regression.

### The one carve-out: the daily briefing nudge (2026-07-26)

`BriefingReminder` ships a single local notification, which reads against the
"notification-driven re-engagement" refusal below. It is allowed as a **narrow, named
exception**, not a softening of the rule, and only while all of these hold:

- **One notification type.** A second one is the signal this was abused, not a precedent.
- **Off by default, at a time the user picks.** An alarm they set, not a hook we cast.
- **No badges, no counts, no "5 tasks overdue", no escalation, no streaks.**
- **It never fires on a day the briefing already played** (`BriefingSchedule.occurrences`,
  asserted in `BriefingScheduleTests`).
- **It does not inflate the engagement metric.** An open the app solicited is excluded
  from `Metrics.selfInitiatedOpens` — otherwise the one honest pull metric quietly
  becomes the vanity number this section exists to refuse.

The reasoning: the Today sequence is a once-a-day moment that only happens if you
remember it, and a moment you have to remember is a chore. The rule is about not
optimizing for sessions; a self-scheduled alarm that actively skips days you already
showed up for does the opposite.

## Performance Budgets (engineering constraints, not aspirations)

| Interaction | Budget |
|---|---|
| Task completion motion | <200ms (`Motion.complete` + `completeHold`) |
| System response to any accept/undo tap | <150ms |
| Review phase appearing after inference returns | <100ms (state swap + one `Motion.settle`) |
| Detail sheet presentation + stagger spread | <250ms total (stagger ≤0.15s per section) |
| Mic tap → listening state visible | <500ms (asset download excepted — shown as `.preparing` pulse) |
| Any animation blocking interaction | never |

## Confidence & Autonomy Definitions

Grounded in `AutonomyPolicy` (the code's source of truth):

- **silent** = confidence ≥ 0.8 AND reversible AND not a judgment call
- **suggest** = 0.5–0.8, one-tap confirm
- **ask** = < 0.5 OR judgment call OR irreversible

These tiers (`AutonomyPolicy.tier`) are unchanged. What changed with the state-layer
split: the tier no longer *is* the task's state — it only drives **workflow routing**
via `AutonomyPolicy.proposedWorkflow`. Only the **silent** tier is filed straight to
the `.ready` lane; **suggest**, **ask**, and every judgment call enter `.suggested`
(the Suggested lane / Inbox), awaiting the user's "Make ready". Workflow lanes
(Suggested / Ready / In Progress / Done) are the only user-owned states; **Blocked**,
**Up for Grabs**, and **Needs Decision** are now *derived assessments* (`TaskAssessment`,
never stored — computed from the `blockers` list, `ownerPending`, and
`isJudgmentCall`/`confidence`) that a card wears without changing its lane.

The **auto-commit threshold is 0.85**, deliberately above the silent floor (0.8):
auto-commit skips even the review glance, so it demands a stricter bar, and it
additionally requires exactly one draft and no judgment call (`CapturePolicy`).
**Judgment calls never auto-anything at any confidence** — the invariant extends
from filing to committing, and a judgment call always routes to `.suggested`
regardless of how confident the model is.

## Future Feature Checklist

Does it remove friction? · Does AI infer instead of ask? · Does it reduce future
work? · Does it preserve user agency? · Can it be undone? · Does it simplify the UI?
· Would we still build it if AI disappeared? — **Two "no"s = don't build it.**

## Things We Refuse to Build

Priority matrices · gamification / streaks / productivity scores · mandatory metadata
· complex project hierarchies · AI chat as the interface · notification-driven
re-engagement · a setting for every behavior · explicit "AI" branding beyond the
sanctioned `AITag`. (Deliberately NOT adopted despite existing in prior apps:
streaming/crystallize theater, confetti, priority systems, swipe-card boards,
"Apple Intelligence" chrome.)

## Architecture Principles (prevent drift)

- Pure logic lives outside views and is testable (`AutonomyPolicy`, `CapturePolicy`, `TaskItem` mutations in `TaskMutations.swift`).
- Views stay declarative; behavior lives in models/services.
- Everything AI is engine-agnostic — it operates on `TaskDraft`, identical for `FoundationModelsEngine` and `HeuristicEngine`.
- SwiftData owns persistence; views never invent state the model can hold.
- Design tokens only (`Palette` / `Font` / `Spacing` / `Radius` / `Motion`), never hardcoded values.
- The cobalt→cyan `Palette.accentGradient` is reserved for a small set of high-signal moments; use `Palette.accentFlat` everywhere else (the review's ✦ "assumed" marker is `accentFlat`, not the gradient `AITag`).
