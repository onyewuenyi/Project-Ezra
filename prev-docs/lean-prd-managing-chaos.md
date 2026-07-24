# Managing Chaos, Effortlessly: Lean PRD

## Product Vision Statement

For people who have downloaded and abandoned Todoist, TickTick, Things, or Notion at least once,
who watch their task list quietly turn into an untrustworthy graveyard of overdue items until starting over feels easier than cleaning up,
we provide a task system where AI automates the administrative mechanics reliably and hands judgment calls back to the user, rather than one more app that leaves all of it to them,
that delivers a list that always answers "what should I do next" instead of "here are 437 things,"
unlike existing task apps, which help you create and organize tasks but leave maintaining the system entirely to you.

**Internal design principle** (not the external headline, which stays "Managing chaos, effortlessly"): *Automate the mechanics. Preserve the judgment.* The goal isn't a self-maintaining system that runs the user's life, it's a system where the user spends their limited attention only on the decisions that actually require them.

## Lean PRD

```
Problem:
  Every task app has solved fast capture, and people churn out of all of them anyway.
  The bottleneck isn't capability, it's trust decay: backlogs outgrow the user's
  ability to maintain them, the list stops reflecting reality, and starting over
  in a new app feels easier than cleaning up the old one. The real incumbent isn't
  Todoist or TickTick, it's the user's own brain, Notes app, and texts-to-self,
  which win today not because they're good but because they require zero setup
  and zero maintenance. This product has to beat that convenience, not just other
  task apps.

User:
  Adults who've cycled through 2+ task apps, feel the "graveyard" pain acutely,
  and are skeptical that another list-based app will help them.

Core Use Case:
  As a user with a messy, growing list of errands and tasks,
  I open the app and act on what it surfaces,
  so that I make progress without spending effort managing the list itself.

Core Loop (V0 / MVP):
  Capture (voice/text/forward) → AI reduces friction on the mechanical, reliably-
  automatable parts (categorizing, timeline suggestions, extracting details)
  → User makes the decisions that actually require judgment, surfaced as a small,
  honest, bounded "next actions" set, with low-confidence AND values-laden items
  routed to a visible Needs Decision state rather than silently resolved
  (and, in a shared household, an item with no clear owner routed to an equally
  visible Up for Grabs state rather than silently assumed to be the user's own —
  same honesty principle, applied to who does it instead of how confident the
  AI is; see "Shipped Beyond Original MVP Scope" below)
  → Completed/stale items resolve (done or killed), loop repeats tomorrow

JUDGMENT-CATEGORY RULE (new, sits alongside the confidence tiers, doesn't replace
them): some decisions are always human, regardless of how confident the AI is,
because they're values judgments, not factual ones — "should you quit this
project," "is this life priority still important," "should you cancel this
commitment." High confidence about what the user would probably choose is not
the same as the decision being appropriate to automate. The confidence tiers
(silent/suggest/ask) govern HOW SURE the AI is; this rule governs WHETHER the
category of decision is ever the AI's to make at all. A values-laden decision
routes to Needs Decision even at high confidence.

Core Loop (V1 addition, not V0):
  ... → Learn: the system observes completions, ignores, postponements, and
  rejections to require less input over time.
  GUARDRAIL (must ship with this, not after): the system must learn to need
  LESS attention and interaction, not more. If any V1 learning feature is found
  to be optimizing for session count or time-in-app rather than reducing user
  effort, that is the trust thesis breaking from the inside and the feature
  must be cut or redesigned before shipping, not tuned. Deferred to V1 because
  it needs real usage data to work at all and isn't required to prove the core
  loop; the guardrail is recorded now so it isn't lost by the time V1 starts.

MVP Scope:
  INCLUDE:
    - Triage inbox (single capture point, processed in batch) — this is the trigger
      half of the core loop; without one obvious inbox, capture friction reappears
    - AI-driven state model (Needs Decision / Ready / Blocked / Done) — this is
      where friction gets removed for mechanical decisions and preserved for
      judgment calls; Needs Decision is the visible surface both for low-confidence
      routing AND for values-laden decisions the AI should never resolve on its
      own (see the judgment-category rule above), without this state, ambiguous
      or values-laden items get silently misfiled into Ready or Blocked and
      quietly erode trust (since refactored into two layers — user-owned workflow
      lanes (Suggested / Ready / In Progress / Done) with AI assessments (Needs
      Decision / Blocked / Up for Grabs) layered on top rather than one fused
      state; see "Shipped Beyond Original MVP Scope" below)
    - Confidence-gated autonomy (silent / suggest / ask, per action-class) plus
      the judgment-category rule — this is what makes automation trustworthy
      rather than overreaching; without it, every automated action risks either
      breaking trust in one wrong move or making a call that was never the AI's
      to make
    - Daily brief (today's small bounded set only) — this is the "User Value" step
      of the loop; it's the payoff that has to land every single open
    - Weekly retro (force a decision on stalled items: do / kill / defer) — this
      is the direct rot-fighting mechanism and the "Repeat Signal" that keeps the
      system honest over time, not just on day one
    - Onboarding import + first-run transformation (paste/forward existing messy
      list, AI collapses it to a first honest "next actions" set in the first
      session) — this is where the core loop is proven to a brand-new user inside
      minute one, which is the acquisition wedge as well as first activation

  V1 (not required to validate the core loop, but scoped now so the guardrail travels with the feature):
    - Learn step: system requires less input over time by observing completions,
      ignores, postponements, rejections — ships only with the attention-reduction
      guardrail above enforced, not as a bare engagement feature
    - Dependency chains (task A blocks task B, auto-resurfacing) — demoted from
      P0: a genuinely uncontested feature gap and a real rot lever, but proving
      the AI can maintain a trustworthy daily brief doesn't require it; needed
      before the daily brief can be trusted with real-world task sequencing,
      so it should follow shortly after V0, not be treated as fully secondary
      [SHIPPED — see "Shipped Beyond Original MVP Scope" below; this is no longer
      a V1 gap, it's built]

  EXCLUDE:
    - Location-based states or reminders — deliberately cut (battery, privacy,
      complexity); not needed to validate the core loop
    - Monthly pattern review — post-MVP; needs weeks of data to be meaningful and
      isn't required to prove the daily/weekly loop works
    - Calendar and personalization inputs — optional confidence levers, not
      required for MVP; the loop must work with lower confidence and more
      confirmations before these exist
    - Cross-platform (Android/web) — Apple-first per design philosophy; can
      expand once the loop is validated
    - Shareable "wow" recap videos / acquisition media — downstream of proving
      surfacing quality; building this before the AI reliably picks the right
      few items is theater

Success Metrics:
  Primary:   AI suggestion acceptance rate — % of AI-proposed actions (suggest-tier
             confirmations, and Needs Decision resolutions) the user accepts rather
             than undoes or overrides. This is a single behavioral number, hard to
             game by deleting things (a wrongly-archived task gets un-archived,
             which lowers acceptance, not raises it), and it directly measures
             whether the user trusts what the AI did without checking its work,
             which is the thing the entire thesis depends on.
  Secondary: Rot rate (% of tasks stale before being acted on, trending down) —
             now a diagnostic for WHY acceptance is moving, not the headline;
             Self-initiated open rate (habit forming vs. notification-dependent);
             Time-to-first-payoff (install to first experienced transformation,
             target under 60 seconds); Undo/reversal rate on AI actions (paired
             guardrail with acceptance rate, watches for over-aggressive auto-
             archiving specifically)
  Timeframe: 2-4 weeks post private beta, once daily brief + weekly retro have
             each run at least 3-4 cycles per user
```

