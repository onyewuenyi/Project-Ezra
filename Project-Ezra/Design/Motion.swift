//
//  Motion.swift
//  Project-Ezra
//
//  Named motion tokens — the same role `Palette` plays for color. Every value here
//  is preserved from an existing inline usage so adopting the token is a no-op on
//  screen; the win is that the design system's spring spec becomes enforceable and
//  the Reduce Motion fallback (non-negotiable, per the design doc) is applied the
//  same way everywhere.
//  Source of truth: docs/design-system-managing-chaos.md
//

import SwiftUI
import UIKit

// MARK: - Motion tokens

enum Motion {

    // Springs — frequency-tiered, critically damped (dampingFraction 1.0) so nothing
    // overshoots. Faster for high-frequency responses, slower for earned moments.

    /// System responses (<150ms rule): undo, subsequent retro decisions.
    static let snap = Animation.spring(response: 0.15, dampingFraction: 1.0)
    /// Completion motion — kept under 200ms because an active user completes many a day.
    static let complete = Animation.spring(response: 0.18, dampingFraction: 1.0)
    /// The hold before `onComplete` mutates the store (matches TaskCardView's fade-out).
    static let completeHold: TimeInterval = 0.19
    /// Inbox triage decision.
    static let decide = Animation.spring(response: 0.2, dampingFraction: 1.0)
    /// The retro's first decision — allowed a beat; subsequent ones use `snap`.
    static let decideFirst = Animation.spring(response: 0.3, dampingFraction: 1.0)
    /// Today's entrance / list settle.
    static let settle = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Per-card delay in a staggered entrance (capped spread).
    static let staggerStep: Double = 0.05

    // Today sequence (spec §4.3), calibrated to the design-engineering rules: express
    // in Apple's clearer duration/bounce form; keep transitions crisp (a faster settle
    // reads as more responsive, so durations sit at/under ~0.5s); critically damped
    // (bounce 0) by default because overshoot on something that merely arrives feels
    // wrong; a bounce (kept in the earned 0.1–0.3 range) ONLY where the moment is rare
    // and celebratory — the hero numeral and the plan payoff, nowhere else.

    /// Beat-to-beat advance (Recap → Docket → Plan): modal recede. Critically damped —
    /// the user follows a spatial shift, which earns no overshoot. 0.42s reads
    /// deliberate without dragging.
    static let beatAdvance = Animation.spring(duration: 0.42, bounce: 0)
    /// The day's centerpiece landing (the Recap hero numeral): rises and settles with a
    /// clean, earned overshoot — rare + celebratory, so a touch of life is right.
    static let heroSettle = Animation.spring(duration: 0.5, bounce: 0.22)
    /// Capacity capsule entrance — blur + scale materialize together. No bounce: a
    /// surface arriving shouldn't overshoot.
    static let capsuleExpand = Animation.spring(duration: 0.4, bounce: 0)
    /// Plan items landing — the ONE earned bounce in the whole sequence, snappy (0.34s)
    /// so the payoff feels alive, not springy.
    static let planLanding = Animation.spring(duration: 0.34, bounce: 0.2)
    /// The advisor briefing arriving after the Recap cover — a slightly longer,
    /// confident reveal for the payoff scene.
    static let briefingReveal = Animation.spring(duration: 0.6, bounce: 0.12)
    /// The Recap numeral counting up 0→N — an eased roll, not a spring.
    static let countUp = Animation.easeOut(duration: 0.9)

    /// Press feedback — touch-down/up on every pressable surface.
    static let press = Animation.easeOut(duration: 0.15)
    /// Opacity cross-fades: empty-state ↔ list swaps, blocked frost. Comprehension
    /// aids — these stay on under Reduce Motion (opacity only), per the design doc.
    static let fade = Animation.easeOut(duration: 0.2)

    // Onboarding — the one place that earns dramatic, extended motion.
    static let onboardSettle = Animation.spring(response: 0.6, dampingFraction: 0.75)
    static let onboardReveal = Animation.spring(response: 0.6, dampingFraction: 0.8)
    static let onboardStaggerStep: Double = 0.04

    /// The composer's "thinking" glow pulse — never a spinner.
    static let glowPulse = Animation.easeInOut(duration: 0.6)
    /// Slow ambient drift for the held-depth diffuse field.
    static let ambient = Animation.easeInOut(duration: 6)

