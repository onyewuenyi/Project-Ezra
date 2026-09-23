//
//  HeuristicEngineTests.swift
//  Project-EzraTests
//
//  Covers the deterministic fallback engine: item splitting, word-boundary
//  categorization (the "daycare ≠ Car" regression), judgment/blocked detection,
//  and end-to-end triage. This engine is what the simulator always runs, so its
//  behavior is the one we can pin down without a device.
//

import Foundation
import Testing
@testable import Project_Ezra

@Suite("Heuristic uncertainty (audit P3)")
struct HeuristicUncertaintyTests {

    @Test("A never-verified line scores under the uncertainty threshold")
    func unverifiedLineReadsUncertain() {
        // No action opener, no judgment shape, no strong category — the honest
        // "not sure this is a task" class the confirm card dims with a "?".
        let intent = HeuristicEngine.intent(from: "okay so this week is a lot")
        #expect(intent.confidence < 0.5)
        #expect(!intent.isJudgmentCall)
    }

    @Test("A verified item or a strong category hit never reads uncertain")
    func verifiedLinesKeepTheirConfidence() {
        #expect(HeuristicEngine.intent(from: "renew my passport").confidence >= 0.5)
        // No action opener, but "oil change" is a strong Car signal.
        #expect(
            HeuristicEngine.intent(from: "oil change is overdue by two weeks").confidence >= 0.5)
    }
}

@Suite("HeuristicEngine")
struct HeuristicEngineTests {

    // MARK: - Item splitting

    @Test("Newline-separated blob splits into individual items")
    func splitsNewlines() {
        let items = HeuristicEngine.splitIntoItems("renew passport\ncall mom\npay water bill")
        #expect(items.count == 3)
    }

    @Test("Bullets and stray punctuation are stripped")
    func stripsBullets() {
        let items = HeuristicEngine.splitIntoItems("- renew passport\n• call mom")
        #expect(items.contains("renew passport"))
        #expect(items.contains("call mom"))
    }

    @Test("A short comma list becomes multiple items")
    func splitsCommaList() {
        let items = HeuristicEngine.splitIntoItems("buy milk, return package, call bank")
        #expect(items.count == 3)
    }

    @Test("Blank and one-character lines are dropped")
    func dropsEmptyLines() {
        let items = HeuristicEngine.splitIntoItems("renew passport\n\n \nx")
        #expect(items == ["renew passport"])
    }

    @Test("A capture that is one filler word is nothing, not a card")
    func bareFillerIsNoItem() {
        #expect(HeuristicEngine.splitIntoItems("Have").isEmpty)
        #expect(HeuristicEngine.splitIntoItems("Um.").isEmpty)
        #expect(HeuristicEngine.splitIntoItems("Hello").isEmpty)
        #expect(HeuristicEngine.splitIntoItems("Laundry") == ["Laundry"])
        #expect(HeuristicEngine.splitIntoItems("Have the car washed") == ["Have the car washed"])
    }

    @Test("The category with the most signals wins; table order only breaks ties")
    func mostHitsWins() {
        #expect(HeuristicEngine.intent(from: "email the client about the invoice").category == "Work")
        #expect(HeuristicEngine.intent(from: "pay the invoice").category == "Finance")
        #expect(HeuristicEngine.intent(from: "daycare enrollment forms").category == "Family")
    }

    @Test("Kitchen and room words file under Home, not Admin")
    func kitchenIsHome() {
        #expect(HeuristicEngine.intent(from: "cook dinner for tomorrow").category == "Home")
        #expect(HeuristicEngine.intent(from: "make lunch at noon").category == "Home")
        #expect(HeuristicEngine.intent(from: "sort the garage").category == "Home")
    }

    // MARK: - Categorization (word-boundary regression)

    @Test("‘daycare’ files under Family, not Car (word-boundary match)")
    func daycareIsFamilyNotCar() {
        let draft = HeuristicEngine.intent(from: "daycare enrollment forms")
        #expect(draft.category == "Family")
    }

    @Test("Category keywords still match on whole words")
    func categoryMatching() {
        #expect(HeuristicEngine.intent(from: "oil change is overdue").category == "Car")
        #expect(HeuristicEngine.intent(from: "renew my passport").category == "Travel")
        #expect(HeuristicEngine.intent(from: "pay the water bill").category == "Finance")
    }

