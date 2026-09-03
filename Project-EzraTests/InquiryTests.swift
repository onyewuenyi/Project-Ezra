//
//  InquiryTests.swift
//  Project-EzraTests
//
//  The primitive, tested as a primitive: a stub scope that is neither the task nor the
//  household proves the loop is scope-agnostic — floor before model, the ledger written
//  where the routing lands, continuity on a moved fingerprint, per-key isolation,
//  verified citations. If a third scope ever behaves differently from these two, the
//  difference is in the scope, not the loop.
//

import Foundation
import Testing

@testable import Project_Ezra

/// A scope with a floor for one question, a context block, and a fingerprint the test
/// can move.
struct StubScope: InquiryScope {
    let key: String
    let fingerprint: Int
    let shown: [InquiryCitable]

    var instructions: String { "RULES\n\nPICTURE \(fingerprint)" }

    static let changedNoun = "the picture"
    var feature: ModelFeature { .advisorChat }
    var config: CapabilityProfiles.Config {
        CapabilityProfiles.Config(temperature: 0.4, reasoningLevel: nil, maximumResponseTokens: 100)
    }
    static let maxLines = 3
    var openerText: String? = nil
    func opener() -> InquiryAnswer? { openerText.map { InquiryAnswer(text: $0, citedTaskIDs: shown.map(\.id)) } }
    static let prewarmPrefix = "QUESTION:"

    func floor(for question: String) -> InquiryAnswer? {
        question.lowercased().contains("count")
            ? InquiryAnswer(text: "\(shown.count) things.", citedTaskIDs: shown.map(\.id)) : nil
    }

    func context(for question: String) -> InquiryContext {
        InquiryContext(block: "SHOWN:\n" + shown.map(\.title).joined(separator: "\n"), shown: shown)
    }

    func starterQuestions() -> [String] { ["Count them?"] }
}

@MainActor
@Suite("Inquiry — the one loop")
struct InquiryTests {

    private let a = InquiryCitable(id: UUID(), title: "Renew the passport")
    private let b = InquiryCitable(id: UUID(), title: "Book the flights")

    private func scope(key: String = "k", fingerprint: Int = 1) -> StubScope {
        StubScope(key: key, fingerprint: fingerprint, shown: [a, b])
    }

