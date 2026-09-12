//
//  RelativeAge.swift
//  Project-Ezra
//
//  ONE compact "how long ago" vocabulary — "now" · "5m ago" · "2h ago" · "3d ago" —
//  for every caption that dates a thing by its age rather than by a deadline.
//
//  `DueLabel` answers WHEN something is due, which is a date on the calendar; this
//  answers how long since something HAPPENED, which is a distance from now. The two
//  read differently on purpose ("Fri" against "3d ago") so a row never has to say which
//  it means. Terse, never a sentence: this is a caption on a row, not the row's point.
//  Two readers today — the parked-capture row (when the words were left) and the
//  resolved task row (when it was finished) — and they must not drift.
//

import Foundation

enum RelativeAge {
    static func compact(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