    // MARK: - Reduce-motion helpers (imperative sites)

    // Declarative `.animation(_:value:)` sites keep the house `@Environment(
    // \.accessibilityReduceMotion)` pattern; these two are for `withAnimation`
    // call sites, where reading the UIKit global at event time is the clean read.

    /// Returns the animation, or `nil` under Reduce Motion (an un-animated change).
    static func respecting(_ animation: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }

    /// `withAnimation` that respects Reduce Motion.
    @discardableResult
    static func withMotion<Result>(_ animation: Animation, _ body: () -> Result) -> Result {
        withAnimation(respecting(animation), body)
    }

    // MARK: - Transitions (asymmetric enter/exit)

    /// A card arriving from nothing: rises 8pt and fades in; on removal just fades
    /// (the neighbor sliding up is the real motion, so no exit offset).
    static let cardEntry = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 8)),
        removal: .opacity
    )

    /// A chip appearing/leaving — a small trailing-anchored scale + fade.
    static let chip = AnyTransition.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing))

    /// The cinematic beat transition (Recap → Docket → Plan): the outgoing beat
    /// recedes (scales to 0.93, dims, blurs) while the incoming beat advances forward
    /// (rises from 0.98, clears its blur). The blur bridges the two states so the eye
    /// reads one transformation, not two screens crossfading (masking trick). Top
    /// anchor keeps the header edge stable. Callers pass `.opacity` instead under
    /// Reduce Motion — movement out, comprehension-preserving fade in.
    static let beatRecede = AnyTransition.asymmetric(
        insertion: .opacity
            .combined(with: .scale(scale: 0.98, anchor: .top))
            .combined(with: blur(4)),
        removal: .opacity
            .combined(with: .scale(scale: 0.93, anchor: .top))
            .combined(with: blur(4))
    )

    /// A blur transition between `radius` (active/out-of-frame) and 0 (identity).
    private static func blur(_ radius: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurTransitionModifier(radius: radius),
            identity: BlurTransitionModifier(radius: 0))
    }
}

/// Backs `Motion.beatRecede`'s blur masking — a transition-driven blur radius.
private struct BlurTransitionModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

// MARK: - Repeating animation helper

extension Animation {
    /// Repeats forever while `active` is true; otherwise runs once. Used for the
    /// composer's processing glow and the mic capsule.
    ///
    /// The Reduce Motion gate lives HERE, not at call sites, on the design system's
    /// "the modifier enforces the rule" principle: two of the three original call
    /// sites forgot the gate (an infinite pulse is precisely what Reduce Motion users
    /// opt out of), and a gate a call site can forget isn't a rule. Same UIKit-global
    /// read as `Motion.respecting` — these fire from value changes, not body builds,
    /// so the event-time read is the clean one.
    func repeatWhileTrue(_ active: Bool) -> Animation {
        guard active, !UIAccessibility.isReduceMotionEnabled else { return self }
        return self.repeatForever(autoreverses: true)
    }
}

// MARK: - PressableStyle

/// The one press-feedback button style. Buttons must confirm the interface heard the
/// touch — the biggest cross-cutting gap this closes. Role decides the feedback:
/// larger surfaces scale (the shrink carries it), small targets dim (shrinking a tiny
/// hit area reads as broken). Under Reduce Motion, scale is dropped and the dim is
/// used for every role instead.
struct PressableStyle: ButtonStyle {
    enum Role { case surface, prominent, textLink, icon }

    let role: Role
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let usesScale = (role == .surface || role == .prominent) && !reduceMotion
        return
            configuration.label
            .scaleEffect(usesScale && pressed ? 0.97 : 1)
            .opacity(!usesScale && pressed ? 0.6 : 1)
            .animation(Motion.press, value: pressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Scales on press (0.97). For medium+ surfaces — decision bars, glass rows.
    static var pressable: PressableStyle { PressableStyle(role: .surface) }
    /// Scales on press (0.97). For primary CTAs on the accent gradient.
    static var pressableProminent: PressableStyle { PressableStyle(role: .prominent) }
    /// Dims on press (0.6). For text buttons — small targets shouldn't shrink.
    static var pressableLink: PressableStyle { PressableStyle(role: .textLink) }
    /// Dims on press (0.6). For icon-only controls.
    static var pressableIcon: PressableStyle { PressableStyle(role: .icon) }
}
