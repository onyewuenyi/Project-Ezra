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
    func headline(deferralCount: Int) -> String {
        switch self {
        case .blocked:
            return "This is waiting on something else."
        case .tooBig:
            return "This might be too big to start."
        case .reallyADecision:
            return "This reads like a decision, not a task."
        case .dying:
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
    static func diagnose(
        _ task: TaskItem, among tasks: [TaskItem], now: Date = Date()
    ) -> StallDiagnosis? {
        guard task.status.isLive else { return nil }
        guard !(task.needsDecision && !task.status.isResolved) else { return nil }
        guard isStalled(task, now: now) else { return nil }

        // First match wins, most-actionable first. Each rung names a cause the user can
        // do something about; `dying` is the honest fallback when none applies.
        if task.hasActiveBlockers(among: tasks) { return .blocked }
        if let reason = BreakdownEligibility.evaluate(task, among: tasks) { return .tooBig(reason) }
        if readsAsDecision(task) { return .reallyADecision }
        return .dying
    }

    /// Has this task actually stalled? Two independent signals, either sufficient.
    static func isStalled(_ task: TaskItem, now: Date = Date()) -> Bool {
        if task.deferralCount >= deferralThreshold { return true }
        return now.timeIntervalSince(task.humanTouchedAt) > quietThreshold
    }

    /// Does the wording read as a choice? Reuses `IntentResolver`'s decision lexicon
    /// rather than a second vocabulary — one place to widen when the wording changes.
    ///
    /// Note this reads the TITLE, never `isJudgmentCall` or `needsDecision`. Axis 2 and
    /// axis 3 stay independent; a suggestion the user accepts goes through the human
    /// `setWorkIntent` path, which is a person deciding, not the classifier reading a flag.
    static func readsAsDecision(_ task: TaskItem) -> Bool {
        task.workIntent != .decision
            && IntentResolver.inferredWorkIntent(title: task.title) == .decision
    }
}