## Shipped Beyond Original MVP Scope

Tracking real product evolution since this PRD was first written — not a rewrite of the original scope above
(kept intact as the record of original intent), but an honest account of what the product has grown into.

- **Dependency chains** (originally the V1/"demoted from P0" item below) — **now fully shipped**, and more
  capable than originally scoped: a real reference graph (`blockedBy: [UUID]`, N blockers per task, cycle-safe
  by construction — a dependency can never be added if it would close a loop), not just a modeled idea. Rendered
  on the Tasks board as physically stacked card groups (a collapsed front card + a depth badge showing the true
  chain length, expandable to the full ordered sequence) rather than plain "after X" text.
- **Family roster + ownership** — genuinely new, not scoped in the original lean PRD at all: a task can be
  delegated to a specific person via a real `FamilyMember` record (stable identity, optional photo) rather than
  a free-text guess, so two mentions of the same name are provably the same person. **Up for Grabs** is the
  assessment this introduces: an item with no clear owner in a household that has other people to assign it to is
  a visible gap, following the exact same honesty principle as Needs Decision, just on a different axis (who, not
  how confident). It's a derived observation off an `ownerPending` flag, not a workflow lane — the task stays in
  its Ready lane and simply wears an Up for Grabs chip until someone claims it. Solo installs never see any of
  this surface — zero added friction — it only activates once a household has more than one person.
