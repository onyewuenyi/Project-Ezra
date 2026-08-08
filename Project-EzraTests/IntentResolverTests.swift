//
//  IntentResolverTests.swift
//  Project-EzraTests
//
//  The resolver is the deterministic half of triage: raw intents in, resolved
//  drafts out. Date resolution lives HERE, in app code — never in the model — so
//  which Friday "next week" means is a testable rule, not a generation artifact.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("IntentResolver")
struct IntentResolverTests {

    /// A Wednesday, mid-afternoon local time, so weekday math is unambiguous.
    private var wednesday: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 15  // 2026-07-15 is a Wednesday
        comps.hour = 15
        return Calendar.current.date(from: comps)!
    }

    private func resolved(_ expression: String?) -> Date? {
        IntentResolver.resolveDate(expression: expression, now: wednesday)
    }

    private func day(_ dayOfMonth: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = dayOfMonth
        return Calendar.current.startOfDay(for: Calendar.current.date(from: comps)!)
    }

    // MARK: - Date resolution

    @Test("today / tomorrow resolve relative to the injected now")
    func todayTomorrow() {
        #expect(resolved("today") == day(15))
        #expect(resolved("tonight") == day(15))
        #expect(resolved("tomorrow") == day(16))
    }

    @Test("A weekday name resolves to the NEXT occurrence")
    func weekdays() {
        #expect(resolved("friday") == day(17))
        #expect(resolved("by friday") == day(17))
        // A weekday that already passed this week rolls to next week.
        #expect(resolved("monday") == day(20))
    }

    @Test("'next week' resolves to the start of the next calendar week")
    func nextWeek() {
        let date = resolved("next week")
        #expect(date != nil)
        if let date {
            let thisWeek = Calendar.current.dateInterval(of: .weekOfYear, for: wednesday)!
            #expect(date == thisWeek.end)
        }
    }

    @Test("'this weekend' resolves to the coming Saturday")
    func weekend() {
        #expect(resolved("this weekend") == day(18))
    }

    @Test("An ISO date the user literally said passes through")
    func isoPassthrough() {
        #expect(
            resolved("2026-08-01")
                == {
                    let formatter = DateFormatter()
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    return formatter.date(from: "2026-08-01")
                }())
    }

    @Test("Unresolvable expressions resolve to nil, never a guess")
    func unresolvableIsNil() {
        #expect(resolved(nil) == nil)
        #expect(resolved("") == nil)
        #expect(resolved("before the trip") == nil)
        #expect(resolved("soonish") == nil)
    }

    // MARK: - Date resolution: the arms that contain each other

    /// The two orderings that were wrong, and stay wrong the moment an arm moves.
    @Test("Overlapping phrases resolve by specificity, not by list position")
    func overlappingPhrasePrecedence() {
        // "day after tomorrow" contains "tomorrow" — it used to land a day early.
        #expect(resolved("day after tomorrow") == day(17))
        // A named weekday beats a bare week reference.
        #expect(resolved("next week friday") == day(24))
        // "this weekend" contains "this week" — the weekend arm has to win.
        #expect(resolved("this weekend") == day(18))
    }

    @Test("Relative offsets resolve, spelled out or in digits")
    func relativeOffsets() {
        #expect(resolved("in 3 days") == day(18))
        #expect(resolved("in three days") == day(18))
        #expect(resolved("in a week") == day(22))
        #expect(resolved("in 2 weeks") == day(29))
        #expect(resolved("a week from now") == day(22))
        #expect(resolved("in ten days") == day(25))
    }

    @Test("A named month and day resolves to the next occurrence, never the past")
    func calendarDates() {
        #expect(resolved("july 20") == day(20))
        #expect(resolved("20 july") == day(20))
        #expect(resolved("jul 20th") == day(20))
        // Already past this year — rolls forward rather than landing pre-dated.
        let january = resolved("january 5")
        #expect(january != nil)
        if let january {
            #expect(Calendar.current.component(.year, from: january) == 2027)
        }
        // A month name is matched whole — "market" is not March.
        #expect(resolved("the market on the 3rd") == nil)
    }

    @Test("Week and month boundaries resolve to the honest edge")
    func boundaries() {
        // The current week runs Sun 12 – Sat 18; its end is the Saturday.
        #expect(resolved("end of the week") == day(18))
        #expect(resolved("this week") == day(18))
        #expect(resolved("end of the month") == day(31))
        // "next month" reads like "next week": the start of it.
        var august = DateComponents()
        august.year = 2026
        august.month = 8
        august.day = 1
        #expect(resolved("next month") == Calendar.current.date(from: august))
    }

    // MARK: - Work-intent backfill (axis 2)

    @Test("Kind of work backfills from the wording; an engine value always wins")
    func workIntentBackfill() {
        func draft(_ title: String, engine: String? = nil) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Home", confidence: 0.9, isJudgmentCall: false,
                    reasoning: "", workIntent: engine))
        }
        // Choice-shaped wording lands .planning — Decision retired from axis 2;
        // DecisionShape (not the type) is what summons the Thinking Partner.
        #expect(draft("Should I switch dentists").workIntent == .planning)
        #expect(draft("Decide on the school").workIntent == .planning)
        #expect(draft("Figure out if we can afford it").workIntent == .planning)
        #expect(draft("Plan the Lisbon trip").workIntent == .planning)
        #expect(draft("Figure out how to get there").workIntent == .planning)
        #expect(draft("Break down the move").workIntent == .planning)
        #expect(draft("Call the plumber").workIntent == .action)
        // The engine's classification is never second-guessed.
        #expect(draft("Plan the Lisbon trip", engine: "action").workIntent == .action)
        #expect(draft("Call the plumber", engine: "planning").workIntent == .planning)
        // …but an unrecognised token falls through to the lexical backfill rather than
        // leaving the field nil. `reference` is retired, so it is exactly such a token.
        #expect(draft("Plan the Lisbon trip", engine: "reference").workIntent == .planning)
    }

    /// Axes 2 and 3 answer different questions. If the backfill ever keys off the
    /// judgment flag, an action-shaped judgment call starts reading as choice-shaped
    /// work and the two axes are fused again.
    @Test("A judgment call with an action-shaped title still classifies as action")
    func workIntentIgnoresJudgmentFlag() {
        let draft = IntentResolver.resolve(
            TaskIntent(
                title: "Call the school about the transfer", category: "Family", confidence: 0.9,
                isJudgmentCall: true, reasoning: ""))
        #expect(draft.workIntent == .action)
        #expect(draft.needsDecision)  // axis 3 still fires, independently
    }

    // MARK: - Due dates proposed from the task's nature

    @Test("Recurring obligations propose a date; ordinary tasks stay undated")
    func dueDateFromNature() {
        func draft(_ title: String, due: String? = nil, kind: String? = nil) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Admin", dateExpression: due, confidence: 0.9,
                    isJudgmentCall: false, reasoning: "", workIntent: kind),
                now: wednesday)
        }
        #expect(draft("Pay the rent").dueDate == day(31))  // month end
        #expect(draft("Renew my passport").dueDate == day(29))  // +14
        #expect(draft("File the taxes").dueDate == day(22))  // +7
        #expect(draft("Text Sam back").dueDate == nil)  // nothing to infer
        // A reference item never completes, so a deadline on it is meaningless.
        #expect(draft("The wifi password is hunter2", kind: "reference").dueDate == nil)
        // A spoken date always wins over the proposal.
        #expect(draft("Pay the rent", due: "tomorrow").dueDate == day(16))
    }

    @Test("A judgment call never receives a proposed date — a spoken one still lands")
    func judgmentCallSuppressesProposedDate() {
        func draft(_ title: String, due: String? = nil) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Admin", dateExpression: due, confidence: 0.9,
                    isJudgmentCall: true, reasoning: ""), now: wednesday)
        }
        // "insurance" is a renewal signal, but deciding about it is a values call —
        // a topic-word deadline on a decision is manufactured pressure, not help.
        #expect(draft("Figure out if we should switch insurance").dueDate == nil)
        #expect(draft("Figure out if we should switch insurance").dueReason == nil)
        // The recurring-bill arm SURVIVES judgment: money leaves on a real cadence
        // whether or not the call gets made.
        #expect(draft("Decide whether to cancel the streaming subscription").dueDate != nil)
        // The user's own date is theirs to set, judgment call or not.
        #expect(draft("Decide about the insurance", due: "friday").dueDate != nil)
    }

    @Test("A proposed date carries its reason; a spoken one carries none")
    func dueReasonOnlyForProposals() {
        func draft(_ title: String, due: String? = nil) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Admin", dateExpression: due, confidence: 0.9,
                    isJudgmentCall: false, reasoning: ""), now: wednesday)
        }
        #expect(draft("Pay the rent").dueReason != nil)
        #expect(draft("Pay the rent", due: "friday").dueReason == nil)
        #expect(draft("Text Sam back").dueReason == nil)
    }

    /// The no-feedback rule: `inferredImportance` reads the SPOKEN date only. A
    /// proposed date landing inside its two-day imminence window must not raise the
    /// score, or a guess inflates the attention substrate.
    @Test("A proposed due date never feeds the importance backfill")
    func proposedDateDoesNotInflateImportance() {
        // Resolved on the 30th, so the month-end proposal (the 31st) is imminent.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 30
        comps.hour = 15
        let lateInMonth = Calendar.current.date(from: comps)!

        // "subscription" proposes a month-end date but is NOT a consequence signal, so
        // importance can only read 0.75 here by having read the proposed date.
        let draft = IntentResolver.resolve(
            TaskIntent(
                title: "Cancel the gym subscription", category: "Home", confidence: 0.9,
                isJudgmentCall: false, reasoning: ""), now: lateInMonth)
        #expect(draft.dueDate == day(31))  // proposed, imminent
        #expect(draft.aiImportance == IntentResolver.ordinaryImportance)  // and ignored
    }

    // MARK: - Corrections

    @Test("A kind changed at confirm is diffed; an untouched one is not")
    func workIntentCorrection() {
        var draft = IntentResolver.resolve(
            TaskIntent(
                title: "Call the plumber", category: "Home", confidence: 0.9,
                isJudgmentCall: false, reasoning: ""))
        #expect(draft.workIntent == .action)
        #expect(draft.corrections.isEmpty)

        draft.workIntent = .planning
        let diff = draft.corrections.first { $0.field == "workIntent" }
        #expect(diff?.aiValue == "action")
        #expect(diff?.userValue == "planning")
    }

    // MARK: - Draft resolution

    @Test("Every resolved draft proposes Inbox and carries the raw fields forward")
    func resolveCarriesFieldsForward() {
        let intent = TaskIntent(
            title: "Book flights",
            category: "Travel",
            dateExpression: "friday",
            personReference: "Sarah",
            blockerPhrase: "passport",
            confidence: 0.9,
            isJudgmentCall: false,
            reasoning: "Filed under Travel.",
            importance: 0.7,
            effortMinutes: 30
        )
        let draft = IntentResolver.resolve(intent, now: wednesday)
        #expect(draft.title == "Book flights")
        #expect(draft.dueDate == day(17))
        #expect(draft.ownerName == "Sarah")
        #expect(draft.blockedBy == "passport")
        #expect(draft.aiImportance == 0.7)
        #expect(draft.effortMinutes == 30)
        #expect(draft.autonomy == .silent)
        #expect(!draft.needsDecision)
    }

    @Test("Only create-intents become drafts; update/delete are reserved")
    func onlyCreateResolves() {
        let create = TaskIntent(
            title: "a", category: "Home", confidence: 0.9, isJudgmentCall: false, reasoning: "")
        var update = create
        update.action = .update
        var delete = create
        delete.action = .delete
        #expect(IntentResolver.resolve([create, update, delete]).count == 1)
    }

    // MARK: - Metadata backfill (nothing reaches the confirm card empty)

    @Test("Effort backfills by verb band; an explicit estimate always wins")
    func effortBackfill() {
        func draft(_ title: String, effort: Int? = nil) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Home", confidence: 0.9, isJudgmentCall: false,
                    reasoning: "", effortMinutes: effort))
        }
        #expect(draft("Call mom back").effortMinutes == 15)  // quick touch
        #expect(draft("Plan the offsite").effortMinutes == 60)  // focused work
        #expect(draft("Pick up dry cleaning").effortMinutes == 30)  // errand default
        #expect(draft("Call mom back", effort: 45).effortMinutes == 45)  // extracted wins
    }

    @Test("Importance backfills from consequence and imminence; extracted values win")
    func importanceBackfill() {
        func draft(
            _ title: String, due: String? = nil, importance: Double? = nil
        ) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: title, category: "Home", dateExpression: due, confidence: 0.9,
                    isJudgmentCall: false, reasoning: "", importance: importance),
                now: wednesday)
        }
        #expect(draft("Pay the water bill").aiImportance == 0.75)  // consequence signal
        #expect(draft("Water the plants", due: "tomorrow").aiImportance == 0.75)  // imminent date
        #expect(draft("Water the plants").aiImportance == 0.4)  // ordinary
        #expect(draft("Pay the water bill", importance: 0.1).aiImportance == 0.1)  // engine's call wins
    }

    @Test("Backfill lands inside the aiOriginal snapshot — no phantom corrections")
    func backfillInsideSnapshot() {
        let draft = IntentResolver.resolve(
            TaskIntent(
                title: "Call mom back", category: "Family", confidence: 0.9,
                isJudgmentCall: false, reasoning: ""))
        #expect(draft.aiOriginal?.effortMinutes == draft.effortMinutes)
        #expect(draft.aiOriginal?.isUrgent == draft.isUrgent)
        #expect(draft.corrections.isEmpty)
    }

    // MARK: - Reverse dependencies

    @Test("An open task's external note matching the new title becomes a dependent")
    func dependentFromExternalNote() {
        let flights = OpenTaskSnapshot(
            id: UUID(), title: "Book flights", externalBlockerNotes: ["passport"])
        let unrelated = OpenTaskSnapshot(id: UUID(), title: "Water the plants")
        let intent = TaskIntent(
            title: "Renew my passport", category: "Travel", confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
        let draft = IntentResolver.resolve(intent, openTasks: [flights, unrelated])
        #expect(draft.blocks.map(\.id) == [flights.id])
    }

    @Test("Model-flagged titles resolve against the open set; unmatched titles drop")
    func dependentFromModelTitles() {
        let flights = OpenTaskSnapshot(id: UUID(), title: "Book flights for the trip")
        var intent = TaskIntent(
            title: "Renew my passport", category: "Travel", confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
        intent.blocksExisting = ["Book flights for the trip", "A task that does not exist"]
        let draft = IntentResolver.resolve(intent, openTasks: [flights])
        #expect(draft.blocks.map(\.id) == [flights.id])  // exact match in, hallucination out
    }

    @Test("Both sources dedupe to one dependent")
    func dependentSourcesDedupe() {
        let flights = OpenTaskSnapshot(
            id: UUID(), title: "Book flights", externalBlockerNotes: ["passport"])
        var intent = TaskIntent(
            title: "Renew my passport", category: "Travel", confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
        intent.blocksExisting = ["Book flights"]
        let draft = IntentResolver.resolve(intent, openTasks: [flights])
        #expect(draft.blocks.count == 1)
    }

    @Test("Confidence is clamped to 0…1")
    func confidenceClamped() {
        let hot = TaskIntent(
            title: "a", category: "Home", confidence: 1.7, isJudgmentCall: false, reasoning: "")
        #expect(IntentResolver.resolve(hot).confidence == 1.0)
        let cold = TaskIntent(
            title: "b", category: "Home", confidence: -0.2, isJudgmentCall: false, reasoning: "")
        #expect(IntentResolver.resolve(cold).confidence == 0.0)
    }

    // MARK: - Capture-graph proposals

    private func intent(_ title: String) -> TaskIntent {
        TaskIntent(title: title, category: "Travel", confidence: 0.9, isJudgmentCall: false, reasoning: "")
    }

    @Test("Edge proposals tier by confidence; unknown ids are dropped")
    func edgeProposalTiering() {
        let candID = UUID()
        let candidates = [RetrievalCandidate(id: candID, title: "Renew passport", facts: "", score: 1)]

        func dupDraft(_ confidence: Double, id: UUID = UUID()) -> TaskDraft {
            var i = intent("Renew passport")
            i.duplicateOf = EdgeReference(targetID: id, confidence: confidence)
            return IntentResolver.resolve(i, candidates: candidates)
        }
        #expect(dupDraft(0.9, id: candID).edgeProposals.first?.decision == .accepted)
        #expect(dupDraft(0.6, id: candID).edgeProposals.first?.decision == .undecided)
        #expect(dupDraft(0.3, id: candID).edgeProposals.isEmpty)  // below threshold → suppressed
        #expect(dupDraft(0.9).edgeProposals.isEmpty)  // unknown id → dropped
    }

    @Test("Self-dedupe: the same target can't be both a duplicate and a child")
    func edgeSelfDedupe() {
        let candID = UUID()
        let candidates = [RetrievalCandidate(id: candID, title: "Plan trip", facts: "", score: 1)]
        var i = intent("Plan trip")
        i.duplicateOf = EdgeReference(targetID: candID, confidence: 0.9)
        i.childOf = EdgeReference(targetID: candID, confidence: 0.9)
        let draft = IntentResolver.resolve(i, candidates: candidates)
        #expect(draft.edgeProposals.count == 1)
        #expect(draft.edgeProposals.first?.kind == .duplicateOf)  // duplicate wins
    }

    @Test("childOf is auto-accepted above the floor — additive links get no undecided limbo")
    func childAutoAccept() {
        let candID = UUID()
        let candidates = [RetrievalCandidate(id: candID, title: "Plan trip", facts: "", score: 1)]
        func childDraft(_ confidence: Double) -> TaskDraft {
            var i = intent("Book flights")
            i.childOf = EdgeReference(targetID: candID, confidence: confidence)
            return IntentResolver.resolve(i, candidates: candidates)
        }
        #expect(childDraft(0.9).edgeProposals.first?.decision == .accepted)
        // The mid band that would be .undecided for a duplicate is ACCEPTED for a child
        // (additive + reversible — the auto-accept invariant's tiering is by
        // destructiveness, not uniform).
        #expect(childDraft(0.6).edgeProposals.first?.decision == .accepted)
        // The suppression floor still holds: below it the model is declining, not gating.
        #expect(childDraft(0.4).edgeProposals.isEmpty)
    }

    @Test("A rejected pairing is dropped on the next capture of the same title — and only that title")
    func suppressionDropsRepeatProposal() {
        let candID = UUID()
        let candidates = [RetrievalCandidate(id: candID, title: "Renew passport", facts: "", score: 1)]
        // What commit writes after the user taps "Keep both": keyed on the normalized
        // DRAFT TITLE against the target (a fresh draft id can never match a pair key).
        let suppression = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: nil, targetID: candID,
            normalizedTitle: RelationshipSuppression.normalizeTitle("Renew — the Passport!"),
            createdAt: Date())

        var same = intent("renew the passport")
        same.duplicateOf = EdgeReference(targetID: candID, confidence: 0.9)
        let suppressed = IntentResolver.resolve(same, candidates: candidates, suppressions: [suppression])
        #expect(suppressed.edgeProposals.isEmpty)

        var different = intent("Book flights to Rome")
        different.duplicateOf = EdgeReference(targetID: candID, confidence: 0.9)
        let proposed = IntentResolver.resolve(
            different, candidates: candidates, suppressions: [suppression])
        #expect(proposed.edgeProposals.count == 1)  // materially different text still proposes

        // A duplicate suppression never silences a CHILD proposal to the same target.
        var child = intent("renew the passport")
        child.childOf = EdgeReference(targetID: candID, confidence: 0.9)
        let childDraft = IntentResolver.resolve(child, candidates: candidates, suppressions: [suppression])
        #expect(childDraft.edgeProposals.count == 1)
    }
}
