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
    /// The Ramble orb's breath — seconds-long on purpose. Faster reads as a spinner;
    /// this reads as thinking.
    static let orbBreath = Animation.easeInOut(duration: 2.4)
    static let ambient = Animation.easeInOut(duration: 6)

    // MARK: - The Ramble orb's internal weather

    /// The periods the orb's mesh control points travel on, in seconds.
    ///
    /// **Deliberately incommensurate** (no common divisor worth speaking of): the surface's
    /// combined state has no short repeat, so the eye never catches a loop. That irregularity
    /// is the entire difference between "alive" and "animating" — three points on 8s would
    /// pulse in unison every eight seconds and instantly read as a mechanism.
    ///
    /// They are also all SLOW. The orb must never read as a spinner, and rate is what decides
    /// that far more than shape: the same mesh at a third of these periods looks like a
    /// loading indicator.
    static let orbDriftPeriods: [Double] = [4.3, 5.9, 3.5, 7.1]

    /// The orb's breath, in seconds — the period it expands and contracts on.
    ///
    /// Named separately from the drift periods because it is a different idea, and reusing a
    /// drift period for it (11.1s, in the first version) produced an orb that measurably
    /// moved and perceptibly did not: a breath on a ten-second cycle is not a breath. This is
    /// deliberately in the range a calm person actually breathes at, which is what the
    /// gesture is imitating.
    static let orbBreathPeriod: Double = 3.2

    /// Frame ceiling for the CAPTURE orb's timeline — the screen-filling beat. It runs during
    /// exactly the window the model is generating, so it is capped rather than free-running at
    /// display rate: a fluid gradient gains nothing visible above this and the ANE needs the
    /// room.
    ///
    /// That "exactly the window the model is generating" premise stopped being universal on
    /// 2026-08-29, when a mini orb took up residence inside the Capture button beside the system
    /// tab bar and began running for the whole app lifetime. This constant still describes the
    /// capture beat; the always-on instance uses `orbBarFrameInterval` below.
    static let orbFrameInterval: Double = 1.0 / 30.0

    /// Frame ceiling for the CHROME orb — the mini instance inside the Capture button beside
    /// the system tab bar, which is mounted for as long as the app is.
    ///
    /// Half the capture orb's rate, because at that scale there is half as much to see: the
    /// mesh's weather is sub-pixel at ~40pt (blur lands well under a point and the control
    /// points travel a few), so what actually reads is the breath and the light riding it.
    /// A 3.2s breath is indistinguishable at this rate and costs half as much to draw.
    ///
    /// That orb is additionally PAUSED whenever it is covered or the app is backgrounded
    /// (`RambleOrb.paused`) — a permanently-mounted timeline should only run while someone can
    /// actually see it.
    static let orbBarFrameInterval: Double = 1.0 / 15.0

    /// How long the orb takes to gather — a slow, one-way settle from diffuse haze into a
    /// defined object.
    ///
    /// The answer to the one real complaint about a spinner-free wait: a fixed-amplitude
    /// breath makes twenty seconds indistinguishable from stalled. The orb CONDENSES as the
    /// wait lengthens — turbulence decays, the rim tightens — so time passing is legible in
    /// the object itself. It reports nothing: the settle is not tied to generation progress
    /// (there is no such signal, and inventing one would be a lie), and it never reaches a
    /// state that reads as "done". A fire that has caught, not a progress bar.
    static let orbGatherSeconds: Double = 14

    /// The shortest time the orb may hold the screen once it has taken it.
    ///
    /// **A problem the pipeline getting FASTER created.** The orb was designed against an
    /// on-device parse measured in many seconds, where a minimum was unimaginable. A
    /// healthy cloud read answers a median ramble in about a second — and `heroSettle` is
    /// a 0.5s spring, so without a floor the field morphs into an orb that is still
    /// arriving when it starts morphing into cards. The breath (3.2s) never completes a
    /// single cycle, the gather never visibly begins, and the product's signature moment
    /// renders as a stutter between two layouts. A flash of a screen-filling mesh gradient
    /// reads as a bug, and a bug costs more than a beat does.
    ///
    /// Sized as "the entrance spring, plus enough held presence to read as an object
    /// rather than a transition artifact" — NOT as a fraction of the breath. Making the
    /// user wait a full breath for an answer that already exists would be theatre, which
    /// is the thing one floor below a flicker.
    ///
    /// It can only ever fire when the model beat the animation, so it never lengthens a
    /// wait anyone is actually feeling — the slow captures this product worries about are
    /// far past it and unaffected.
    static let orbMinimumDwellSeconds: Double = 1.1

    /// The dwell floor for a VOICE capture the deterministic read answered (~2ms) —
    /// where this floor IS the reveal latency, not a guard against one.
    ///
    /// **0.7 is a CANDIDATE UX dwell, not a number the animation was shrunk to** —
    /// the distinction is the owner's (2026-08-29) and it decides how this constant
    /// may ever change. The performance contract's 0.8s simple-tier p50 is a target
    /// the experience should meet; it is not permission to damage the interaction to
    /// meet it, and if a longer beat visibly feels better while the measured result
    /// lands at 0.82s, the right move is to keep the better beat and note the miss —
    /// never to sacrifice 20ms of feel for a row in a table.
    ///
    /// Why a shorter candidate is even plausible here: the 1.1s above was sized for
    /// the cloud path's ARRIVAL — field morphs to orb, entrance spring, held
    /// presence. On the voice-local path none of that entrance exists: the orb has
    /// been on screen since listening, the phase change is same-branch (only the
    /// status word animates, the orb decays from its listening floor), so the floor
    /// buys only the acknowledgment beat — the 0.5s `heroSettle` on the status word
    /// plus a moment of settled presence.
    ///
    /// **The VIDEO test decides, not the target** (the repo rule for every orb
    /// beat): if the frame strip shows the listening orb still mid-decay when the
    /// card morph begins, step this up until it reads as calm — and let the contract
    /// report whatever number that produces.
    static let orbLocalDwellSeconds: Double = 0.7

    /// The turbulence the orb HOLDS while listening — attentive, alive, and going nowhere.
    ///
    /// Listening has no 14-second burn-down: the gather is the THINKING gesture (a wait
    /// condensing toward an answer), and running it while someone is still speaking would
    /// read as the system finishing with them. This is also the value `thinkingUnsettled`
    /// decays FROM at the listening → thinking swap — restarting the gather at 1.0 would
    /// step turbulence UP at the exact beat the orb should read as settling.
    static let orbListeningUnsettledFloor: Double = 0.6

    /// How much of itself the orb may swell at full voice — the ceiling on the energy-driven
    /// scale term, layered ON TOP of the breath. Presence, not a meter: much lower would be
    /// invisible beside the ±3–4% breath; much higher starts tracking syllables.
    static let orbLevelSwellMax: Double = 0.09

    /// Half-life of the orb's glide toward the microphone level, in seconds.
    ///
    /// The monitor updates at buffer cadence (~12/s); the orb draws at 30fps — this is what
    /// turns those steps into a glide. Short enough that speech onset is felt, long enough
    /// that the surface never flickers with the waveform. THE anti-VU-meter number: tune it
    /// (with the soft-knee energy curve) against the reception test, never toward zero.
    static let orbLevelSmoothingHalfLife: Double = 0.12

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
