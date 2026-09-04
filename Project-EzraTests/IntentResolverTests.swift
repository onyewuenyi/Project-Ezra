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

    @Test("A bare clock time implies today; a spoken day always wins over the clock beside it")
    func bareClockTimeMeansToday() {
        // P1 (2026-09-02): 8 of the first 26 real captures were "cook dinner at 3",
        // "make lunch at noon" — every one meant today, every one used to land undated
        // behind a "When?" chip.
        #expect(resolved("at 3 pm") == day(15))
        #expect(resolved("at 3PM") == day(15))
        #expect(resolved("3 PM") == day(15))
        #expect(resolved("at 9 p.m.") == day(15))
        #expect(resolved("at 3:30pm") == day(15))
        #expect(resolved("at noon") == day(15))
        #expect(resolved("midnight") == day(15))
        #expect(resolved("at 5") == day(15))
        #expect(resolved("this afternoon") == day(15))
        // Arm order is load-bearing: the clock arm is LAST, so a day word wins.
        #expect(resolved("tomorrow at 3 pm") == day(16))
        #expect(resolved("friday at noon") == day(17))
        #expect(resolved("monday at 8 am") == day(20))
        #expect(resolved("next week on friday at 8 am") == day(24))
        #expect(resolved("tonight at 9") == day(15))
        // Not a clock time: a capture cut at "at", a duration, a 24h-looking number.
        #expect(resolved("at") == nil)
        #expect(resolved("in 5 minutes") == nil)
        #expect(resolved("at 20") == nil)
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

    // MARK: - Instance expansion (one intent → one draft per named occasion)

    private func walkTheDog(_ expression: String?) -> [TaskDraft] {
        IntentResolver.resolve(
            [
                TaskIntent(
                    title: "Walk the dog", category: "Home", dateExpression: expression,
                    confidence: 0.9, isJudgmentCall: false, reasoning: "")
            ], now: wednesday)
    }

    @Test("Two named days become two drafts, earliest first, everything else identical")
    func expandsNamedOccasions() {
        let drafts = walkTheDog("monday and tuesday")
        #expect(drafts.count == 2)
        #expect(drafts.map(\.dueDate) == [day(20), day(21)])
        // The fan-out multiplies occasions, never identity or content.
        #expect(drafts.allSatisfy { $0.title == "Walk the dog" })
        #expect(Set(drafts.map(\.id)).count == 2)
        // Each draft's own due date is what the confirm-card diff will compare against —
        // a shared snapshot would record one of them as a user correction on sight.
        #expect(drafts.map(\.aiOriginal?.dueDate) == [day(20), day(21)])
    }

    @Test("Commas and mixed separators enumerate too")
    func expandsCommaList() {
        // Friday is the nearest of the three from a Wednesday, so it leads.
        #expect(
            walkTheDog("monday, wednesday and friday").map(\.dueDate)
                == [day(17), day(20), day(22)])
        #expect(walkTheDog("tomorrow and friday").map(\.dueDate) == [day(16), day(17)])
    }

    @Test("A repeated day is one occasion said twice")
    func dedupesIdenticalDates() {
        #expect(walkTheDog("monday and monday").count == 1)
    }

    @Test("Expansion is all-or-nothing: one unresolvable fragment declines the whole split")
    func declinesWhenAFragmentIsNotADate() {
        // The guard that stops a connective inside a date phrase from manufacturing a
        // task. Both of these still resolve normally as a SINGLE occasion.
        #expect(walkTheDog("before the trip and after the meeting").count == 1)
        let conditional = walkTheDog("tomorrow and if i have time")
        #expect(conditional.count == 1)
        #expect(conditional[0].dueDate == day(16))
    }

    @Test("A quantity is not an enumeration — the outcome stays one task")
    func quantityNeverExpands() {
        // The product rule read the other way: "cook lunch for three days next week" is
        // one cooking session, and no number in the phrase may multiply it.
        let drafts = IntentResolver.resolve(
            [
                TaskIntent(
                    title: "Cook lunch for three days", category: "Home",
                    dateExpression: "next week", confidence: 0.9, isJudgmentCall: false,
                    reasoning: "")
            ], now: wednesday)
        #expect(drafts.count == 1)
    }

    @Test("Past the week cap the expansion is declined, never truncated")
    func capDeclinesRatherThanTruncates() {
        let everyDay =
            "sunday, monday, tuesday, wednesday, thursday, friday, saturday and monday"
        // Eight fragments — one task the user can correct beats eight they must delete.
        #expect(walkTheDog(everyDay).count == 1)
        // Seven still expands; the cap is a ceiling, not an off switch.
        #expect(
            walkTheDog("sunday, monday, tuesday, wednesday, thursday, friday and saturday")
                .count == 7)
    }

    @Test("The heuristic hands over the whole enumeration, not its first day")
    func heuristicKeepsTheWholePhrase() {
        // Both engines must agree: expansion can only fan out the phrase it is given, so
        // a truncating extractor would silently drop occasions on the offline arm.
        #expect(
            HeuristicEngine.dateExpression(from: "walk the dog monday and tuesday") == "monday and tuesday")
        #expect(
            HeuristicEngine.dateExpression(from: "gym monday, wednesday and friday")
                == "monday, wednesday and friday")
        // A single weekday is unchanged, and a non-enumeration is untouched.
        #expect(HeuristicEngine.dateExpression(from: "call mom friday") == "friday")
        #expect(HeuristicEngine.dateExpression(from: "call mom and dad tomorrow") == "tomorrow")
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

    // MARK: - Unresolved details (the targeted ask)

    @Test("A spoken time phrase we can't read is reported, not silently dropped")
    func unreadableSpokenDateIsReported() {
        // The silent failure this exists for: `resolveDate` returning nil for a phrase
        // the user actually said used to drop it on the floor, so their only clue was
        // noticing an empty chip where they remembered saying something.
        let intent = TaskIntent(
            title: "Sort the thing", category: "Admin",
            dateExpression: "before the trip", confidence: 0.9, isJudgmentCall: false,
            reasoning: "")
        let draft = IntentResolver.resolve(intent)
        #expect(draft.dueDate == nil)
        #expect(draft.unresolved == [.date], "a spoken date that resolved to nothing must be named")
    }

    @Test("A spoken clock time is resolved, so it no longer raises the ask")
    func clockTimeIsNotUnresolved() {
        let intent = TaskIntent(
            title: "Cook dinner", category: "Home", dateExpression: "at 3 pm",
            confidence: 0.9, isJudgmentCall: false, reasoning: "")
        let draft = IntentResolver.resolve(intent)
        #expect(draft.dueDate != nil)
        #expect(draft.unresolved.isEmpty)
    }

    @Test("An UNDATED task is not an unresolved one")
    func silenceIsNotAnUnresolvedDate() {
        // The distinction the whole feature rests on. Most tasks have no date because
        // nobody mentioned one; asking "When?" on those would be a nag on every card.
        let intent = TaskIntent(
            title: "Water the plants", category: "Home", confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
        #expect(IntentResolver.resolve(intent).unresolved.isEmpty)
    }

    @Test("A phrase we CAN read leaves nothing unresolved")
    func readableDateIsNotReported() {
        let intent = TaskIntent(
            title: "Call the vet", category: "Home", dateExpression: "tomorrow",
            confidence: 0.9, isJudgmentCall: false, reasoning: "")
        let draft = IntentResolver.resolve(intent)
        #expect(draft.dueDate != nil)
        #expect(draft.unresolved.isEmpty)
    }

    @Test("Naming more occasions than expand's cap is reported, not silently narrowed to one")
    func exceedingInstanceCapIsReported() {
        // Eight real, individually-resolvable occasions — one past `IntentResolver
        // .maxInstances` (7; there are only seven weekday names, so the eighth has to
        // come from elsewhere in the vocabulary). `expand` declines to fan this out,
        // and without the `exceedsInstanceCap` guard `resolveDate`'s substring match
        // would silently pick the FIRST phrase it recognizes and report it as a
        // confident single date, dropping the other seven with no signal to the user.
        let intent = TaskIntent(
            title: "Clean the litter box", category: "Home",
            dateExpression: "today, tomorrow, monday, tuesday, wednesday, thursday, friday, "
                + "and saturday",
            confidence: 0.9, isJudgmentCall: false, reasoning: "")
        let draft = IntentResolver.resolve(intent, now: wednesday)
        #expect(draft.dueDate == nil, "no single date honestly represents eight named occasions")
        #expect(draft.unresolved == [.date], "too many named occasions must ask, not guess")
    }

    @Test("The instance-cap guard does not misfire on an ordinary non-enumeration phrase")
    func exceedingInstanceCapDoesNotMisfireOnOrdinaryPhrases() {
        // A guard against the fix above being too broad: a phrase with several "and"s
        // that ISN'T a calendar enumeration (its fragments aren't all dates) must not
        // be treated as exceeding the cap, however many fragments it splits into.
        #expect(
            !IntentResolver.exceedsInstanceCap(
                in: "before the trip and after the meeting", now: wednesday))
        // Seven or fewer resolvable occasions is exactly what `expand` handles itself —
        // the cap guard only fires strictly ABOVE `maxInstances`.
        #expect(
            !IntentResolver.exceedsInstanceCap(
                in: "monday, tuesday, wednesday, thursday, friday, saturday, and sunday",
                now: wednesday))
    }

    @Test("An INFERRED due date is not an answer to a question the user asked")
    func inferredDatesDoNotSuppressTheAsk() {
        // `inferredDueDate` only fires when no date was spoken, so the two can never
        // collide — but pinning it stops a future refactor from letting a guessed date
        // quietly satisfy an ask about words the user actually said.
        let intent = TaskIntent(
            title: "Pay the electricity bill", category: "Admin", confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
        let draft = IntentResolver.resolve(intent)
        #expect(draft.dueDate != nil, "the bill arm should propose a date")
        #expect(draft.unresolved.isEmpty, "nothing was spoken, so nothing is unresolved")
    }
}
