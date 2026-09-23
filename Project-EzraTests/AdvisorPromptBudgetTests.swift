//
//  AdvisorPromptBudgetTests.swift
//  Project-EzraTests
//
//  The trim ladder that fits the Advisor's facts into the phone's 4096-token window.
//  Pure over the facts value: each level gives up exactly what it says, the fingerprint
//  never moves, and the clip cuts on a word. The token count that drives the ladder is
//  the model's own and is exercised on device, not here.
//

import Foundation
import FoundationModels
import Testing

@testable import Project_Ezra

@Suite("Advisor — prompt budget")
@MainActor
struct AdvisorPromptBudgetTests {

    private static let id = UUID()

    private var facts: TaskAdvisorFacts {
        var f = TaskAdvisorFacts(
            id: Self.id, title: "Renew passport", notes: String(repeating: "note ", count: 100),
            category: "Admin", rawCapture: String(repeating: "said ", count: 100),
            reasoning: String(repeating: "why ", count: 100), status: .todo,
            effortMinutes: 60, dueDate: nil, overdueDays: nil, daysUntilDue: nil,
            isUrgent: false, needsDecision: false, isJudgmentCall: false, decisionShaped: false,
            deferralCount: 0, quietDays: 0, blockerTitles: [], blockerIDs: [],
            dependentTitles: [], childIDs: [], openStepTitles: [], stepLabel: nil,
            parentTitle: nil, diagnosis: nil, breakdownReason: nil, workIntent: nil)
        f.relatedLines = ["Book flights", "Find the birth certificates"]
        f.advisorPreferences = ["declines steps"]
        return f
    }

    @Test("Full is the identity")
    func fullIsIdentity() {
        #expect(facts.trimmed(to: .full) == facts)
    }

    @Test("Each level strictly shortens the prompt, in ladder order")
    func eachLevelShortens() {
        let lengths = TaskAdvisorFacts.TrimLevel.allCases.map { facts.trimmed(to: $0).promptBlock.count }
        for (shorter, longer) in zip(lengths.dropFirst(), lengths) {
            #expect(shorter < longer, "\(lengths)")
        }
    }

    @Test("The ladder gives up what it names, and nothing before its turn")
    func ladderOrder() {
        let noRelated = facts.trimmed(to: .noRelated)
        #expect(noRelated.relatedLines.isEmpty)
        #expect(noRelated.rawCapture == facts.rawCapture)

        let shortQuotes = facts.trimmed(to: .shortQuotes)
        #expect(shortQuotes.rawCapture.count <= TaskAdvisorFacts.quoteClip + 1)
        #expect(shortQuotes.reasoning.count <= TaskAdvisorFacts.quoteClip + 1)
        #expect(shortQuotes.notes == facts.notes)

        let shortNotes = facts.trimmed(to: .shortNotes)
        #expect((shortNotes.notes?.count ?? 0) <= TaskAdvisorFacts.quoteClip + 1)

        let bare = facts.trimmed(to: .bare)
        #expect(bare.rawCapture.isEmpty && bare.reasoning.isEmpty && bare.notes == nil)
        #expect(bare.advisorPreferences.isEmpty)
        #expect(bare.title == facts.title)
        #expect(bare.promptBlock.contains("TASK: Renew passport"))
    }

    @Test("The levels that spare the notes hold the fingerprint; the notes levels move it")
    func fingerprintHoldsUntilNotes() {
        for level in [TaskAdvisorFacts.TrimLevel.full, .noRelated, .shortQuotes] {
            #expect(facts.trimmed(to: level).fingerprint == facts.fingerprint)
        }
        // `notes` is a meaningful fact, so clipping it IS a different fingerprint — the
        // reason the service fits the prompt alone and keys everything else on the
        // original facts.
        #expect(facts.trimmed(to: .shortNotes).fingerprint != facts.fingerprint)
        #expect(facts.trimmed(to: .bare).fingerprint != facts.fingerprint)
    }

    @Test("The clip cuts on a word and marks the cut; short text is untouched")
    func clipCutsOnAWord() {
        #expect(TaskAdvisorFacts.clip("short", to: 10) == "short")
        let clipped = TaskAdvisorFacts.clip("find the old passports before the appointment", to: 20)
        #expect(clipped == "find the old…")
        #expect(clipped.count <= 21)
    }

    @Test("A context overflow is recognised on the GA vocabulary")
    func overflowLabel() {
        let overflow = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: "too long"))
        #expect(InquiryService.isContextOverflow(overflow))
        #expect(!InquiryService.isContextOverflow(CancellationError()))
    }
}
