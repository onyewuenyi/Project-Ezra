//
//  TaskCapabilities.swift
//  Project-Ezra
//
//  Which help does this task need?
//
//  A capability is NOT "the module for this work type". Each one exists to reduce a
//  specific kind of cognitive load, and the type only biases which one is offered:
//
//    Complexity   → Break this down   → "I have smaller executable work."
//    Uncertainty  → Thinking Partner  → "I have clarity."
//    Inertia      → Unstick           → "I'm moving again."
//
//  That framing decides a real question. Because the breakdown reduces COMPLEXITY, its
//  trigger is complexity (`BreakdownEligibility`) — not `workIntent == .planning`, which
//  would offer it to a 15-minute "plan birthday dinner" and withhold it from a genuinely
//  multi-step "renew passport".
//
//  Keeping the triggers here rather than inline in the view is what lets the detail
//  render whatever this returns without knowing why.
//

import Foundation

/// A capability the detail page can surface for a task.
enum Capability: Hashable {
    /// Reduces uncertainty. Frames a choice; never makes it.
    case thinkingPartner
    /// Reduces complexity. Proposes steps; never splits on its own.
    case breakDown(BreakdownEligibility.Reason)
    /// Reduces inertia. Diagnoses WHY a task is stalled and routes to the capability
    /// that addresses it — the one capability that is never absent off-device, because
    /// its trigger and its diagnosis are both deterministic.
    case unstick(StallDiagnosis)
}

enum TaskCapabilities {

    /// The Advisor's deterministic pre-gate: should this task's page spend a model call?
    ///
    /// **A cost heuristic, never a semantic verdict.** Every task HAS an Advisor; a task
    /// this gate filters out gets a judgment of deterministic silence (`.quiet(.gate)`)
    /// for zero model cost — it is NOT "this task isn't worthy of intelligence", and
    /// this list must not calcify (the `CaptureRoute` precedent: "simple inputs never
    /// use AI" is policy, not architecture). The model keeps its own `nothing` past the
    /// gate — two independent silence mechanisms, both first-class judgments.
    static func advisorWorthy(
        for task: TaskItem, among tasks: [TaskItem] = [], now: Date = Date()
    ) -> Bool {
        guard !task.status.isResolved else { return false }
        if task.needsDecision { return true }
        if DecisionShape.reads(title: task.title) { return true }
        if BreakdownEligibility.evaluate(task, among: tasks) != nil { return true }
        if StallDetector.diagnose(task, among: tasks, now: now) != nil { return true }
        if task.hasActiveBlockers(among: tasks) { return true }
        if task.status == .doing { return true }
        if let due = task.dueDate, let days = TaskItem.daysUntil(due, now: now), days < 0 {
            return true
        }
        return false
    }

    /// Everything this task should be offered, in render order.
    ///
    /// - **Thinking Partner** when it is a genuine choice: it carries the open
    ///   `needsDecision` flag, OR its wording reads as a choice (`DecisionShape`).
    ///   These are independent — the wording never reads or writes the flag; this OR
    ///   is composition, not conversion. (Decision was a work-intent case until
    ///   2026-08-08; choosing is a capability the system brings, not a kind of work
    ///   the user classifies.)
    /// - **Break this down** when it is genuinely complex — see `BreakdownEligibility`.
    ///
    /// A task can qualify for both (a big decision is still a big task), and that is
    /// fine: they answer different questions.
    ///
    /// - **Unstick** when it has demonstrably stalled — see `StallDetector`.
    ///
    /// - Parameters:
    ///   - tasks: the working set, for the has-children and blocked checks.
    ///   - now: injected so the staleness half of the stall trigger is testable.
    ///   - partnerCardVisible: whether the Thinking Partner card will actually be
    ///     DRAWN (the flag path, or wording + a model to frame with). The render
    ///     layer owns that answer; passing it here keeps the one-intervention-per-
    ///     problem rule pure — Unstick's choice rung folds through when the partner
    ///     is already saying the same thing.
    static func available(
        for task: TaskItem, among tasks: [TaskItem] = [], now: Date = Date(),
        partnerCardVisible: Bool = false
    ) -> [Capability] {
        // Nothing is offered on a settled task. The other two triggers guard this
        // themselves, but the decision arm cannot: `workIntent` is axis 2 and survives
        // resolution by design (a decision you made was still a decision), so without
        // this a completed "Should we move to Lisbon?" would still offer to frame the
        // choice — and spend a model call doing it.
        guard !task.status.isResolved else { return [] }

        var capabilities: [Capability] = []
        // Choice-ness is the flag OR the wording — never the type (Decision retired
        // from axis 2). The two stay independent: the flag is an obligation only
        // `resolveDecision()` discharges; the wording is a lexical observation.
        if task.needsDecision || DecisionShape.reads(title: task.title) {
            capabilities.append(.thinkingPartner)
        }
        let diagnosis = StallDetector.diagnose(
            task, among: tasks, now: now, suppressChoiceRung: partnerCardVisible)

        // A big task that is ALSO stalled gets one card, not two. Unstick subsumes the
        // breakdown here and routes into it, because the useful thing to say is *why*
        // it hasn't moved — a bare "break this down" card sitting above a "this keeps
        // sliding" card that says "break it into steps" is the same advice twice.
        //
        //   big + healthy  → breakDown        (offered proactively)
        //   big + stalled  → unstick(.tooBig) (explains first, then routes)
        if case .tooBig = diagnosis {
        } else if let reason = BreakdownEligibility.evaluate(task, among: tasks) {
            capabilities.append(.breakDown(reason))
        }
        if let diagnosis { capabilities.append(.unstick(diagnosis)) }
        return capabilities
    }
}
