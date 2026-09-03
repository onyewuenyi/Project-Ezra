//
//  Glass.swift
//  Project-Ezra
//
//  The Liquid Glass design system. Glass is CHROME, never content — floating
//  controls that sit over the record surface. This centralizes the one correct
//  iOS 27 recipe so every glass surface reads identically: a neutral `.regular`
//  `.glassEffect(_:in:)`, a `Palette.border` hairline, and a solid
//  `Palette.secondarySurface` fallback under Reduce Transparency AND Increase
//  Contrast.
//
//  Rules encoded here:
//  - Neutral `.regular` for plain chrome; an accent tint is passed only by the
//    signature AI tile (`HeldDepthView`). A tint over a near-black list has nothing
//    to refract and reads muddy, so plain chrome stays untinted.
//  - `.interactive()` on tappable chrome for the system's native press response.
//  - The `GlassEffectContainer` lives at the CALL SITE, never here: `glassEffectID`
//    morphing needs ONE container spanning both endpoints, so baking a container
//    per element would silently kill the morph.
//
//  Also home to the "recessed"/blocked treatment that REPLACES the old content blur
//  (glass-on-content was the anti-pattern that read muddy): a contrast-aware dim plus
//  a small `BlockedIndicator`, never a blur.
//

import SwiftUI

// MARK: - Glass chrome

private struct GlassChromeModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    /// Optional matched-glass morph across a state change (e.g. the segmented pill
    /// flowing between tabs). Uses `glassEffectID` on real glass and
    /// `matchedGeometryEffect` on the flat fallback.
    var morph: (id: AnyHashable, ns: Namespace.ID)? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Glass is dropped for BOTH signals — Reduce Transparency and Increase Contrast —
    /// falling back to a solid, legible chrome surface.
    private var usesFlat: Bool { reduceTransparency || contrast == .increased }

    func body(content: Content) -> some View {
        surface(content)
            .overlay { shape.strokeBorder(Palette.border, lineWidth: 0.5) }
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if usesFlat {
            if let morph {
                shape.fill(Palette.secondarySurface)
                    .matchedGeometryEffect(id: morph.id, in: morph.ns)
            } else {
                shape.fill(Palette.secondarySurface)
            }
        } else {
            // Glass lenses the live content behind it (the exemplar hands it real
            // content to sample; a plain pill hands it `Color.clear`).
            content.overlay { glassLayer }
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        let glass = resolvedGlass()
        if let morph {
            Color.clear
                .glassEffect(glass, in: shape)
                .glassEffectID(morph.id, in: morph.ns)
        } else {
            Color.clear.glassEffect(glass, in: shape)
        }
    }

    private func resolvedGlass() -> Glass {
        var glass = tint.map { Glass.regular.tint($0) } ?? .regular
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Liquid Glass chrome in an arbitrary shape (default: the card radius). Neutral by
    /// default; pass `tint` only for the signature AI surface, `interactive: true` for
    /// tappable chrome, and `morph` to flow the glass across a selection change. The
    /// caller must wrap a morphing region in a single `GlassEffectContainer`.
    func glassChrome(
        in shape: some InsettableShape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
        tint: Color? = nil, interactive: Bool = false,
        morph: (id: AnyHashable, ns: Namespace.ID)? = nil
    ) -> some View {
        modifier(GlassChromeModifier(shape: shape, tint: tint, interactive: interactive, morph: morph))
    }

    /// Liquid Glass chrome in a capsule — the pill/segmented-control shape. NOTE: glass
    /// carries a vibrancy that dims foreground text — do NOT put high-contrast labels on
    /// it; a text-bearing selection chip uses a solid surface instead (see the My Tasks
    /// segmented pill). Glass chrome is for icon/press affordances, not primary text.
    func glassCapsule(
        tint: Color? = nil, interactive: Bool = false,
        morph: (id: AnyHashable, ns: Namespace.ID)? = nil
    ) -> some View {
        glassChrome(in: Capsule(), tint: tint, interactive: interactive, morph: morph)
    }
}

// MARK: - Recessed / blocked treatment (replaces content blur)

private struct RecessedModifier: ViewModifier {
    let on: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Under Increase Contrast the dim lifts so blocked text stays legible — the
        // visible marker is the guaranteed cue, the dim is only atmosphere.
        content.opacity(on ? (contrast == .increased ? 0.85 : 0.6) : 1)
    }
}

extension View {
    /// Recede blocked/inactive content — a contrast-aware dim, NEVER a blur (glass on
    /// content is the muddy anti-pattern this replaces). Pair with `BlockedIndicator`
    /// on surfaces that don't already show a blocked label.
    func recessed(_ on: Bool) -> some View { modifier(RecessedModifier(on: on)) }
}

/// The small "waiting/blocked" marker that replaces the old blur on dense rows. Reuses
/// the app's existing `hourglass` waiting glyph (the same vocabulary as external-blocker
/// waits elsewhere), so it reads as recognition, not a new symbol. Silent to VoiceOver —
/// the row already announces "blocked".
struct BlockedIndicator: View {
    var body: some View {
        Image(systemName: "hourglass")
            .font(.glyphCaption())
            .foregroundStyle(Palette.mutedText)
            .accessibilityHidden(true)
    }
}

/// The chain marker: how many tasks are linked into this row's dependency chain, in the
/// same row slot the blocked hourglass and the step count use.
///
/// **Deliberately not a button.** It replaced a 44pt expander that toggled the chain open
/// in the list, which gave a stack row two tap targets and put a control exactly where
/// `TaskRow` draws the due label. The pile's depth is already drawn — the peek slivers
/// behind the card — so this states the number and nothing more; opening the row and
/// paging is how you reach the members (`TaskDetailPeers.flatten` unrolls a chain
/// root-first). Silent to VoiceOver: the row announces the chain in words.
struct ChainDepthIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.glyphNano())
            Text("\(count)")
                .font(.chipLabel)
                .monospacedDigit()
        }
        .foregroundStyle(Palette.mutedText)
        .accessibilityHidden(true)
    }
}

/// The container marker: "1/3" beside a broken-down task, in the same row slot the
/// blocked hourglass uses.
///
/// **Deliberately not the hourglass.** A task with open steps genuinely can't be finished
/// yet, which makes it tempting to render as blocked — but the hourglass means "waiting on
/// the world", and a task you just decomposed is the opposite of stuck. Stating the count
/// says the same thing truthfully and tells the user something they didn't know. Silent to
/// VoiceOver; the row announces the progress in words.
struct StepProgressIndicator: View {
    let progress: StepProgress

    var body: some View {
        Text("\(progress.done)/\(progress.total)")
            .font(.chipLabel)
            .monospacedDigit()
            .foregroundStyle(progress.isComplete ? Palette.accentFlat : Palette.mutedText)
            .accessibilityHidden(true)
    }
}
