//
//  DueLabel.swift
//  Project-Ezra
//
//  ONE due-date vocabulary for every surface that states WHEN.
//
//  The record row and the detail page used to derive their due text separately, and
//  the two drifted in the way that matters most: the row said "3d over" in the
//  overdue token while the detail chip — the place a person goes to read the task
//  properly — said "Mon Sep 1" in neutral text, as if nothing were wrong. Position
//  can't carry lateness on a page with one task on it, so the chip has to say it.
//
//  Two densities of the same facts, never two vocabularies:
//    • `.compact` — the row's trailing label: "3d over" · "Today" · "Fri" · "Sep 12".
//    • `.full`    — the detail chip: "3 days overdue" · "Today" · "Tomorrow" ·
//                   "Friday" · "Fri, Sep 12".
//
//  Only LIVE work with a date earns a label. A resolved task's due is over — the
//  caller falls back to a plain date there, because "overdue" on a finished task is
//  a scold about the past.
//

import Foundation

struct DueLabel: Equatable {
    enum Style {
        case compact
        case full
    }

    let text: String
    let isOverdue: Bool

    /// The label for a task — nil for resolved work and for undated work.
    static func make(
        for task: TaskItem, style: Style, now: Date = Date(), calendar: Calendar = .current
    ) -> DueLabel? {
        guard !task.status.isResolved, let due = task.dueDate else { return nil }
        return make(due: due, style: style, now: now, calendar: calendar)
    }

    /// The label for a date, independent of any task.
    static func make(
        due: Date, style: Style, now: Date = Date(), calendar: Calendar = .current
    ) -> DueLabel? {
        guard let days = TaskItem.daysUntil(due, now: now, calendar: calendar) else { return nil }
        var format = Date.FormatStyle()
        format.calendar = calendar
        switch (style, days) {
        case (.compact, ..<0):
            return DueLabel(text: "\(-days)d over", isOverdue: true)
        case (.full, ..<0):
            return DueLabel(text: -days == 1 ? "1 day overdue" : "\(-days) days overdue", isOverdue: true)
        case (_, 0):
            return DueLabel(text: "Today", isOverdue: false)
        case (.full, 1):
            return DueLabel(text: "Tomorrow", isOverdue: false)
        case (.compact, ..<7):
            return DueLabel(text: due.formatted(format.weekday(.abbreviated)), isOverdue: false)
        case (.full, ..<7):
            return DueLabel(text: due.formatted(format.weekday(.wide)), isOverdue: false)
        case (.compact, _):
            return DueLabel(text: due.formatted(format.month(.abbreviated).day()), isOverdue: false)
        case (.full, _):
            return DueLabel(
                text: due.formatted(format.weekday(.abbreviated).month(.abbreviated).day()),
                isOverdue: false)
        }
    }
}
