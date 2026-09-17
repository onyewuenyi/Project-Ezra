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
//  IS resolving. Silent-tier rules only — with ONE named exception that lives
//  OUTSIDE this pass: `DuplicateSweep` (its own file) merges existing near-
//  duplicate pairs at the capture-time destructive tier (model ≥0.85), reversibly
//  and Inbox-logged, per the 2026-08-07 product decision — it shares only this
//  file's hourly debounce, never its silent tier.
//

import Foundation
import CoreData

enum BrainSweeps {

    /// One sweep's outcome, for logging/testing.
    struct Result {
        var archived: [TaskItem] = []
        var prunedCaptures: [Capture] = []
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
        //
        for task in all
        where !task.status.isResolved
            && !task.isJudgmentCall
            && !task.needsDecision
            && task.isStale(now: now, threshold: StalePolicy.archiveThreshold)
        {
            // Read the SAME clock the stale trigger did (`humanTouchedAt`, via `isStale`),
            // not `updatedAt` — otherwise a task archived right after a system edge-write
            // reads "untouched for 0 days" while it was genuinely idle for weeks.
            let idleDays = Int(now.timeIntervalSince(task.humanTouchedAt) / 86_400)
            task.kill(now: now)
            context.insert(
                ChangeLogEntry(
                    summary: "Archived “\(task.title)” — untouched for \(idleDays) days",
                    detail: "Undo brings it back to your list for another look.",
                    action: "archived",
                    initiatedBy: .ai,
                    isReversible: true,
                    taskTitle: task.title,
                    taskUUID: task.uuid,
                    timestamp: now, in: context
                ))
            result.archived.append(task)
        }

        // Parked captures decay like everything else. The "N captures waiting" line is
        // the one surface with no resolution path other than reopening the composer, so
        // left alone it only ever grows — and a product where everything else decays
        // should not have one permanent nag.
        //
        // **The prune is logged and reversible, never silent.** A silent prune would
        // reintroduce the exact failure this whole feature exists to prevent — park a
        // thought, come back later, it has vanished — just on a longer clock. Nothing
        // else lists past captures, so `rawText` surviving in a row nothing renders is
        // the letter of the promise, not the spirit. Undo re-parks it.
        for capture in AppBrain.parkedCaptures(in: context)
        where now.timeIntervalSince(capture.createdAt) > StalePolicy.archiveThreshold {
            let idleDays = Int(now.timeIntervalSince(capture.createdAt) / 86_400)
            capture.parkedDrafts = nil  // the derived half; `rawText` is kept forever
            context.insert(
                ChangeLogEntry(
                    summary: "Let go of a capture from \(idleDays) days ago",
                    detail: "“\(capture.rawText.prefix(60))” — the raw text is kept.",
                    action: "prunedCapture",
                    fieldChanged: "capture",
                    // The capture id rides in `oldValue`, the same way the "merged" arm
                    // carries its snapshot — this entry points at a Capture, not a task,
                    // so `taskUUID` stays nil and the undo arm resolves it from here.
                    oldValue: capture.uuid?.uuidString,
                    initiatedBy: .ai,
                    isReversible: true,
                    timestamp: now, in: context
                ))
            result.prunedCaptures.append(capture)
        }

        if !result.archived.isEmpty || !result.prunedCaptures.isEmpty { context.saveChanges() }
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
        // The activation reading rides the same hourly debounce: derived over the working
        // set, and the ONE bit that leaves (`householdActivated`) fires the first time it
        // flips and never again (`HouseholdActivation.recordIfNewlyActivated`).
        if let household = Household.existing(in: context) {
            let entries =
                (try? context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))) ?? []
            let reading = HouseholdActivation.measure(
                household: household, tasks: TaskItem.fetchAll(in: context), entries: entries, now: now)
            HouseholdActivation.recordIfNewlyActivated(reading, defaults: defaults)
        }
        // The destructive-tier exception rides the same debounce but never the
        // foreground: model judgments run behind a background deadline, hard-capped
        // per run, and the whole pass is absent off-device.
        Task { await DuplicateSweep.run(in: context, now: now) }
        // The grouping sweep proposes, never writes: its output is a row that asks.
        Task { await GroupingSweep.run(in: context, now: now) }
    }
}