- **In Progress** — a new, purely manual workflow lane (never AI-inferred) letting a person mark a Ready task as
  actively underway. No autonomy or trust implications; it's workflow visibility, not a judgment the AI is
  making. In a shared household it doubles as a quiet "is anyone on this?" signal.
- **The state-layer split** — the single fused state enum was refactored into three independent layers: a
  stored, user-owned **workflow lane** (Suggested / Ready / In Progress / Done — the only states a person or the
  lifecycle moves a task through), a derived-on-read **assessment** (Needs Decision, Blocked, Up for Grabs — the
  AI's live observations, never stored, computed from confidence/judgment, the blockers list, and ownership),
  and a derived **recommended action**. This is what lets a card wear a Blocked or Needs Decision chip *without*
  its lane changing — and it's why an In Progress task that picks up a blocker now stays In Progress instead of
  bouncing back to Ready.
- **Tasks board (formerly "Runs")** — a Kanban-style board over the workflow lanes only (Suggested / Ready / In
  Progress — Done leaves the board), reusing the daily brief's bounded-attention discipline (a scrollable lane
  switcher plus an owner filter, never a raw 437-item list) at the "browse everything, not just today's 3"
  altitude the original PRD didn't specify a home for. Blocked and Up for Grabs ride along as assessment chips
  inside those lanes rather than being lanes of their own. Category — the original organizing idea for this
  screen — is now card metadata, not the grouping key; workflow state is.

## User Flows, Ranked by Value to the User

Ranked by the payoff each flow delivers to the user, not by build sequencing (that's the Execution Backlog below,
which orders by what has to exist first, not by what matters most once everything exists). A flow ranks higher
here the more directly it delivers on the vision statement's promise — "what should I do next" instead of "here
are 437 things" — and the more it's where trust is actually won or lost, per the two-part trust thesis.

### 1. Daily Brief — the payoff moment
**Why #1:** This is the one moment the entire product exists to deliver, the "User Value" step of the core loop
that "has to land every single open." Every other flow exists to make this one honest and small. If this flow
stops delivering, nothing else compensates.

