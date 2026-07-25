//
//  UndoNoticeView.swift
//  Project-Ezra
//
//  The calm undo pill. Completing and killing are high-frequency, instant actions —
//  which is exactly why a mis-tap needs a zero-friction way back (trust checklist:
//  the user can Undo anything). It also gives auto-resurfaced dependents an in-flow
//  voice ("unblocked X"), so the AI's chain reaction is visible where it happened,
//  not only in the trail. Never blocks interaction, auto-dismisses, one at a time.
//

import SwiftUI

/// One transient notice. Identity-based equality so replacing a notice re-arms
/// the dismiss timer and the transition.
struct UndoNotice: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undoAction: (() -> Void)?

    static func == (lhs: UndoNotice, rhs: UndoNotice) -> Bool { lhs.id == rhs.id }

    /// Standard message for a resolution (complete/kill), folding in any tasks the
    /// resolution auto-unblocked so the AI's action is visible in-flow.
    static func resolution(
        _ verb: String, _ title: String, unblocked: [TaskItem] = [], undo: (() -> Void)? = nil
    ) -> UndoNotice {
        var message = "\(verb) “\(title)”"
        if unblocked.count == 1 {
            message += " — unblocked “\(unblocked[0].title)”"
        } else if unblocked.count > 1 {
            message += " — unblocked \(unblocked.count) tasks"
        }
        return UndoNotice(message: message, undoAction: undo)
    }
}

extension View {
    /// Floats the undo pill above the content's bottom edge (inside the safe area,
    /// so it sits above the tab bar and never covers it).
    func undoNotice(_ notice: Binding<UndoNotice?>) -> some View {
        modifier(UndoNoticeModifier(notice: notice))
    }
}

private struct UndoNoticeModifier: ViewModifier {
    @Binding var notice: UndoNotice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice {
                    pill(notice)
                        .transition(reduceMotion ? .opacity : Motion.cardEntry)
                        .task(id: notice.id) {
                            AccessibilityNotification.Announcement(notice.message).post()
                            try? await Task.sleep(for: .seconds(4))
                            if self.notice?.id == notice.id { self.notice = nil }
                        }
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.snap, value: notice?.id)
    }

    private func pill(_ notice: UndoNotice) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(notice.message)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let undo = notice.undoAction {
                Button("Undo") {
                    undo()
                    self.notice = nil
                }
                .font(.controlLabel)
                .foregroundStyle(Palette.accentFlat)
                .buttonStyle(.pressableLink)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.elevatedSurface, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.xs)
    }
}

#Preview {
    @Previewable @State var notice: UndoNotice? = .resolution(
        "Completed", "Renew my passport",
        unblocked: [TaskItem(title: "Book flights", status: .todo)], undo: {})

    return Palette.background
        .ignoresSafeArea()
        .undoNotice($notice)
}
