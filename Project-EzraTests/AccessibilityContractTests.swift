//
//  AccessibilityContractTests.swift
//  Project-EzraTests
//
//  **The rules this app states about itself have to hold for VoiceOver too.**
//
//  The app is well accessorised — around 146 accessibility modifiers across 32 files,
//  and a sweep for glyph-only controls with no label returns nothing. What an audit on
//  2026-09-20 found instead were OPERABILITY gaps, and the worst of them was a product
//  invariant that held for the eyes and broke for everyone else: "not yours to advance"
//  removed the swipe and inerted the long-press menu on someone else's task, while the
//  row's accessibility actions still offered "Complete".
//
//  These are greps, because each property is the SHAPE of a call site rather than a
//  value anything returns. A SwiftUI accessibility tree is not reachable from a unit
//  test; the call site is, and the call site is where all four of these went wrong.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Accessibility contract · the invariants hold for VoiceOver too")
struct AccessibilityContractTests {

    private func code(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra").appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
    }

    /// The one that was a correctness break rather than a gap. `interactive` is exactly
    /// `!resolved && recommendedAction != nil` — the rule the leading swipe and the
    /// long-press menu already follow — so gating the spoken actions on it is what makes
    /// all four channels agree about whose task this is.
    @Test("A row offers Complete only when it offers the swipe and the menu")
    func theRowsActionsFollowTheOwnershipRule() throws {
        let lines = try code("Features/Tasks/TaskRow.swift")
        for action in ["Button(\"Complete\")", "Button(\"Cancel Task\")"] {
            let site = try #require(lines.first { $0.contains(action) })
            #expect(
                site.contains("interactive,"),
                """
                \(action) is offered to VoiceOver without checking `interactive`. On \
                someone else's task the swipe is absent and the menu is inert by design; \
                an unguarded action list advances a task the sighted UI refuses to.
                """)
        }
    }

    /// The leading swipe IS `performRecommendedAction` — Start / Reopen / That's mine /
    /// Unblock — and these rows are in a `LazyVStack`, not a `List`, so whether SwiftUI
    /// exposes `.swipeActions` as custom actions here is undocumented. Declaring them
    /// explicitly beside the swipe means it does not matter.
    @Test("The swipe contract has a spoken equivalent, declared beside the swipe")
    func theSwipeHasAnAccessibilityEquivalent() throws {
        let lines = try code("Features/Tasks/TaskLaneList.swift")
        #expect(lines.contains { $0.contains(".accessibilityActions {") })
        #expect(
            lines.contains { $0.contains("Button(action.title)") },
            "the leading swipe's own verb must be reachable without the gesture")
    }

    /// Undo is the app's only reversal affordance for a completion, a cancel, an AI
    /// structural act and the grouping sweep. The pill announces its whole sentence and
    /// then dismissed on a four-second timer — about as long as the announcement takes
    /// to speak, so the button was gone before it could be reached.
    @Test("Undo outlives its own announcement")
    func undoWaitsLongEnoughToReach() throws {
        let lines = try code("Features/Components/UndoNoticeView.swift")
        #expect(
            lines.contains { $0.contains("UIAccessibility.isVoiceOverRunning") },
            "the dwell must lengthen when the message has to be spoken before it is acted on")
    }

    /// `.opacity(0)` hides a view from the eyes and NOT from VoiceOver. Both of these
    /// exist to reserve line height, and both were being read aloud — one of them a
    /// warning about the five-second auto-submit, permanently true-sounding.
    @Test("Views faded to reserve height leave the accessibility tree with the fade")
    func fadedSpacersAreHidden() throws {
        let lines = try code("Features/Capture/ComposerView.swift")
        #expect(lines.contains { $0.contains(".accessibilityHidden(!counting)") })
        #expect(lines.contains { $0.contains(".accessibilityHidden(statusText.isEmpty)") })
    }

    /// The sheet opens into a live microphone with no transcript and a hidden orb. If
    /// nothing announces it, nothing tells the person the mic is hot.
    @Test("Opening into listening, and the wait after Done, are both announced")
    func theSilentBeatsSpeak() throws {
        let lines = try code("Features/Capture/ComposerView.swift")
        #expect(lines.contains { $0.contains("announcePhase(newPhase)") })
        let body = lines.joined(separator: "\n")
        #expect(body.contains("\"Listening. Say what's on your mind"))
        #expect(body.contains("\"Reading what you said.\""))
    }

    /// Selection carried by font weight, text colour and a capsule is selection VoiceOver
    /// cannot see. Three scopes read as three identical buttons.
    @Test("The ownership scope says which one is selected")
    func theScopePillsCarryTheSelectedTrait() throws {
        let lines = try code("Features/Tasks/TasksHomeView.swift")
        #expect(lines.contains { $0.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])") })
    }

    /// The detail pager gives its horizontal swipe named actions; the deck is the same
    /// interaction and gave none.
    @Test("Both horizontal pagers can be paged without the gesture")
    func bothPagersOfferNamedActions() throws {
        for path in ["Features/Tasks/TaskDeckView.swift", "Features/Detail/TaskDetailPager.swift"] {
            let lines = try code(path)
            #expect(
                lines.contains { $0.contains("accessibilityAction(named: \"Next task\")") },
                "\(path) has no spoken way to page")
        }
    }
}