- **Trigger:** User opens the app (self-initiated, ideally — see the retention loop's trigger risk).
- **Steps:**
  1. Today screen loads first, before any composer or capture UI — no empty-state friction, no "what do you want to do" prompt.
  2. A small, bounded set of next actions is shown (target: 3, never a scrollable backlog).
  3. User acts directly on a card (complete, defer, drill in) — completion is fast/near-instant (~200ms), never a ceremony.
  4. A quiet footnote ("AI handled 17 items") reports what the AI resolved without the user's input; tapping it opens the AI Activity Trail sheet rather than restating the list on-screen.
- **Payoff:** The user leaves knowing what to do and trusting the rest is handled, without ever seeing the size of the backlog behind it.

### 2. Onboarding Import & First-Run Transformation — the trust-founding moment
**Why #2:** This is a single-session flow (it only happens once per user), but it's what makes flow #1 credible
on day one instead of theoretical. It's the acquisition wedge and first activation combined — the PRD calls it
where "the core loop is proven to a brand-new user inside minute one." Ranked above the recurring judgment-call
and capture flows because if this flow fails, the user churns before those flows ever get a chance to run.
- **Trigger:** First app launch.
- **Steps:**
  1. User pastes or forwards their existing mess (Notes app dump, old Todoist export, texts-to-self) — no manual re-entry.
  2. AI processes it live, on-screen, as a visible transformation, not a progress bar — this is the one screen in the app that earns dramatic, extended motion (the chaos→clarity settle).
  3. Output collapses the mess into a first honest set (e.g. "I found 5 areas... I can manage these going forward").
  4. User lands directly on their first real Daily Brief, generated from their own data, not sample content.
- **Payoff:** Proof, inside the first 60 seconds, that this app is different from the graveyard of apps already abandoned — target time-to-first-payoff is under 60 seconds.

### 3. Needs Decision Resolution — where trust is won or lost
**Why #3:** This is the flow the product's primary success metric (AI suggestion acceptance rate) directly
measures. It's ranked below the two payoff-delivering flows above because it's a means to their end (a clean
Daily Brief, a credible onboarding result) rather than the payoff itself, but it's ranked above plain capture
because this is specifically where the judgment-category rule and the confidence tiers are experienced firsthand
— get this wrong and every other flow inherits the damage.
- **Trigger:** An item is low-confidence, ambiguous, costly/hard-to-reverse (suggest tier), or a values-laden judgment call (always routed here regardless of confidence, per the judgment-category rule).
- **Steps:**
  1. Item surfaces in the Suggested lane wearing a visible Needs Decision assessment — never silently auto-resolved, never silently filed straight into Ready, and (in a household) never left to default onto the user as owner instead of wearing an Up for Grabs chip.
  2. Confidence Indicator communicates why it's here ("AI suggestion — Accept" for suggest tier, "Need your input" for ask tier).
  3. User accepts, overrides, or answers the judgment call directly — a values decision ("should I quit this project") is never pre-resolved on the user's behalf no matter how confident the AI is.
  4. The action (or the user's override) feeds the acceptance-rate metric, and an override/undo never reads as a dead end — it's what the metric is designed to catch.
- **Payoff:** The user's attention is spent only on decisions that actually required a human, and every one of those decisions was genuinely theirs to make.

### 4. Triage Inbox — the capture entry point
**Why #4:** Necessary trigger for the whole loop (no single inbox means no clean entry point), but it's
explicitly friction-reduction, not the payoff — the PRD frames it as "the trigger half of the core loop," not the
value half. Ranked below the decision and onboarding flows because a fast capture with nothing good happening
downstream is exactly the failure mode of every incumbent app already abandoned.
- **Trigger:** User has something to offload — an errand, a thought, a forwarded email or receipt.
- **Steps:**
  1. Capture via voice or text in the Composer (two visible affordances only — no manual attach/context buttons); voice/keyboard capture targets under a second, matching the product's speed bar.
  2. Item lands in the Inbox, batched rather than processed one at a time.
  3. AI triages in batch: categorizes, extracts details, assigns a confidence score, and files each item to a workflow lane — silent-tier items straight to Ready, everything less certain (suggest tier, low confidence, judgment calls) to the Suggested lane — layering on assessments (Blocked, Needs Decision, or, in a household when no owner is detected, Up for Grabs) as observations rather than separate lanes.
- **Payoff:** Offloading a messy thought costs the user nothing beyond saying or typing it — no forced categorization, no manual filing.

### 5. Weekly Retro — the rot-fighting mechanism
**Why #5:** Recurring and load-bearing for long-term trust (it's the direct rot-fighting mechanism, the thing
that keeps the system honest over time, not just on day one), but it's lower-frequency than every flow above it
and only matters once a backlog of stale items exists for it to act on — it has nothing to do in week one.
- **Trigger:** Weekly cadence, or a stale-item threshold being crossed.
- **Steps:**
  1. Stalled items are surfaced as a forced decision set, presented as a ledger/receipts of what happened, not another to-do list to process.
  2. For each item, the user picks do, kill, or explicitly defer — no fourth option to silently ignore it again.
  3. Once the user is mid-flow through a sequence of items, transitions go near-instant — a 30-second retro shouldn't turn into a slog.
- **Payoff:** Nothing is allowed to quietly rot forever; staleness gets forced into an explicit decision on a predictable cadence.

### 6. Learn (V1) — requires less input over time
**Why #6:** Deferred to V1 because it needs real usage data to exist at all, and it's additive on top of flows
1–5 rather than something a user directly initiates. Ships only with the attention-reduction guardrail enforced —
if it starts optimizing for session count or time-in-app instead of reducing user effort, that's the trust thesis
breaking from the inside, and the feature gets cut or redesigned, not tuned.
- **Trigger:** Passive — accumulates from the user's completions, ignores, postponements, and rejections across flows 1–5.
- **Steps:**
  1. System observes patterns in what gets accepted, overridden, or ignored.
  2. Confidence thresholds and default routing adjust so fewer items need to land in Needs Decision over time.
- **Payoff:** The app asks for less input the longer it's used, the inverse of how backlogs normally grow.

### 7. Dependency Chain Resurfacing — blocked-item automation (SHIPPED — no longer P1)
**Why #7:** A genuinely uncontested feature gap and a real rot lever. Originally scoped as P1 because proving the
AI can maintain a trustworthy Daily Brief didn't require it first — it's since been built, and built more capably
than the original single-blocker idea: a real reference graph, not a modeled placeholder.
- **Trigger:** A blocked task's dependency (one or more other tasks, referenced by a real, cycle-safe link — not
  a text guess) is completed.
