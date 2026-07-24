//
//  Blocker.swift
//  Project-Ezra
//
//  One thing a task is waiting on. There is exactly one notion of "blocked" in this
//  app: a task is Blocked iff it has at least one *active* blocker. What differs is
//  only what it's waiting on —
//
//  - `.task`     — a tracked dependency. Auto-resurfaces when its target resolves;
//                  forms the real edge the chain stacks and cycle guard are built on.
//  - `.external` — something we don't track ("the contractor calls back"). Never
//                  auto-resurfaces; only a human clears it. **User-authored only** —
//                  the AI may only ever add `.task` blockers, so it can never trap a
//                  task on a guess (see `AppBrain.resolveBlockers`).
//
//  No longer persisted directly — `Blocker` is now a READ-ONLY UI value type derived
//  on read from a task's `.blocks` `Relationship` edges (see
//  `TaskItem.blockers`). Each derived blocker reuses its edge's `id`, so a blocker's
//  identity round-trips back to the underlying relationship for removal. The four
//  factory verbs below survive for tests and call-site symmetry.
//

import Foundation

struct Blocker: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case task
        case external
    }

    var id: UUID = UUID()
    var kind: Kind
    /// The blocking `TaskItem.uuid`. Set iff `kind == .task`.
    var taskID: UUID?
    /// What we're waiting on, in the user's own words. Set iff `kind == .external`;
    /// nil is allowed and reads as "something else".
    var note: String?

    static func task(_ id: UUID) -> Blocker {
        Blocker(kind: .task, taskID: id)
    }

    static func external(_ note: String? = nil) -> Blocker {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Blocker(kind: .external, note: (trimmed?.isEmpty == false) ? trimmed : nil)
    }

    /// How this blocker reads on a card, preposition included, so the summary is a
    /// whole phrase rather than a fragment the caller has to guess a preposition for.
    /// `.task` needs its target's title resolved by the caller — hence `taskTitle`.
    func phrase(taskTitle: String?) -> String {
        switch kind {
        case .task: return "after \(taskTitle ?? "another task")"
        case .external: return "waiting on \(note ?? "something else")"
        }
    }
}
