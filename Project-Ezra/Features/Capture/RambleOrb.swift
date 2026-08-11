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
    @State private var settledIn = false

    /// The orb's resting diameter. A named metric, like every other layout constant.
    static let diameter: CGFloat = LayoutMetrics.rambleOrb

    /// How long the orb takes to gather itself — a slow, one-way settle from a diffuse
    /// haze into a defined object.
    ///
    /// This is the answer to the one real complaint about a spinner-free wait: a single
    /// object breathing at a fixed amplitude has no sense of progression, so somewhere
    /// past fifteen seconds "calm" becomes indistinguishable from "stalled". The orb now
    /// CONDENSES over that window — the glow tightens, the edge sharpens, the breath
    /// narrows — so time passing is legible in the object itself.
    ///
    /// It reports nothing. The settle is not tied to generation progress (there is no such
    /// signal, and inventing one would be a lie), it does not complete at any particular
    /// moment, and it never reaches a state that reads as "done". It is the difference
    /// between a fire that has caught and a progress bar.
    private static let gatherSeconds: TimeInterval = 14

    var body: some View {
        let gathered = settledIn || reduceMotion
        Circle()
            .fill(Palette.accentGradient)
            .frame(width: Self.diameter, height: Self.diameter)
            // The glow is the "thinking" half — it breathes wider than the orb does, so
            // the edge stays soft instead of pulsing like a status light. It starts wide
            // and diffuse and draws in as the wait lengthens.
            .shadow(
                color: Palette.accentGlow,
                radius: (breathing ? 28 : 16) * (gathered ? 0.62 : 1.0)
            )
            .blur(radius: gathered ? 0 : 6)
            // The breath narrows as it gathers: early on it swings wide and loose, later
            // it holds closer — an object concentrating, not one winding down.
            .scaleEffect(breathing ? (gathered ? 1.02 : 1.06) : (gathered ? 0.99 : 0.94))
            .animation(
                reduceMotion ? nil : Motion.orbBreath.repeatWhileTrue(true), value: breathing
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.gatherSeconds), value: settledIn)
            .onAppear {
                guard !reduceMotion else { return }
                breathing = true
                settledIn = true
            }
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
