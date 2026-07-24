//
//  TaskStage.swift
//  Project-Ezra
//
//  The Linear-style status vocabulary — a *display* layer over the two real axes,
//  never a fourth stored dimension fused into the others. The user-owned lifecycle
//  (`TaskStatus`: inbox → active → done | killed) stays exactly as it was; `TaskStage`
//  is a sub-state that only means anything while a task is `.active`, letting the
//  working set read as Backlog / Todo / In Progress / In Review the way Linear does.
//
//  `TaskDisplayStatus` is the single source of truth for the six visible states: it
//  DERIVES from (status, stage) — there is no separate stored "display status" that
//  could drift. The row glyph, the detail picker, and the My Tasks sectioning all
//  read `displayStatus` and write back through `applyDisplayStatus` (see
//  `TaskMutations`), so a state a user picks can never disagree with the lifecycle.
//
//  Stage is user-owned, never AI-written: the AI proposes `.inbox` at capture (which
//  reads as Backlog); `confirm()` stamps `defaultOnConfirm` (Todo). Stage never enters
//  `TaskRanking.stackOrder` — it drives *sectioning*, not order, so the comparator's
//  strict-weak-ordering invariant is untouched.
//

import SwiftUI

// MARK: - Stage (a sub-state of `.active`)

/// Where an *active* task sits in the working pipeline. Meaningful only while the
/// status is `.active`; ignored for `.inbox` (reads as Backlog), `.done`, and
/// `.killed` (which have their own display states). Stored raw as an optional
/// `stageRaw` — nil means "not yet stamped" and the getter defaults it to `.todo`.
enum TaskStage: String, Codable, CaseIterable, Identifiable {
    case backlog
    case todo
    case inProgress
    case inReview

    var id: String { rawValue }

    /// The stage a task takes when the user confirms it into the working set. Per the
    /// product decision, a freshly-confirmed task is Todo, not Backlog — confirming is
    /// an act of commitment, so it lands ready to work, not parked.
    static let defaultOnConfirm: TaskStage = .todo
}

// MARK: - Display status (the six visible Linear states, DERIVED)

/// The six states a task ever shows as, in focus order (most-active first). Purely
/// derived from `(TaskStatus, TaskStage)` via `derive(status:stage:)` — the one
/// mapping table. Drives the row glyph, the detail picker, and My Tasks sectioning.
enum TaskDisplayStatus: String, CaseIterable, Identifiable {
    case inProgress
    case inReview
    case todo
    case backlog
    case done
    case canceled

    var id: String { rawValue }

    /// The mapping table (docs/PRD + the Linear-redesign plan). `.inbox` always reads
    /// as Backlog regardless of stage; an `.active` task reads by its stage; resolved
    /// tasks read Done / Canceled.
    static func derive(status: TaskStatus, stage: TaskStage) -> TaskDisplayStatus {
        switch status {
        case .inbox: return .backlog
        case .active:
            switch stage {
            case .backlog: return .backlog
            case .todo: return .todo
            case .inProgress: return .inProgress
            case .inReview: return .inReview
            }
        case .done: return .done
        case .killed: return .canceled
        }
    }

    var label: String {
        switch self {
        case .inProgress: return "In Progress"
        case .inReview: return "In Review"
        case .todo: return "Todo"
        case .backlog: return "Backlog"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }

    /// The Linear-style leading glyph. A single glyph vocabulary shared by the row,
    /// the picker, and the section header, so a state always looks the same.
    var symbol: String {
        switch self {
        case .inProgress: return "circle.lefthalf.filled"
        case .inReview: return "circle.badge.checkmark"
        case .todo: return "circle"
        case .backlog: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return Palette.statusInProgress
        case .inReview: return Palette.accentFlat
        case .todo: return Palette.secondaryText
        case .backlog: return Palette.mutedText
        case .done: return Palette.success
        case .canceled: return Palette.mutedText
        }
    }

    /// A resolved display state — Done or Canceled. These read as a record, not an
    /// action (the row glyph is static, no swipe-to-complete).
    var isResolved: Bool { self == .done || self == .canceled }

    /// The active-pipeline `TaskStage` this display state maps to, or nil for the
    /// resolved states (Done/Canceled have no stage). Used to restore a stage edit on
    /// Undo without routing back through the logged `applyDisplayStatus` seam.
    var asStage: TaskStage? {
        switch self {
        case .backlog: return .backlog
        case .todo: return .todo
        case .inProgress: return .inProgress
        case .inReview: return .inReview
        case .done, .canceled: return nil
        }
    }

    /// The filter-menu predicate: does this task match the selected display state?
    /// Computed over the task's own `(status, stage)`.
    func matches(_ task: TaskItem) -> Bool {
        task.displayStatus == self
    }
}
