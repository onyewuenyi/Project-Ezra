//
//  StatusGlyphView.swift
//  Project-Ezra
//
//  The Linear-style leading status glyph — the one place a task's six-state display
//  status is drawn and changed. Interactive by default: a tap opens a menu of all
//  six states, and picking one composes the underlying lifecycle + stage moves
//  through `applyDisplayStatus`, so complete / cancel / re-stage are one tap from any
//  row (and the detail picker calls the exact same seam, so they never drift). A
//  static variant renders the glyph without the menu for a resolved record row.
//

import CoreData
import SwiftUI

struct StatusGlyphView: View {
    let task: TaskItem
    /// The full working set, so the applied transition (reopen re-block, etc.) is
    /// graph-accurate.
    var allTasks: [TaskItem] = []
    /// Whether the glyph is a tappable state menu. A resolved record row passes
    /// `false` for a static glyph.
    var interactive: Bool = true
    var size: CGFloat = 22
    /// When set, the parent handles applying the picked state (e.g. to route a
    /// Done/Canceled through its own undo-notice path). When nil, the glyph applies
    /// the transition itself.
    var onPick: ((TaskDisplayStatus) -> Void)? = nil

    @Environment(\.managedObjectContext) private var context

    private var display: TaskDisplayStatus { task.displayStatus }

    var body: some View {
        if interactive {
            Menu {
                ForEach(TaskDisplayStatus.allCases) { state in
                    Button {
                        pick(state)
                    } label: {
                        Label {
                            Text(state.label)
                        } icon: {
                            // A checkmark marks the current state; every other row shows
                            // its own state glyph so the whole vocabulary reads at a glance.
                            Image(systemName: state == display ? "checkmark" : state.symbol)
                        }
                    }
                }
            } label: {
                glyph
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("Status: \(display.label)")
            .accessibilityHint("Change status")
        } else {
            glyph.accessibilityLabel("Status: \(display.label)")
        }
    }

    private var glyph: some View {
        Image(systemName: display.symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(display.tint)
            .frame(width: LayoutMetrics.recordGlyphColumn, height: LayoutMetrics.recordGlyphColumn)
            .contentShape(Rectangle())
    }

    private func pick(_ state: TaskDisplayStatus) {
        guard state != display else { return }
        if let onPick {
            onPick(state)
            return
        }
        Motion.withMotion(Motion.decide) {
            task.applyDisplayStatus(state, in: context)
        }
        try? context.save()
    }
}

#Preview {
    let todo = TaskItem(title: "Todo task", status: .active, stage: .todo)
    let review = TaskItem(title: "In review", status: .active, stage: .inReview)
    return HStack(spacing: Spacing.lg) {
        StatusGlyphView(task: todo)
        StatusGlyphView(task: review)
        StatusGlyphView(task: todo, interactive: false)
    }
    .padding()
    .background(Palette.background)
    .environment(\.managedObjectContext, PersistenceStack.scratch)
}
