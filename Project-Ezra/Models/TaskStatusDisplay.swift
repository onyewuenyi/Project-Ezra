//
//  TaskStatusDisplay.swift
//  Project-Ezra
//
//  The visible vocabulary for the lifecycle axis — glyph, tint, and the pickable set.
//  Replaces the retired `TaskStage.swift`, which existed only because the lifecycle
//  was split across two stored fields and needed a `(status, stage) → display`
//  mapping table. With one four-case `TaskStatus` the mapping is 1:1, so there is no
//  table left: a row, a picker, and a section header all read the status itself.
//
//  Display lives here rather than on the enum in `TaskItem.swift` so the domain model
//  stays free of SwiftUI. The glyph vocabulary is unchanged from the Linear-style
//  redesign, minus the two retired states — a status always looks the same wherever
//  it appears.
//

import SwiftUI

extension TaskStatus {

    /// The leading glyph. One vocabulary shared by the row, the picker, and the
    /// section header.
    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .todo: return Palette.secondaryText
        case .doing: return Palette.statusInProgress
        case .done: return Palette.success
        case .canceled: return Palette.mutedText
        }
    }

    /// The states a user can pick, in focus order (most-active first). Identical to
    /// `allCases` reordered — there is no unpickable birth state any more, because a
    /// task does not exist until Confirm creates it as `.todo`.
    static let pickable: [TaskStatus] = [.doing, .todo, .done, .canceled]

    /// Does this task match the selected state? The filter-menu predicate.
    func matches(_ task: TaskItem) -> Bool { task.status == self }
}

extension MyTasksSectionKind {

    /// The section header's glyph. Reference borrows the note vocabulary rather than a
    /// lifecycle glyph — it is a shelf, not a stage of the pipeline.
    var symbol: String {
        switch self {
        case .status(let status): return status.symbol
        case .reference: return "text.book.closed"
        }
    }

    var tint: Color {
        switch self {
        case .status(let status): return status.tint
        case .reference: return Palette.mutedText
        }
    }
}