- **Steps:**
  1. A blocked task stays out of the Daily Brief while any of its blockers are still open — Blocked is a derived
     assessment, so the task sits in its own workflow lane wearing a decorative frost on the title only, never on
     the assessment chip — and on the Tasks board, chained tasks render as a physically stacked card group
     (collapsed front card + a depth badge), not separate unrelated cards.
  2. All of a task's blockers complete (a task with multiple blockers stays blocked until every one clears).
  3. The task becomes actionable again the moment its last blocker clears (its lane never changed; it simply
     stops reading as Blocked, and may still wear an Up for Grabs chip if it has no owner) — without the user
     having to remember or manually check; the stack visually reshapes to show what's newly actionable.
- **Payoff:** Sequencing errands correctly ("renew passport" → "book flight" → "request time off") stops being
  something the user has to track by memory, and seeing the whole chain at a glance (not just one blocked card
  at a time) makes the sequencing itself legible.

### 8. Claiming an Up for Grabs Task — closing the ownership gap
**Why #8:** Not part of the original lean PRD (family/ownership wasn't scoped at MVP at all) — this is the
household-only counterpart to Needs Decision Resolution, but a smaller, purely-logistics decision (who does this)
rather than a judgment call, so it ranks below flow #3 rather than beside it. Only ever appears once a household
has more than one person to potentially assign work to; a solo install never sees this flow at all.
- **Trigger:** The AI captured a task with no detected delegation, in a household that has other people in its
  roster.
- **Steps:**
  1. Item surfaces wearing a visible Up for Grabs assessment chip — never silently assumed to be the user's own by default.
  2. From the task's detail sheet, the user either taps "That's mine" or picks a specific person from the Owner menu.
  3. Claiming clears the `ownerPending` flag — the Up for Grabs chip drops (the task was already in its Ready
     lane and never moved), leaving it indistinguishable from any other actionable task, save any Blocked chip a
     real dependency still warrants.
- **Payoff:** A shared household's capture list never silently defaults ambiguous work onto one person; who does
  what stays an explicit, visible decision instead of an assumption.

### 9. Starting / Stopping Progress — a personal work-in-progress signal
**Why #9:** The newest and smallest addition — pure workflow visibility layered on top of the existing Ready
state, with zero autonomy or trust implications (nothing here is AI-driven or judged, unlike every flow above
it). Ranked last because it's optional flavor for a solo user and only becomes genuinely useful once a household
is coordinating around who's actively on what.
- **Trigger:** The user is about to start (or has finished, for now) working on a Ready task.
- **Steps:**
  1. From the task's detail sheet, tap "Start" — the task moves to In Progress, distinguished only by a quiet
     chip, never a color or urgency signal.
  2. Completing an In Progress task works exactly like completing a Ready one (same tap, same fast animation).
  3. "Back to Ready" undoes it if the user stops before finishing.
