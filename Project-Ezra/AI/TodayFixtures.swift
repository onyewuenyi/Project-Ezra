//
//  TodayFixtures.swift
//  Project-Ezra
//
//  Deterministic seed data for the Today cinematic sequence (Recap → Docket →
//  Capacity → Plan). Where `SampleFlowFixtures` predates the redirect and only
//  lights up the Docket, this set exercises every beat and the personalization /
//  routing paths behind them, by constructing `TaskItem` / `CapacityLog` directly
//  rather than going through triage. Launch with `-SeedTodayFixtures`.
//
//  What each block exercises:
//  - Recap: several tasks completed inside the 24h window (+ one older, to prove the
//    window boundary excludes it — never an empty celebration, never a stale one).
//  - Docket: due-today, multi-day overdue (with the material edge cue), and both
//    kinds of Needs Decision (judgment call + low confidence).
//  - Chain routing: a blocked-AND-blocking dependency chain, so
//    `TodayQueries.hasBlockedBlockingChain` fires and PlanRouting can prefer PCC.
//  - Personalization: CapacityLog history so `CapacityBaseline` is personalized for
//    Steady (~4, on-track), divergent for Full (~3 vs default 6 → the one-shot PCC
//    escalation), and cold-start for Light (< 5 samples → the static default).
//  - Attention substrate: an Urgent-signal task (leading `SignalMarker` on My Tasks +
//    its boost in the stack), plus a per-task `WorkIntent` spread.
//  - Decision Framing: a choice-worded task that is NOT a needsDecision judgment
//    call, so the detail shows the lighter Thinking Partner card ("A decision to make").
//  - Capture Graph Awareness (persisted results of the confirm-card decisions): a parent
//    task with `.parent` child sub-steps, a rejected duplicate ("Keeping both" —
//    suppression records), and a merged capture (provenance note + a reversible "merged" Inbox entry
//    whose Undo resurrects the folded draft).
//

import CoreData
import Foundation

