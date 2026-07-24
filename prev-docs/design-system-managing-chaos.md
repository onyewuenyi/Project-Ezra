# Managing Chaos — Design System (Revised)

Core principle, unchanged from the original draft, this part was right:

> **Calm intelligence: the interface disappears so the user can focus on progress.**

This revision keeps everything from the original that held up (quiet-by-default, progressive disclosure, typography scale, spacing grid, the confidence indicator concept, the chaos-to-clarity transformation as signature component) and corrects four places where the draft quietly reversed decisions already made in the product strategy and PRD.

Worth noting: Apple's own design principles (specifically "Purpose": *decide what not to build, every feature spends the user's time and trust, spend that budget only where it pays off*) is an independent restatement of this product's whole thesis, bounded attention as the point, not a constraint to work around. That's a useful external check that the direction is sound, not just internally consistent.

---

## What changed, and why

### 1. Composer moved off the home screen
The original made an "AI Composer" ("What's on your mind?") the app's starting screen, styled after ChatGPT/Claude. This reintroduces the empty-state problem the PRD already solved for: a blank capture box is the worst first impression for an app whose value is "it manages the chaos for you," because there's no chaos yet to manage. The composer is the **Inbox's** entry point, and a persistent quick-add affordance reachable from anywhere, not the destination the app opens to. **Today (the daily brief) remains the home screen.**

### 2. No standalone "AI" tab
Giving AI its own tab puts AI branding on equal footing with Today and Inbox in the single most prominent piece of real estate in the app, which contradicts "AI is the mechanism, not the pitch" (the Linear/Postgres framing from the strategy doc, nobody buys Linear for its database). The trust-layer content (activity timeline, undo log, reasoning) is kept in full, it moves to a toolbar-accessible sheet reachable from Today/Tasks, consistent with the "recently tidied trail" already scoped in the PRD.

### 3. Review restored to the nav
The weekly retro is the PRD's direct rot-fighting mechanism and had no home in the original draft's five tabs. It's back as a tab. "Projects" is renamed back to **Runs**, matching the PRD's weekly/trip-based batching model rather than an ongoing-container model; if you want to revisit that naming later, do it deliberately.

**Second rename: Runs → Tasks.** In practice the category-grouped batching view didn't deliver the "runs, not sprints" idea it was named for — it read as a second, quieter backlog next to Today rather than a trip-based batch. Renamed again, this time to **Tasks**: workflow-based lanes (Suggested / Ready / In Progress — a mobile-friendly Kanban-lite) replace category-Dictionary grouping, dependency chains render as real stacked card groups instead of plain "after X" text, and an owner filter (a real family roster, not a free-text guess) lets you view your own tasks or a specific person's. Blocked and Up for Grabs are not lanes — they're derived assessment chips a card wears inside whichever lane it sits in.

### 4. Accent color reconsidered (twice)
Indigo/purple is the default signal for "AI product" across the category (ChatGPT, Claude, and most AI wrappers converge here), which works against differentiation rather than for it. A warm amber was tried next and rejected outright. Landed on a **bold cobalt→cyan gradient**, distinctive against both the AI-purple convention and the acid-green/vermilion-on-black cliché, used narrowly on the same small set of high-signal moments a flat accent would occupy, with a flat fallback color for contexts too small to render a gradient legibly.

### 5. Completion color resolved
The original assigned green as a persistent "completed" status color while also correctly saying completion should feel like a transition, not a checkbox state. Green is now used **only as a transient animation color during the completion motion itself** (see Motion section), never as a standing badge or persistent task-card color. A completed task has no special color at rest, it simply leaves the visible set.

---

## Navigation

**Tab bar (four tabs):**

```
Today       Tasks       Inbox       Review
```

- **Today** — home screen, the daily brief. Opens here by default.
- **Tasks** — Suggested / Ready / In Progress workflow lanes (workflow state, not category, is the organizing
  axis); Blocked and Up for Grabs ride along as assessment chips, not lanes; dependency chains render as
  stacked card groups; filterable by owner (you, or a specific family member).
- **Inbox** — the composer and capture entry point. Chaos lands here, gets triaged.
- **Review** — weekly retro (stale-item decisions) and, later, monthly pattern review.

Trust-layer content (AI activity/undo log) is a toolbar-accessible sheet from Today or Tasks, not a tab. Settings is a toolbar item, not a tab, for the same reason, it's not part of the core loop.

