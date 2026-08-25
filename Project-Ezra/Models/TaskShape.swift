//
//  TaskShape.swift
//  Project-Ezra
//
//  What kind of page this task needs. DERIVED, never stored, never model-decided.
//
//  The task detail used to be one universal template with the Advisor bolted in as a
//  section. But a task blocked on someone else, a task carrying an open decision, an
//  umbrella with three live steps and a plain errand are not the same page wearing
//  different chips — the thing most demanding attention should be the page's spine,
//  and which thing that is derives from facts the system already holds.
//
//  Why facts and not the model's `AdvisorMove`: under a model-driven shape a timeout,
//  a spent budget or an offline device would reshape the whole page, and the layout
//  would pop when the reading landed. Under a fact-derived shape the page is identical
//  at every rung and in every failure mode; only the words inside it come from the
//  model. This is the codebase's standing division — sensors, gate and fallback
//  deterministic, the model judging only the shape of HELP — applied one level up.
//
//  **Shape ⊆ fingerprint.** Every input here (`status`, `needsDecision`, blocker
//  edges, child edges) is already hashed by `TaskAdvisorFacts.fingerprint`, so the
//  page can only reshape when the reading was going to change anyway. No new churn
//  source; `AdvisorRevealGate`'s one-interpretation-per-fingerprint calm extends to
//  layout for free. Pinned by `TaskShapeTests`.
//
//  **A signal is not a shape.** Breakdown-eligibility, staleness, urgency and
//  decision-shaped WORDING are signals that ride on top of a shape; adding a branch to
//  one of their detectors must never add a case here. In particular `DecisionShape`
//  (lexical) may never pick a page — only the human-owned `needsDecision` flag does,
//  because a false positive under the old design cost one dismissible card and under
//  this one would cost the whole layout.
//

import Foundation

enum TaskShape: String, CaseIterable, Sendable {
    /// A standing human obligation — the choice is the work.
    case deciding
    /// Waiting on something else — the blocker is the work.
    case waiting
    /// Broken into steps — the steps are the work.
    case container
    /// The residual, and the common case. Deliberately boring: the contrast that
    /// makes the other three land depends on this one staying quiet.
    case action

    /// Precedence follows the codebase's standing order, not a fresh opinion:
    /// decision outranks blocked in `advisorGateReason`, in `SignalMarker`, and in
    /// `TaskRanking` ("Needs Decision forced top → Blocked sinks").
    static func of(_ task: TaskItem, among tasks: [TaskItem]) -> TaskShape {
        guard !task.status.isResolved else { return .action }
        if task.needsDecision { return .deciding }
        if task.hasActiveBlockers(among: tasks) { return .waiting }
        if task.stepProgress(among: tasks) != nil { return .container }
        return .action
    }

    /// The same answer from a facts snapshot — used by anything that already holds
    /// facts, and the seam that keeps "shape ⊆ fingerprint" provable rather than
    /// asserted: `TaskShapeTests` pins that the two constructors always agree.
    static func of(_ facts: TaskAdvisorFacts) -> TaskShape {
        guard !facts.status.isResolved else { return .action }
        if facts.needsDecision { return .deciding }
        if !facts.blockerIDs.isEmpty || !facts.externalWaits.isEmpty { return .waiting }
        if facts.stepLabel != nil { return .container }
        return .action
    }
}
