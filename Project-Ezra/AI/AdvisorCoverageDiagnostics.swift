//
//  AdvisorCoverageDiagnostics.swift
//  Project-Ezra
//
//  `-AdvisorCoverage` — print what fraction of the user's REAL tasks the Advisor speaks
//  on, and why it is silent on the rest.
//
//  **It reads the live store, not `PersistenceStack.scratch`.** That is the whole point
//  and the one thing not to change: `AdvisorDiagnostics` runs hand-built fixtures because
//  it is measuring the model's judgment, where a controlled input is exactly right.
//  Coverage is the opposite question — *what does this rule do to a real household?* —
//  and fixtures answer it by construction, since we chose them. A coverage number over
//  invented tasks would measure our own imagination.
//
//  Readable headlessly over the cable, which is what makes it usable on the device where
//  the only meaningful task list lives:
//
//      xcrun devicectl device process launch --device <udid> --console \
//        --terminate-existing amanze-studios.Project-Ezra -- -AdvisorCoverage
//
//  Deliberately non-destructive and side-effect free: it fetches, counts and prints.
//  Safe to re-run as often as the boundary moves.
//

#if DEBUG

import CoreData
import Foundation

enum AdvisorCoverageDiagnostics {

    @MainActor
    static func runIfRequested(in context: NSManagedObjectContext) {
        guard ProcessInfo.processInfo.arguments.contains("-AdvisorCoverage") else { return }

        let request = NSFetchRequest<TaskItem>(entityName: "TaskItem")
        guard let tasks = try? context.fetch(request) else {
            print("=== ADVISOR COVERAGE ===\n  (fetch failed)")
            return
        }

        let started = Date()
        let report = AdvisorCoverage.measure(tasks)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        print("=== ADVISOR COVERAGE ===")
        print(report.table)
        print("  swept in \(ms)ms")
        // The floor, printed next to the gate it answers for: of the tasks the gate
        // judged worthy, how many does rung 0 speak to with no model at all?
        let floor = AdvisorCoverage.floorCoverage(tasks)
        if floor.worthy > 0 {
            let pct = Int(Double(floor.covered) / Double(floor.worthy) * 100 + 0.5)
            print("  rung-0 floor: \(floor.covered)/\(floor.worthy) worthy tasks speak (\(pct)%)")
        }
        // Restated so the number that goes in a commit message can be copied from one
        // line rather than reassembled from the table.
        print("  " + report.line)

        // The two lines that otherwise live only on the Settings diagnostics card. They
        // are the BASELINE the gate inversion gets judged against, and a baseline you
        // have to read off a screenshot is one that gets transcribed slightly wrong.
        // Printing them here makes capturing it a single headless command, and makes the
        // after-measurement literally comparable to the before.
        print("  — baseline —")
        print("  " + (AdvisorMetrics.shared.footerLine ?? "advisor: (no outcomes recorded yet)"))
        print(
            "  "
                + (AdvisorMetrics.shared.progressionLine(among: tasks)
                    ?? "moved: (no acted events yet)"))
    }
}

#endif
