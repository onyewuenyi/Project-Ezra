//
//  TaskSearchMatchTests.swift
//  Project-EzraTests
//
//  Search matches what the person remembers: the title, their notes, and the words they
//  said at capture. Title-only search answered "No matches" to a task whose notes held
//  the very word being typed (2026-09-18).
//

import CoreData
import Testing

@testable import Project_Ezra

@Suite("Search — what a query matches")
@MainActor
struct TaskSearchMatchTests {

    private func task(_ title: String, notes: String? = nil, said: String = "") -> TaskItem {
        let context = TestStore.makeContext()
        let t = TaskItem(title: title, status: .todo, in: context)
        t.notes = notes
        t.rawCapture = said
        return t
    }

    @Test("The title matches, case-insensitively, and an empty query matches everything")
    func titleMatches() {
        let t = task("Renew the passport")
        #expect(TaskSlice.matches(t, search: "PASSPORT", category: nil))
        #expect(TaskSlice.matches(t, search: "   ", category: nil))
        #expect(!TaskSlice.matches(t, search: "flights", category: nil))
    }

    @Test("The notes and the captured words match too")
    func notesAndCaptureMatch() {
        let t = task("Buy a gift", notes: "Sam wanted the blue one", said: "get sam something for the party")
        #expect(TaskSlice.matches(t, search: "blue", category: nil))
        #expect(TaskSlice.matches(t, search: "party", category: nil))
        #expect(!TaskSlice.matches(t, search: "red", category: nil))
    }

    @Test("A category filter still narrows before the words are read")
    func categoryNarrows() {
        let t = task("Buy a gift", notes: "blue")
        t.category = "Personal"
        #expect(TaskSlice.matches(t, search: "blue", category: "Personal"))
        #expect(!TaskSlice.matches(t, search: "blue", category: "Home"))
    }
}