---

## Color System

### Dark Mode (primary; dark-first reads premium and matches the "quiet" thesis)

```
Background          #111111
Primary Surface      #181818
Secondary Surface    #202020
Elevated Surface     #262626
Border               #303030
Primary Text         #F5F5F5
Secondary Text       #A1A1A1
Muted Text           #6B6B6B
```

### Light Mode

```
Background           #FAFAFA
Primary Surface      #FFFFFF
Secondary Surface    #F5F5F5
Border               #E5E5E5
Primary Text         #1A1A1A
Secondary Text       #6B6B6B
```

### Accent — bold cobalt→cyan gradient, not amber, not AI-purple

```
Accent Start         #1E5EFF   (electric cobalt)
Accent End           #22D3EE   (bright cyan)
Accent Gradient      linear-gradient(135deg, #1E5EFF 0%, #22D3EE 100%)
Accent Flat Fallback #2F6BFF   (single-color equivalent, for contexts where a gradient can't render, e.g. system tint colors, SF Symbol fills)
Accent Soft          #1E5EFF @ 15%
Accent Glow          #1E5EFF @ 8%
```

Deliberately avoids both AI-purple (the category-wide convention) and warm amber/clay/terracotta (rejected directly, and clay is close to Anthropic's own Claude-interaction accent, a tell if used here). Also avoids the other AI-design cliché of a single acid-green or vermilion accent on a near-black background, using a gradient rather than a flat neon hue sidesteps that pattern too.

Usage stays as restrictive as the flat-amber version was, only for AI actions, recommendations, and active/focus states, never every task, category, or priority label, since a bold, gradient-rendered accent draws more attention per use than a flat one did, spreading it further would break the "quiet by default" principle harder than amber ever would have. The gradient is reserved for a small set of high-signal moments (the AI tag on a recommended task, the active tab indicator, the retro's primary confirm button); everywhere else in the accent's usual footprint, fall back to the flat `Accent Flat Fallback` color rather than rendering a gradient at small sizes, since gradients read poorly below roughly 24px.

Accent Glow is reserved specifically for the AI processing indicator's soft-glow motion (see Motion section); it won't appear in any static screen, only during that animated state, so its absence from a still mockup isn't a sign it's unused.

### Semantic Colors (minimal, and resolved for the completion conflict)

```
Success (transient only, completion motion)   #34C759
Warning (needs attention)                     #F59E0B   — now clearly distinct from the accent since the accent is cobalt/cyan, not amber; no conflict to resolve
Error (rare)                                  #EF4444
```

Success green never appears as a resting state, only as part of the completion animation described below.

---

## Typography

SF Pro Display / SF Pro Text, Dynamic Type throughout.

```
Large Hero        34pt  Bold       "What should I work on?"
Screen Title       28pt  Semibold
Section Header     17pt  Semibold
Task Title         16pt  Medium
Supporting Text     14pt  Regular
Metadata           12pt  Regular
```

**Tracking is size-specific, never one fixed value across the scale** (per Apple's typography guidance): tighten large text with slightly negative tracking (Large Hero, Screen Title get ~-0.02em), leave Task Title and Supporting Text near 0, and body-scale leading stays comfortably loose while the hero's leading stays tight. A single letter-spacing value applied everywhere is wrong somewhere on this scale.

## Layout System

**Spacing (8pt grid):** 4, 8, 12, 16, 24, 32, 48, 64

**Corner radius:** Small 8px · Cards 14px · Composer 20px · Sheets 24px (continuous/squircle style, matching iOS system controls)

---

## Core Components

### 1. Daily Focus Card (home screen, Today)
```
Today

3 things worth doing
────────────
Finish daycare forms
Prepare presentation
Call insurance
────────────
AI handled 17 items
```
This is the payoff moment and must load first, before any composer or capture UI.

### 2. Composer (Inbox entry point, not home)
```
┌─────────────────────────┐
│ What's on your mind?    │
└─────────────────────────┘
```
Two visible affordances only: type or speak. No manual "attach" or "context" buttons, an attachment is a rare enough case to live behind a single overflow rather than a permanent icon, and context (calendar, personalization) is inferred automatically per the confidence-lever framing in the PRD, never something the user manually toggles from the composer. Lives in Inbox and as a persistent quick-add affordance elsewhere; never the app's landing screen.

### 3. AI Activity Trail (toolbar sheet, not a tab, and its ONLY home)
```
AI Updates
✓ Combined duplicate tasks
✓ Rescheduled dentist reminder
✓ Archived inactive goal
Undo
```
This is the single place AI activity is enumerated. Today's footnote ("AI handled 17 items") is a count only, not a restated list, tapping it opens this same sheet rather than showing its own version. Review does not repeat this content, Review's screen is scoped to the retro decision only; showing "recent AI updates" there again would be the same information doing the same job twice.

### 4. Task Card
```
○ Renew passport
Personal · Due Friday
AI suggestion: Do this first
```
No priority colors, no tag clutter, no persistent status badges.

### 5. Confidence Indicator (maps directly to the PRD's silent/suggest/ask autonomy tiers)
```
High confidence  → "✓ Automatically updated"      (silent tier)
Medium confidence → "AI suggestion — Accept"       (suggest tier)
Low confidence    → "Need your input"              (ask tier)
```

---

## Motion

Motion decisions here follow one added test, borrowed from Emil Kowalski's design engineering philosophy: **before animating anything, ask how often the user will see it per day.** High-frequency actions (tens of times/day) should animate minimally or not at all; rare/first-time moments are where elaborate motion is earned. This corrects one thing from the first draft of this system:

**Correction: task completion should be fast, not elaborate.** The original called for a "gentle collapse, one less thing" completion motion, styled as a meaningful transition. For an active user completing many tasks a day, that's a high-frequency action, and under the frequency test it should be closer to instant (fade/scale under ~200ms), not a deliberate, weighty animation. Save the elaborate motion budget for genuinely rare moments.

- **Task completion (high-frequency):** fast fade + scale, under ~200ms, no lingering choreography. The brief green flash (see Color section) happens within this same short window, never as a separate lingering beat.
- **Inbox swipe-to-triage (high-frequency):** minimal, near-instant, no decorative flourish, same logic as completion.
- **Daily brief appearing on Today (occasional, once or a few times a day):** a standard, brief entrance is fine here, this is the one place a light stagger across the 3 cards earns its keep (cap total stagger spread under ~0.15s per the platform's own guidance).
- **AI processing indicator:** subtle pulse or soft glow, never a spinner.
- **Onboarding chaos→clarity reveal (rare, first-time):** the one screen where a longer, more dramatic spring is earned, this is the signature moment and should feel weightier than everything else in the app.

**Asymmetric timing on suggest-tier confirmations:** the decision moment can afford a beat (a deliberate, unhurried entrance on the confirmation sheet), but the system's response to the user's tap (accept or undo) must resolve fast, under ~150ms. Slow when the user is deciding, fast when the system responds.

**Skip the delay on repeated decisions:** in the weekly retro, the first keep/kill/defer decision can use a standard transition, but once the user is mid-flow through a sequence of stale items, subsequent transitions should be instant or near-instant. A retro that's supposed to take 30 seconds shouldn't turn into a slog because every item plays out the same unhurried animation.

**Spring values, per Apple's own defaults:** critically damped (`damping 1.0, response 0.3-0.4`) for anything that just appears or completes on its own, no gesture behind it, this covers task completion, the daily brief entrance, and confirmation sheets above. Reserve bounce (`damping ~0.8, response 0.3-0.4`) strictly for interactions where the user's own gesture carried momentum, a swiped/flicked card being dismissed or deferred, never a fade-in. Applying bounce to something that wasn't physically thrown (a menu, a toast) is the most common misuse of springs and reads as unintentional wobble rather than physicality.

Use spring physics rather than linear easing everywhere on-screen movement occurs, and always provide a Reduce Motion fallback: cross-fade instead of slide/spring, no elastic overshoot, keep only the opacity/color changes that aid comprehension.

---

## Materials & Depth

Governs how Liquid Glass and translucency get used across the app, beyond the existing "glass is for chrome, not content" rule:

- **Material weight encodes hierarchy.** Heavier, more opaque materials separate structural regions (the tab bar, a modal's backing); lighter, more transparent materials draw attention to interactive controls sitting on top of content (the floating capture affordance). Don't use the same glass weight everywhere, it flattens the hierarchy the material is supposed to communicate.
- **Never stack translucent surfaces on translucent surfaces.** A glass toolbar over a glass card is where Liquid Glass most commonly goes muddy and illegible; give one of the two a solid surface.
- **Materialize on entry, don't just fade.** Glass surfaces (the AI Activity Trail sheet, the suggest-tier confirmation) should animate blur radius and scale together as they appear, not opacity alone, so they read as a physical layer arriving rather than content simply becoming visible.
- **Dim to focus, don't dim for parallel content.** The onboarding transformation (a blocking, focused moment) pairs with a background scrim and recession. The AI Activity Trail (a parallel, non-blocking check-in) should use offset and translucency without a scrim, so checking it doesn't feel like leaving the main flow.

## Signature Depth Motif (the actual moat, not the palette)

The gradient and dark base are necessary but not sufficient, they're clean and current, but easily copied. The real differentiator has to encode the one thing this product does that nothing else does: absorb chaos and hand back calm. This is now rendered as material, not just described.

**Depth behind glass (Today).** The items the AI is holding but not surfacing are rendered as slow, deliberately unreadable diffuse motion behind a frosted glass layer; the day's 3 crisp cards sit solid on top. This is viable now specifically because iOS 27 tuned Liquid Glass to diffuse complex content behind it far more effectively than iOS 26, with a darkened edge and brighter specular highlights adding real depth and separation, per Apple's own WWDC26 changes. **Accessibility guardrail, non-negotiable:** Liquid Glass must adapt to Reduce Transparency and Increase Contrast, so this effect needs a flat fallback, a plain "AI handled 17 items" count with no rendered depth, for anyone with those settings on. The depth is atmosphere, never the only way the information is conveyed.

**Signature settling motion (onboarding).** The chaos-to-clarity transformation becomes a physical precipitation: a diffuse field condenses and settles into the 5 solid areas, rather than a screenshot-style swap. This is the one animation worth obsessing over, since it's simultaneously the content hook, the onboarding aha, and the model for the daily brief's own generation moment, one piece of craft paying off in three places. Use the onboarding-tier spring values already specified (response 0.5-0.7) for the settle itself.

**Assessment as material, not a replacement for the label.** Since the state-layer split, these visual treatments key off a card's derived *assessment* (`TaskAssessment`), not a workflow lane — a card wears them inside whatever lane (Suggested / Ready / In Progress) it occupies. An unblocked, unflagged card stays crisp and full-opacity. A **Blocked** assessment gets a light frost/blur applied only to the task title text (decorative), never to the assessment chip itself (semantic, always crisp) — the chip remains the source of truth for anyone with Reduce Transparency on or anyone glancing quickly. A **Needs Decision** assessment (the umbrella over judgment-call and low-confidence proposals sitting in the Suggested lane) gets a subtle gradient edge-glow, this is a 4th sanctioned use of the accent gradient beyond the three already scoped (AI tag, active tab, primary button), justified because Needs Decision is precisely where judgment-category and low-confidence items surface, the single most important thing to draw the eye toward.

**Retro as receipts, not more to-dos.** The weekly retro's visual language should read as a statement of what happened, closer to a ledger or a git log than a task list, so it registers as accountability rather than another list to process.

**Explicitly deferred, not adopted: an ambient "pressure gauge."** A persistent visual indicator of how much the AI is holding versus surfacing was proposed alongside the above, but it directly contradicts an earlier decision that a persistent count/progress indicator on the core screen undermines the bounded-attention promise. The idea's own risk case, that the churn behind the glass could read as anxiety ("look how much is still undone") rather than relief, is exactly the failure mode that earlier decision was protecting against. This stays out of the core design system; it's a candidate for a later experiment, not a V0 commitment.

---

Unchanged from the original, this was correctly identified as the strongest idea in the whole system and the acquisition wedge from the product strategy.

First launch, user pastes their existing mess:

```
I found 5 areas:
Personal — Schedule dentist
Car — Book repair
Travel — Research flights
Insurance — Renewal
Family — Call mom

I can manage these going forward.
```

This is the onboarding `.fullScreenCover` moment, the only screen in the app that earns dramatic, extended motion.

---

## Native iOS Components to Use

NavigationStack (detail drill-in only, not Today itself) · TabView (Liquid Glass by default) · Sheet · ContextMenu · SwipeActions (any view, not just List, per iOS 27) · Search · TimelineView · WidgetKit · TipKit · Dynamic Type · SF Symbols (hierarchical rendering) · Liquid Glass materials (`.glassEffect`) for chrome only, never content surfaces.
