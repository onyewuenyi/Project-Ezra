//
//  ShellSurfaceTests.swift
//  Project-EzraTests
//
//  The shell's shape since the Ask-home swap (2026-09-23), pinned by grep because each
//  property is the shape of a call site and no unit test can reach a SwiftUI stack:
//  Ask is the root of the ONE `NavigationStack`, the list and the roster are its pushed
//  destinations, neither pushed page carries a stack of its own, the home's bar carries
//  the orb, and the two events the swap is judged on fire from a person's tap.
//

import Foundation
import Testing

@Suite("Shell — Ask at the root, Tasks one push away")
struct ShellSurfaceTests {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Project-Ezra")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Ask is the root; Tasks is a sheet with its own surfaces host")
    func askIsTheRootAndTasksIsASheet() throws {
        let shell = try source("Features/Root/RootTabView.swift")
        #expect(shell.contains("NavigationStack {\n                HouseholdChatView()"))
        #expect(
            shell.contains(
                ".sheet(item: $tasksPreset, onDismiss: { surfaces.presentCommitNotice(brain: brain) }) {"))
        #expect(!shell.contains(".sheet(isPresented: $showAsk)"), "Ask is the home, never a sheet again")
        #expect(
            !shell.contains("navigationDestination(for:"), "the list is a sheet, not a push (Back faulted)")
        // Each context mounts the host once, with the orb only where the home's bar is not.
        #expect(
            shell.contains("controller: surfaces, showsOrb: false, coveredAbove: showOnboarding || showTasks")
        )
        #expect(shell.contains("controller: surfaces, showsOrb: true,"))
    }

    @Test("Neither the list, the home nor the roster carries a NavigationStack of its own")
    func noNestedStacks() throws {
        for path in [
            "Features/Tasks/TasksHomeView.swift", "Features/Chat/HouseholdChatView.swift",
            "Features/Household/HouseholdRosterView.swift",
        ] {
            let lines = try source(path).split(separator: "\n")
            let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            // A preview may wrap itself; the body may not.
            let body = code.prefix { !$0.contains("#Preview") }
            #expect(!body.contains { $0.contains("NavigationStack") }, "\(path) nests a stack in its host's")
        }
    }

    @Test("The home's composer bar carries the capture orb; the surfaces host owns every sheet")
    func theHomeBarCarriesTheOrb() throws {
        let home = try source("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains("onCapture: openCapture,"))
        let bar = try source("Features/Chat/ChatComponents.swift")
        #expect(bar.contains("if let onCapture {\n                CaptureOrbButton("))
        let host = try source("Features/Root/ShellSurfaces.swift")
        for surface in ["ComposerView(", "ActivityView()", "SettingsView()"] {
            #expect(host.contains(surface), "\(surface) is not presented by the host")
        }
        // Nothing else presents them: one definition, one instance per context.
        let list = try source("Features/Tasks/TasksHomeView.swift")
        #expect(!list.contains("SettingsView()") && !list.contains("ActivityView()"))
        #expect(!list.contains("navigationDestination"), "the roster push belongs to the sheet's stack")
    }

    @Test("The two events the swap is judged on fire from a person's tap, not a seam")
    func eventsFireFromTheTap() throws {
        let home = try source("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains("Telemetry.log(.tasksOpened)"))
        #expect(home.contains(".askAsked(scope: .household,"))
        let taskChat = try source("Features/Advisor/TaskAdvisorChatView.swift")
        #expect(taskChat.contains(".askAsked(scope: .task,"))
        let shell = try source("Features/Root/RootTabView.swift")
        #expect(!shell.contains("Telemetry.log(.tasksOpened)"), "the shell's action is what the seams call")
        let store = try source("AI/Inquiry.swift")
        #expect(!store.contains("askAsked"), "the store answers seams too; the view knows a person asked")
    }

    @Test("Every seam the list reads is one the shell presents the sheet for")
    func listSeamsArePresented() throws {
        let shell = try source("Features/Root/RootTabView.swift")
        for arg in [
            "-OpenTasks", "-OpenTaskDetail", "-FilterStatus", "-FilterCategory", "-MyTasksTab",
            "-DeckPage", "-OpenSearch", "-CompleteListRow", "-TasksPreset",
        ] {
            #expect(shell.contains("\"\(arg)\""), "\(arg) is read on the list and never presented")
        }
    }

    /// The grouping row lives on the HOME since the calm pass (2026-09-23); its seams
    /// opening the Tasks sheet hid the very row they seed (2026-09-26).
    @Test("The grouping seams stay on the home, where the row is")
    func groupingSeamsStayHome() throws {
        let shell = try source("Features/Root/RootTabView.swift")
        guard let start = shell.range(of: "static let tasksSurfaceArgs"),
            let end = shell.range(of: "]", range: start.upperBound..<shell.endIndex)
        else {
            Issue.record("the seam list is gone")
            return
        }
        let list = String(shell[start.upperBound..<end.lowerBound])
        #expect(!list.contains("\"-SeedGroupProposal\""))
        #expect(!list.contains("\"-AcceptGroupProposal\""))
    }
}
