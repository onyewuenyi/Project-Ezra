//
//  AdvisorCoverage.swift
//  Project-Ezra
//
//  What fraction of a real task list does the Advisor actually speak on, and WHY is it
//  silent on the rest?
//
//  Nothing measured this before. The gate was written as a whitelist of seven signals
//  and shipped on the reasoning that those seven are the cases worth a model call — a
//  reasonable argument that nobody could check, because the product had no way to see
//  its own coverage. This is that readout, built BEFORE the boundary moves, on the
//  codebase's own precedent for the capture deadline: tuned on evidence, never argument.
//
//  **Coverage is a diagnostic, never a target.** The exclusion is defined semantically —
//  "a small, clear, single-verb errand the Advisor demonstrably cannot improve" — and
//  the percentage is whatever that rule turns out to produce on a real household. A
//  number outside expectations is a prompt to go and look at which reason is
//  responsible, never a reason to loosen or tighten the rule until the number is
//  comfortable. Optimizing this figure would convert a product decision into a
//  number-hitting exercise.
//
//  Pure and synchronous: no model, no Core Data mutation, no I/O. `measure` is O(n²)
//  because `advisorGateReason` scans the task set per task (blocker and child edges) —
//  single-digit milliseconds at family scale. Above roughly 2000 open tasks, precompute
//  an id→task map and hand it down rather than making this incremental.
//

import Foundation

enum AdvisorCoverage {

    /// One sweep's findings. `byReason` carries every case — including zeroes — so a
    /// table renders a stable set of rows and a reason that stops occurring is visible
    /// as a zero rather than as a missing line.
    struct Report: Equatable {
        var total: Int
        var worthy: Int
        var byReason: [AdvisorGateReason: Int]

        var silent: Int { total - worthy }
        /// Nil rather than zero for an empty store: "no tasks" and "0% coverage" are
        /// different facts, and a diagnostic that conflates them lies on first launch.
        var worthyShare: Double? {
            total > 0 ? Double(worthy) / Double(total) : nil
        }

        func count(_ reason: AdvisorGateReason) -> Int { byReason[reason] ?? 0 }

        /// The one-line form, for the Settings diagnostics footer.
        /// `advisor coverage: 41/58 worthy (71%) · plain 14 · decomposed 3`
        var line: String {
            guard total > 0 else { return "advisor coverage: no tasks" }
            let pct = Int((worthyShare ?? 0) * 100 + 0.5)
            var out = "advisor coverage: \(worthy)/\(total) worthy (\(pct)%)"
            for reason in [AdvisorGateReason.plain, .decomposed, .resolved] where count(reason) > 0 {
                out += " · \(reason.rawValue) \(count(reason))"
            }
            return out
        }

        /// The full per-reason breakdown, for `-AdvisorCoverage` on stdout. Silent
        /// reasons are grouped first because they are what the inversion is about.
        var table: String {
            var lines = ["ADVISOR COVERAGE", "  total \(total) · worthy \(worthy) · silent \(silent)"]
            if let share = worthyShare {
                lines.append("  worthy share: \(Int(share * 100 + 0.5))%")
            }
            lines.append("  — silent —")
            for reason in AdvisorGateReason.allCases where !reason.isWorthy {
                lines.append("    \(pad(reason.rawValue)) \(count(reason))")
            }
            lines.append("  — worthy —")
            for reason in AdvisorGateReason.allCases where reason.isWorthy {
                lines.append("    \(pad(reason.rawValue)) \(count(reason))")
            }
            return lines.joined(separator: "\n")
        }

        private func pad(_ s: String) -> String {
            s.padding(toLength: max(16, s.count), withPad: " ", startingAt: 0)
        }
    }

    /// How many of the worthy tasks rung 0 can actually speak to, with no model.
    ///
    /// **This is the number the deterministic floor exists for, and it is deliberately
    /// separate from `measure`.** The gate answers "is this worth a judgment?"; this
    /// answers "and if no model ever arrives, does the surface still say something?"
    /// They were silently different for a long time: the fallback rendered
    /// `StallDiagnosis.headline`, which only exists for the `.stalled` rung, while the
    /// gate opens for nine reasons. On a fixture set with `stalled: 0` that meant every
    /// worthy task drew the ADVISOR kicker over an empty box.
    ///
    /// Kept out of `Report` because `measure` also backs the Settings footer, and the
    /// footer should not pay for a `TaskAdvisorFacts.make` per task.
    ///
    /// A shortfall is not automatically a bug — a `.doing` task with no steps has
    /// nothing factual to add, and silence is the honest answer there. It is a number to
    /// look at when it moves.
    ///
    /// "Speaks" means the page states the fact SOMEWHERE with no model: the shape's
    /// spine (a waiting page names its blockers, a container its steps, a deciding
    /// page its obligation), the diagnosed-stall template, or the rung-0 floor.
    /// Counting only the floor would have reported the spine-suppression rule ("the
    /// floor never restates the spine") as a coverage regression, when it moved the
    /// same fact to a better surface.
    static func floorCoverage(
        _ tasks: [TaskItem], now: Date = Date()
    ) -> (
        covered: Int, worthy: Int
    ) {
        var covered = 0
        var worthy = 0
        for task in tasks
        where TaskCapabilities.advisorGateReason(for: task, among: tasks, now: now).isWorthy {
            worthy += 1
            let facts = TaskAdvisorFacts.make(task: task, among: tasks, now: now)
            // A diagnosed stall is covered by the richer template; a non-action shape
            // is covered by its spine. Both count even though `make` returns nil.
            if facts.diagnosis != nil || TaskShape.of(facts) != .action
                || DeterministicReading.make(from: facts) != nil
            {
                covered += 1
            }
        }
        return (covered, worthy)
    }

    /// Sweep a task set. Pass the whole set — `advisorGateReason` needs it to resolve
    /// blocker and child edges, so a filtered array would silently change the verdicts.
    static func measure(_ tasks: [TaskItem], now: Date = Date()) -> Report {
        var byReason: [AdvisorGateReason: Int] = [:]
        for reason in AdvisorGateReason.allCases { byReason[reason] = 0 }

        var worthy = 0
        for task in tasks {
            let reason = TaskCapabilities.advisorGateReason(for: task, among: tasks, now: now)
            byReason[reason, default: 0] += 1
            if reason.isWorthy { worthy += 1 }
        }
        return Report(total: tasks.count, worthy: worthy, byReason: byReason)
    }
}