    @Test("Unknown wording falls back to Admin")
    func unknownIsAdmin() {
        #expect(HeuristicEngine.intent(from: "ponder the universe").category == "Admin")
    }

    // MARK: - Judgment + blocked detection

    @Test("Values-laden wording is flagged as a judgment call")
    func detectsJudgmentCall() {
        #expect(HeuristicEngine.intent(from: "should I quit the side project").isJudgmentCall)
        #expect(HeuristicEngine.intent(from: "figure out if the gym is worth it").isJudgmentCall)
    }

    @Test("A judgment intent resolves to ask-tier and Needs Decision")
    func judgmentDraftRouting() {
        let draft = IntentResolver.resolve(
            HeuristicEngine.intent(from: "should I keep paying for the gym"))
        #expect(draft.autonomy == .ask)
        #expect(draft.needsDecision)
    }

    @Test("Dependency wording is detected — captured as a blocker phrase, not a status")
    func detectsBlocked() {
        let intent = HeuristicEngine.intent(from: "book flights after passport is done")
        #expect(intent.blockerPhrase != nil)  // resolved to a real blocker at commit; blocked is derived
    }

    @Test("The blocker phrase is extracted, minus resolution words")
    func extractsBlockerPhrase() {
        let intent = HeuristicEngine.intent(from: "book flights after passport is done")
        #expect(intent.blockerPhrase == "passport")
        #expect(HeuristicEngine.blockerPhrase(from: "call plumber once the quote arrives") == "the quote")
        #expect(HeuristicEngine.blockerPhrase(from: "submit expenses waiting on receipts") == "receipts")
    }

