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
import UIKit

/// One transient notice. Identity-based equality so replacing a notice re-arms
/// the dismiss timer and the transition.
struct UndoNotice: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undoAction: (() -> Void)?

    static func == (lhs: UndoNotice, rhs: UndoNotice) -> Bool { lhs.id == rhs.id }

    /// Standard message for a resolution (complete/kill), folding in any tasks the
    /// resolution auto-unblocked so the AI's action is visible in-flow — and any steps
    /// left behind when the resolved task was a container.
    ///
    /// Closing an umbrella with open steps is allowed: sometimes the steps stop mattering
    /// the moment the job is done. But it must never be SILENT — the steps are real rows
    /// that would otherwise sit in the list with nothing above them to explain why. Naming
    /// them here (with the Undo already in the pill) is the iOS-native answer: inform and
    /// offer the way back, rather than interrupt with a dialog to confirm what the user
    /// plainly meant.
    static func resolution(
        _ verb: String, _ title: String, unblocked: [TaskItem] = [],
        steps: StepProgress? = nil, readiedOutcome: String? = nil, undo: (() -> Void)? = nil
    ) -> UndoNotice {
        var message = "\(verb) “\(title)”"
        if unblocked.count == 1 {
            message += " — unblocked “\(unblocked[0].title)”"
        } else if unblocked.count > 1 {
            message += " — unblocked \(unblocked.count) tasks"
        }
        if let phrase = steps?.openStepsPhrase { message += " — \(phrase)" }
        // The last step of an outcome: the umbrella has just surfaced from behind its
        // deck, and this is the one place that says why — the pill is the receipt for a
        // moment the list can only show as a row that wasn't there before.
        if let readiedOutcome { message += " — “\(readiedOutcome)” has no steps left" }
        return UndoNotice(message: message, undoAction: undo)
    }
}

extension View {
    /// Floats the undo pill above the content's bottom edge (inside the safe area,
    /// so it sits above the tab bar and never covers it). Pass `bottomInset` when the
    /// modifier is applied ABOVE the tab bar in the hierarchy rather than inside a tab:
    /// there the safe area no longer accounts for the floating bar, and the pill lands
    /// on top of the tab labels.
    func undoNotice(_ notice: Binding<UndoNotice?>, bottomInset: CGFloat = 0) -> some View {
        modifier(UndoNoticeModifier(notice: notice, bottomInset: bottomInset))
    }
}

private struct UndoNoticeModifier: ViewModifier {
    @Binding var notice: UndoNotice?
    var bottomInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice {
                    pill(notice)
                        .transition(reduceMotion ? .opacity : Motion.cardEntry)
                        .task(id: notice.id) {
                            AccessibilityNotification.Announcement(notice.message).post()
                            try? await Task.sleep(for: .seconds(Self.dwell))
                            if self.notice?.id == notice.id { self.notice = nil }
                        }
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.snap, value: notice?.id)
    }

    /// How long the pill waits before dismissing itself.
    ///
    /// **Four seconds is not four seconds with VoiceOver on (2026-09-20).** The pill
    /// posts its whole sentence as an announcement — "Completed “Renew my passport” —
    /// unblocked “Book flights for the trip”" — which takes roughly the entire four
    /// seconds to speak at the default rate. Only then could someone start swiping
    /// toward the Undo button, and by then the overlay is gone. This is the app's only
    /// reversal affordance for a completion, a cancel, an AI structural act and the
    /// grouping sweep, so the failure is not "a nicety is hard to reach" — it is that a
    /// blind user can destroy work and cannot take it back.
    ///
    /// The sighted timing is untouched: four seconds is right for a glance, and a longer
    /// pill would sit over the list for no reason. The reader gets the time the reading
    /// costs them.
    static var dwell: Double { UIAccessibility.isVoiceOverRunning ? 14 : 4 }

    private func pill(_ notice: UndoNotice) -> some View {
        HStack(spacing: Spacing.sm) {
            // Two lines, not one (2026-09-18): the pill is the RECEIPT for a resolution
            // — "Completed “Renew passport” — unblocked “Book flights for the trip”" —
            // and a one-line, middle-truncated pill read "Completed “Ren…the trip”",
            // losing the very names the notice exists to say. The announcement always
            // carried the whole sentence; the eyes now get it too.
            Text(notice.message)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo = notice.undoAction {
                Button {
                    undo()
                    self.notice = nil
                } label: {
                    Text("Undo")
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.pressableLink)
                // The action never yields its width (2026-09-26): beside a long receipt
                // it truncated to "Un…", and it is the only way back.
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.elevatedSurface, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.xs + bottomInset)
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
