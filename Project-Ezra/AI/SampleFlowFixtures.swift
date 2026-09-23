//
//  SampleFlowFixtures.swift
//  Project-Ezra
//
//  Deterministic fixture data covering every core user flow except onboarding —
//  and, since the walkthrough doc was retired with the status vocabulary it
//  described, the readable record of what those flows are. Unlike `-SeedSampleData`
//  (which runs real text
//  through the live triage engine, so results depend on which engine is active),
//  this constructs TaskItem/ChangeLogEntry directly so status, confidence, and
//  autonomy are exact and identical on every run.
//

import Foundation
import CoreData
import UIKit

enum SampleFlowFixtures {
    /// Populates the Today Recap, Needs Decision, stale/rotting work, and
    /// Dependency Chain Resurfacing data in one call. Capture is exercised live
    /// (type into the Composer) rather than seeded. Onboarding is bypassed by
    /// the caller, not seeded here.
    static func seed(into context: NSManagedObjectContext) {
        let now = Date()
        let day: TimeInterval = 24 * 3600

        // MARK: Flow 1 — Daily Brief
        // The advisor selects and orders the day's actions from the candidate set;
        // TaskRanking provides the cap. Four confirmed .todo tasks here means at
        // least one is always held back, so the footnote has something to report.
        let dryCleaning = TaskItem(
            title: "Pick up dry cleaning", category: "Errands", status: .todo, confidence: 0.9,
            reasoning: "Filed under Errands from the wording.",
            dueDate: now.addingTimeInterval(1 * day), createdAt: now, in: context)
        let expenseReport = TaskItem(
            title: "Submit expense report", category: "Work", status: .todo, confidence: 0.85,
            reasoning: "Filed under Work from the wording.",
            dueDate: now.addingTimeInterval(2 * day), createdAt: now, in: context)
        let registration = TaskItem(
            title: "Renew car registration", category: "Car", status: .todo, confidence: 0.82,
            reasoning: "Filed under Car from the wording.",
            dueDate: now.addingTimeInterval(5 * day), createdAt: now, in: context)
        // All tasks are born confirmed at the single Confirm-Creation boundary.
        // Confidence 0.7 is recorded for quality review; it no longer routes to a
        // separate lane. Rank beats a sooner due date when urgent.
        let birthdayGift = TaskItem(
            title: "Buy birthday gift for Sam", category: "Personal", status: .todo,
            confidence: 0.7,
            reasoning: "Medium confidence — worth a quick confirm before filing.",
            dueDate: now.addingTimeInterval(3 * day), createdAt: now, in: context)
        let waterPlants = TaskItem(
            title: "Water the plants", category: "Home", status: .todo, confidence: 0.9,
            reasoning: "Filed under Home from the wording.", createdAt: now, in: context)

        for task in [dryCleaning, expenseReport, registration, waterPlants] {
            context.insert(task)
            logSilentFiling(task, into: context)
        }
        context.insert(birthdayGift)

        // MARK: Flow 8 — Metadata (owner / priority / effort)
        // Overdue + urgent tops the daily brief (focusOrder puts overdue first);
        // the delegated task never enters Today (not the user's to act on) but
        // shows its owner chip in Runs. Neither logs a trail entry, so the doc's
        // "AI handled 7" footnote stays exact.
        let waterBill = TaskItem(
            title: "Pay the water bill", category: "Finance", status: .todo, confidence: 0.9,
            reasoning: "Filed under Finance; the wording said urgent.",
            dueDate: now.addingTimeInterval(-1 * day), isUrgent: true, effortMinutes: 15,
            createdAt: now, in: context)
        // The household identity layer: you (Charles), the family, and the shared
        // household record everything else will eventually hang off of. Photos are
        // generated stand-ins (see `samplePhotoData(for:)`), so every avatar exercises
        // the real photo path rather than the initials fallback.
        let profile = UserProfile(
            displayName: "Charles Onyewuenyi", photoData: samplePhotoData(for: "Charles"), in: context)
        context.insert(profile)
        let household = Household(
            name: "The Onyewuenyis",
            photoData: samplePhotoData(for: "Onyewuenyi household", glyph: "person.3.fill"), in: context)
        context.insert(household)
        let settings = HouseholdSettings(planningStyle: .balanced, in: context)
        settings.household = household
        context.insert(settings)

        // ADULT, not owner (2026-09-18). A household has ONE owner — the person whose
        // profile minted it (`UserProfile`) — and the partner is an adult caretaker.
        // As a second owner Maya could never be invited (`canInvite` excludes owners),
        // so the fixture set that exists to cover the core flows could not reach the
        // launch's headline one: sharing the household with a second phone. The
        // caretaker count is unchanged — `HouseholdActivation.caretakerIDs` counts
        // owner AND adult — so the digest default and the activation metrics are too.
        let maya = FamilyMember(
            name: "Maya", photoData: samplePhotoData(for: "Maya"), relationship: .partner,
            role: .adult, in: context)
        let ezra = FamilyMember(
            name: "Ezra", photoData: samplePhotoData(for: "Ezra"), relationship: .child, role: .child,
            in: context)
        let nehemiah = FamilyMember(
            name: "Nehemiah", photoData: samplePhotoData(for: "Nehemiah"), relationship: .child,
            role: .child, in: context)
        for member in [maya, ezra, nehemiah] {
            member.household = household
            context.insert(member)
        }
        // The current user is a real household member too (explicit-ownership model):
        // create Charles's "you" member, link the private profile to it, and every
        // unowned/non-pending task below gets stamped with this id at the end — so
        // "your" work reads as yours (ownerID == you), never as shared.
        let you = FamilyMember(
            name: "Charles", photoData: samplePhotoData(for: "Charles"), role: .owner, in: context)
        you.household = household
        context.insert(you)
        profile.linkedMemberID = you.uuid

        let offsiteVenue = TaskItem(
            title: "Book venue for the offsite", category: "Work", status: .todo, confidence: 0.85,
            reasoning: "Sounds like Maya's to handle — kept off your Today.",
            ownerID: maya.uuid, effortMinutes: 30, createdAt: now, in: context)
        context.insert(waterBill)
        context.insert(offsiteVenue)

        // MARK: Flow 3 — Needs Decision Resolution
        // Two distinct reasons a task carries the needsDecision flag: a judgment call
        // (isJudgmentCall: true, always deferred regardless of confidence) and plain
        // low confidence (< 0.5, not a judgment call).
        let judgmentCall = TaskItem(
            title: "Figure out if the side project is still worth it", category: "Personal",
            status: .todo, confidence: 0.85, isJudgmentCall: true, needsDecision: true,
            reasoning: "This is a personal judgment call, so it's yours to make.", createdAt: now, in: context
        )
        let lowConfidence = TaskItem(
            title: "Deal with the thing from last week", category: "Admin", status: .todo,
            confidence: 0.3, needsDecision: true,
            reasoning: "Not enough detail to categorize confidently.",
            createdAt: now, in: context)
        context.insert(judgmentCall)
        context.insert(lowConfidence)

        // MARK: Flow 5 — Stale / rotting work
        // Anything `isStale()` (not done, createdAt older than the 7-day default
        // threshold) or long-overdue now surfaces through the Docket and the
        // day-rollover reconciliation rather than a retro. State doesn't matter for
        // staleness, so this mixes Active, Blocked, and Needs Decision items on
        // purpose, spanning just-past-threshold (8d) to long-buried (60d), plus one
        // item permanently blocked on an external wait. None of these call
        // logSilentFiling: the Today "AI handled N items" held-depth footnote is
        // scoped to Flow 1 + Flow 7 only, and stays exact regardless of how much
        // stale data exists.
        let staleSubscription = TaskItem(
            title: "Cancel unused streaming subscription", category: "Finance",
            status: .todo, confidence: 0.9, isJudgmentCall: true, needsDecision: true,
            reasoning: "This is a personal judgment call, so it's yours to make.",
            createdAt: now.addingTimeInterval(-21 * day), in: context)
        let staleFaucet = TaskItem(
            title: "Fix the leaky faucet", category: "Home", status: .todo, confidence: 0.8,
            reasoning: "Filed under Home from the wording.",
            createdAt: now.addingTimeInterval(-15 * day), in: context)
        let staleClient = TaskItem(
            title: "Follow up with old client", category: "Work", status: .todo,
            confidence: 0.35, needsDecision: true,
            reasoning: "Not enough detail to categorize confidently.",
            createdAt: now.addingTimeInterval(-10 * day), in: context)
        let staleDonate = TaskItem(
            title: "Donate old clothes", category: "Home", status: .todo, confidence: 0.75,
            reasoning: "Medium confidence — worth a quick confirm before filing.",
            createdAt: now.addingTimeInterval(-30 * day), in: context)
        // Ancient: still just a normal Active item, but old enough to show
        // genuinely long-buried rot, not just fresh-past-threshold cases.
        let staleGarage = TaskItem(
            title: "Reorganize the garage", category: "Home", status: .todo, confidence: 0.65,
            reasoning: "Medium confidence — worth a quick confirm before filing.",
            createdAt: now.addingTimeInterval(-60 * day), in: context)
        // Permanently stuck on an *external* blocker — it waits on the contractor
        // calling back, which isn't a tracked task, so nothing auto-resurfaces it and
        // Review is the only path forward. Its workflow stays Ready; the external
        // blocker just makes it *read* as Blocked (blocked is an assessment, not a
        // lane, and can never be set directly).
        let staleContractorQuote = TaskItem(
            title: "Get a quote from the contractor", category: "Home", status: .todo,
            confidence: 0.6,
            reasoning: "Waiting on the contractor to call back.",
            createdAt: now.addingTimeInterval(-18 * day), in: context)
        staleContractorQuote.addExternalBlocker(
            "the contractor to call back", among: [staleContractorQuote])
        // Boundary case: 8 days old, just past the 7-day staleness threshold, to
        // check the cutoff renders correctly rather than only testing comfortably-
        // stale items.
        let staleDentist = TaskItem(
            title: "Schedule the dentist", category: "Health", status: .todo, confidence: 0.8,
            reasoning: "Filed under Health from the wording.",
            createdAt: now.addingTimeInterval(-8 * day), in: context)
        for task in [
            staleSubscription, staleFaucet, staleClient, staleDonate,
            staleGarage, staleContractorQuote, staleDentist,
        ] {
            context.insert(task)
        }

        // MARK: Flow 7 — Dependency Chain Resurfacing (real references)
        // A 3-link chain by real uuid reference: completing "Renew passport" auto-
        // unblocks "Book flights…"; completing that auto-unblocks "Request time off".
        // Plus a two-blocker task ("Apply for visa") waiting on BOTH passport and
        // flights, to prove a task stays blocked until *all* its blockers clear.
        let passport = TaskItem(
            title: "Renew passport", category: "Travel", status: .todo, confidence: 0.9,
            reasoning: "Filed under Travel from the wording.", createdAt: now, in: context)
        let flights = TaskItem(
            title: "Book flights for the trip", category: "Travel", status: .todo, confidence: 0.8,
            reasoning: "Looks like it depends on something else finishing first.",
            blockedBy: [passport.uuid].compactMap { $0 }, createdAt: now, in: context)
        let timeOff = TaskItem(
            title: "Request time off work", category: "Work", status: .todo, confidence: 0.8,
            reasoning: "Looks like it depends on something else finishing first.",
            blockedBy: [flights.uuid].compactMap { $0 }, createdAt: now, in: context)
        for task in [passport, flights, timeOff] {
            context.insert(task)
            logSilentFiling(task, into: context)
        }
        // Waits on two things at once; no trail entry so the "AI handled 7" count holds.
        let visa = TaskItem(
            title: "Apply for travel visa", category: "Travel", status: .todo, confidence: 0.8,
            reasoning: "Needs both the passport and booked flights first.",
            blockedBy: [passport.uuid, flights.uuid].compactMap { $0 }, createdAt: now, in: context)
        context.insert(visa)

        // A second, independent 2-task chain, deliberately in different categories
        // and vocabulary from the Travel chain above — now that grouping is a real
        // graph, not text, two chains can never merge on wording alone, but distinct
        // vocabulary keeps the fixture readable too. Proves the Tasks screen renders
        // two separate stacks, not one. No trail entries, so "AI handled 7" holds.
        let movers = TaskItem(
            title: "Schedule the movers", category: "Home", status: .todo, confidence: 0.85,
            reasoning: "Filed under Home from the wording.", createdAt: now, in: context)
        let mailingAddress = TaskItem(
            title: "Change our mailing address", category: "Admin", status: .todo, confidence: 0.8,
            reasoning: "Looks like it depends on something else finishing first.",
            blockedBy: [movers.uuid].compactMap { $0 }, createdAt: now, in: context)
        context.insert(movers)
        context.insert(mailingAddress)

        // MARK: Flow 8b — The rest of the family carry their own tasks
        // Every member owns something, so the owner filter has real people (plus "Me")
        // to switch between and each delegated card shows a distinct photo. No trail
        // entries, same reason as Maya's task above.
        let reunionCaterer = TaskItem(
            title: "Confirm caterer for the reunion", category: "Family", status: .todo, confidence: 0.85,
            reasoning: "Sounds like Ezra's to handle — kept off your Today.",
            ownerID: ezra.uuid, effortMinutes: 30, createdAt: now, in: context)
        context.insert(reunionCaterer)
        let soccerKit = TaskItem(
            title: "Pack the soccer kit", category: "Family", status: .todo, confidence: 0.85,
            reasoning: "Sounds like Nehemiah's to handle — kept off your Today.",
            ownerID: nehemiah.uuid, effortMinutes: 10, createdAt: now, in: context)
        context.insert(soccerKit)
        // Give Maya a heavier, flagged plate so the Household surface exercises the
        // per-member overdue/blocked flags (offsite venue above + these two). No
        // trail entries — delegated work, like the member tasks above — so the
        // "AI handled 7" count on Now is untouched.
        let mayaOverdue = TaskItem(
            title: "Renew the car insurance", category: "Finance", status: .todo, confidence: 0.85,
            reasoning: "Sounds like Maya's to handle — kept off your Today.",
            dueDate: now.addingTimeInterval(-2 * day), ownerID: maya.uuid,
            effortMinutes: 20, createdAt: now, in: context)
        let mayaBlocked = TaskItem(
            title: "Schedule the kitchen remodel", category: "Home", status: .todo, confidence: 0.8,
            reasoning: "Sounds like Maya's to handle — kept off your Today.",
            ownerID: maya.uuid, effortMinutes: 30, createdAt: now, in: context)
        mayaBlocked.addExternalBlocker("the plumber to confirm", among: [mayaBlocked])
        context.insert(mayaOverdue)
        context.insert(mayaBlocked)

        // MARK: Flow 9 — Status/flag signals (Up for Grabs / blocked-while-active)
        // "Up for Grabs" is a flag, not a status: this task is live, and a nil owner
        // makes it read as unowned (a "That.s mine" action on its card). Every task is
        // now born owned, so this state is only reachable by a deliberate human
        // hand-back — which is exactly what this fixture stands in for.
        let upForGrabsTask = TaskItem(
            title: "Plan the weekend trip", category: "Travel", status: .todo,
            confidence: 0.8,
            reasoning: "Filed under Travel from the wording.", createdAt: now, in: context
        )
        context.insert(upForGrabsTask)
        // Regression guard for the status/flag split: an Active task that gains a
        // blocker STAYS Active (it just reads as blocked) and returns to normal when
        // the blocker clears — blocked is an observation, never a status.
        let startedButBlocked = TaskItem(
            title: "Wire up the analytics events", category: "Work", status: .todo,
            confidence: 0.85, reasoning: "Started, then hit a dependency.", createdAt: now, in: context)
        startedButBlocked.addExternalBlocker("the API keys from IT", among: [startedButBlocked])
        context.insert(startedButBlocked)

        // Explicit ownership: every task not delegated to a member and not deliberately
        // handed back to the household is the current user’s own — stamp it with the you-member id,
        // exactly as `AppBrain.commit` does for a real capture. Without this, the retired
        // `nil == you` sentinel is gone and "your" tasks would read as shared/unassigned.
        let allTasks = (try? context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? []
        for task in allTasks where task.ownerID == nil && task !== upForGrabsTask {
            task.ownerID = you.uuid
        }

        // Authorship (My Tasks "Created" tab): you created almost everything.
        for task in allTasks { task.creatorID = you.uuid }
        // Demo Created ≠ Assigned: a task you own but Maya created (shows in your
        // Assigned, not your Created).
        waterPlants.creatorID = maya.uuid
        // The offsite is yours-created but Maya-owned (shows in Created, not Assigned) —
        // creatorID already `you` from the loop; ownerID is Maya. Nothing more to do.

        // A lifecycle spread so the Assigned sections aren.t all Todo. Written through
        // the raw status setter (not `setStatus`) so no fixture writes a change-log entry.
        waterBill.status = .doing
        expenseReport.status = .doing

        // Human activity for the Activity feed: a completion by Maya, an assignment, and a
        // decision — each a reversible `.human` change-log entry carrying an `actorID`.
        let mayaChore = TaskItem(
            title: "Drop the kids at practice", category: "Family", status: .todo,
            creatorID: maya.uuid, confidence: 0.9, ownerID: maya.uuid,
            createdAt: now.addingTimeInterval(-2 * day), in: context)
        context.insert(mayaChore)
        mayaChore.complete(now: now.addingTimeInterval(-3 * 3600))
        context.insert(
            ChangeLogEntry(
                summary: "Completed “\(mayaChore.title)”", action: "completed", initiatedBy: .human,
                isReversible: true, taskTitle: mayaChore.title, taskUUID: mayaChore.uuid,
                actorID: maya.uuid, timestamp: now.addingTimeInterval(-3 * 3600), in: context))
        context.insert(
            ChangeLogEntry(
                summary: "Reassigned “\(offsiteVenue.title)”", action: "assigned",
                fieldChanged: "ownerID", oldValue: you.uuid.uuidString, newValue: maya.uuid.uuidString,
                initiatedBy: .human, isReversible: true, taskTitle: offsiteVenue.title,
                taskUUID: offsiteVenue.uuid, actorID: you.uuid,
                timestamp: now.addingTimeInterval(-5 * 3600), in: context))
        context.insert(
            ChangeLogEntry(
                summary: "Decided “\(judgmentCall.title)”", action: "decided", initiatedBy: .human,
                isReversible: true, taskTitle: judgmentCall.title, taskUUID: judgmentCall.uuid,
                actorID: you.uuid, timestamp: now.addingTimeInterval(-6 * 3600), in: context))

        // MARK: New primitives — Decision intent, capture-graph edges
        // A plain quick follow-up: position comes from the computed attention score.
        let pediatricianFollowUp = TaskItem(
            title: "Call the pediatrician back", category: "Health", status: .todo, confidence: 0.9,
            reasoning: "Filed under Health.", ownerID: you.uuid, effortMinutes: 10,
            createdAt: now, in: context)
        context.insert(pediatricianFollowUp)
        // A decision intent-only task → the lighter Thinking Partner card in the detail
        // (choice-shaped wording, but NOT a needsDecision judgment call).
        let vendorDecision = TaskItem(
            title: "Choose the wedding caterer", category: "Family", status: .todo, confidence: 0.9,
            reasoning: "Weighing menu against budget.", ownerID: you.uuid, effortMinutes: 30,
            createdAt: now, in: context)
        vendorDecision.workIntent = .planning
        context.insert(vendorDecision)
        // A `.parent` edge: the mailing-address change is a STEP of the move (an edge is not
        // a status, so it keeps its dependency blocker too).
        mailingAddress.linkParent(movers.uuid!)
        // A rejected duplicate ("Keeping both"): a near-dup of "Donate old clothes"
        // leaves pair-owned suppression records — never an edge — so the pairing is
        // not re-proposed on a later similar capture.
        let donateBooks = TaskItem(
            title: "Donate the old books", category: "Home", status: .todo, confidence: 0.85,
            reasoning: "A separate donation from the clothes.", ownerID: you.uuid, effortMinutes: 20,
            createdAt: now, in: context)
        context.insert(donateBooks)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: donateBooks.title, createdID: donateBooks.uuid,
            targetID: staleDonate.uuid!, in: context)
        // A merged capture folded into the expense report: the target keeps the provenance,
        // and a reversible `.human` "merged" Inbox entry (Undo resurrects the folded draft).
        expenseReport.notes = "Also captured: File the Q2 expenses"
        let mergedDraft = TaskDraft(
            title: "File the Q2 expenses", category: "Work", confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "Same as the expense report.")
        context.insert(
            ChangeLogEntry(
                summary: "Merged “File the Q2 expenses” into “\(expenseReport.title)”",
                detail: "Same as an existing task — folded in rather than duplicated.",
                action: "merged", oldValue: MergedTaskSnapshot(draft: mergedDraft).encoded,
                initiatedBy: .human, isReversible: true,
                taskTitle: expenseReport.title, taskUUID: expenseReport.uuid, actorID: you.uuid,
                timestamp: now.addingTimeInterval(-4 * 3600), in: context))

        // Backfill authorship + a plausible WorkIntent spread over everything (fixtures
        // bypass the model's classification), then score so the stack ranks by attention.
        let scored = TaskItem.fetchAll(in: context)
        for task in scored {
            if task.creatorID == nil { task.creatorID = you.uuid }
            if task.workIntent == nil {
                let title = task.title.lowercased()
                if ["decide", "choose", "figure out", "worth it"].contains(where: { title.contains($0) }) {
                    task.workIntent = .planning
                } else if ["plan", "schedule", "follow up", "reorganize", "prepare"].contains(where: {
                    title.contains($0)
                }) {
                    task.workIntent = .planning
                } else {
                    task.workIntent = .action
                }
            }
        }
        AttentionEngine.recompute(scored, among: scored, now: now)

        context.saveChanges()
    }

