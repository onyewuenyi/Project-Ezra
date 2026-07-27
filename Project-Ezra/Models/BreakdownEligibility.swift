//
//  BreakdownEligibility.swift
//  Project-Ezra
//
//  Should this task be offered "Break this down"?
//
//  The capability exists to reduce COMPLEXITY, so complexity is what triggers it —
//  not the work type. That inversion is deliberate and it is the whole design:
//
//    "Plan birthday dinner"  →  planning, 15 minutes  →  no card. Nothing to help with.
//    "Renew passport"        →  action, 90 minutes    →  card. Genuinely multi-step.
//
//  Keying the trigger off `workIntent == .planning` would have gotten both of those
//  backwards. Type BIASES the answer (rung 3 lowers the bar for a planning task) but
//  never decides it alone.
//
//  Pure and deterministic, in the shape of `OwnerProposer`: no model call, so the
//  eligibility question is answerable in the simulator, in tests, and for every user
//  whose Apple Intelligence is off. Only the *content* of a breakdown needs the model.
//

import Foundation

enum BreakdownEligibility {

    /// Why this task qualifies. Returned rather than a bare `Bool` so the card can say
    /// what it noticed — the same "every AI decision is explainable" rule the owner
    /// chip's reason line follows.
    enum Reason: String, Hashable {
        case largeEffort
        case compoundTitle
        case planningIntent

        /// One short phrase, rendered under the card's title.
        var rationale: String {
            switch self {
            case .largeEffort: return "This is a long one"
            case .compoundTitle: return "This sounds like several things"
            case .planningIntent: return "This reads as planning"
            }
        }
    }

    /// The effort band at which a task is long enough to be worth splitting. Matches the
    /// engines' own "focused work" band, so the two agree about what "big" means.
    static let largeEffortMinutes = 60
    /// A planning task qualifies at a lower bar — but not at *no* bar. An unestimated
    /// planning task also qualifies, because "no estimate" on planning work is itself a
    /// sign nobody has sized it yet.
    static let planningEffortMinutes = 30

    /// Evaluate a task. Nil means "no card" — which is the answer for most tasks, and
    /// the card is worth nothing if it is always there.
    ///
    /// - Parameter tasks: the working set, for the has-children check.
    static func evaluate(_ task: TaskItem, among tasks: [TaskItem]) -> Reason? {
        // Nothing to break down: it is finished, or it already has been.
        // `children`, NOT `dependents` — the latter is the blocking reverse edge, so
        // using it would suppress the card on any task that merely blocks another.
        guard !task.status.isResolved else { return nil }
        guard task.children(among: tasks).isEmpty else { return nil }

        if let effort = task.effortMinutes, effort >= largeEffortMinutes { return .largeEffort }
        if isCompound(task.title) { return .compoundTitle }
        if task.workIntent == .planning,
            task.effortMinutes.map({ $0 >= planningEffortMinutes }) ?? true
        {
            return .planningIntent
        }
        return nil
    }

    /// Does the title describe more than one thing?
    ///
    /// Deliberately conservative — a false positive puts a breakdown card on a one-step
    /// errand, which is the expensive direction. It fires on an explicit joiner ("book
    /// the venue **and** send invites", "call the vet, then pick up food") rather than on
    /// length or verb-counting, which mis-fire on ordinary phrasing like "call the school
    /// about the transfer".
    static func isCompound(_ title: String) -> Bool {
        let lower = title.lowercased()
        // A joiner only counts with real content on BOTH sides, so "salt and pepper"
        // inside one errand doesn't split it.
        for joiner in strongJoiners {
            guard let range = lower.range(of: joiner) else { continue }
            if hasContentBothSides(lower, range) { return true }
        }
        if let range = lower.range(of: bareJoiner), hasContentBothSides(lower, range) {
            let next = lower[range.upperBound...].split(separator: " ").first.map(String.init)
            if let next, taskVerbs.contains(next) { return true }
        }
        return false
    }

    /// Joiners that imply a second task on their own.
    private static let strongJoiners = [" and then ", " then ", " and also ", ", then ", " as well as "]

    /// A bare "and" only splits when a TASK VERB follows it. Without that gate,
    /// "buy salt and pepper for the recipe" reads as two tasks — the exact false
    /// positive that would staple a breakdown card onto a single errand.
    private static let bareJoiner = " and "
    private static let taskVerbs: Set<String> = [
        "call", "text", "email", "message", "book", "buy", "order", "send", "pick",
        "drop", "schedule", "pay", "renew", "cancel", "confirm", "check", "clean",
        "fix", "wash", "file", "submit", "return", "collect", "arrange", "register",
        "print", "sign", "post", "reply", "ask", "find", "make",
    ]

    /// Both sides must carry real content, so a joiner inside one errand
    /// ("pick up milk and eggs") doesn't split it.
    private static func hasContentBothSides(_ lower: String, _ range: Range<String.Index>) -> Bool {
        wordCount(lower[lower.startIndex..<range.lowerBound]) >= 2
            && wordCount(lower[range.upperBound...]) >= 2
    }

    private static func wordCount(_ fragment: Substring) -> Int {
        fragment.split(whereSeparator: { $0 == " " || $0 == "," }).count
    }
}
