//
//  CaptureSurfaceTests.swift
//  Project-EzraTests
//
//  The 2026-09-04 capture-surface pass, pinned where it is pure: the reveal's subtitle
//  carries the ask, the Create CTA says what it does, a removed card can be taken back
//  (and the merge forgets it), "nothing actionable" has a way forward the person owns,
//  a parked capture says how old it is, and only a just-committed row washes in.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Capture surface — the reveal, the list, the parked row")
struct CaptureSurfaceTests {

    private func draft(_ title: String) -> TaskDraft {
        TaskDraft(
            title: title, category: "Personal", confidence: 0.8, autonomy: .silent,
            isJudgmentCall: false, reasoning: "", dueDate: nil)
    }

    @Test("The subtitle counts the things and names the ask only when there is one")
    func revealSubtitle() {
        #expect(ComposerView.revealSubtitle(count: 1, asks: 0) == "1 thing")
        #expect(ComposerView.revealSubtitle(count: 3, asks: 0) == "3 things")
        #expect(ComposerView.revealSubtitle(count: 3, asks: 1) == "3 things · 1 needs a date")
        #expect(ComposerView.revealSubtitle(count: 4, asks: 2) == "4 things · 2 need a date")
        #expect(ComposerView.revealSubtitle(count: 2, asks: 0, leftOut: 2) == "2 things · 2 lines left out")
        #expect(
            ComposerView.revealSubtitle(count: 3, asks: 1, leftOut: 1)
                == "3 things · 1 needs a date · 1 line left out")
    }

    @Test("The Create CTA states creates and merges separately, never a merge as a create")
    func createTitle() {
        #expect(ComposerView.createTitle(created: 1, merged: 0) == "Create 1 task")
        #expect(ComposerView.createTitle(created: 3, merged: 0) == "Create 3 tasks")
        #expect(ComposerView.createTitle(created: 2, merged: 1) == "Create 2 tasks · merge 1")
        // Grouped, the button names the outcome — the one task the cards did not show —
        // and a single card is never a group.
        #expect(
            ComposerView.createTitle(created: 3, merged: 0, group: "Trip to Lagos")
                == "Create “Trip to Lagos” · 3 steps")
        #expect(ComposerView.createTitle(created: 1, merged: 0, group: "Trip") == "Create 1 task")
        #expect(ComposerView.createTitle(created: 0, merged: 1) == "Merge into existing task")
        #expect(ComposerView.createTitle(created: 0, merged: 2) == "Merge 2 into existing tasks")
    }

    @Test("A removal the user takes back is forgotten by the merge, so a re-read keeps the card")
    func removalIsReversible() {
        var removed = RemovedDraftSet()
        let card = draft("Renew the passport")
        removed.record(card)
        #expect(removed.contains(card))
        #expect(removed.filter([card]).isEmpty)
        removed.forget(card)
        #expect(!removed.contains(card))
        #expect(removed.filter([card]).count == 1)
        // Twice recorded, once forgotten: one removal still stands.
        removed.record(card)
        removed.record(card)
        removed.forget(card)
        #expect(removed.filter([card, card]).count == 1)
    }

    @Test("Keep-as-one-task is the person's words, populated by the resolver, never invented")
    func keepAsOneTask() {
        let kept = CaptureFlow.keepAsOneTask(text: "  yeah so   anyway the thing with\nthe landlord  ")
        let draft = try! #require(kept)
        #expect(draft.title.lowercased().contains("landlord"))
        #expect(!draft.title.contains("\n"))
        #expect(!draft.title.contains("  "))
        #expect(!draft.category.isEmpty)
        #expect(draft.confidence >= 0.5)  // the person vouched for it
        #expect(draft.aiOriginal?.title == draft.title)  // no phantom title correction at commit
        #expect(CaptureFlow.keepAsOneTask(text: "   \n  ") == nil)
        let long = String(repeating: "word ", count: 60)
        let cut = try! #require(CaptureFlow.keepAsOneTask(text: long))
        #expect(cut.title.count <= CaptureFlow.keptTitleMaxLength)
        #expect(!cut.title.hasSuffix(" "))
    }

    @Test("A parked capture's age is terse and monotone")
    func parkedAge() {
        let now = Date()
        #expect(ParkedCapturesRow.age(of: now.addingTimeInterval(-10), now: now) == "now")
        #expect(ParkedCapturesRow.age(of: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
        #expect(ParkedCapturesRow.age(of: now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
        #expect(ParkedCapturesRow.age(of: now.addingTimeInterval(-2 * 86400), now: now) == "2d ago")
        // A clock that ran backwards never yields a negative age.
        #expect(ParkedCapturesRow.age(of: now.addingTimeInterval(60), now: now) == "now")
    }

    @Test(
        "Only a row confirmed within the arrival window washes in; never an old one, never an unconfirmed one"
    )
    func arrivalWindow() {
        let now = Date()
        #expect(TaskRow.isFreshArrival(confirmedAt: now.addingTimeInterval(-1), now: now))
        #expect(
            !TaskRow.isFreshArrival(confirmedAt: now.addingTimeInterval(-TaskRow.arrivalWindow), now: now))
        #expect(!TaskRow.isFreshArrival(confirmedAt: now.addingTimeInterval(-3600), now: now))
        #expect(!TaskRow.isFreshArrival(confirmedAt: nil, now: now))
        // A confirm stamped in the future (clock skew) is not an arrival either.
        #expect(!TaskRow.isFreshArrival(confirmedAt: now.addingTimeInterval(30), now: now))
    }
}