    private func store(
        available: Bool = true, ledger: IntelligenceLedger? = nil,
        responder: @escaping InquiryStore<StubScope>.Responder
    ) -> InquiryStore<StubScope> {
        InquiryStore<StubScope>(
            responder: responder, isModelAvailable: { available },
            ledger: ledger ?? IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    @Test("Rung 0 answers before the model may: a floor question never reaches the responder")
    func floorFirst() {
        var calls = 0
        let store = store { _ in
            calls += 1
            return .success("model")
        }
        store.ask("Count them", scope: scope())
        let messages = store.messages(key: "k")
        #expect(messages.count == 2)
        #expect(messages[1].state == .sent)
        #expect(messages[1].text == "2 things.")
        #expect(messages[1].citedTaskIDs == [a.id, b.id])
        #expect(store.lastRoute(key: "k") == .floor)
        #expect(calls == 0)
        #expect(!store.isReplying(key: "k"))
    }

    @Test("The ledger is written where the routing lands: .facts for the floor, .onDevice for the model")
    func ledgerAtTheDecision() async {
        let ledger = IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = store(ledger: ledger) { _ in .success("Because.") }
        store.ask("Count them", scope: scope())
        store.ask("Why?", scope: scope())
        await store.awaitPendingReplies(key: "k")
        #expect(ledger.counts[.chat]?[.facts] == 1)
        #expect(ledger.counts[.chat]?[.onDevice] == 1)
    }

    @Test("A model reply lands validated and cited against what the turn showed — never beyond it")
    func modelReplyCited() async {
        var seen: InquiryTurn<StubScope>?
        let store = store { turn in
            seen = turn
            return .success("Renew the passport first; the flights can wait. Also invent The Garage Roof.")
        }
        store.ask("Why?", scope: scope())
        #expect(store.messages(key: "k")[1].state == .pending)
        #expect(store.lastRoute(key: "k") == .model)
        await store.awaitPendingReplies(key: "k")
        let reply = store.messages(key: "k")[1]
        #expect(reply.state == .sent)
        // "Renew the passport" is named in order → cited. "the flights can wait" is a near-miss
        // of "Book the flights" (no "book") → NOT cited. "The Garage Roof" was never shown → cannot be.
        #expect(reply.citedTaskIDs == [a.id])
        #expect(seen?.context.shown.count == 2)
        #expect(seen?.prompt.hasPrefix("SHOWN:") == true)
        #expect(seen?.prompt.hasSuffix("QUESTION: Why?") == true)
        #expect(seen?.continuity == nil)
    }

    @Test("A moved fingerprint carries the continuity digest into the next turn; a held one does not")
    func continuityOnMove() async {
        var seen: [InquiryTurn<StubScope>] = []
        let store = store { turn in
            seen.append(turn)
            return .success("Answer.")
        }
        store.ask("Why?", scope: scope(fingerprint: 1))
        await store.awaitPendingReplies(key: "k")
        store.ask("Still?", scope: scope(fingerprint: 1))
        await store.awaitPendingReplies(key: "k")
        store.ask("And now?", scope: scope(fingerprint: 2))
        await store.awaitPendingReplies(key: "k")
        #expect(seen.count == 3)
        #expect(seen[1].continuity == nil)
        #expect(
            seen[2].continuity == "They asked: Why?\nYou said: Answer.\nThey asked: Still?\nYou said: Answer."
        )
        #expect(seen[2].prompt.hasPrefix("EARLIER IN THIS CONVERSATION (the picture has changed since):"))
    }

    @Test("Conversations are per key; clearing one leaves the other")
    func perKey() async {
        let store = store { _ in .success("x") }
        store.ask("Why?", scope: scope(key: "one"))
        store.ask("Why?", scope: scope(key: "two"))
        await store.awaitPendingReplies(key: "one")
        await store.awaitPendingReplies(key: "two")
        #expect(store.messages(key: "one").count == 2)
        #expect(store.messages(key: "two").count == 2)
        store.clear(key: "one")
        #expect(store.messages(key: "one").isEmpty)
        #expect(store.messages(key: "two").count == 2)
        #expect(store.lastRoute(key: "one") == nil)
    }

    @Test("No model → an honest non-retryable slot; a failed reply is retryable in place")
    func failures() async {
        let off = store(available: false) { _ in .success("never") }
        off.ask("Why?", scope: scope())
        await off.awaitPendingReplies(key: "k")
        #expect(off.messages(key: "k")[1].state == .failed(retryable: false))

        var attempt = 0
        let flaky = store { _ in
            attempt += 1
            return attempt == 1 ? .failed("boom") : .success("Fine.")
        }
        flaky.ask("Why?", scope: scope())
        await flaky.awaitPendingReplies(key: "k")
        let failed = flaky.messages(key: "k")
        #expect(failed[1].state == .failed(retryable: true))
        flaky.retry(replyID: failed[1].id, scope: scope())
        await flaky.awaitPendingReplies(key: "k")
        #expect(flaky.messages(key: "k")[1].text == "Fine.")
        #expect(flaky.messages(key: "k")[1].state == .sent)
    }

    @Test("The reply clamp is the scope's: a list is cut at the scope's maxLines")
    func scopeClamp() async {
        let store = store { _ in .success("Steps:\n1. A\n2. B\n3. C\n4. D") }
        store.ask("How?", scope: scope())
        await store.awaitPendingReplies(key: "k")
        #expect(store.messages(key: "k")[1].text.components(separatedBy: "\n").count == StubScope.maxLines)
    }

    @Test("The unasked turn: open() seats the scope's opener once per fingerprint, and never over a question")
    func openerOnce() async {
        let first = store { _ in .success("x") }
        var scope = scope(fingerprint: 1)
        scope.openerText = "Two things deserve you first."
        first.open(scope: scope)
        #expect(first.messages(key: "k").count == 1)
        #expect(first.messages(key: "k")[0].role == .advisor)
        #expect(first.messages(key: "k")[0].citedTaskIDs.count == 2)
        #expect(first.lastRoute(key: "k") == .floor)
        first.open(scope: scope)
        #expect(first.messages(key: "k").count == 1)
        var moved = self.scope(fingerprint: 2)
        moved.openerText = "One thing deserves you first."
        first.open(scope: moved)
        #expect(first.messages(key: "k").count == 1)
        #expect(first.messages(key: "k")[0].text == "One thing deserves you first.")
        first.ask("Why?", scope: moved)
        await first.awaitPendingReplies(key: "k")
        var later = self.scope(fingerprint: 3)
        later.openerText = "Later."
        first.open(scope: later)
        #expect(first.messages(key: "k").count == 3)
        let quiet = store { _ in .success("x") }
        quiet.open(scope: self.scope(key: "q"))
        #expect(quiet.messages(key: "q").isEmpty)
    }

    @Test("Both shipped scopes are conformances, not copies: their turns are the shared type")
    func shippedScopesAreConformances() {
        #expect(TaskAdvisorChatTurn.self == InquiryTurn<TaskInquiryScope>.self)
        #expect(HouseholdChatTurn.self == InquiryTurn<HouseholdInquiryScope>.self)
        #expect(TaskAdvisorChatStore.self == InquiryStore<TaskInquiryScope>.self)
        #expect(HouseholdChatStore.self == InquiryStore<HouseholdInquiryScope>.self)
    }
}
