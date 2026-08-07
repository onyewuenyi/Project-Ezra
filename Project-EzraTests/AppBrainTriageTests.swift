//
//  AppBrainTriageTests.swift
//  Project-EzraTests
//
//  The A1 contract: generation starts without waiting for retrieval, and the
//  retrieval set comes BACK from each parse so the rolling chain can hand it to
//  the next prompt. XCTest forces the heuristic engine, so these pin the
//  chain-carry plumbing — the on-device half (candidate-blind first prompt,
//  enrichment re-parse) is device-verified via -CaptureDiagnostics.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Triage run (A1: candidates ride the chain)")
struct AppBrainTriageTests {

    @Test("A parse returns its retrieval set for the next parse's prompt")
    func parseReturnsRetrievalSet() async {
        _ = TestStore.makeContext()
        let brain = AppBrain()
        let open = [OpenTaskSnapshot(id: UUID(), title: "Renew my passport before the trip")]

        let run = await brain.triage("renew my passport", openTasks: open)

        #expect(!run.drafts.isEmpty)
        #expect(run.candidates.contains { $0.title == "Renew my passport before the trip" })
        // Off-device the enrichment backstop never fires — there is no model to
        // re-prompt, and the heuristic ignores candidates entirely.
        #expect(!run.suggestsEnrichment)
    }

    @Test("A prepared candidate the fresh ranking dropped still reaches the resolver's guard")
    func preparedCandidateSurvivesRankingShift() async {
        _ = TestStore.makeContext()
        let brain = AppBrain()
        // Prepared from a previous parse; the fresh retrieval (empty open set) will
        // not re-surface it. The model could only have cited ids from its PROMPT, so
        // the anti-hallucination guard must keep seeing this entry.
        let stale = RetrievalCandidate(id: UUID(), title: "Old neighbour", facts: "", score: 0.5)

        let run = await brain.triage("call mom back", preparedCandidates: [stale])

        #expect(run.candidates.contains { $0.id == stale.id })
    }
}
