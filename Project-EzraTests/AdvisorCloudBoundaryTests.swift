//
//  AdvisorCloudBoundaryTests.swift
//  Project-EzraTests
//
//  **The Advisor's cloud arm may not carry the person's own words.**
//
//  Settings states, on the screen where the app asks to be believed: *"To prepare your
//  advice, only structured task information goes out — titles, dates and flags, never
//  your raw notes."* `DataBoundary`'s own design note explains why that sentence is load
//  bearing — capture parsing genuinely needs the verbatim words and judgment does not,
//  and that asymmetry is what makes the capture sentence acceptable at all.
//
//  Until 2026-09-20 the code did not keep it. `TaskAdvisorService` passed the cloud rung
//  the full facts block, which carries `NOTES:` (the person's free text), `THEY SAID:`
//  (their verbatim capture) and `WHY IT EXISTS:` — unclipped, because only the on-device
//  arm was being fitted to a context window. An explicit negative promise about a
//  transmission that was happening, found while writing the privacy policy from the code
//  rather than from the copy.
//
//  This is a grep of the PROMPT the provider would receive, because that is the artifact
//  the promise is about. The on-device arm is deliberately not constrained: nothing
//  leaves the device there, and a reading that can see the person's notes is a better
//  reading.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Advisor · the cloud arm carries no free text")
struct AdvisorCloudBoundaryTests {

    /// Facts with something identifiable in every free-text field, so a leak is obvious.
    private var loaded: TaskAdvisorFacts {
        var facts = TaskAdvisorFacts(
            id: UUID(), title: "Renew my passport",
            notes: "NOTESLEAK the old one is in the drawer with Maya's birth certificate",
            category: "Admin",
            rawCapture: "CAPTURELEAK renew my passport before the Lagos trip in October",
            reasoning: "REASONLEAK it expires and the trip is booked", status: .todo,
            effortMinutes: 60, dueDate: nil, overdueDays: nil, daysUntilDue: nil,
            isUrgent: false, needsDecision: false, isJudgmentCall: false, decisionShaped: false,
            deferralCount: 0, quietDays: 0, blockerTitles: [], blockerIDs: [],
            dependentTitles: [], childIDs: [], openStepTitles: [], stepLabel: nil,
            parentTitle: nil, diagnosis: nil, breakdownReason: nil, workIntent: nil)
        facts.advisorPreferences = ["PREFLEAK they dislike being offered a breakdown"]
        facts.relatedLines = ["Book flights for the trip"]
        return facts
    }

    /// The four things the sentence promises never go out.
    private let forbidden = ["NOTESLEAK", "CAPTURELEAK", "REASONLEAK", "PREFLEAK"]

    @Test("The bare facts carry none of the person's own words")
    func bareFactsAreClean() {
        let prompt = loaded.trimmed(to: .bare).promptBlock
        for leak in forbidden {
            #expect(!prompt.contains(leak), "\(leak) reached the bare facts block")
        }
        // …and it is still worth sending: the structured half survives.
        #expect(prompt.contains("Renew my passport"))
    }

    /// The guard that would have caught the drift. `.bare` being correct is not enough —
    /// the service has to be the thing that asks for it, on the cloud rung, and that
    /// coupling is a single expression which was wrong for as long as it existed.
    @Test("The service sends the bare facts on the cloud rung, and only there")
    func theServiceTrimsBeforeTheProvider() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Project-Ezra/AI/TaskAdvisorService.swift"),
            encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }

        #expect(
            code.contains { $0.contains("rung == .cloud ? facts.trimmed(to: .bare)") },
            """
            The cloud rung must be handed the BARE facts. Passing `facts` whole sends \
            NOTES, THEY SAID and WHY IT EXISTS to the provider, which the privacy screen \
            promises never happens.
            """)
    }

    /// The full block is what the ON-DEVICE arm gets, and it should keep everything —
    /// this is the half of the invariant that stops someone "fixing" the leak by
    /// stripping the facts everywhere and quietly making every reading worse.
    @Test("The on-device arm still sees everything the person wrote")
    func theLocalArmKeepsTheWords() {
        let prompt = loaded.promptBlock
        for leak in forbidden {
            #expect(prompt.contains(leak), "\(leak) should reach the on-device reading")
        }
    }
}
