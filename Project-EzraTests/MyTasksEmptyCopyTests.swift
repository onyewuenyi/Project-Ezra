//
//  MyTasksEmptyCopyTests.swift
//  Project-EzraTests
//
//  The empty list's words, by situation. The one that matters most is the first screen
//  a new person sees after onboarding: alone in the app, they must not be told that
//  nothing is "assigned" to them.
//

import Testing

@testable import Project_Ezra

@Suite("My Tasks — empty copy")
@MainActor
struct MyTasksEmptyCopyTests {

    @Test("Alone in the app, the empty list is about capture, never assignment")
    func soloIsAboutCapture() {
        let copy = AssignedSectionsView.emptyCopy(
            scope: .assigned, solo: true, searching: false, filteredMessage: nil)
        #expect(copy.title == "Nothing here yet")
        #expect(!copy.message.lowercased().contains("assigned"))
        #expect(copy.message.contains("what's on your mind"))
    }

    @Test("With a household, the scope decides the words")
    func householdScopes() {
        let mine = AssignedSectionsView.emptyCopy(
            scope: .assigned, solo: false, searching: false, filteredMessage: nil)
        #expect(mine.title == "Nothing assigned to you")
        let everyone = AssignedSectionsView.emptyCopy(
            scope: .everyone, solo: false, searching: false, filteredMessage: nil)
        #expect(everyone.title == "Nothing here yet")
        #expect(everyone.message.contains("household"))
    }

    @Test("A filter that matches nothing names the filter, solo or not")
    func filteredNamesTheFilter() {
        let copy = AssignedSectionsView.emptyCopy(
            scope: .assigned, solo: true, searching: true, filteredMessage: "No tasks match “Done”.")
        #expect(copy.title == "No matches")
        #expect(copy.message == "No tasks match “Done”.")
    }
}
