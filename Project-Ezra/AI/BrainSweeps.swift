//
//  BrainSweeps.swift
//  Project-Ezra
//
//  The ongoing-maintenance pass: what the AI is allowed to do to tasks that
//  already exist, on its own, silently. Today that is exactly one thing — the
//  stale auto-archive: an undated task untouched past the long rot threshold is
//  killed, reversibly, with a change-log entry the user can undo from the trail.
//
//  Deliberately narrow. Overdue/Stale/Blocking are derived on read (no bit-flip
//  jobs needed), and anything with judgment attached is untouchable: the
//  judgment-category rule means the AI never resolves a values call, and killing
//  IS resolving. Silent-tier rules only.
//

import Foundation
import CoreData

enum BrainSweeps {

    /// One sweep's outcome, for logging/testing.
    struct Result {
        var archived: [TaskItem] = []
    }

    /// Run the maintenance pass. Pure with respect to time — callers inject `now`
    /// so tests are exact. Callers own `save()` cadence via the context.
    @discardableResult
    @MainActor
    static func run(in context: NSManagedObjectContext, now: Date = Date()) -> Result {
        var result = Result()
        let all = (try? context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? []

        // Stale auto-archive: undated, untouched past the archive threshold, and
        // carrying no judgment or open decision (those are a human's to resolve,
        // never silently killable). Reversible via the trail, always.
        for task in all
        where !task.status.isResolved
            && !task.isJudgmentCall
            && !task.needsDecision
            && task.isStale(now: now, threshold: StalePolicy.archiveThreshold)
        {
            let idleDays = Int(now.timeIntervalSince(task.updatedAt) / 86_400)
            task.kill(now: now)
            context.insert(
                ChangeLogEntry(
                    summary: "Archived “\(task.title)” — untouched for \(idleDays) days",
                    detail: "Undo brings it back to your Inbox for another look.",
                    action: "archived",
                    initiatedBy: .ai,
                    isReversible: true,
                    taskTitle: task.title,
                    taskUUID: task.uuid,
                    timestamp: now, in: context
                ))
            result.archived.append(task)
        }

        if !result.archived.isEmpty { try? context.save() }
        return result
    }
}

extension AppBrain {
    /// Debounced trigger for the maintenance sweep — called on every foreground.
    /// Hourly is plenty: staleness moves on a scale of days.
    func runMaintenanceSweepsIfDue(
        in context: NSManagedObjectContext, now: Date = Date(), defaults: UserDefaults = .standard
    ) {
        let key = "brainSweeps.lastRunAt"
        if let last = defaults.object(forKey: key) as? Date, now.timeIntervalSince(last) < 3600 {
            return
        }
        defaults.set(now, forKey: key)
        BrainSweeps.run(in: context, now: now)
    }
}
