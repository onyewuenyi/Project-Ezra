//
//  AssessmentChip.swift
//  Project-Ezra
//
//  The one visible flag. Per the flags spec, only Needs Decision ever earns a
//  label (plus the small Overdue marker rendered in the card's metadata line) —
//  Blocked is internal and manifests as position + the frosted title, never a
//  chip. "Up for Grabs" survives as the household ownership question (a
//  needs-a-human state, same family as Needs Decision). Always crisp and
//  full-opacity, legible under Reduce Transparency. Renders nothing when there's
//  nothing to say.
//

import SwiftUI

struct AssessmentChip: View {
    let assessment: TaskAssessment

    var body: some View {
        if let display {
            HStack(spacing: 4) {
                if let icon = display.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))  // micro: bespoke chip metrics
                }
                Text(display.label)
                    .font(.system(size: 11, weight: .semibold))  // micro: bespoke chip metrics
            }
            .foregroundStyle(display.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(display.background, in: Capsule())
            .overlay(alignment: .center) {
                // Needs Decision earns the accent gradient edge-glow (4th sanctioned use).
                // Nothing else spends from that budget.
                if display.gradientStroke {
                    Capsule().strokeBorder(Palette.accentGradient, lineWidth: 1)
                }
            }
        }
    }

    private struct Display {
        var label: String
        var icon: String?
        var foreground: Color
        var background: Color
        var gradientStroke: Bool
    }

    /// Precedence: a human-judgment/low-confidence proposal is the highest-signal
    /// thing to surface, then the household ownership gap. Blocked deliberately
    /// renders nothing — it sinks in the stack instead. Nil (no chip) when the
    /// task is clean.
    private var display: Display? {
        if assessment.needsDecision != nil {
            return Display(
                label: "Needs Decision", icon: "hand.raised",
                foreground: Palette.accentStart, background: Palette.accentSoft, gradientStroke: true)
        }
        if assessment.isUnowned {
            return Display(
                label: "Up for Grabs", icon: "person.fill.questionmark",
                foreground: Palette.secondaryText, background: Palette.secondarySurface,
                gradientStroke: false)
        }
        return nil
    }
}

#Preview {
    VStack(spacing: 8) {
        AssessmentChip(
            assessment: TaskAssessment(
                needsDecision: .humanJudgment, isBlocked: false, isUnowned: false, isStale: false,
                tier: .ask))
        AssessmentChip(
            assessment: TaskAssessment(
                needsDecision: nil, isBlocked: false, isUnowned: true, isStale: false, tier: .silent))
    }
    .padding()
    .background(Palette.background)
}
