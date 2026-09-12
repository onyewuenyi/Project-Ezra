//
//  HouseholdActivation.swift
//  Project-Ezra
//
//  The launch plan's two household metrics, as pure derivations (2026-09-12).
//
//  **Activated** — both caretakers each did a capture or completed an item within seven
//  days of the household becoming shared. **Retained** — the household had at least one
//  action by either caretaker in the trailing week. A **single-caretaker** household is
//  welcome and tracked apart, never counted toward either — the positioning is "split the
//  load", and a household of one has no load to split.
//
//  Same charter as `RequiredAttention`: derived over data the store already holds
//  (`TaskItem.creatorID`/`confirmedAt` for captures, the HUMAN `"completed"` change-log
//  entries with their `actorID` for completions), local-only, DEBUG-surfaced, never shown
//  to the person as a score. The one thing that leaves is a single bit — `Telemetry`'s
//  `householdActivated`, fired once per install the first time the reading flips — which
//  is the activation metric the plan pre-registers, observed on device rather than
//  inferred from a dashboard.
//
//  **The anchor is when the household became SHARED, not when it was created.** The
//  owner's `Household` row is minted at first launch, weeks or months before anyone is
//  invited, so "seven days from creation" would expire before the second caretaker
//  exists. `anchor(for:)` therefore reads the earliest accepted `Invitation` and falls
//  back to `createdAt` only when there is none — on which day nothing here can activate
//  anyway, because a household of one has one caretaker.
//

import Foundation

struct HouseholdActivation: Equatable {

    /// Where a household stands against the two definitions.
    enum Standing: Equatable {
        /// One caretaker. Tracked, not counted.
        case singleCaretaker
        /// Two or more caretakers, inside the window, not every required act done yet.
        case pending
        /// Both caretakers acted inside the window.
        case activated
        /// The window closed with fewer than two caretakers having acted.
        case lapsed
    }

    static let activationWindow: TimeInterval = 7 * 24 * 3600
    static let retentionWindow: TimeInterval = 7 * 24 * 3600
    /// How many caretakers must act. Two — the plan's "both" — even when the roster holds
    /// a third adult; the metric is about the load being split, not about everyone.
    static let requiredActors = 2

    let caretakerCount: Int
    /// Caretakers who captured or completed inside the activation window.
    let activeInWindow: Set<UUID>
    let standing: Standing
    /// Any caretaker acted in the trailing week.
    let retainedThisWeek: Bool

    /// A caretaker is an adult who is still on the roster. Children and pets are people the
    /// household plans FOR, not caretakers who plan.
    static func caretakerIDs(in household: Household) -> [UUID] {
        household.activeMembers
            .filter { $0.role == .owner || $0.role == .adult }
            .filter { $0.relationship != .child && $0.relationship != .pet }
            .map(\.uuid)
    }

    /// When the household became shared: the earliest accepted invitation, else creation.
    static func anchor(for household: Household) -> Date {
        let accepted = ((household.invitations as? Set<Invitation>) ?? [])
            .filter { $0.status == .accepted }
            .compactMap(\.acceptedAt)
            .min()
        return accepted ?? household.createdAt
    }

    /// One act per (caretaker, moment): a confirmed capture or a human completion.
    static func acts(
        by caretakers: Set<UUID>, tasks: [TaskItem], entries: [ChangeLogEntry]
    ) -> [(actor: UUID, at: Date)] {
        var acts: [(UUID, Date)] = []
        for task in tasks {
            if let creator = task.creatorID, caretakers.contains(creator), let at = task.confirmedAt {
                acts.append((creator, at))
            }
        }
        for entry in entries where entry.action == "completed" && entry.initiatedBy == .human && !entry.undone
        {
            if let actor = entry.actorID, caretakers.contains(actor) {
                acts.append((actor, entry.timestamp))
            }
        }
        return acts.map { (actor: $0.0, at: $0.1) }
    }

    static func measure(
        caretakers: [UUID], anchor: Date, tasks: [TaskItem], entries: [ChangeLogEntry], now: Date
    ) -> HouseholdActivation {
        let ids = Set(caretakers)
        let acts = acts(by: ids, tasks: tasks, entries: entries)
        let windowEnd = anchor.addingTimeInterval(activationWindow)
        let inWindow = Set(acts.filter { $0.at >= anchor && $0.at <= windowEnd }.map(\.actor))
        let retained = acts.contains { $0.at > now.addingTimeInterval(-retentionWindow) && $0.at <= now }

        let standing: Standing
        if ids.count < requiredActors {
            standing = .singleCaretaker
        } else if inWindow.count >= requiredActors {
            standing = .activated
        } else if now <= windowEnd {
            standing = .pending
        } else {
            standing = .lapsed
        }
        return HouseholdActivation(
            caretakerCount: ids.count, activeInWindow: inWindow, standing: standing,
            retainedThisWeek: retained)
    }

    /// The store-backed form: caretakers and anchor from the household itself.
    static func measure(
        household: Household, tasks: [TaskItem], entries: [ChangeLogEntry], now: Date = Date()
    ) -> HouseholdActivation {
        measure(
            caretakers: caretakerIDs(in: household), anchor: anchor(for: household),
            tasks: tasks, entries: entries, now: now)
    }

    /// One DEBUG diagnostics line: `household: 2 caretakers · activated · active this week`.
    var footerLine: String {
        var parts = ["\(caretakerCount) caretaker\(caretakerCount == 1 ? "" : "s")"]
        switch standing {
        case .singleCaretaker: parts.append("single (not counted)")
        case .pending: parts.append("pending \(activeInWindow.count)/\(Self.requiredActors)")
        case .activated: parts.append("activated")
        case .lapsed: parts.append("lapsed")
        }
        parts.append(retainedThisWeek ? "active this week" : "quiet this week")
        return "household: " + parts.joined(separator: " · ")
    }

    // MARK: - The one bit that leaves

    static let recordedKey = "household.activationRecorded"

    /// Fire `householdActivated` the FIRST time the reading flips, and never again on this
    /// install. Called from the foreground sweep, where the working set is already fetched.
    static func recordIfNewlyActivated(_ reading: HouseholdActivation, defaults: UserDefaults = .standard) {
        guard reading.standing == .activated, !defaults.bool(forKey: recordedKey) else { return }
        defaults.set(true, forKey: recordedKey)
        Telemetry.log(.householdActivated)
    }
}