    /// A demonstrative names nothing that can ever be matched, so a wait on it can only
    /// ever be cleared by hand — while the task recesses, sinks under the blocked band
    /// and opens the Advisor's blocked gate the whole time. The cost is entirely
    /// one-sided, so the extractor declines.
    @Test("A pronoun is not a blocker — a wait that names nothing is no wait")
    func contentlessWaitsAreDeclined() {
        for line in [
            "book flights for the trip after that",
            "send the invoice once it is done",
            "order the parts depends on them",
            "reply to the email after the",
        ] {
            #expect(
                HeuristicEngine.intent(from: line).blockerPhrase == nil,
                "\(line) recorded a wait that names nothing")
        }
        // A real phrase that merely BEGINS with a determiner still passes — the check is
        // "does any word carry content", not "is the first word a noun".
        #expect(HeuristicEngine.blockerPhrase(from: "book flights after the passport") == "the passport")
        #expect(
            HeuristicEngine.blockerPhrase(from: "call the vet once the results are in")
                == "the results are in")
    }

    /// The reasoning line and the recorded wait used to be decided separately, so a line
    /// that read as blocked but yielded no usable phrase told the user "it depends on
    /// something else finishing first" while recording nothing to depend on.
    @Test("The explanation never claims a dependency the draft does not carry")
    func reasoningAgreesWithTheWait() {
        let phantom = HeuristicEngine.intent(from: "book flights for the trip after that")
        #expect(phantom.blockerPhrase == nil)
        #expect(!phantom.reasoning.contains("depends on something else"))

        let real = HeuristicEngine.intent(from: "book flights after passport is done")
        #expect(real.blockerPhrase == "passport")
        #expect(real.reasoning.contains("depends on something else"))
    }

    @Test("Dependency keywords never match inside other words")
    func blockedNeedsWordBoundary() {
        let intent = HeuristicEngine.intent(from: "clean the rafters")
        #expect(intent.blockerPhrase == nil)
    }

    // MARK: - Metadata extraction (urgent / importance / owner / effort)

    @Test("Urgent signal comes from the user's own wording; false when unstated")
    func urgentFromWording() {
        #expect(HeuristicEngine.urgencySignal(for: "pay the water bill asap"))
        #expect(!HeuristicEngine.urgencySignal(for: "clean the garage someday"))
        #expect(!HeuristicEngine.urgencySignal(for: "water the plants"))
    }

    @Test("Importance reads high on consequence/emphasis, low on deferral, nil when unstated")
    func importanceFromWording() {
        #expect(HeuristicEngine.importanceSignal(for: "pay the water bill asap") == 0.85)
        #expect(HeuristicEngine.importanceSignal(for: "clean the garage someday") == 0.15)
        #expect(HeuristicEngine.importanceSignal(for: "don't forget the daycare forms") == 0.7)
        #expect(HeuristicEngine.importanceSignal(for: "water the plants") == nil)
    }

    @Test("Explicit deferral outranks emphasis words")
    func deferralBeatsEmphasis() {
        #expect(HeuristicEngine.importanceSignal(for: "important but no rush") == 0.15)
    }

    @Test("Delegation wording extracts an owner name")
    func extractsOwner() {
        #expect(HeuristicEngine.ownerName(from: "ask sarah to book the venue") == "Sarah")
        #expect(HeuristicEngine.ownerName(from: "remind mom about the forms") == "Mom")
        #expect(HeuristicEngine.ownerName(from: "mike will handle the invoices") == "Mike")
        #expect(HeuristicEngine.ownerName(from: "renew my passport") == nil)
        // Pronouns never become owners.
        #expect(HeuristicEngine.ownerName(from: "ask them to reply") == nil)
    }

    @Test("A delegated intent carries the person reference and says so")
    func delegatedDraft() {
        let intent = HeuristicEngine.intent(from: "ask sarah to book the venue")
        #expect(intent.personReference == "Sarah")
        #expect(intent.reasoning.contains("Sarah"))
    }

    @Test("Effort comes from explicit durations or quick-verb inference")
    func extractsEffort() {
        #expect(HeuristicEngine.effortMinutes(from: "review the doc for 30 min") == 30)
        #expect(HeuristicEngine.effortMinutes(from: "deep clean, about 2 hours") == 120)
        #expect(HeuristicEngine.effortMinutes(from: "call mom back") == 15)
        #expect(HeuristicEngine.effortMinutes(from: "plan the offsite") == nil)
    }

    // MARK: - Time phrases

    /// The extractor hands `IntentResolver.resolveDate` a phrase verbatim, so a
    /// truncated phrase is a wrong DATE, not just a cosmetic one. The token list is
    /// ordered longest-first for exactly this reason and used not to be.
    @Test("The longest matching time phrase wins, not the first one listed")
    func timePhrasePrecedence() {
        #expect(
            HeuristicEngine.dateExpression(from: "call the vet day after tomorrow")
                == "day after tomorrow")
        #expect(HeuristicEngine.dateExpression(from: "pay it this weekend") == "this weekend")
        #expect(HeuristicEngine.dateExpression(from: "wrap up end of the week") == "end of the week")
        #expect(HeuristicEngine.dateExpression(from: "book it tomorrow") == "tomorrow")
    }

    @Test("Open-ended phrases a token list can't hold are extracted by shape")
    func timePhrasePatterns() {
        #expect(HeuristicEngine.dateExpression(from: "renew it in three days") == "in three days")
        #expect(HeuristicEngine.dateExpression(from: "due july 20") == "july 20")
        #expect(HeuristicEngine.dateExpression(from: "a week from now") == "a week from now")
        #expect(HeuristicEngine.dateExpression(from: "sometime soonish") == nil)
    }

    @Test("A clock time is handed over verbatim, and never shadows a spoken day")
    func clockTimePhrases() {
        #expect(HeuristicEngine.dateExpression(from: "clean up room at 3 pm.") == "at 3 pm")
        #expect(HeuristicEngine.dateExpression(from: "make lunch at noon") == "at noon")
        #expect(HeuristicEngine.dateExpression(from: "cook dinner at 9 p.m. no. no") == "at 9 p.m.")
        #expect(HeuristicEngine.dateExpression(from: "cook dinner at 5") == "at 5")
        #expect(HeuristicEngine.dateExpression(from: "get ready for the gym at 10 am. be") == "at 10 am")
        // The day token list runs first, so the resolver sees the day, not the clock.
        #expect(HeuristicEngine.dateExpression(from: "clean my room tomorrow at 3 pm") == "tomorrow")
        #expect(HeuristicEngine.dateExpression(from: "cook at 3pm today") == "today")
        #expect(HeuristicEngine.dateExpression(from: "call back this afternoon") == "this afternoon")
        // A capture cut at "at": the person spoke a time the window never heard. The
        // bare "at" is handed over so the resolver reports it as unresolved and the
        // "When?" ask fires — instead of a silently undated card.
        #expect(HeuristicEngine.dateExpression(from: "be ready to go to brunch at") == "at")
        #expect(HeuristicEngine.dateExpression(from: "look at") == "at")
        #expect(HeuristicEngine.dateExpression(from: "meet at the station") == nil)
    }

    @Test("Meta-narration and a dangling tail leave the title; the ask still fires")
    func narrationStrippedAndFragmentAsks() {
        // Real corpus rows 31 and 40 (2026-09-02): "I want to add that…" is the act of
        // capturing, not the capture; "…brunch at" was cut by the silence window.
        // Through the segmenter, as production runs it: lead-ins are stripped when a
        // clause is cut, and the per-clause classifier sees the stripped line.
        func first(_ text: String) -> TaskIntent {
            HeuristicEngine.intent(from: Segmentation.items(from: text).first ?? text)
        }
        let intent = first("I want to add that I need to be ready to go to brunch at")
        #expect(intent.title == "Be ready to go to brunch")
        #expect(intent.dateExpression == "at")
        let draft = IntentResolver.resolve(intent)
        #expect(draft.dueDate == nil)
        #expect(draft.unresolved == [.date])
        #expect(first("Adding pickup shirt at 3 PM").title == "Pickup shirt at 3 PM")
        #expect(first("remind me to call the vet").title == "Call the vet")
        #expect(first("Take something to my").title == "Take something")
        // Never empties: a one-word line keeps its word.
        #expect(HeuristicEngine.cleanTitle("at") == "At")
    }

    @Test("The day lifted into the chip leaves the title's edge; a day used as a modifier stays")
    func dateLeavesTheTitleEdge() {
        func intent(_ text: String) -> TaskIntent { HeuristicEngine.intent(from: text) }
        // Trailing, with and without the preposition that hung it there.
        #expect(intent("call the dentist thursday").title == "Call the dentist")
        #expect(intent("call the dentist thursday").dateExpression == "thursday")
        #expect(intent("pay rent by friday").title == "Pay rent")
        #expect(intent("pay the bill the day after tomorrow").title == "Pay the bill")
        // The dangling-tail rule then takes the "in" the day had been holding up.
        #expect(intent("book the car in next week").title == "Book the car")
        // Leading.
        #expect(intent("tomorrow call the vet").title == "Call the vet")
        #expect(intent("on monday email the school").title == "Email the school")
        // Mid-line is a modifier, not a when — cutting it changes the task.
        #expect(intent("book the tuesday meeting room").title == "Book the tuesday meeting room")
        #expect(intent("plan the weekend trip with mum").title == "Plan the weekend trip with mum")
        // A clock time stays: the chip shows the day, the title keeps the hour.
        #expect(intent("pickup shirt at 3 PM").title == "Pickup shirt at 3 PM")
        // A day after a topic preposition is what the task is ABOUT, and stays.
        #expect(intent("text sarah about saturday").title == "Text sarah about saturday")
        // Never empties.
        #expect(intent("tomorrow").title == "Tomorrow")
        // The pure function, without an expression, is unchanged.
        #expect(HeuristicEngine.cleanTitle("call the dentist thursday") == "Call the dentist thursday")
    }

    @Test("The dependency clause leaves the title once it is the blocker; a verb's own preposition stays")
    func waitLeavesTheTitle() {
        func intent(_ text: String) -> TaskIntent { HeuristicEngine.intent(from: text) }
        let flights = intent("book flights for the trip after passport is done")
        #expect(flights.title == "Book flights for the trip")
        #expect(flights.blockerPhrase == "passport")
        #expect(intent("renew the passport, waiting on photos").title == "Renew the passport")
        #expect(intent("call mom after lunch").title == "Call mom")
        // A pronoun wait is not a blocker, but it is still not the task.
        #expect(intent("book flights after it comes through").title == "Book flights")
        // Fewer than two words before the signal: the preposition belongs to the verb.
        #expect(intent("look after the kids").title == "Look after the kids")
        #expect(intent("call after lunch").title == "Call after lunch")
        // A day inside the clause leaves with the clause; the chip still reads the line.
        let dated = intent("book the flights after the passport is done on friday")
        #expect(dated.title == "Book the flights")
        #expect(dated.dateExpression == "friday")
        // "after" inside a date phrase is a WHEN, not a wait: no blocker, whole title.
        let dayAfter = intent("pay the bill the day after tomorrow")
        #expect(dayAfter.title == "Pay the bill")
        #expect(dayAfter.blockerPhrase == nil)
        #expect(dayAfter.dateExpression == "day after tomorrow")
    }

    @Test("A named subject is the owner, and leaves the title; a spoken day-of-month is a date")
    func namedSubjectAndDayOfMonth() {
        func first(_ text: String) -> TaskIntent {
            HeuristicEngine.intent(from: Segmentation.items(from: text).first ?? text)
        }
        let maya = first("Maya needs to pick up her prescription before the pharmacy closes at 6")
        #expect(maya.personReference == "Maya")
        #expect(maya.title == "Pick up her prescription before the pharmacy closes at 6")
        // "the school needs to" names nobody; the words stay.
        #expect(first("the school needs to send the forms").title == "The school needs to send the forms")

        let table = first("Book a table for Sam's birthday on the 3rd of October")
        #expect(table.dateExpression == "3rd of october")
        #expect(table.title == "Book a table for Sam's birthday")
        #expect(IntentResolver.resolveDate(expression: table.dateExpression) != nil)

        // The date leaves and the verb it hung on goes with it.
        let permit = first("the parking permit renewal is due end of month")
        #expect(permit.title == "The parking permit renewal")
        #expect(permit.dateExpression == "end of month")
    }

    @Test("A hedged lead-in and a trailing justification leave the title; a bare month is a date")
    func hedgeReasonAndBareMonth() {
        func first(_ text: String) -> TaskIntent {
            HeuristicEngine.intent(from: Segmentation.items(from: text).first ?? text)
        }
        let gym = first("I should really cancel the gym membership, it's like 40 quid a month for nothing")
        #expect(gym.title == "Cancel the gym membership")
        #expect(first("book the venue, because the deposit is due").title == "Book the venue")
        // A comma that is not a reason stays (on the engine directly — the segmenter
        // splits a comma list before the engine ever sees it).
        #expect(HeuristicEngine.intent(from: "buy milk, eggs and bread").title == "Buy milk, eggs and bread")
        #expect(
            HeuristicEngine.intent(from: "call mom, then book the vet").title == "Call mom, then book the vet"
        )

        let passports = first("get the kids' passports sorted before the summer holidays in July")
        #expect(passports.dateExpression == "in july")
        #expect(passports.title == "Get the kids' passports sorted before the summer holidays")
        let due = IntentResolver.resolveDate(expression: passports.dateExpression)
        #expect(due != nil)
        if let due {
            let cal = Foundation.Calendar.current
            let comps = cal.dateComponents([.month, .day], from: due)
            #expect(comps.month == 7)
            #expect(comps.day == 1 || cal.component(.month, from: Foundation.Date()) == 7)
        }
        // A month as a topic is not a date.
        #expect(first("file the july invoice").dateExpression == nil)
    }

    @Test("The urgency phrase leaves the title's edge once it is the flag")
    func urgencyLeavesTheTitleEdge() {
        func intent(_ text: String) -> TaskIntent { HeuristicEngine.intent(from: text) }
        let oil = intent("oil change is overdue")
        #expect(oil.title == "Oil change")
        #expect(oil.isUrgent)
        #expect(intent("renew the car insurance asap").title == "Renew the car insurance")
        #expect(intent("urgent: call the bank").title == "Call the bank")
        #expect(intent("call the bank, it's urgent").title == "Call the bank")
        // Mid-line stays; a line that is only its urgency keeps its words.
        #expect(intent("sort the overdue library books").title == "Sort the overdue library books")
        #expect(intent("urgent").title == "Urgent")
        // Not urgent → untouched, even with an edge word the flag would have taken.
        #expect(intent("read the critical review").title == "Read the critical review")
    }

    // MARK: - End-to-end triage

    @Test("Triage turns a messy blob into structured intents")
    func triageProducesDrafts() async throws {
        let engine = HeuristicEngine()
        let blob = """
            renew my passport
            should I quit the side project
            oil change overdue
            """
        let intents = try await engine.triage(rawText: blob)
        #expect(intents.count == 3)
        #expect(intents.contains { $0.isJudgmentCall })
        #expect(intents.contains { $0.category == "Travel" })
        // Every intent resolves to a draft — and a draft carries no lifecycle position
        // at all. Creation only happens at Confirm, which is what stamps `.todo`.
        let drafts = IntentResolver.resolve(intents)
        #expect(drafts.count == intents.count)
    }
}