- **Payoff:** In a shared household, seeing that someone's already started something is a small but real trust
  signal — it answers "is anyone on this?" without anyone having to say so out loud.

## Execution Backlog

| # | Task | Category | Ties to Core Loop | Priority | Estimate |
|---|------|----------|--------------------|----------|----------|
| 1 | Triage inbox: unified capture (voice, text, forward) | Core Feature | Is the loop's entry point; no single inbox means no clean trigger | P0 | M |
| 2 | State model: Needs Decision / Ready / Blocked / Done + confidence-scored transitions *(shipped; since split into user-owned workflow lanes — Suggested / Ready / In Progress / Done — plus derived AI assessments — Needs Decision / Blocked / Up for Grabs — layered on top, see "Shipped Beyond Original MVP Scope")* | Core Feature | Is where friction gets removed on mechanical decisions and preserved on judgment calls; Needs Decision surfaces both low-confidence AND values-laden items | P0 | L |
| 3 | Autonomy tiers: silent / suggest / ask, per action-class, plus the judgment-category rule (some decisions are always human regardless of confidence) | Core Feature | Makes automation trustworthy instead of overreaching into decisions that were never the AI's to make | P0 | M |
| 4 | Daily brief: bounded "today" surface | Core Feature | Is the "User Value" payoff step; must land every session | P0 | M |
| 5 | Onboarding import + first-run transformation | Core Feature | Proves the loop to new users in minute one; doubles as activation and acquisition demo | P0 | L |
| 6 | Weekly retro: forced decision on stale items | Core Feature | Is the "Repeat Signal" step; the direct rot-fighting mechanism over time | P0 | M |
| 7 | Instrumentation: acceptance rate, undo rate, rot rate, time-to-first-payoff, self-initiated opens | Instrumentation | Acceptance rate is now primary; these are the only signals that tell us if the loop is working | P0 | M |
| 8 | Confirmation UI for "suggest" tier actions (one-tap accept/undo) | UX | Reduces friction on the one place users interact with AI decisions directly; feeds the acceptance-rate metric directly | P0 | S |
| 9 | Dependency chains: block/unblock + auto-resurface *(SHIPPED — real reference graph, cycle-safe, N blockers, stacked-card rendering; see "Shipped Beyond Original MVP Scope")* | Core Feature | Demoted from P0; not required to prove the core loop, but needed soon after to trust the daily brief with real sequencing | P1 | M |
| 10 | "Recently tidied" trail for silent actions | UX | Keeps silent autonomy from reading as loss of control | P1 | S |
| 11 | A/B: daily brief framing (count shown vs. hidden) | Experiment | Tests whether seeing "437 remaining" undermines the bounded-attention promise | P1 | S |
| 12 | Learn step: reduce required input over time from completion/ignore/postpone/reject signals | Core Feature | V1, not V0; must ship with the attention-reduction guardrail enforced (see PRD core loop), not as a bare engagement feature | P1 | L |
| 13 | Monthly pattern review | Core Feature | Post-MVP; needs multiple weeks of retro data to be meaningful | P2 | M |
| 14 | Calendar input as confidence lever | Core Feature | Raises autonomy ceiling; not required to prove the base loop | P2 | M |
| 15 | Family roster + ownership: `FamilyMember` records (name, optional photo), delegation, Up for Grabs state, owner filter *(SHIPPED, not originally scoped)* | Core Feature | Extends the judgment-category rule's honesty principle to a second axis (who, not just how confident); zero added friction for solo installs | — | L |
| 16 | Kanban board expansion: In Progress workflow lane (manual-only), Tasks board (formerly Runs) redesigned as a workflow-lane board (Suggested / Ready / In Progress) with a scrollable switcher, Blocked/Up for Grabs as assessment chips rather than lanes *(SHIPPED, not originally scoped)* | Core Feature | Gives "browse everything, not just today's 3" a real home without breaking the daily brief's bounded-attention promise | — | L |
