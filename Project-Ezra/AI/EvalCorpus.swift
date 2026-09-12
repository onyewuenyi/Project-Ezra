//
//  EvalCorpus.swift
//  Project-Ezra
//
//  The hands-on evaluation corpus: `SampleFlowFixtures` plus everything a person
//  walking the product would otherwise never reach.
//
//  It ADDS rather than replaces, because the flow fixtures already cover a lot —
//  32 tasks, the roster, two dependency chains, three flagged decisions, seven
//  stale items, two external waits — and they own identity setup (the named "you"
//  member and `profile.linkedMemberID`). Forking them would have produced two
//  fixture files that drift, and the older one is always the one nobody notices
//  going stale.
//
//  What it adds is chosen by one rule: **a surface that cannot be reached at all,
//  not a surface that could use more rows.** The flow fixtures leave exactly one
//  completed task, zero captures, zero AI-initiated activity and zero corrections,
//  and those absences are why the resolution ledger, the Activity trust surface and
//  four of the five Required Attention dimensions render as "—" on a seeded store.
//  A dimension that reads "—" is not a low score, it is an unmeasurable one, and a
//  walkthrough cannot judge what never renders.
//
//  Two things it deliberately does NOT do:
//
//  • **No synthetic capture provenance.** The receipt sidecar records forward only,
//    on purpose, and faking one would put invented routing and latency numbers on
//    the one screen whose whole job is to say what actually happened. Seeded capture
//    rows show the honest "Not recorded" state; the recorded state comes from a real
//    ramble during the walkthrough.
//
//  • **No invented AI verbs.** Every `.ai` change-log entry here uses an action a
//    real writer in this app actually produces, with a payload its undo arm actually
//    decodes — `linked` (AppBrain), `mergedPair` (DuplicateSweep), `archived` and
//    `prunedCapture` (BrainSweeps). An entry whose Undo button does nothing teaches
//    the evaluator the opposite of what the surface is claiming.
//

import CoreData
import Foundation

enum EvalCorpus {

