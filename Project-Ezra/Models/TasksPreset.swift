//
//  TasksPreset.swift
//  Project-Ezra
//
//  The glance strip's counts open the LIST, filtered (2026-09-23). "2 overdue" is a
//  number about the inventory, and "which ones?" is list vocabulary — the rows, the
//  sections, the swipes — not a sentence for a chat to repeat back. So a count on the
//  home deep-links into the Tasks sheet with a filter already set, and the strip stops
//  overlapping the chips underneath it, which stay questions only a judgment answers.
//
//  Two things here. `TasksAttention` is the list's THIRD filter dimension, beside status
//  and category: the attention flags the four axes derive on read (overdue, waiting,
//  decisions, urgent) plus one owner, because "Maya 3" is a count of hers. It is a real
//  filter — in the menu, named in the capsule, cleared by Clear filters — never a
//  passenger of the strip. `TasksPreset` is what a deep-link carries: a tab, a status
//  and an attention, each optional, applied once when the sheet opens.
//

import Foundation

/// The attention axis of the list's filter: what the row's markers say, as a subset.
enum TasksAttention: Equatable, Hashable, Sendable {
    case overdue
    case dueToday
    /// Waiting on a blocker or an external wait — Blocked, derived.
    case waiting
    case decisions
    case urgent
    /// One person's tasks by name — the Everyone scope narrowed to a caretaker.
    case ownedBy(UUID, name: String)

    /// What the capsule and the empty state call it.
    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueToday: return "Due today"
        case .waiting: return "Waiting"
        case .decisions: return "Decisions"
        case .urgent: return "Urgent"
        case .ownedBy(_, let name): return "\(name)’s"
        }
    }

    var symbol: String {
        switch self {
        case .overdue: return "exclamationmark.circle"
        case .dueToday: return "sun.max"
        case .waiting: return "hourglass"
        case .decisions: return "hand.raised"
        case .urgent: return "bolt"
        case .ownedBy: return "person"
        }
    }

    /// The four the menu lists — the owner arm is reached from the strip only, because
    /// a menu of every household member is the roster, and the Everyone scope already
    /// shows whose each row is.
    static let pickable: [TasksAttention] = [.overdue, .dueToday, .waiting, .decisions, .urgent]

    /// Whether a task belongs to the subset. `among` is the population the derived
    /// flags read against — blocked is never stored.
    func matches(_ task: TaskItem, among tasks: [TaskItem], now: Date = Date()) -> Bool {
        switch self {
        case .overdue:
            guard !task.status.isResolved, let due = task.dueDate,
                let days = TaskItem.daysUntil(due, now: now)
            else { return false }
            return days < 0
        case .dueToday:
            guard !task.status.isResolved, let due = task.dueDate,
                let days = TaskItem.daysUntil(due, now: now)
            else { return false }
            return days == 0
        case .waiting:
            return !task.status.isResolved && task.hasActiveBlockers(among: tasks)
        case .decisions:
            return !task.status.isResolved && task.needsDecision
        case .urgent:
            return !task.status.isResolved && task.isUrgent
        case .ownedBy(let id, _):
            return task.ownerID == id
        }
    }
}

/// The household's counts, as the Tasks sheet shows them under its header (2026-09-23,
/// the calm home: the strip left the home, where six capsules and six numbers were the
/// most dashboard-like thing on the screen, and became the list's own glance — each
/// count sets the filter in place). Only what is non-zero, in triage order. Pure over
/// the live tasks, no facts snapshot, so the sheet pays nothing it did not already pay.
enum TasksCounts {
    static func items(tasks: [TaskItem], now: Date = Date()) -> [HouseholdChatPrompt.SummaryItem] {
        let live = tasks.filter { !$0.status.isResolved }
        var items: [HouseholdChatPrompt.SummaryItem] = []
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)" }
        let overdue = live.filter { TasksAttention.overdue.matches($0, among: tasks, now: now) }.count
        if overdue > 0 {
            items.append(
                .init(
                    label: count(overdue, "overdue"),
                    preset: TasksPreset(tab: .everyone, attention: .overdue),
                    opens: "Overdue tasks", kind: .overdue))
        }
        let today = live.filter { TasksAttention.dueToday.matches($0, among: tasks, now: now) }.count
        if today > 0 {
            items.append(
                .init(
                    label: count(today, "due today"),
                    preset: TasksPreset(tab: .everyone, attention: .dueToday),
                    opens: "Tasks due today", kind: .dueToday))
        }
        // No "in progress" count: the list's own IN PROGRESS section header carries the
        // same number a line below (2026-09-25, the importance audit). The strip keeps
        // only what cuts ACROSS sections.
        let waiting = live.filter { TasksAttention.waiting.matches($0, among: tasks, now: now) }.count
        if waiting > 0 {
            items.append(
                .init(
                    label: count(waiting, "waiting"),
                    preset: TasksPreset(tab: .everyone, attention: .waiting),
                    opens: "Tasks waiting on something", kind: .waiting))
        }
        let decisions = live.filter { $0.needsDecision }.count
        if decisions > 0 {
            items.append(
                .init(
                    label: count(decisions, decisions == 1 ? "decision" : "decisions"),
                    preset: TasksPreset(tab: .everyone, attention: .decisions),
                    opens: "Tasks needing a decision",
                    kind: .decisions))
        }
        // No "done this week" either: the ledger sections below say it, and a list is
        // about what is left.
        return items
    }
}

/// What a deep-link into the list carries. Every field optional; nil leaves the sheet's
/// own default (Mine, no filter).
struct TasksPreset: Equatable, Hashable, Sendable, Identifiable {
    var tab: MyTasksTab? = nil
    var status: TaskStatus? = nil
    var attention: TasksAttention? = nil

    /// A plain open: no tab, no filter. Named `plain`, NOT `none` — assigned to an
    /// optional (`tasksPreset = .none`) the name resolved to `Optional.none` and the
    /// `-OpenTasks` seam silently opened nothing (found on a screenshot, 2026-09-23).
    static let plain = TasksPreset()

    /// `sheet(item:)` identity: the preset itself. Two opens on the same subset are the
    /// same sheet, which is what a person tapping the same count twice expects.
    var id: Int { hashValue }
}
