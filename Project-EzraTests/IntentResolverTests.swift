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
        #expect(draft.proposedStatus == .inbox)
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
}
