//
//  BreakdownStep.swift
//  Project-Ezra
//
//  One proposed step of a task decomposition — the value `splitInto` consumes and the
//  Advisor's createSteps move renders. A plain value on purpose: the model-facing
//  schema (`AdvisorStep`) is untrusted transport, and `ValidatedReading` maps it into
//  this type after sanitizing, so nothing downstream ever touches raw model output.
//
//  (Formerly a `@Generable` defined beside `TaskBreakdownService`; the Advisor pivot
//  moved it here because the mutation seam and its tests outlive any one generator.)
//

import Foundation

struct BreakdownStep: Sendable, Equatable, Hashable {
    let title: String
    let effortMinutes: Int
}

extension BreakdownStep {

    /// How many steps a breakdown may propose. The cap is a product guardrail, not a
    /// model limit: a fifteen-step plan is a new source of overwhelm, which is the exact
    /// thing the capability exists to remove.
    static let maxSteps = 5

    /// The effort vocabulary the engines and the effort chip already speak.
    static let effortBands = [15, 30, 60, 120]

    /// Anti-hallucination + guardrail pass, the same shape as the Today plan's
    /// `validated(against:)`: drop empties, de-duplicate, clamp effort to the bands the
    /// rest of the app speaks, and cap the count. It does NOT reorder — sequence is the
    /// model's contribution.
    static func sanitized(_ steps: [BreakdownStep]) -> [BreakdownStep] {
        var seen = Set<String>()
        var out: [BreakdownStep] = []
        for step in steps {
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 2 else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(BreakdownStep(title: title, effortMinutes: clampEffort(step.effortMinutes)))
            if out.count == maxSteps { break }
        }
        // One step is not a breakdown — it is the task restated.
        return out.count >= 2 ? out : []
    }

    /// Snap to the bands, so a step never shows an estimate the rest of the app
    /// can't render.
    static func clampEffort(_ minutes: Int) -> Int {
        effortBands.min { abs($0 - minutes) < abs($1 - minutes) } ?? 30
    }
}
