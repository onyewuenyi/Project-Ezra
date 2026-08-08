//
//  CaptureConversationTests.swift
//  Project-EzraTests
//
//  The continuous session's TURN CONTRACT — the pure half a sim can verify. The
//  session itself needs the on-device model (device A/B via -CaptureDiagnostics);
//  what must hold regardless: a grown ramble sends only its new words, a revision
//  re-sends everything, a failed turn never advances the covered baseline (that
//  invariant lives in `triage` and is enforced by construction — covered moves
//  only after `collect()` returns), and the candidate block renders the same
//  package the single-use prompt carried.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureConversationTests {

    @Test("First words are an initial turn with the standard prompt head")
    func initialTurn() {
        let turn = CaptureConversation.turn(from: "", to: "renew my passport")
        #expect(turn == .initial("renew my passport"))
        let prompt = CaptureConversation.prompt(for: turn)
        #expect(prompt.hasPrefix(FoundationModelsEngine.promptHead))
        #expect(prompt.contains("renew my passport"))
    }

    @Test("A grown ramble sends ONLY the new words")
    func continuationSendsSuffixOnly() {
        let covered = "renew my passport"
        let current = "renew my passport and then call mom about thanksgiving"
        let turn = CaptureConversation.turn(from: covered, to: current)
        #expect(turn == .continuation(suffix: " and then call mom about thanksgiving"))

        let prompt = CaptureConversation.prompt(for: turn)
        #expect(prompt.contains("call mom about thanksgiving"))
        #expect(!prompt.contains("renew my passport"))  // the delta, not the ramble
        #expect(prompt.contains("complete updated task list"))  // never additive-only
    }

    @Test("An edit to earlier words falls back to a full-text revision turn")
    func revisionResendsEverything() {
        let covered = "renew my passport and call mom"
        let current = "renew both passports and call mom"
        let turn = CaptureConversation.turn(from: covered, to: current)
        #expect(turn == .revision(current))
        #expect(CaptureConversation.prompt(for: turn).contains("renew both passports"))
    }

    @Test("The candidate block matches the single-use prompt's package contract")
    func candidateBlockContract() {
        let id = UUID()
        let block = CaptureConversation.CaptureProfile.candidateBlock([
            RetrievalCandidate(id: id, title: "Renew passport", facts: "due soon", score: 0.9)
        ])
        #expect(block.contains(id.uuidString))
        #expect(block.contains("Renew passport"))
        #expect(block.contains("ONLY valid ids"))
        #expect(CaptureConversation.CaptureProfile.candidateBlock([]).isEmpty)
    }

    @Test("The continuous contract demands the complete list every turn")
    func contractDemandsCompleteList() {
        #expect(CaptureConversation.continuousContract.contains("complete"))
        #expect(CaptureConversation.continuousContract.contains("never only the new words"))
    }
}
