//
//  HeuristicEngineTests.swift
//  Project-EzraTests
//
//  Covers the deterministic fallback engine: item splitting, word-boundary
//  categorization (the "daycare ≠ Car" regression), judgment/blocked detection,
//  and end-to-end triage. This engine is what the simulator always runs, so its
//  behavior is the one we can pin down without a device.
//

import Testing
@testable import Project_Ezra

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

    @Test("A judgment intent resolves to ask-tier, Needs Decision, landing in the Inbox")
    func judgmentDraftRouting() {
        let draft = IntentResolver.resolve(
            HeuristicEngine.intent(from: "should I keep paying for the gym"))
        #expect(draft.autonomy == .ask)
        #expect(draft.proposedStatus == .inbox)
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
        // The resolver stamps every creation into the Inbox — always-confirm.
        let drafts = IntentResolver.resolve(intents)
        #expect(drafts.allSatisfy { $0.proposedStatus == .inbox })
    }
}
