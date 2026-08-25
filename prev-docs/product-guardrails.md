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

These tiers (`AutonomyPolicy.tier`) are unchanged, and the judgment-category carve-out
is still the point of them: a values-laden call is always `.ask`, no matter how confident
the model is.

**What changed (four-axis model, 2026-08-11): the tier no longer routes anything.** The
workflow lanes this section used to describe — `.suggested` / `.ready` / "Make ready",
and the `proposedWorkflow` + `CapturePolicy` auto-commit machinery — are all deleted.
Lifecycle is one axis with four cases (`todo` · `doing` · `done` · `canceled`), and
**capture is always-confirm**: nothing is gated on confidence, every draft reaches the
confirm card populated and editable, and `AppBrain.commit` *is* the publish boundary.
Uncertainty is a visual state on the confirm card, never a destination.

So the tier's job is narrower than it was: it describes how much autonomy an inference
*deserves*, and it feeds `needsDecision` at birth (via the judgment flag) — it does not
decide whether a task is created, nor where it lands. The one place confidence still
gates an action is inference that **destroys or merges existing user data** (the duplicate
merge, tiered at 0.85 / 0.5), because that is the only case where being wrong costs the
user something they already had.

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

- Pure logic lives outside views and is testable (`AutonomyPolicy`, `IntentResolver`, `TaskRanking`, `TaskItem` mutations in `TaskMutations.swift`).
- Views stay declarative; behavior lives in models/services.
- Everything AI is engine-agnostic — it operates on `TaskDraft`, identical for `FoundationModelsEngine` and `HeuristicEngine`.
- SwiftData owns persistence; views never invent state the model can hold.
- Design tokens only (`Palette` / `Font` / `Spacing` / `Radius` / `Motion`), never hardcoded values.
- The cobalt→cyan `Palette.accentGradient` is reserved for a small set of high-signal moments; use `Palette.accentFlat` everywhere else (the review's ✦ "assumed" marker is `accentFlat`, not the gradient `AITag`).
