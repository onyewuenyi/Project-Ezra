//
//  TodayBackdrop.swift
//  Project-Ezra
//
//  The Today sequence's ambient backdrop: a soft cobalt radial glow over the app
//  background that slowly drifts — on-brand cinematic atmosphere (accent family, not
//  a new hue). Gated: a plain background under Reduce Transparency; a static,
//  non-drifting glow under Reduce Motion.
//

import SwiftUI

struct TodayBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false

    var body: some View {
        ZStack {
            Palette.background
            if !reduceTransparency {
                RadialGradient(
                    colors: [Palette.backdropGlow, .clear],
                    center: reduceMotion || !drift ? .topLeading : .topTrailing,
                    startRadius: 0,
                    endRadius: 560
                )
                .animation(
                    reduceMotion ? nil : Motion.ambient.repeatForever(autoreverses: true),
                    value: drift)
            }
        }
        .ignoresSafeArea()
        .onAppear { if !reduceMotion && !reduceTransparency { drift = true } }
    }
}

/// A numeral that rolls from 0 up to `value` when animated in. `Animatable` drives the
/// interpolation, so SwiftUI re-renders the integer at each step. Reduce-Motion callers
/// simply pass the final value with no animation.
struct CountingNumber: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}
