//
//  AppBrainTriageTests.swift
//  Project-EzraTests
//
//  The candidate package: what the model is SHOWN, and therefore which existing tasks it
//  is able to cite as a duplicate or a parent.
//
//  These used to pin the A1 contract as "generation never waits for retrieval, and the
//  retrieval set comes BACK for the next parse's prompt". Both halves were true and the
//  feature was dead anyway, which is the reason this file's framing changed: the shipped
//  composer does ONE parse, so there is never a next one, and no caller passed
//  `preparedCandidates` at all. Every production prompt went out candidate-blind, the
//  model was never shown an id it could cite, and `IntentResolver.edgeProposals` dropped
//  everything for want of a candidate to match. The old assertion here — that the
//  enrichment backstop does NOT fire off-device — was green and describing a flag whose
//  consumer had already been deleted.
//
//  So the thing worth pinning is not that candidates come back, but that they GO OUT.
//  XCTest forces the heuristic engine, which ignores candidates entirely, so the prompt
//  assertion is made against `FoundationModelsEngine.prompt(for:context:)` directly —
//  the point of use, which is the only place the question is answerable off-device.
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

        let run = await brain.triage("renew my passport", openTasks: open, route: .local)

        #expect(!run.drafts.isEmpty)
        #expect(run.candidates.contains { $0.title == "Renew my passport before the trip" })
    }

    @Test("A populated candidate package actually reaches the model's prompt")
    func candidatesReachThePrompt() {
        // The assertion whose absence let capture-time duplicate detection ship inert for
        // as long as it did. Everything downstream — the tiering, the suppression check,
        // the merge at commit — is exercised by tests that hand it candidates directly,
        // so all of it stayed green while the one link that had to hold in production
        // (the model being SHOWN an id it could cite) was never checked anywhere.
        let target = RetrievalCandidate(
            id: UUID(), title: "Renew my passport", facts: "Travel · due Friday", score: 0.9)
        let context = TriageContext(candidates: [target])

        let prompt = FoundationModelsEngine.prompt(for: "renew the passport", context: context)

        #expect(prompt.contains(target.id.uuidString), "the model cannot cite an id it never saw")
        #expect(prompt.contains("CANDIDATES"))
        #expect(prompt.contains(target.title))
    }

    @Test("An empty package leaves the prompt clean rather than announcing an empty list")
    func emptyPackageAddsNothing() {
        // The honest blind case — retrieval missed its bound, or there is nothing open.
        // An empty CANDIDATES header would invite the model to cite from a list that
        // isn't there, which is the one thing the anti-hallucination guard can't fix
        // cheaply: it drops the citation, but the task keeps whatever framing the
        // hallucination gave it.
        let prompt = FoundationModelsEngine.prompt(for: "renew the passport", context: TriageContext())
        #expect(!prompt.contains("CANDIDATES"))
    }

    @Test("A prepared candidate the fresh ranking dropped still reaches the resolver's guard")
    func preparedCandidateSurvivesRankingShift() async {
        _ = TestStore.makeContext()
        let brain = AppBrain()
        // Prepared from a previous parse; the fresh retrieval (empty open set) will
        // not re-surface it. The model could only have cited ids from its PROMPT, so
        // the anti-hallucination guard must keep seeing this entry.
        let stale = RetrievalCandidate(id: UUID(), title: "Old neighbour", facts: "", score: 0.5)

        let run = await brain.triage("call mom back", preparedCandidates: [stale], route: .local)

        #expect(run.candidates.contains { $0.id == stale.id })
    }
}
