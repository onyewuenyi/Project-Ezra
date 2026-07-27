//
//  ContextRetrievalTests.swift
//  Project-EzraTests
//
//  ContextRetrieval is the deterministic, pre-model substrate behind Capture Graph
//  Awareness. These pin near-duplicate ranking, the embedding-nil lexical fallback (the
//  path the simulator runs), the cap, and determinism. (Rejected-pair suppression is
//  the resolver's job now — see `IntentResolverTests` — retrieval stays a pure ranking.)
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Context retrieval")
struct ContextRetrievalTests {

    private func snap(
        _ id: UUID, _ title: String, category: String = "Admin", daysAgo: Double = 0
    ) -> OpenTaskSnapshot {
        OpenTaskSnapshot(
            id: id, title: title, category: category,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400))
    }

    @Test("Detached execution produces byte-identical output to the synchronous call")
    func detachedEqualsSynchronous() async {
        // The ranking went `nonisolated` so `AppBrain.triage` can run it off the main
        // actor. The move must be invisible: same input → same output, on any executor.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tasks = [
            snap(UUID(), "Renew my passport before the trip", category: "Travel"),
            snap(UUID(), "Buy groceries for the week"),
            snap(UUID(), "Call the dentist about the crown"),
        ]
        let onMain = ContextRetrieval.candidates(matching: "renew passport", among: tasks, now: now)
        let detached = await Task.detached {
            ContextRetrieval.candidates(matching: "renew passport", among: tasks, now: now)
        }.value
        #expect(onMain == detached)
    }

    @Test("Ranks a near-duplicate above unrelated tasks")
    func nearDupeRanksTop() {
        let dupID = UUID()
        let tasks = [
            snap(UUID(), "Buy groceries for the week"),
            snap(dupID, "Renew my passport before the trip", category: "Travel"),
            snap(UUID(), "Call the dentist"),
        ]
        let result = ContextRetrieval.candidates(matching: "renew passport", among: tasks)
        #expect(result.first?.id == dupID)
    }

    @Test("Lexical overlap ranks the right neighbour even without an embedding model")
    func lexicalFallback() {
        let dupID = UUID()
        let tasks = [snap(UUID(), "water the plants"), snap(dupID, "pay the water bill")]
        let result = ContextRetrieval.candidates(matching: "pay water bill", among: tasks)
        #expect(result.first?.id == dupID)
    }

    @Test("Caps at maxCandidates")
    func caps() {
        let tasks = (0..<30).map { snap(UUID(), "renew passport copy \($0)") }
        let result = ContextRetrieval.candidates(matching: "renew passport", among: tasks)
        #expect(result.count <= ContextRetrieval.maxCandidates)
    }

    @Test("Deterministic: same input → identical output")
    func deterministic() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tasks = (0..<8).map { snap(UUID(), "task about the passport number \($0)") }
        let a = ContextRetrieval.candidates(matching: "passport", among: tasks, now: now)
        let b = ContextRetrieval.candidates(matching: "passport", among: tasks, now: now)
        #expect(a == b)
    }

    @Test("Unrelated tasks fall below the relevance floor")
    func floorDropsNoise() {
        let tasks = [snap(UUID(), "quantum chromodynamics seminar")]
        let result = ContextRetrieval.candidates(matching: "buy milk", among: tasks)
        #expect(result.isEmpty)
    }
}
