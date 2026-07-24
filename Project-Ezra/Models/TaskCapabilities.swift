//
//  TaskCapabilities.swift
//  Project-Ezra
//
//  A tiny mapping from a task to the AI capabilities its detail page can offer. The
//  detail view renders whatever this returns, so new capabilities (break-down,
//  follow-up, summarize) slot in later WITHOUT touching the view's structure — V1 ships
//  exactly one, the Thinking Partner. Keeping the trigger here (not inline in the view)
//  is what makes that extension a one-line change.
//

import Foundation

/// A capability the detail page can surface for a task. Only `.thinkingPartner` exists in
/// V1; the others are placeholders for the shape, not shipped.
enum Capability {
    case thinkingPartner
}

enum TaskCapabilities {
    /// The Thinking Partner is offered when the task is a genuine choice — either the model
    /// classified its `workIntent` as `.decision`, or it carries the open `needsDecision`
    /// flag. (These are independent: an intent never reads or writes the flag.)
    static func available(for task: TaskItem) -> [Capability] {
        var capabilities: [Capability] = []
        let isDecision = task.workIntent == .decision || (task.needsDecision && !task.status.isResolved)
        if isDecision { capabilities.append(.thinkingPartner) }
        return capabilities
    }
}
