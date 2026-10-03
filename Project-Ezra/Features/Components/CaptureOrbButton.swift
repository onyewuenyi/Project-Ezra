//
//  CaptureOrbButton.swift
//  Project-Ezra
//
//  The persistent Capture action: a circular Liquid Glass button holding a live mini
//  `RambleOrb`. It has two placements since the Ask-home swap (2026-09-23) — the shell
//  parks one bottom-trailing over the Tasks list, and the Ask home's composer bar
//  carries one as its trailing control — and both are THIS view at a different
//  diameter, so the capture door looks the same wherever it sits.
//
//  **Every line of the composition is load-bearing**, and all three ways to get it
//  wrong were made and caught in the simulator during the custom-bar pass (2026-08-29):
//
//  - **Glass is the BACKGROUND, never a wrapper.** `.glassChrome` draws as
//    `content.overlay { glass }` and, on its flat (Reduce Transparency / Increase
//    Contrast) path, REPLACES content with a filled shape. Wrapped around the orb it
//    would put the orb under a glass sheet — and DELETE it under either setting.
//  - **No `GlassEffectContainer`.** A container groups its descendants into the glass
//    rendering pass, which blurs them; the orb would smear. A container earns its place
//    only when two glass elements must morph, and nothing here morphs.
//  - **No tint, no coloured shadow, no dark well.** Glass is recessive chrome and the
//    orb supplies the only saturation.
//
//  It is mounted for the whole app lifetime — unlike the capture beat's orb, which
//  exists only while someone waits — so it runs only while it can actually be seen:
//  the shell says when a sheet, onboarding or the background covers it (`\.orbCovered`).
//

import SwiftUI

extension EnvironmentValues {
    /// Whether something is drawn over the capture orb right now — a presented sheet,
    /// onboarding, the app in the background. The shell decides; every placement obeys,
    /// so a permanently-mounted animation never runs where nobody can see it.
    @Entry var orbCovered: Bool = false
}

struct CaptureOrbButton: View {
    /// The button's diameter. The shell's is 62pt (grown from the retired FAB's 52pt on
    /// 2026-08-29, sized to the system tab bar capsule it once sat beside); the bar's is
    /// the HIG hit target.
    var diameter: CGFloat = 62
    /// The orb inside it. The shell keeps the 11pt glass bezel the old 52/30 pairing
    /// had: the bezel is what makes this read as a lens set into a button rather than
    /// a bare orb floating beside the content.
    var orbDiameter: CGFloat = 40
    /// Paused beyond what `\.orbCovered` already knows — the shell adds the keyboard.
    var paused: Bool = false
    let action: () -> Void

    @Environment(\.orbCovered) private var covered

    var body: some View {
        Button(action: action) {
            RambleOrb(
                diameter: orbDiameter,
                frameInterval: Motion.orbBarFrameInterval,
                paused: paused || covered
            )
            .frame(width: diameter, height: diameter)
            .background { Color.clear.glassChrome(in: Circle(), interactive: true) }
        }
        .buttonStyle(.pressable)
        // `RambleOrb` is `.accessibilityHidden(true)` — it is atmosphere — so the button
        // has no other label source.
        .accessibilityLabel("Capture a task")
    }
}

#Preview {
    HStack(spacing: 24) {
        CaptureOrbButton {}
        CaptureOrbButton(diameter: 44, orbDiameter: 28) {}
    }
    .padding()
    .background(Palette.background)
}
