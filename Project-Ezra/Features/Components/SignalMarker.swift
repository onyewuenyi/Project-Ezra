//
//  SignalMarker.swift
//  Project-Ezra
//
//  The leading attention-Signal glyph on the RECORD surfaces (My Tasks rows + the
//  detail chips). Replaces the retired `PriorityBadgeView` bars: attention is now a
//  computed system score (never a badge), and only the USER signal surfaces as a
//  mark — Urgent (`exclamationmark.circle.fill`, warning tint). A task without it
//  renders NOTHING (zero footprint), so the row title sits flush against the status
//  glyph — Today (`TodayTaskRow`/`TaskCardView`) stays entirely signal-free by design.
//
//  Tokens only — never a hardcoded color or size.
//

import SwiftUI

struct SignalMarker: View {
    var isUrgent: Bool
    /// Unscaled base glyph size; scales with Dynamic Type via `unit`.
    var size: CGFloat = 14

    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 1

    var body: some View {
        if isUrgent {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Palette.warning)
                    .accessibilityLabel("Urgent")
            }
            .font(.system(size: size * unit, weight: .semibold))
        }
    }
}

extension SignalMarker {
    /// Convenience for the common case of reading straight off a task.
    init(task: TaskItem, size: CGFloat = 14) {
        self.init(isUrgent: task.isUrgent, size: size)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.md) {
        SignalMarker(isUrgent: true)
        HStack {
            SignalMarker(isUrgent: false)
            Text("No signal — zero footprint").metadataStyle()
        }
    }
    .padding()
    .background(Palette.background)
}
