//
//  StallDiagnosis.swift
//  Project-Ezra
//
//  "Unstick" — the capability that reduces INERTIA. Silent on a healthy task; present
//  only when one is demonstrably sliding.
//
//  The important part is that it does not merely *reflect* the fact. Telling someone
//  "you've deferred this four times" is a scold, not help. So this diagnoses WHY the
//  task is stuck and hands off to whichever capability actually addresses it — which is
//  what stops the three capabilities from being three isolated modules:
//
//      blocked      → resolve the blocker      (an existing seam)
//      too big      → Break this down          (§ BreakdownEligibility)
//      really a choice → set the kind          (→ the Thinking Partner appears)
//      dying        → do it · defer it · kill it
//
//  Chronic deferral IS information: the user is avoiding something, and the useful move
//  is to name what.
//
//  Deterministic on purpose. Unlike the other two capabilities, this one has no model
//  call in its trigger OR its diagnosis — so it works in the simulator, in tests, and
//  for every user whose Apple Intelligence is off. On device the model may only *phrase*
//  the result; it can never change it.
//

import Foundation

/// Why a task is stalled, and therefore what to offer.
enum StallDiagnosis: Hashable {
    /// Something concrete is in the way — the blocker is the work, not this task.
    case blocked
    /// It is too large to start. Carries the breakdown's own reason so the card can
    /// hand straight over without re-deriving it.
    case tooBig(BreakdownEligibility.Reason)
    /// It reads as a choice rather than a doable thing — no wonder it isn't moving.
    case reallyADecision
    /// None of the above: it has simply been set aside, repeatedly.
    case dying

    /// The card's one-line statement of what it noticed. Reporting, never scoring —
    /// no streaks, no judgement, no exclamation marks.
    /// Both counts are REQUIRED. A default here is how this branch would stay dead a
    /// second time: `ChatAdvisorLine.citedTasks` shipped unset for a day and rendered no
    /// citations at all with every test green, and `triage`'s `route:` defaulted to
    /// `.cloud` and transmitted a new user's first brain dump. A caller that does not name
    /// the input is a caller nobody is deciding for.
    func headline(deferralCount: Int, abandonedStarts: Int) -> String {
        switch self {
        case .blocked:
            return "This is waiting on something else."
        case .tooBig:
            return "This might be too big to start."
        case .reallyADecision:
            return "This reads like a decision, not a task."
        case .dying:
            // Two different stalls, and saying the wrong one is worse than saying nothing
            // specific. A task picked up and dropped repeatedly has NOT "gone quiet" — it
            // is the loudest thing on the list — and until 2026-09-12 that is exactly what
            // it was told, because this branch read `deferralCount` and the Brief that
            // wrote it was cut on 2026-09-02.
            if abandonedStarts >= 2 {
                return "You've started this \(abandonedStarts) times and put it back down."
            }
            return deferralCount >= 2
                ? "You've set this aside \(deferralCount) times." : "This has gone quiet."
        }
    }
}

enum StallDetector {

    /// Planned-and-ignored this many times CONSECUTIVELY → stalled. `deferralCount` is
    /// the true skip signal (`carriedOverCount` is worked-but-unfinished, the inverted
    /// case), so this counts avoidance rather than effort.
    ///
    /// "Consecutively" is what makes the card dismissable: `touchHuman` resets the
    /// counter, so every action this card offers clears the condition that raised it.
    /// A lifetime counter would pin "This keeps sliding" to the task forever.
    static let deferralThreshold: Int32 = 3

    /// Or quiet for half the auto-archive window — surfacing it here is what gives the
    /// user a say before `BrainSweeps` eventually archives it.
    static let quietThreshold: TimeInterval = StalePolicy.archiveThreshold / 2

    /// Diagnose a stalled task, or nil when it is healthy — which is the answer for most
    /// tasks, and the card is worth nothing if it is always there.
    ///
    /// Suppressed for a task that already carries `needsDecision`: the decision section
    /// is already saying something more specific, and two cards competing to explain the
    /// same task is exactly the clutter the surface refuses.
    /// - Parameter suppressChoiceRung: **one intervention per problem.** The same
    ///   lexicon that fires `.reallyADecision` also summons the Thinking Partner, so
    ///   whenever the partner card is actually VISIBLE this rung is a duplicate —
    ///   the same advice twice, the clutter the tooBig subsumption exists to prevent.
    ///   The caller (the render layer, which knows whether the partner is drawn —
    ///   absence is a render-layer decision) passes `true` to fold the rung through
    ///   to the next diagnosis. Off-device, where the partner card isn't drawn, the
    ///   default keeps the escalate arm alive. A pure parameter; the trigger stays
    ///   view-free.
    static func diagnose(
        _ task: TaskItem, among tasks: [TaskItem], now: Date = Date(),
        suppressChoiceRung: Bool = false
    ) -> StallDiagnosis? {
        guard task.status.isLive else { return nil }
        guard !(task.needsDecision && !task.status.isResolved) else { return nil }
        guard isStalled(task, now: now) else { return nil }

        // First match wins, most-actionable first. Each rung names a cause the user can
        // do something about; `dying` is the honest fallback when none applies.
        if task.hasActiveBlockers(among: tasks) { return .blocked }
        if let reason = BreakdownEligibility.evaluate(task, among: tasks) { return .tooBig(reason) }
        if !suppressChoiceRung, readsAsDecision(task) { return .reallyADecision }
        return .dying
    }

    /// Repeatedly picked up and put back down inside `quietThreshold` → stalled.
    ///
    /// **Two, not three**, and for the same reason the depth router's floor is two: a
    /// deferral is one tap and often means nothing about the task, while an abandoned start
    /// is a declared start and an abandoned one. One is an interruption; two is a pattern.
    static let abandonmentThreshold = 2

    /// Has this task actually stalled? Two independent signals, either sufficient.
    ///
    /// **One of them had been dead for ten days** (fixed 2026-09-12). The avoidance signal
    /// read `deferralCount`, whose only writer was the Brief's day-rollover, and the Brief
    /// was cut on 2026-09-02 — so the only surviving route to "stalled" was neglect by
    /// SILENCE. A person actively bouncing off a task, picking it up and dropping it week
    /// after week, was invisible to the sensor that exists to catch exactly that, and the
    /// whole Advisor diagnosis ladder behind it (`blocked` / `tooBig` / `reallyADecision` /
    /// `dying`) never opened for them.
    ///
    /// The abandonment arm deliberately does not fire while the task is `.doing`: the open
    /// visit is not an abandonment, and telling someone they keep avoiding the thing they
    /// are doing right now is nagging. Starting it silences the diagnosis for as long as
    /// they are working, which is the same dismissability `touchHuman` used to provide.
    static func isStalled(_ task: TaskItem, now: Date = Date()) -> Bool {
        if task.deferralCount >= deferralThreshold { return true }
        if task.status != .doing,
            task.recentAbandonedStarts(within: quietThreshold, now: now) >= abandonmentThreshold
        {
            return true
        }
        return now.timeIntervalSince(task.humanTouchedAt) > quietThreshold
    }

    /// Does the wording read as a choice? Reads `DecisionShape` — the one decision
    /// lexicon — and the TITLE only, never `isJudgmentCall` or `needsDecision`.
    /// (Decision is no longer a work-intent; this rung's job is unchanged: a stalled
    /// task worded as a choice hasn't moved because nobody made the call, and the
    /// useful act is escalating it to a visible decision, a human act.)
    static func readsAsDecision(_ task: TaskItem) -> Bool {
        DecisionShape.reads(title: task.title)
    }
}
