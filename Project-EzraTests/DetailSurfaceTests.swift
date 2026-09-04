//
//  DetailSurfaceTests.swift
//  Project-EzraTests
//
//  The detail page's 2026-09-04 second pass, pinned where it is pure: the share text
//  a task leaves the app as.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Task detail — share text")
struct DetailSurfaceTests {

    @Test("Share text is the title, the due line only when dated, the notes only when present")
    func shareText() {
        #expect(TaskMoreMenu.shareText(title: "Renew passport", dueDate: nil, notes: nil) == "Renew passport")
        #expect(
            TaskMoreMenu.shareText(title: "  Renew passport ", dueDate: nil, notes: "   ")
                == "Renew passport")
        let withNotes = TaskMoreMenu.shareText(
            title: "Renew passport", dueDate: nil, notes: "Bring the old one.")
        #expect(withNotes == "Renew passport\n\nBring the old one.")
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let dated = TaskMoreMenu.shareText(title: "Renew passport", dueDate: due, notes: nil)
        #expect(dated.hasPrefix("Renew passport\nDue "))
        #expect(dated.contains("Sep 11"))
        #expect(!dated.contains("Ezra"))
    }
}
