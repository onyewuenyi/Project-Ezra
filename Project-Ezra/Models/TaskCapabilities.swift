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
    /// Everything this task should be offered, in render order.
    ///
    /// - **Thinking Partner** when it is a genuine choice: the model classified
    ///   `workIntent` as `.decision`, OR it carries the open `needsDecision` flag. These
    ///   are independent — an intent never reads or writes the flag; this OR is
    ///   composition, not conversion.
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
    static func available(
        for task: TaskItem, among tasks: [TaskItem] = [], now: Date = Date()
    ) -> [Capability] {
        // Nothing is offered on a settled task. The other two triggers guard this
        // themselves, but the decision arm cannot: `workIntent` is axis 2 and survives
        // resolution by design (a decision you made was still a decision), so without
        // this a completed "Should we move to Lisbon?" would still offer to frame the
        // choice — and spend a model call doing it.
        guard !task.status.isResolved else { return [] }

        var capabilities: [Capability] = []
        if task.workIntent == .decision || task.needsDecision { capabilities.append(.thinkingPartner) }
        let diagnosis = StallDetector.diagnose(task, among: tasks, now: now)

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