enum TodayFixtures {
    /// Wipe the task-related store + the Today day-cache so `-SeedTodayFixtures` can
    /// force a fresh, repeatable seed on every launch (device iteration), without
    /// requiring the app to be deleted first. Identity (Household / FamilyMember /
    /// UserProfile) is preserved — `seed` re-bootstraps it idempotently.
    static func reset(in context: NSManagedObjectContext) {
        // The third destructive path, and the easiest to fire by accident: leaving
        // `-SeedTodayFixtures` ticked in the scheme wipes real captured work on the next
        // ⌘R. Take the same safety copy the schema reset takes. Best-effort by design —
        // this copies a store that is currently open, and a dev seam must never be able
        // to fail the seed it precedes.
        _ = PersistenceStack.backupStore()
        for entity in [
            "TaskItem", "CapacityLog", "Capture", "ChangeLogEntry", "Correction",
            "SuppressionRecord", "EmbeddingCache",
        ] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            (try? context.fetch(request))?.forEach(context.delete)
        }
        context.saveChanges()
        // The Today plan cache + recap cutoff live in UserDefaults, keyed by day — clear
        // them so a stale resting plan can't reference wiped tasks.
        let defaults = UserDefaults.standard
        for key in ["today.planCache", "today.recapCutoff"] { defaults.removeObject(forKey: key) }
        for capacity in Capacity.allCases {
            defaults.removeObject(forKey: "today.baselineEscalated.\(capacity.rawValue)")
        }
    }

    static func seed(into context: NSManagedObjectContext) {
        let now = Date()
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        let cal = Calendar.current

        // The current user, so the seeded work reads as "mine" on Tasks / Household.
        _ = UserProfile.bootstrapIdentity(in: context)
        let me = UserProfile.currentMemberID(in: context)

        // MARK: Recap — completed inside (and just outside) the 24h window
        func completed(_ title: String, _ category: String, agoHours: Double) {
            let task = TaskItem(
                title: title, category: category, status: .todo, confidence: 0.9,
                reasoning: "", ownerID: me,
                createdAt: now.addingTimeInterval(-2 * day), in: context)
            task.complete(now: now.addingTimeInterval(-agoHours * hour))
        }
        completed("Send the standup notes", "Work", agoHours: 0.5)
        completed("Reply to the landlord", "Home", agoHours: 1)
        completed("Pay the electric bill", "Finance", agoHours: 2)
        completed("Book the dentist", "Health", agoHours: 4)
        completed("Drop off the dry cleaning", "Errands", agoHours: 8)
        // Older than 24h → intentionally excluded from the Recap window.
        completed("File the quarterly taxes", "Finance", agoHours: 30)

        // MARK: Docket — due today
        let expenseReport = TaskItem(
            title: "Submit the expense report", category: "Work", status: .todo, confidence: 0.9,
            reasoning: "Filed under Work.", dueDate: now, ownerID: me,
            effortMinutes: 30, createdAt: now.addingTimeInterval(-day), in: context)
        _ = TaskItem(
            title: "Call the pharmacy about the refill", category: "Health", status: .todo,
            confidence: 0.9, reasoning: "Filed under Health.", dueDate: now, ownerID: me, effortMinutes: 10,
            createdAt: now.addingTimeInterval(-day), in: context)

        // MARK: Docket — overdue (drives the warm material edge cue)
        _ = TaskItem(
            title: "Renew the car insurance", category: "Car", status: .todo, confidence: 0.9,
            reasoning: "Filed under Car.", dueDate: now.addingTimeInterval(-2 * day),
            isUrgent: true, ownerID: me, effortMinutes: 20,
            createdAt: now.addingTimeInterval(-6 * day), in: context)
        let amazonReturn = TaskItem(
            title: "Return the Amazon package", category: "Errands", status: .todo,
            confidence: 0.9, reasoning: "Filed under Errands.",
            dueDate: now.addingTimeInterval(-5 * day), ownerID: me,
            effortMinutes: 15, createdAt: now.addingTimeInterval(-8 * day), in: context)

        // MARK: Docket — Needs Decision (judgment call + low confidence)
        _ = TaskItem(
            title: "Decide whether to keep the gym membership", category: "Finance",
            status: .todo, confidence: 0.9, isJudgmentCall: true, needsDecision: true,
            reasoning: "A personal judgment call — yours to make.", ownerID: me,
            createdAt: now.addingTimeInterval(-3 * day), in: context)
        _ = TaskItem(
            title: "Sort out the invoice discrepancy", category: "Work", status: .todo,
            confidence: 0.35, needsDecision: true,
            reasoning: "Not enough detail to file confidently.", ownerID: me,
            createdAt: now.addingTimeInterval(-2 * day), in: context)

        // MARK: Chain — a blocked-AND-blocking middle (chain routing signal)
        let photos = TaskItem(
            title: "Get passport photos", category: "Travel", status: .todo, confidence: 0.9,
            reasoning: "Filed under Travel.", ownerID: me, effortMinutes: 20,
            createdAt: now.addingTimeInterval(-3 * day), in: context)
        let passport = TaskItem(
            title: "Renew the passport", category: "Travel", status: .todo, confidence: 0.9,
            reasoning: "Filed under Travel.", blockedBy: [photos.uuid!], ownerID: me, effortMinutes: 45,
            createdAt: now.addingTimeInterval(-3 * day),
            in: context)
        let flights = TaskItem(
            title: "Book the flights for the trip", category: "Travel", status: .todo,
            confidence: 0.9, reasoning: "Filed under Travel.", blockedBy: [passport.uuid!],
            ownerID: me, effortMinutes: 30,
            createdAt: now.addingTimeInterval(-3 * day), in: context)

        // MARK: General working set (fuller plan + a Tasks tab worth browsing)
        _ = TaskItem(
            title: "Draft the Q3 deck", category: "Work", status: .todo, confidence: 0.85,
            reasoning: "Filed under Work.", dueDate: now.addingTimeInterval(2 * day),
            ownerID: me, effortMinutes: 90,
            createdAt: now.addingTimeInterval(-day), in: context)
        _ = TaskItem(
            title: "Water the plants", category: "Home", status: .todo, confidence: 0.9,
            reasoning: "Filed under Home.", ownerID: me, effortMinutes: 5,
            createdAt: now.addingTimeInterval(-day), in: context)
        _ = TaskItem(
            title: "Schedule the team offsite", category: "Work", status: .todo, confidence: 0.8,
            reasoning: "Filed under Work.", ownerID: me, effortMinutes: 60,
            createdAt: now.addingTimeInterval(-4 * day), in: context)
        _ = TaskItem(
            title: "Prep for the trip", category: "Travel", status: .todo, confidence: 0.8,
            reasoning: "Filed under Travel.", dueDate: now.addingTimeInterval(3 * day),
            ownerID: me, effortMinutes: 120,
            createdAt: now.addingTimeInterval(-day), in: context)
        // External wait — blocked on the world, not a task.
        let analytics = TaskItem(
            title: "Wire up the analytics events", category: "Work", status: .todo,
            confidence: 0.85, reasoning: "Filed under Work.", ownerID: me,
            effortMinutes: 45, createdAt: now.addingTimeInterval(-2 * day), in: context)
        analytics.addExternalBlocker("the API keys from IT", among: [])
        // A plain quick win — position comes from the computed attention score.
        _ = TaskItem(
            title: "Call the accountant back", category: "Finance", status: .todo,
            confidence: 0.9, reasoning: "Filed under Finance.", ownerID: me,
            effortMinutes: 15, createdAt: now.addingTimeInterval(-day), in: context)

        // MARK: Decision Framing — an intent-only decision (the lighter Thinking Partner card)
        // A genuine choice that is NOT a needsDecision judgment call: choice-shaped wording
        // alone unlocks the Thinking Partner (the "A decision to make" card, no "Mark decided").
        let apartmentDecision = TaskItem(
            title: "Choose between the two apartment offers", category: "Personal", status: .todo,
            confidence: 0.9, reasoning: "Weighing the commute against the rent.", ownerID: me,
            effortMinutes: 30, createdAt: now.addingTimeInterval(-2 * day), in: context)
        apartmentDecision.workIntent = .planning

        // MARK: Capture Graph — a parent task with child sub-steps (`.parent` edges)
        // "Plan the Italy trip" is the umbrella; the three Travel tasks above become its
        // steps (they ALSO form the dependency chain among themselves — an edge is not a
        // status). Exercises `parentTaskID`, the child-link result, and the framing context.
        let italyPlan = TaskItem(
            title: "Plan the Italy trip", category: "Travel", status: .todo, confidence: 0.85,
            reasoning: "The umbrella task the trip steps hang off.", ownerID: me,
            effortMinutes: 60, createdAt: now.addingTimeInterval(-3 * day), in: context)
        for step in [photos, passport, flights] { step.linkParent(italyPlan.uuid!) }

        // MARK: Capture Graph — a rejected duplicate ("Keeping both")
        // The persisted result of the user rejecting a duplicate proposal: pair-owned
        // suppression records (never an edge) that stop the pairing being re-proposed
        // on the next similar capture.
        let bestBuyReturn = TaskItem(
            title: "Return the Best Buy package", category: "Errands", status: .todo,
            confidence: 0.9, reasoning: "A separate return — kept apart from the Amazon one.",
            ownerID: me, effortMinutes: 15, createdAt: now.addingTimeInterval(-2 * day), in: context)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: bestBuyReturn.title, createdID: bestBuyReturn.uuid,
            targetID: amazonReturn.uuid!, in: context)

        // MARK: Capture Graph — a merged capture (the accepted-duplicate result)
        // A later capture of the same task folded INTO the expense report: the target keeps
        // the capture provenance, and a reversible `.human` "merged" entry shows in Activity
        // feed (Undo resurrects the folded draft as a real task).
        expenseReport.notes = "Also captured: Send in the expense report"
        let mergedDraft = TaskDraft(
            title: "Send in the expense report", category: "Work",
            confidence: 0.9, autonomy: .silent, isJudgmentCall: false,
            reasoning: "Same as the expense report already on the list.")
        context.insert(
            ChangeLogEntry(
                summary: "Merged “Send in the expense report” into “\(expenseReport.title)”",
                detail: "Same as an existing task — folded in rather than duplicated.",
                action: "merged", oldValue: MergedTaskSnapshot(draft: mergedDraft).encoded,
                initiatedBy: .human, isReversible: true,
                taskTitle: expenseReport.title, taskUUID: expenseReport.uuid, actorID: me,
                timestamp: now.addingTimeInterval(-2 * hour), in: context))

        // MARK: CapacityLog history — personalization & routing substrate
        func logDays(_ capacity: Capacity, completions: [Int], startOffset: Int) {
            for (index, completed) in completions.enumerated() {
                let date = cal.startOfDay(
                    for: now.addingTimeInterval(-Double(startOffset + index) * day))
                _ = CapacityLog(
                    date: date, capacity: capacity, planCount: completed + 1,
                    completedCount: completed, skippedCount: 1, in: context)
            }
        }
        // Steady: 8 days averaging ~4 → personalized, on-track (not divergent).
        logDays(.steady, completions: [4, 4, 3, 5, 4, 4, 3, 5], startOffset: 1)
        // Full: 6 days averaging ~3 vs default 6 → divergent → one-shot PCC escalation.
        logDays(.full, completions: [3, 3, 2, 4, 3, 3], startOffset: 9)
        // Light: 3 days → below the 5-sample floor → cold-starts to the static default.
        logDays(.light, completions: [2, 1, 2], startOffset: 15)

        // Authorship and a WorkIntent spread so My Tasks + the detail read correctly
        // (fixtures bypass the model's classification, so stamp a plausible intent per
        // task — decision/planning/action; the on-device classifier would refine it
        // later on a real device).
        let all = TaskItem.fetchAll(in: context)
        for task in all {
            if task.creatorID == nil { task.creatorID = me }
            if task.workIntent == nil {
                let title = task.title.lowercased()
                if title.contains("decide") || title.contains("choose") || title.contains("whether") {
                    task.workIntent = .planning
                } else if ["plan", "draft", "schedule", "prep", "sort out"].contains(where: {
                    title.contains($0)
                }) {
                    task.workIntent = .planning
                } else {
                    task.workIntent = .action
                }
            }
        }
        photos.status = .doing

        // A CONTAINER — a task already broken into steps, one of them done — so the
        // detail's container spine (progress header, next-step pointer, tappable
        // rows) is reachable from `-SeedTodayFixtures` without a tap. `splitInto` is
        // the real seam, so the fixture exercises the same edges production writes.
        let review = TaskItem(
            title: "Vendor contract review", category: "Work", status: .todo,
            confidence: 0.9, reasoning: "Broken into steps on capture.", ownerID: me,
            effortMinutes: 90, createdAt: now.addingTimeInterval(-3 * 86_400), in: context)
        review.creatorID = me
        let steps = review.splitInto(
            [
                BreakdownStep(title: "Collect the revised terms", effortMinutes: 15),
                BreakdownStep(title: "Compare pricing against last year", effortMinutes: 30),
                BreakdownStep(title: "Send the signed copy back", effortMinutes: 15),
            ], in: context)
        steps.first?.complete(now: now.addingTimeInterval(-86_400))

        // Score every seeded task so the stack ranks by real attention (fixtures build
        // TaskItems directly, bypassing the commit-time stamp).
        AttentionEngine.recompute(all, among: all, now: now)

        context.saveChanges()
    }
}