    /// A synthesized stand-in headshot: a deterministic two-tone gradient (hue keyed to
    /// the name, so every person is visibly distinct and stable across runs) behind a
    /// white person silhouette. Reads as a *photo* rather than the initials fallback, so
    /// the fixtures exercise the real decode path on every family member. Deliberately
    /// generated, not a bundled asset — mock data, not app content, and a real photo
    /// replaces it the moment someone picks one in the Household screen.
    private static func samplePhotoData(for name: String, glyph: String = "person.fill") -> Data {
        var hash: UInt64 = 5381
        for scalar in name.lowercased().unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let hue = CGFloat(hash % 360) / 360
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { ctx in
            let colors =
                [
                    UIColor(hue: hue, saturation: 0.5, brightness: 0.62, alpha: 1).cgColor,
                    UIColor(
                        hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62,
                        brightness: 0.42, alpha: 1
                    ).cgColor,
                ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // Aspect-preserved so a wider glyph (the family's `person.3.fill`) doesn't
            // stretch the way a fixed square rect would.
            if let symbol = UIImage(
                systemName: glyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold))?
                .withTintColor(UIColor.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal)
            {
                let box: CGFloat = 72
                let scale = min(box / symbol.size.width, box / symbol.size.height)
                let drawn = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(
                    in: CGRect(
                        x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                        width: drawn.width, height: drawn.height))
            }
        }
    }

    /// Mirrors the "recently tidied" change-log entry `AppBrain.commit` logs for
    /// every silent-tier draft, so the seeded data drives the Today footnote and AI
    /// Activity Trail exactly the way a real triage commit would — including the
    /// informational (non-reversible) flag, or the seeded feed would offer an Undo the
    /// real one doesn't.
    private static func logSilentFiling(_ task: TaskItem, into context: NSManagedObjectContext) {
        context.insert(
            ChangeLogEntry(
                summary: "Filed “\(task.title)” under \(task.category)",
                detail: task.reasoning,
                action: "filed",
                initiatedBy: .ai,
                isReversible: false,
                taskTitle: task.title,
                taskUUID: task.uuid, in: context
            ))
    }
}
