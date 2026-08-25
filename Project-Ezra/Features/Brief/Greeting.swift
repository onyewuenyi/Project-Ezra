//
//  Greeting.swift
//  Project-Ezra
//
//  The Today greeting, as a value rather than a string — so it can grow. Today it's
//  just a time-of-day salutation with the user's first name; `lines` is the reserved
//  seam for the household-context lines that make personalization pay off later
//  ("Ezra has daycare", "Maya is traveling", "Rain starts at 3"). Pure and testable.
//

import Foundation

struct Greeting {
    /// "Good morning, Charles" (or just "Good morning" when there's no name yet).
    var primary: String
    /// Reserved: contextual lines drawn from the household (empty in V1).
    var lines: [String] = []

    static func make(
        firstName: String?,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> Greeting {
        let salutation: String
        switch calendar.component(.hour, from: date) {
        case 5..<12: salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        let trimmed = firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = (trimmed?.isEmpty == false) ? "\(salutation), \(trimmed!)" : salutation
        return Greeting(primary: primary)
    }
}