    /// Seed the flow fixtures, then everything the walkthrough needs on top.
    ///
    /// Order matters at both ends: the flow fixtures must run first (they create the
    /// household and the "you" member every task here is stamped with), and the
    /// attention rescore must run last (every edge has to exist before a score that
    /// reads graph centrality means anything).
    static func seed(into context: NSManagedObjectContext) {
        SampleFlowFixtures.seed(into: context)

        let now = Date()
        let day: TimeInterval = 24 * 3600
        let hour: TimeInterval = 3600

        let you = UserProfile.currentMemberID(in: context)
        let members = (try? context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))) ?? []
        let maya = members.first { $0.name == "Maya" }?.uuid

        // MARK: A container worth opening
        // The flow fixtures have exactly one `.parent` edge, so the container shape
        // renders a one-step spine and the step ORDER — the model's contribution,
        // persisted as `sortIndex` — is never exercised. Four steps with one done gives
        // the row its "1/4", the spine its progress header and next-step pointer, and
        // the "Add a step" row something to append after.
        let partyPlan = TaskItem(
            title: "Plan Nehemiah's birthday party", category: "Family", status: .todo,
            confidence: 0.85, reasoning: "A few moving parts — worth breaking down.",
            dueDate: now.addingTimeInterval(9 * day), ownerID: you, effortMinutes: 120,
            createdAt: now.addingTimeInterval(-4 * day), in: context)
        context.insert(partyPlan)
        let partySteps = partyPlan.splitInto(
            [
                BreakdownStep(title: "Pick a date and book the venue", effortMinutes: 60),
                BreakdownStep(title: "Send the invitations", effortMinutes: 30),
                BreakdownStep(title: "Order the cake", effortMinutes: 15),
                BreakdownStep(title: "Buy decorations and party favours", effortMinutes: 30),
            ], in: context, now: now.addingTimeInterval(-4 * day))
        // One step done, so progress is a fraction rather than an empty or full bar.
        partySteps.first?.complete(now: now.addingTimeInterval(-2 * day))
        // A dated step: step rows carry `DueLabel.compact` now, and every other step
        // being undated is what proves the label is conditional rather than decorative.
        if partySteps.count > 1 { partySteps[1].dueDate = now.addingTimeInterval(3 * day) }

        // MARK: The resolution ledger
        // The Done section caps inline at five and offers "Show all N" past that, and
        // the flow fixtures ship ONE completion — so the cap, the overflow row and the
        // status-filter flip behind it have never had data. Six-plus completions also
        // give the day answer its "done this week" and `rotRate` its denominator.
        let recentlyDone: [(String, String, TimeInterval, TimeInterval)] = [
            ("Send the rent payment", "Finance", -3 * day, -1 * day),
            ("Pick up the prescription", "Health", -4 * day, -2 * day),
            ("Reply to the school email", "Family", -5 * day, -3 * day),
            ("Take the recycling out", "Home", -6 * day, -5 * day),
            ("Book the annual physical", "Health", -20 * day, -12 * day),
        ]
        for (title, category, created, completed) in recentlyDone {
            let task = TaskItem(
                title: title, category: category, status: .todo, confidence: 0.9,
                reasoning: "Filed under \(category) from the wording.", ownerID: you,
                effortMinutes: 15, createdAt: now.addingTimeInterval(created), in: context)
            context.insert(task)
            task.complete(now: now.addingTimeInterval(completed))
        }
        // Rot: captured five weeks ago, finished nine days ago. `rotRate` counts work
        // that took longer than a week to close, and with no such row it reads "—" —
        // which looks like a clean score rather than an absent measurement.
        let shed = TaskItem(
            title: "Clear out the shed", category: "Home", status: .todo, confidence: 0.8,
            reasoning: "Filed under Home from the wording.", ownerID: you, effortMinutes: 120,
            createdAt: now.addingTimeInterval(-40 * day), in: context)
        context.insert(shed)
        shed.complete(now: now.addingTimeInterval(-9 * day))

        // MARK: Lifecycle captions
        // `TaskTimeline.caption` is nil for a `.todo` task and reads the CURRENT visit,
        // so it only says anything when a task changed state at a knowable moment. The
        // flow fixtures set `.doing` through the raw setter at `now`, which can only
        // ever produce "just now" — the caption's whole vocabulary goes unseen.
        let offsiteAgenda = TaskItem(
            title: "Draft the offsite agenda", category: "Work", status: .todo, confidence: 0.85,
            reasoning: "Filed under Work from the wording.",
            dueDate: now.addingTimeInterval(4 * day), ownerID: you, effortMinutes: 60,
            createdAt: now.addingTimeInterval(-6 * day), in: context)
        context.insert(offsiteAgenda)
        offsiteAgenda.transition(to: .doing, now: now.addingTimeInterval(-2 * hour))

        let rowingClub = TaskItem(
            title: "Look into the rowing club", category: "Personal", status: .todo,
            confidence: 0.7, reasoning: "Filed under Personal from the wording.",
            ownerID: you, createdAt: now.addingTimeInterval(-14 * day), in: context)
        context.insert(rowingClub)
        rowingClub.kill(now: now.addingTimeInterval(-3 * day))

        // MARK: Resume
        // A task picked up, put down, and still open. The CTA has to say "Resume"
        // rather than "Start" — its honest history — and no fixture has ever produced
        // a closed `.doing` visit for it to read.
        let performanceReview = TaskItem(
            title: "Write the performance review", category: "Work", status: .todo,
            confidence: 0.85, reasoning: "Filed under Work from the wording.",
            dueDate: now.addingTimeInterval(6 * day), ownerID: you, effortMinutes: 60,
            createdAt: now.addingTimeInterval(-9 * day), in: context)
        context.insert(performanceReview)
        performanceReview.transition(to: .doing, now: now.addingTimeInterval(-3 * day))
        performanceReview.transition(to: .todo, now: now.addingTimeInterval(-2 * day))

        // MARK: The due-date vocabulary, end to end
        // One vocabulary, two densities: the row says "3d over" where the detail chip
        // says "3 days overdue". Every arm needs a row or the two can drift again —
        // including the singular, which is the one a plural-only implementation misses.
        let parkingTicket = TaskItem(
            title: "Pay the parking ticket", category: "Admin", status: .todo, confidence: 0.9,
            reasoning: "Filed under Admin from the wording.",
            dueDate: now.addingTimeInterval(-1 * day), ownerID: you, effortMinutes: 10,
            createdAt: now.addingTimeInterval(-3 * day), in: context)
        let libraryBooks = TaskItem(
            title: "Return the library books", category: "Errands", status: .todo, confidence: 0.9,
            reasoning: "Filed under Errands from the wording.",
            dueDate: now.addingTimeInterval(-3 * day), ownerID: you, effortMinutes: 15,
            createdAt: now.addingTimeInterval(-5 * day), in: context)
        let plumberCallback = TaskItem(
            title: "Call the plumber back", category: "Home", status: .todo, confidence: 0.9,
            reasoning: "Filed under Home from the wording.", dueDate: now, ownerID: you,
            effortMinutes: 10, createdAt: now.addingTimeInterval(-1 * day), in: context)
        let gymMembership = TaskItem(
            title: "Renew the gym membership", category: "Personal", status: .todo,
            confidence: 0.85, reasoning: "Filed under Personal from the wording.",
            dueDate: now.addingTimeInterval(20 * day), ownerID: you, effortMinutes: 15,
            createdAt: now.addingTimeInterval(-2 * day), in: context)
        for task in [parkingTicket, libraryBooks, plumberCallback, gymMembership] {
            context.insert(task)
        }

        // MARK: Both kinds of wait on one task
        // A tracked blocker resolves itself when its target completes; an external wait
        // only a person can release. The waiting spine draws them differently — one taps
        // through, one cannot — and that difference is invisible until a single task
        // carries both at once.
        let payStubs = TaskItem(
            title: "Get the pay stubs from HR", category: "Work", status: .todo, confidence: 0.85,
            reasoning: "Filed under Work from the wording.", ownerID: you, effortMinutes: 15,
            createdAt: now.addingTimeInterval(-5 * day), in: context)
        context.insert(payStubs)
        let mortgage = TaskItem(
            title: "Submit the mortgage application", category: "Finance", status: .todo,
            confidence: 0.85, reasoning: "Waiting on paperwork from two directions.",
            dueDate: now.addingTimeInterval(11 * day), ownerID: you, effortMinutes: 60,
            createdAt: now.addingTimeInterval(-7 * day), in: context)
        context.insert(mortgage)
        mortgage.addTaskBlocker(payStubs.uuid!, among: [mortgage, payStubs])
        mortgage.addExternalBlocker("the bank to send the forms", among: [mortgage, payStubs])

        // MARK: The attention marker's one slot
        // Two signals, one column. Needs Decision has to win, and a resolved task has to
        // stop wearing the flag it was resolved with — both are single-line rules that
        // only fail visibly when something is carrying both states at once.
        let healthPlan = TaskItem(
            title: "Choose the health plan for next year", category: "Admin", status: .todo,
            confidence: 0.8, isJudgmentCall: true, needsDecision: true,
            reasoning: "A values call about cover versus cost — yours to make.",
            dueDate: now.addingTimeInterval(5 * day), isUrgent: true, ownerID: you,
            createdAt: now.addingTimeInterval(-6 * day), in: context)
        context.insert(healthPlan)
        let schoolDistrict = TaskItem(
            title: "Decide on the school district", category: "Family", status: .todo,
            confidence: 0.85, isJudgmentCall: true, needsDecision: true,
            reasoning: "A values call only you can make.", ownerID: you,
            createdAt: now.addingTimeInterval(-25 * day), in: context)
        context.insert(schoolDistrict)
        // Resolved with the flag still set: confirming a decision exists is not making
        // it, so `complete` deliberately leaves `needsDecision` alone.
        schoolDistrict.complete(now: now.addingTimeInterval(-6 * day))

        // MARK: One task per reason the Advisor speaks
        // The gate has a distinct arm for each of these, and a coverage table with zeroes
        // in it cannot tell "this reason never fires" from "no task has ever matched it".
        // The last one is the point of the set: a plain, small, fresh task the Advisor
        // should say NOTHING about. Silence is a judgment, and a walkthrough that only
        // shows the talking cases teaches the opposite.
        let carInsurance = TaskItem(
            title: "Should I switch the car insurance?", category: "Finance", status: .todo,
            confidence: 0.8, reasoning: "Reads like a question rather than a step.",
            ownerID: you, effortMinutes: 30, createdAt: now.addingTimeInterval(-11 * day),
            in: context)
        let homeOffice = TaskItem(
            title: "Redesign the home office", category: "Home", status: .todo, confidence: 0.8,
            reasoning: "A big one.", ownerID: you, effortMinutes: 120,
            createdAt: now.addingTimeInterval(-5 * day), in: context)
        // Effort stays UNDER the large-effort line on purpose: `BreakdownEligibility`
        // checks size before shape, so a big compound task is reported as merely big and
        // the compound arm never fires. Small-but-compound is the only way to see it.
        let garageAndBikes = TaskItem(
            title: "Clear the garage and then list the bikes", category: "Home", status: .todo,
            confidence: 0.75, reasoning: "Sounds like more than one thing.", ownerID: you,
            effortMinutes: 30, createdAt: now.addingTimeInterval(-3 * day), in: context)
        let summerHoliday = TaskItem(
            title: "Plan the summer holiday", category: "Travel", status: .todo, confidence: 0.8,
            reasoning: "Filed under Travel from the wording.", ownerID: you, effortMinutes: 30,
            createdAt: now.addingTimeInterval(-4 * day), in: context)
        let will = TaskItem(
            title: "Update the will", category: "Admin", status: .todo, confidence: 0.8,
            reasoning: "Filed under Admin from the wording.", ownerID: you, effortMinutes: 30,
            createdAt: now.addingTimeInterval(-12 * day), in: context)
        let stamps = TaskItem(
            title: "Buy stamps", category: "Errands", status: .todo, confidence: 0.95,
            reasoning: "Filed under Errands from the wording.", ownerID: you, effortMinutes: 10,
            createdAt: now, in: context)
        for task in [carInsurance, homeOffice, garageAndBikes, summerHoliday, will, stamps] {
            context.insert(task)
        }
        summerHoliday.workIntent = .planning
        will.workIntent = .action
        stamps.workIntent = .action
        // Put off four days running: the stall signal is consecutive deferrals, and the
        // count is the evidence that the obvious advice has already failed here.
        will.deferralCount = 4

        // MARK: A duplicate the sweep already folded
        // `mergedPair` is the one entry with no home but Activity — the winner absorbed
        // a note line and the loser was killed rather than deleted, so Undo can restore
        // it intact. Kill-don't-delete is only demonstrable if something was killed.
        let airFilter = TaskItem(
            title: "Replace the air filter", category: "Home", status: .todo, confidence: 0.85,
            reasoning: "Filed under Home from the wording.", ownerID: you, effortMinutes: 15,
            createdAt: now.addingTimeInterval(-8 * day), in: context)
        context.insert(airFilter)
        let hvacFilter = TaskItem(
            title: "Change the HVAC filter", category: "Home", status: .todo, confidence: 0.8,
            reasoning: "The same job, captured twice.", ownerID: you, effortMinutes: 15,
            createdAt: now.addingTimeInterval(-7 * day), in: context)
        context.insert(hvacFilter)
        let absorbedLine = "Also captured: \(hvacFilter.title)"
        airFilter.notes = absorbedLine
        hvacFilter.kill(now: now.addingTimeInterval(-6 * day))

        // MARK: An AI-proposed parent link
        // Capture proposes edges, and a proposal is only trustworthy if it is reversible.
        // Kept away from the party plan on purpose: undoing a parent link orphans the
        // child, which reads as damage on a container the walkthrough is also using.
        let quarterlyTaxes = TaskItem(
            title: "File the quarterly taxes", category: "Finance", status: .todo,
            confidence: 0.85, reasoning: "Filed under Finance from the wording.",
            dueDate: now.addingTimeInterval(14 * day), ownerID: you, effortMinutes: 120,
            createdAt: now.addingTimeInterval(-6 * day), in: context)
        context.insert(quarterlyTaxes)
        let receipts = TaskItem(
            title: "Collect the receipts", category: "Finance", status: .todo, confidence: 0.8,
            reasoning: "Reads like part of the tax filing.", ownerID: you, effortMinutes: 30,
            createdAt: now.addingTimeInterval(-6 * day), in: context)
        context.insert(receipts)
        receipts.linkParent(quarterlyTaxes.uuid!, origin: .inferred(confidence: 0.72))

        // MARK: Captures
        // The flow fixtures create none at all, so the unfinished-capture row, the
        // capture rows in Activity and the honest "Not recorded" provenance state are
        // all unreachable. Two parked captures at DIFFERENT ages, because the row now
        // states how old a capture is and one row cannot show that the number varies.
        let parkedFresh = Capture(
            rawText: "need to call the vet about mochi's checkup and also order more of her food",
            source: .voice, createdAt: now.addingTimeInterval(-3 * hour), in: context)
        parkedFresh.parkedDrafts = []
        context.insert(parkedFresh)
        let parkedOld = Capture(
            rawText:
                "grab the dry cleaning tickets and figure out the wedding gift situation before saturday",
            source: .text, createdAt: now.addingTimeInterval(-4 * day), in: context)
        parkedOld.parkedDrafts = []
        context.insert(parkedOld)

        let committedCapture = Capture(
            rawText: "pay the parking ticket and return the library books",
            source: .voice, parsedTaskIDs: [parkingTicket.uuid, libraryBooks.uuid].compactMap { $0 },
            committedAt: now.addingTimeInterval(-3 * day),
            createdAt: now.addingTimeInterval(-3 * day), in: context)
        context.insert(committedCapture)
        let prunedCapture = Capture(
            rawText: "look into that thing with the warranty",
            source: .text, committedAt: now.addingTimeInterval(-30 * day),
            createdAt: now.addingTimeInterval(-30 * day), in: context)
        context.insert(prunedCapture)

        // MARK: Activity — the AI's own trail
        // Every entry here is `.ai`, reversible, and uses an action a real writer in this
        // app produces with a payload its undo arm decodes. Until now every seeded entry
        // was `.human`, so "AI handled N" counted nothing and the kept-rate read "—" —
        // the trust surface had no trust to demonstrate.
        let aiEntries: [ChangeLogEntry] = [
            // AppBrain, resolving a spoken dependency at capture.
            ChangeLogEntry(
                summary: "“\(mortgage.title)” now waits on “\(payStubs.title)”",
                detail: "The capture said the application needs the stubs first.",
                action: "linked", fieldChanged: "blockers", newValue: payStubs.uuid?.uuidString,
                initiatedBy: .ai, isReversible: true, taskTitle: mortgage.title,
                taskUUID: mortgage.uuid, timestamp: now.addingTimeInterval(-7 * day), in: context),
            // AppBrain, accepting a child proposal.
            ChangeLogEntry(
                summary: "“\(receipts.title)” is now a step of “\(quarterlyTaxes.title)”",
                detail: "Read as part of the same job.",
                action: "linked", fieldChanged: "parent", newValue: quarterlyTaxes.uuid?.uuidString,
                initiatedBy: .ai, isReversible: true, taskTitle: receipts.title,
                taskUUID: receipts.uuid, timestamp: now.addingTimeInterval(-6 * day), in: context),
            // DuplicateSweep, folding two existing tasks.
            ChangeLogEntry(
                summary:
                    "Merged “\(hvacFilter.title)” into “\(airFilter.title)” — they read as the same task",
                detail: "Kept the older one and folded the newer capture into it.",
                action: "mergedPair",
                oldValue: MergedPairPayload(loserID: hvacFilter.uuid, noteLine: absorbedLine).encoded,
                initiatedBy: .ai, isReversible: true, taskTitle: airFilter.title,
                taskUUID: airFilter.uuid, timestamp: now.addingTimeInterval(-6 * day), in: context),
            // BrainSweeps, letting go of a capture nobody came back to.
            ChangeLogEntry(
                summary: "Let go of a capture from 30 days ago",
                detail: prunedCapture.rawText, action: "prunedCapture", fieldChanged: "capture",
                oldValue: prunedCapture.uuid?.uuidString, initiatedBy: .ai, isReversible: true,
                timestamp: now.addingTimeInterval(-2 * day), in: context),
        ]
        for entry in aiEntries { context.insert(entry) }

        // BrainSweeps archiving a long-dead task — and the one the user disagreed with,
        // so the kept rate is a real fraction. A rate that can only ever read 100% is
        // not a measurement, and this is exactly the number the Advisor's honesty rests on.
        let phonePlan = TaskItem(
            title: "Sort out the old phone plan", category: "Admin", status: .todo,
            confidence: 0.7, reasoning: "Filed under Admin from the wording.", ownerID: you,
            createdAt: now.addingTimeInterval(-75 * day), in: context)
        context.insert(phonePlan)
        phonePlan.kill(now: now.addingTimeInterval(-5 * day))
        let archived = ChangeLogEntry(
            summary: "Archived “\(phonePlan.title)” — untouched for 70 days",
            action: "archived", initiatedBy: .ai, isReversible: true,
            taskTitle: phonePlan.title, taskUUID: phonePlan.uuid,
            timestamp: now.addingTimeInterval(-5 * day), in: context)
        context.insert(archived)

        let rejected = ChangeLogEntry(
            summary: "Archived “\(will.title)” — untouched for 12 days",
            action: "archived", initiatedBy: .ai, isReversible: true,
            taskTitle: will.title, taskUUID: will.uuid,
            timestamp: now.addingTimeInterval(-1 * day), in: context)
        rejected.undone = true
        context.insert(rejected)

        // The capture's own receipt. Provenance is deliberately absent — see the header.
        context.insert(
            ChangeLogEntry(
                summary: "Captured 2 things", detail: committedCapture.rawText,
                action: ChangeLogEntry.capturedAction, oldValue: committedCapture.uuid?.uuidString,
                initiatedBy: .ai, isReversible: false,
                timestamp: now.addingTimeInterval(-3 * day), in: context))

        // MARK: Hand edits
        // Three on one task, so its Details row states a count worth reading. These stay
        // out of the Activity feed by design (a trail of your own typing is noise); they
        // are the maintenance numerator, and the detail page's own timeline.
        let edits: [(String, String?, String?, String)] = [
            ("title", "Draft offsite agenda", offsiteAgenda.title, "Renamed"),
            ("dueDate", nil, "set", "Set a due date"),
            ("effortMinutes", "30", "60", "Changed the estimate"),
        ]
        for (index, edit) in edits.enumerated() {
            context.insert(
                ChangeLogEntry(
                    summary: "\(edit.3) on “\(offsiteAgenda.title)”",
                    action: ChangeLogEntry.editedAction, fieldChanged: edit.0,
                    oldValue: edit.1, newValue: edit.2, initiatedBy: .human, isReversible: true,
                    taskTitle: offsiteAgenda.title, taskUUID: offsiteAgenda.uuid, actorID: you,
                    timestamp: now.addingTimeInterval(-Double(index + 1) * hour), in: context))
        }

        // MARK: Corrections
        // The write-only learning signal, and the numerator of capture effort. Two land
        // on the same keyword so the twice-then-a-rule threshold is actually crossed —
        // one correction is an accident, two is a preference, and a corpus that never
        // reaches two can't show that anything was learned.
        let corrections: [(TaskItem, String, String, String)] = [
            (parkingTicket, "title", "Parking ticket", "Pay the parking ticket"),
            (libraryBooks, "dueDate", "none", "3 days ago"),
            (gymMembership, "category", "Personal", "Health"),
            (homeOffice, "category", "Admin", "Home"),
            (healthPlan, "urgent", "false", "true"),
            (mortgage, "effort", "30", "60"),
        ]
        for (index, correction) in corrections.enumerated() {
            context.insert(
                Correction(
                    taskUUID: correction.0.uuid, fieldCorrected: correction.1,
                    aiValue: correction.2, userValue: correction.3,
                    createdAt: now.addingTimeInterval(-Double(index + 1) * day), in: context))
        }

        // A second gym-shaped correction, so `category → Health` crosses the threshold
        // on a keyword rather than on a single task.
        let gymClasses = TaskItem(
            title: "Book the gym induction", category: "Health", status: .todo, confidence: 0.8,
            reasoning: "Filed under Health from the wording.", ownerID: you, effortMinutes: 30,
            createdAt: now.addingTimeInterval(-2 * day), in: context)
        context.insert(gymClasses)
        context.insert(
            Correction(
                taskUUID: gymClasses.uuid, fieldCorrected: "category", aiValue: "Personal",
                userValue: "Health", createdAt: now.addingTimeInterval(-2 * day), in: context))

        // A second person's completion inside the week, so the day answer's "done this
        // week" is a household fact rather than a solo one.
        if let maya {
            let mayaDone = TaskItem(
                title: "Renew the parking permit", category: "Admin", status: .todo,
                creatorID: maya, confidence: 0.85, reasoning: "Filed under Admin from the wording.",
                ownerID: maya, effortMinutes: 20, createdAt: now.addingTimeInterval(-6 * day),
                in: context)
            context.insert(mayaDone)
            mayaDone.complete(now: now.addingTimeInterval(-2 * day))
        }

        // MARK: The pass that has to run last
        // `confirmedAt` is the one field a hand-built task can never have: it is stamped
        // at the Confirm boundary, and nothing here went through one. Without it the
        // capture-effort dimension divides by zero and reports "—" on a store holding
        // fifty tasks and seven corrections — an unmeasurable reading dressed as a clean
        // one. Authorship and work intent follow the flow fixtures' own backfill, and the
        // rescore runs after every edge exists, because the score reads graph centrality.
        let scored = TaskItem.fetchAll(in: context)
        for task in scored {
            if task.confirmedAt == nil { task.confirmedAt = task.createdAt }
            if task.creatorID == nil { task.creatorID = you }
            if task.workIntent == nil {
                let title = task.title.lowercased()
                let planning = [
                    "decide", "choose", "figure out", "worth it", "plan", "schedule",
                    "follow up", "reorganize", "prepare", "should i",
                ]
                task.workIntent = planning.contains(where: { title.contains($0) }) ? .planning : .action
            }
        }
        AttentionEngine.recompute(scored, among: scored, now: now)

        context.saveChanges()
    }
}
