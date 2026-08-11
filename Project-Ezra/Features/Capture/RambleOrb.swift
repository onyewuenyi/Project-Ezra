//
//  RambleOrb.swift
//  Project-Ezra
//
//  The one object the whole Ramble arc transforms through: the capture field's rect
//  becomes this orb at submit, and the orb becomes the card composition at the reveal
//  (`matchedGeometryEffect`, the idiom the voice hero already uses).
//
//  It is deliberately NOT a spinner, and must never become one. A spinner says "wait,
//  something is loading"; this says "something is thinking". So: no rotation, no track,
//  no determinate arc, no percentage — a slow breath and a drifting gradient, on a
//  timescale (seconds, not fractions) that reads as continuous intelligence. If it ever
//  reads as a loader, the fix is slower and more organic motion, never a progress
//  affordance.
//
//  Under Reduce Motion it holds perfectly still: the gradient and glow alone carry it.
//

import SwiftUI

struct RambleOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// The orb's resting diameter. A named metric, like every other layout constant.
    static let diameter: CGFloat = LayoutMetrics.rambleOrb

    var body: some View {
        Circle()
            .fill(Palette.accentGradient)
            .frame(width: Self.diameter, height: Self.diameter)
            // The glow is the "thinking" half — it breathes wider than the orb does, so
            // the edge stays soft instead of pulsing like a status light.
            .shadow(color: Palette.accentGlow, radius: breathing ? 28 : 16)
            .scaleEffect(breathing ? 1.04 : 0.96)
            .animation(
                reduceMotion ? nil : Motion.orbBreath.repeatWhileTrue(true), value: breathing
            )
            .onAppear { if !reduceMotion { breathing = true } }
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: Spacing.xl) {
        RambleOrb()
        Text("Making sense of it")
            .font(.sectionHeader)
            .foregroundStyle(Palette.primaryText)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.background)
}
