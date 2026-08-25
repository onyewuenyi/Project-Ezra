//
//  HeldDepthView.swift
//  Project-Ezra
//
//  The signature glass motif and the AI-trail entry point: "AI handled N / holding
//  M". On top, the crisp count; behind it, slow unreadable diffuse motion under a
//  genuine Liquid Glass layer — atmosphere, never the only signal. Falls back to a
//  flat surface under Reduce Transparency / Reduce Motion (the CLAUDE.md exemplar
//  for glass-with-a-fallback). Relocated out of the retired Now surface; the Today
//  resting state renders it below the plan once the AI has handled something.
//

import SwiftUI

/// Renders the "AI handled N / holding M" moment. On top: the crisp count. Behind:
/// slow, unreadable diffuse motion under glass — atmosphere, never the only signal.
/// Falls back to a flat surface under Reduce Transparency / Reduce Motion.
struct HeldDepthView: View {
    let heldCount: Int
    let tidiedCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glassShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }

    var body: some View {
        ZStack {
            // The held chaos churns behind a real Liquid Glass layer (the design
            // system's tinted-over-content path). On iOS 27 the system diffuses this
            // complex, moving content far better than iOS 26 (darkened edge + brighter
            // specular), so we hand the glass genuine content to sample rather than
            // faking a blur. `.glassChrome` owns the Reduce Transparency / Increase
            // Contrast fallback (flat surface) and the hairline border.
            GlassEffectContainer {
                DiffuseField(animated: !reduceMotion)
                    .clipShape(glassShape)
                    .glassChrome(in: glassShape, tint: Palette.accentStart.opacity(0.10))
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Palette.accentFlat)
                VStack(alignment: .leading, spacing: 2) {
                    // Names the CONSEQUENCE, not the actor. "AI handled N items" told the
                    // user which technology did it; what they actually want to know is that
                    // N things were dealt with and they can go look. The per-row actor is
                    // shown in Activity, one tap away, where attribution belongs.
                    Text("Tidied \(tidiedCount) item\(tidiedCount == 1 ? "" : "s")")
                        .font(.supporting.weight(.medium))
                        .foregroundStyle(Palette.primaryText)
                    if heldCount > 0 {
                        Text("\(heldCount) more held for later")
                            .metadataStyle()
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.glyphCaption(.semibold))
                    .foregroundStyle(Palette.mutedText)
            }
            .padding(Spacing.md)
        }
        .frame(height: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Tidied \(tidiedCount) items, \(heldCount) held for later. Opens activity.")
    }
}

/// Slow, deliberately unreadable colored motion — the chaos held behind glass.
/// Kept only lightly blurred so the Liquid Glass layer over it has genuine complex
/// content to diffuse; on iOS 27 that diffusion is what reads as real depth.
private struct DiffuseField: View {
    let animated: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            Palette.background
            ForEach(0..<7, id: \.self) { i in
                Circle()
                    .fill(i.isMultiple(of: 2) ? Palette.accentStart : Palette.accentEnd)
                    .frame(width: 54, height: 54)
                    .opacity(0.5)
                    .blur(radius: 6)
                    .offset(
                        x: CGFloat(i) * 52 - 150 + (phase ? 26 : -26),
                        y: (i.isMultiple(of: 2) ? -16 : 18) + (phase ? 10 : -10)
                    )
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(Motion.ambient.repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}
