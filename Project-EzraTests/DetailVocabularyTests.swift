//
//  DetailVocabularyTests.swift
//  Project-EzraTests
//
//  The task page's two spoken facts, pinned: WHEN a task is due (`DueLabel`, the one
//  vocabulary the row and the detail chip both read — they drifted once, with the row
//  saying "3d over" in orange while the chip said a neutral date) and WHERE a task is
//  in its life (`TaskTimeline.caption`, the line under the title). Plus the title
//  field's return-key rule, which is a pure function so it can be tested without a
//  keyboard.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Due label — one vocabulary for the row and the page")
struct DueLabelTests {

    private let now = Date(timeIntervalSince1970: 1_756_900_000)  // 2025-09-03, mid-week
    private let en = Locale(identifier: "en_US")

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    @Test("Overdue is stated in both densities, and the count is exact")
    func overdue() {
        let compact = DueLabel.make(due: day(-3), style: .compact, now: now)
        let full = DueLabel.make(due: day(-3), style: .full, now: now)
        #expect(compact == DueLabel(text: "3d over", isOverdue: true))
        #expect(full == DueLabel(text: "3 days overdue", isOverdue: true))
        #expect(DueLabel.make(due: day(-1), style: .full, now: now)?.text == "1 day overdue")
    }

    @Test("Today reads the same everywhere; only the page says Tomorrow")
    func todayAndTomorrow() {
        #expect(DueLabel.make(due: now, style: .compact, now: now)?.text == "Today")
        #expect(DueLabel.make(due: now, style: .full, now: now)?.text == "Today")
        #expect(DueLabel.make(due: day(1), style: .full, now: now)?.text == "Tomorrow")
        let compactTomorrow = DueLabel.make(due: day(1), style: .compact, now: now)
        #expect(compactTomorrow?.text != "Tomorrow")
        #expect(compactTomorrow?.isOverdue == false)
    }

    @Test("Inside the week the page says the whole weekday; the row abbreviates it")
    func withinWeek() {
        let compact = DueLabel.make(due: day(3), style: .compact, now: now)!
        let full = DueLabel.make(due: day(3), style: .full, now: now)!
        #expect(!compact.isOverdue && !full.isOverdue)
        #expect(full.text.count > compact.text.count)
        #expect(full.text.hasPrefix(compact.text))
    }

    @Test("Beyond the week both say the date; neither is overdue")
    func beyondWeek() {
        let compact = DueLabel.make(due: day(20), style: .compact, now: now)!
        let full = DueLabel.make(due: day(20), style: .full, now: now)!
        #expect(!compact.isOverdue && !full.isOverdue)
        #expect(full.text.contains(compact.text))
    }

    @Test("Only live, dated work earns a label — a resolved task's due is a plain date")
    func onlyLiveDatedWork() {
        let context = TestStore.makeContext()
        let undated = TaskItem(title: "x", status: .todo, in: context)
        #expect(DueLabel.make(for: undated, style: .full, now: now) == nil)

        let done = TaskItem(title: "y", status: .done, in: context)
        done.dueDate = day(-4)
        #expect(DueLabel.make(for: done, style: .compact, now: now) == nil)

        let live = TaskItem(title: "z", status: .doing, in: context)
        live.dueDate = day(-4)
        #expect(DueLabel.make(for: live, style: .compact, now: now)?.isOverdue == true)
    }
}

@Suite("Lifecycle caption — where the task is in its life, under the title")
struct TaskTimelineCaptionTests {

    private let en = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_756_900_000)

    @Test("A plain to-do says nothing")
    func todoIsSilent() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "x", status: .todo, in: context)
        #expect(TaskTimeline.caption(for: task, now: now, locale: en) == nil)
    }

    @Test("Start reads 'just now' under a minute, then the named relative time")
    func started() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "x", status: .todo, in: context)
        task.transition(to: .doing, now: now.addingTimeInterval(-20))
        #expect(TaskTimeline.caption(for: task, now: now, locale: en) == "Started just now")

        let earlier = TaskItem(title: "y", status: .todo, in: context)
        earlier.transition(to: .doing, now: now.addingTimeInterval(-2 * 3600))
        #expect(TaskTimeline.caption(for: earlier, now: now, locale: en) == "Started 2 hours ago")
    }

    @Test("Resolved work reads as a record: Done yesterday, Canceled 3 days ago")
    func resolved() {
        let context = TestStore.makeContext()
        let done = TaskItem(title: "x", status: .todo, in: context)
        done.transition(to: .doing, now: now.addingTimeInterval(-3 * 86_400))
        done.transition(to: .done, now: now.addingTimeInterval(-86_400))
        #expect(TaskTimeline.caption(for: done, now: now, locale: en) == "Done yesterday")

        let canceled = TaskItem(title: "y", status: .todo, in: context)
        canceled.transition(to: .canceled, now: now.addingTimeInterval(-3 * 86_400))
        #expect(TaskTimeline.caption(for: canceled, now: now, locale: en) == "Canceled 3 days ago")
    }

    @Test("Resumed work is 'started' when it was LAST started, not first")
    func resumedReadsCurrentVisit() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "x", status: .todo, in: context)
        task.transition(to: .doing, now: now.addingTimeInterval(-5 * 86_400))
        task.transition(to: .todo, now: now.addingTimeInterval(-4 * 86_400))
        task.transition(to: .doing, now: now.addingTimeInterval(-30 * 60))
        #expect(TaskTimeline.caption(for: task, now: now, locale: en) == "Started 30 minutes ago")
    }
}

@Suite("Title field — return means done")
struct TitleReturnTests {

    @Test("No line break → nil, the edit is left alone")
    func untouchedWithoutBreak() {
        #expect(TaskDetailView.titleAfterReturn("Renew passport") == nil)
    }

    @Test("A return at the end commits the title without a trailing space")
    func trailingReturn() {
        #expect(TaskDetailView.titleAfterReturn("Renew passport\n") == "Renew passport")
    }

    @Test("A return mid-title joins the halves with one space")
    func midTitleReturn() {
        #expect(TaskDetailView.titleAfterReturn("Renew \npassport") == "Renew passport")
        #expect(TaskDetailView.titleAfterReturn("Renew\n\npassport") == "Renew passport")
    }
}
