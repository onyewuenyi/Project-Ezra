//
//  RambleOrb.swift
//  Project-Ezra
//
//  The one object the whole Ramble arc transforms through: the capture sheet opens INTO
//  this orb listening, the typed field's rect becomes it at submit, it carries the thinking
//  beat, and it becomes the card composition at the reveal (`matchedGeometryEffect`).
//
//  **The governing invariant:** the orb never asks the user to understand the system; it
//  only reflects that the system is present and receiving them — the reveal is where the
//  system proves understanding. So listening shows RECEPTION (the microphone level as
//  presence: swell, light, texture) and never interpretation, and the orb's visual state
//  never depends on model output — listening derives from mic → level → energy, thinking
//  from the deterministic phase machine. A slow, weird, or absent model cannot make this
//  object lie.
//
//  **Audio controls the orb's PRESENCE, never its speed.** The level modulates amplitude,
//  scale, glow and light — never a drift period. A level-scaled RATE is what turns a
//  listening presence into a VU meter, and rate is what decides spinner-vs-thinking
//  everywhere in this file.
//
//  **It is deliberately NOT a spinner, and must never become one.** A spinner says "wait,
//  something is loading"; this says "something is thinking". So: no rotation of anything, no
//  track, no determinate arc, no percentage, no counts. Note that RATE decides this more than
//  shape does — the same mesh at a third of `Motion.orbDriftPeriods` reads as a loading
//  indicator. If it ever reads as a loader, the fix is slower and more organic motion, never
//  a progress affordance.
//
//  **Why a mesh rather than a gradient fill.** A two-stop gradient in a circle is a disc; at
//  the size this beat now occupies, a disc reads as a very large button. `MeshGradient` gives
//  a surface whose interior moves — light pooling and thinning across it — which is what makes
//  a voice-assistant orb feel like a thing that is working rather than a shape that is
//  present. It is pure vector: no asset, no Lottie, resolution-independent, and it follows the
//  palette.
//
//  **Two hues only, and that is a constraint worth understanding.** Everything here is derived
//  from `Palette.accentStart` (cobalt) and `Palette.accentEnd` (cyan). Siri's orb gets its life
//  from hue travel; this one cannot, so it gets it from VALUE travel — cobalt mixed toward
//  near-black for shadowed lobes, cyan toward white for hot spots — plus motion. That is why
//  the mesh needs the full 4×4: with two anchors, spatial variation is doing the work that a
//  wider palette would otherwise do.
//
//  Under Reduce Motion the timeline is genuinely `paused` — not merely invisible — so a still
//  orb costs nothing to render. The LEVEL still applies, by direct value change rather than
//  glide: a level meter is data, not decoration (the rule the deleted `ListeningWaveform`
//  documented; the view is gone, the rule lives here now), and observing `monitor.level`
//  re-evaluates the closure even while the timeline is paused.
//

import SwiftUI

struct RambleOrb: View {
    /// The orb's diameter, handed down from the surface's geometry (see
    /// `LayoutMetrics.rambleOrbScreenFraction`). Not self-sizing: the orb should be as big as
    /// the screen allows, and only the screen knows that.
    var diameter: CGFloat = LayoutMetrics.rambleOrbMin

    /// What the orb is doing, which decides where its motion comes from.
    ///
    /// `.listening` holds turbulence at `Motion.orbListeningUnsettledFloor` — attentive,
    /// alive, and going nowhere: the 14s gather is the thinking gesture, and running it while
    /// someone is still speaking would read as the system finishing with them. The monitor's
    /// level arrives as energy (smoothed, soft-kneed) and swells scale, glow, wander and the
    /// specular.
    ///
    /// `.thinking` — the default, so every pre-voice call site keeps today's behavior — runs
    /// the gather. Mounted fresh it settles 1 → 0 exactly as it always has; entered FROM
    /// listening it decays from the listening floor instead (`thinkingUnsettled`), because
    /// the swap is the settle beat and a restart at 1.0 would step turbulence UP at it.
    enum Mode {
        case listening(AudioLevelMonitor)
        case thinking
    }

    var mode: Mode = .thinking

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When this orb appeared — the clock every drift period is measured from, so the motion
    /// starts at a known phase rather than wherever the wall clock happens to be. Never reset
    /// by a mode change: the mesh must not re-phase at the listening → thinking swap, which
    /// is why the swap gets its own clock (`OrbLevelSmoother.modeSwitchedAt`).
    @State private var startedAt = Date()
    /// Per-frame scratch — see `OrbLevelSmoother`. Held in `@State` for identity only; the
    /// timeline closure mutates it directly and nothing observes it.
    @State private var smoother = OrbLevelSmoother()

    var body: some View {
        TimelineView(
            .animation(minimumInterval: Motion.orbFrameInterval, paused: reduceMotion)
        ) { timeline in
            let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)
            // Gather: 1 → 0 across `orbGatherSeconds` (held at the floor while listening).
            // Everything that should calm down as the wait lengthens reads from this one
            // number.
            let unsettled = unsettledValue(elapsed: elapsed, at: timeline.date)
            let glow = breathGlow(elapsed: elapsed)
            // Reading the monitor INSIDE this closure is the leaf-observer rule: only this
            // view re-evaluates at buffer cadence (~12/s); the composer never pays it.
            let energy = energyValue(at: timeline.date)

            ZStack {
                mesh(elapsed: elapsed, unsettled: unsettled, energy: energy)
                specular(elapsed: elapsed, unsettled: unsettled, glow: glow, energy: energy)
                rim(unsettled: unsettled)
                counterRim(energy: energy)
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            // The glow lives OUTSIDE the clip so the orb sits in its own light. It draws in as
            // the orb gathers (the same gesture as the turbulence decaying), swells with each
            // breath, and blooms with the voice — the light the orb throws breathes with it.
            .shadow(
                color: Palette.accentGlow,
                radius: diameter * (0.10 + 0.07 * unsettled + 0.05 * glow + 0.06 * energy)
            )
            // The voice's own bloom: a second, softer corona that exists only while being
            // spoken to — presence arriving as light, not blink. Radius zero collapses it
            // entirely at rest, so the thinking orb is untouched.
            .shadow(
                color: Palette.accentGlow.opacity(0.6 * energy),
                radius: diameter * 0.16 * energy
            )
            // The swell rides ON TOP of the breath — speech adds presence to an already-alive
            // baseline, so a pause to think never reads as the orb going dead. Layout-safe:
            // `.scaleEffect` lives inside the fixed outer frame, so a pulse never reflows the
            // surface or fights `matchedGeometryEffect`.
            .scaleEffect(breathScale(elapsed: elapsed) * (1 + CGFloat(energy) * Motion.orbLevelSwellMax))
        }
        .frame(width: diameter, height: diameter)
        // The orb is atmosphere; the surface around it carries the spoken label.
        .accessibilityHidden(true)
    }

    // MARK: - The mesh

    /// A 4×4 control-point mesh. The twelve EDGE and CORNER points stay pinned — displacing
    /// them tears the mesh and lets the underlying rectangle show through the clip — so all
    /// the motion lives in the four interior points, which is plenty: their displacement
    /// drags the interpolated colour across the whole surface.
    private func mesh(elapsed: TimeInterval, unsettled: Double, energy: Double) -> some View {
        MeshGradient(
            width: 4, height: 4,
            points: Self.points(elapsed: elapsed, unsettled: unsettled, energy: energy),
            colors: Self.colors(energy: energy),
            smoothsColors: true
        )
        // Drawn LARGER than the circle it is clipped to: a mesh's own corners are its flattest,
        // least interesting regions, and letting them reach the silhouette would give the orb
        // four dull quadrants at its edge.
        .frame(width: diameter * 1.35, height: diameter * 1.35)
        // A whisper of blur — enough to kill banding on a large flat gradient and to soften
        // the control-grid into fluid pools, and NO more. This is a genuinely narrow window:
        // at twice this radius the mesh smears so evenly that the control points can move
        // their full travel with almost no visible change (measured — frame-to-frame peak
        // difference fell from ~80 to ~13, i.e. a moving orb that looked frozen).
        // Voice SHARPENS rather than smears: energy pulls the radius down a touch, so speech
        // reads as the surface becoming more defined. The listening floor (0.6) keeps the
        // whole range inside the measured window.
        .blur(radius: diameter * (0.018 + 0.022 * unsettled - 0.006 * energy))
    }

    /// The interior control points, displaced on incommensurate periods.
    ///
    /// Each interior point orbits its home position on its OWN period, and the x and y axes
    /// use different periods from each other — so a point traces a slow Lissajous wander, not
    /// a circle. A circle would be rotation, and rotation is the one motion this object is not
    /// allowed to have.
    ///
    /// `energy` widens the wander WITHOUT touching any period — voice adds travel and
    /// texture, never speed. The default keeps every pre-voice caller (and the thinking
    /// mode's geometry) bit-identical.
    static func points(
        elapsed: TimeInterval, unsettled: Double, energy: Double = 0
    ) -> [SIMD2<Float>] {
        let periods = Motion.orbDriftPeriods
        // Turbulence decays as the orb gathers, but never to zero: a perfectly still orb
        // would read as finished, and the system is still thinking. The floor matters more
        // than it looks — it is what the user sees for most of a long wait.
        let amplitude = Float((0.105 + 0.075 * unsettled) * (1 + 0.35 * energy))

        func wander(
            _ home: SIMD2<Float>, _ xPeriod: Double, _ yPeriod: Double, _ phase: Double
        )
            -> SIMD2<Float>
        {
            let x = Float(sin(elapsed * 2 * .pi / xPeriod + phase))
            let y = Float(cos(elapsed * 2 * .pi / yPeriod + phase * 1.7))
            return SIMD2(home.x + x * amplitude, home.y + y * amplitude)
        }

        return [
            // Row 0 — pinned.
            SIMD2(0.0, 0.0), SIMD2(0.33, 0.0), SIMD2(0.67, 0.0), SIMD2(1.0, 0.0),
            // Row 1 — edges pinned, interior wanders.
            SIMD2(0.0, 0.33),
            wander(SIMD2(0.33, 0.33), periods[0], periods[1], 0.0),
            wander(SIMD2(0.67, 0.33), periods[2], periods[3], 1.3),
            SIMD2(1.0, 0.33),
            // Row 2 — same.
            SIMD2(0.0, 0.67),
            wander(SIMD2(0.33, 0.67), periods[3], periods[0], 2.6),
            wander(SIMD2(0.67, 0.67), periods[1], periods[2], 3.9),
            SIMD2(1.0, 0.67),
            // Row 3 — pinned.
            SIMD2(0.0, 1.0), SIMD2(0.33, 1.0), SIMD2(0.67, 1.0), SIMD2(1.0, 1.0),
        ]
    }

    /// Sixteen colours for the sixteen control points, all derived from the two accent anchors
    /// by VALUE — mixed toward black for depth, toward white for light. No third hue is
    /// introduced anywhere, which is the palette decision this design is built around.
    ///
    /// `.perceptual` mixing matters here: a device-space blend between cobalt and cyan dips
    /// muddy through the middle, and the middle is most of a 4×4 mesh.
    /// The layout matters as much as the values. A clean left-cobalt / right-cyan split reads
    /// as one diagonal band — a linear gradient wearing a circle — however much the control
    /// points move. Light has to POOL instead, so the bright values sit at two interior
    /// points that are diagonally opposite and the dark values surround them. As the mesh
    /// wanders, the two pools swell and trade dominance, which is the behaviour that reads as
    /// weather rather than as a gradient.
    ///
    /// Corners are the darkest cells: they sit at the clipped silhouette, and darkening them
    /// is most of what makes the edge fall away instead of ending.
    static let colors: [Color] = colors(energy: 0)

    /// The palette as a function of the voice: at rest, byte-for-byte the shipped
    /// sixteen; with energy, the two hot pools run HOTTER and the shadowed shoulder
    /// digs a touch DEEPER — a wider value range, which is the only richness the
    /// two-hue rule permits. Deliberately small travel: the pools brighten by at most
    /// 0.14 of a mix and the shadows deepen by 0.05, so full voice reads as the same
    /// object more alive, never a different object.
    static func colors(energy: Double) -> [Color] {
        let cobalt = Palette.accentStart
        let cyan = Palette.accentEnd
        let e = min(max(energy, 0), 1)
        func shade(_ base: Color, _ towardBlack: Double) -> Color {
            base.mix(with: .black, by: towardBlack, in: .perceptual)
        }
        func light(_ base: Color, _ towardWhite: Double) -> Color {
            base.mix(with: .white, by: towardWhite, in: .perceptual)
        }
        // Pool centers gain heat; the deepest corners gain depth. Everything else holds.
        func pool(_ base: Color, _ towardWhite: Double) -> Color {
            light(base, min(0.9, towardWhite + 0.14 * e))
        }
        func corner(_ base: Color, _ towardBlack: Double) -> Color {
            shade(base, min(0.9, towardBlack + 0.05 * e))
        }
        return [
            // Row 0 — deep shoulder.
            corner(cobalt, 0.72), shade(cobalt, 0.52), shade(cyan, 0.58), corner(cyan, 0.74),
            // Row 1 — the FIRST pool (upper-left interior), cyan and hot.
            shade(cobalt, 0.55), pool(cyan, 0.48), shade(cobalt, 0.42), shade(cyan, 0.58),
            // Row 2 — the SECOND pool (lower-right interior), cobalt-bright, so the two pools
            // differ in hue as well as position and the surface never looks symmetric.
            shade(cobalt, 0.58), shade(cyan, 0.50), pool(cobalt, 0.42), shade(cyan, 0.52),
            // Row 3 — back into shadow.
            corner(cobalt, 0.74), shade(cobalt, 0.56), shade(cyan, 0.60), corner(cyan, 0.76),
        ]
    }

    // MARK: - Listening

    /// Where the turbulence sits this frame. Listening HOLDS the floor; thinking decays —
    /// from 1 on a fresh mount (today's gather, unchanged), or from the FLOOR when this orb
    /// was listening a moment ago, so the swap reads as settling rather than a fresh storm.
    ///
    /// The swap clock is tracked HERE, in the same body pass that first renders thinking —
    /// not via `.onChange`, whose ordering against the render is not guaranteed: a one-frame
    /// gap would draw the settled gather (≈0) and then step UP to the floor, which is exactly
    /// the glitch decay-from-the-floor exists to prevent. `thinkingUnsettled(0) ==
    /// orbListeningUnsettledFloor` holds on the very first thinking frame by construction.
    private func unsettledValue(elapsed: TimeInterval, at date: Date) -> Double {
        switch mode {
        case .listening:
            smoother.wasListening = true
            smoother.modeSwitchedAt = nil
            return Motion.orbListeningUnsettledFloor
        case .thinking:
            guard smoother.wasListening else { return Self.unsettled(at: elapsed) }
            let switchedAt = smoother.modeSwitchedAt ?? date
            if smoother.modeSwitchedAt == nil { smoother.modeSwitchedAt = date }
            return Self.thinkingUnsettled(sinceSwitch: date.timeIntervalSince(switchedAt))
        }
    }

    /// The voice's contribution this frame: the monitor's level, glided (`approach`) and
    /// soft-kneed (`energy`). In thinking mode any residual swell DRAINS on the same glide
    /// rather than snapping off — finishing mid-voice (the orb tap) should read as the orb
    /// settling, not flinching.
    private func energyValue(at date: Date) -> Double {
        switch mode {
        case .listening(let monitor):
            // Reading `monitor.level` registers observation, so the closure re-evaluates on
            // each ~12/s update — including under Reduce Motion, where the glide is skipped
            // and the level applies as a direct value change (data, not decoration).
            if reduceMotion { return Self.energy(level: monitor.level) }
            let dt = smoother.lastAt.map { date.timeIntervalSince($0) } ?? 0
            smoother.lastAt = date
            smoother.displayed = Self.approach(
                current: smoother.displayed, target: monitor.level, dt: dt)
            return Self.energy(level: smoother.displayed)
        case .thinking:
            guard !reduceMotion, smoother.displayed > 0.0005 else {
                smoother.displayed = 0
                return 0
            }
            let dt = smoother.lastAt.map { date.timeIntervalSince($0) } ?? 0
            smoother.lastAt = date
            smoother.displayed = Self.approach(current: smoother.displayed, target: 0, dt: dt)
            return Self.energy(level: smoother.displayed)
        }
    }

    /// One exponential step toward `target`: after `Motion.orbLevelSmoothingHalfLife`
    /// seconds, half the remaining gap is closed. Frame-rate independent — two dt/2 steps
    /// land exactly where one dt step does — so a dropped frame can never kick the surface.
    static func approach(current: Double, target: Double, dt: TimeInterval) -> Double {
        guard dt > 0 else { return current }
        let alpha = 1 - pow(0.5, dt / Motion.orbLevelSmoothingHalfLife)
        return current + (target - current) * alpha
    }

    /// The smoothed level → the orb's energy, through a soft knee: steep out of silence — a
    /// whisper must visibly register, because the user reads this surface as "was I heard?",
    /// and a mute orb over a quiet voice says no — and compressed toward the top, so emphatic
    /// speech swells without agitation. `x·(2−x)` is the ease-out quad: slope 2 at zero,
    /// slope 0 at full; monotone, 0 → 0, 1 → 1, clamped so a hot buffer can never overdrive
    /// the swell.
    static func energy(level: Double) -> Double {
        let x = min(max(level, 0), 1)
        return x * (2 - x)
    }

    // MARK: - Sphericity

    /// Two soft off-centre highlights, each drifting on its own slow period. The first is
    /// what makes the orb read as a SPHERE rather than a disc with a pattern on it: a real
    /// ball has one place the light lands, and it is never dead centre. The second is
    /// smaller, dimmer, and on a DIFFERENT incommensurate period — two lights that never
    /// re-align are what make the surface read liquid instead of printed. Voice brightens
    /// both — light, not motion.
    private func specular(
        elapsed: TimeInterval, unsettled: Double, glow: Double, energy: Double
    ) -> some View {
        let period = Motion.orbDriftPeriods[2]
        let dx = CGFloat(sin(elapsed * 2 * .pi / period)) * diameter * 0.11
        let dy = CGFloat(cos(elapsed * 2 * .pi / (period * 1.4))) * diameter * 0.09
        let second = Motion.orbDriftPeriods[3]
        let dx2 = CGFloat(cos(elapsed * 2 * .pi / second)) * diameter * 0.09
        let dy2 = CGFloat(sin(elapsed * 2 * .pi / (second * 1.3))) * diameter * 0.08
        return ZStack {
            RadialGradient(
                colors: [
                    Color.white.opacity(0.26 - 0.10 * unsettled + 0.14 * glow + 0.10 * energy),
                    Color.white.opacity(0.06),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: diameter * 0.26
            )
            .frame(width: diameter * 0.5, height: diameter * 0.5)
            .offset(x: -diameter * 0.12 + dx, y: -diameter * 0.16 + dy)
            .blur(radius: diameter * 0.05)

            RadialGradient(
                colors: [
                    Color.white.opacity(0.10 + 0.05 * glow + 0.07 * energy),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: diameter * 0.15
            )
            .frame(width: diameter * 0.3, height: diameter * 0.3)
            .offset(x: diameter * 0.18 + dx2, y: diameter * 0.10 + dy2)
            .blur(radius: diameter * 0.04)
        }
        .blendMode(.screen)
    }

    /// A whisper of counter-light along the lower limb — the second light source that
    /// makes the sphere read dimensional at 0.85 of a screen instead of front-lit flat.
    /// Cyan rather than white (the two-hue rule), faint at rest, a touch stronger under
    /// voice. Drawn after `rim` so the darkening can't swallow it.
    private func counterRim(energy: Double) -> some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.62),
                        .init(color: Palette.accentEnd.opacity(0.16 + 0.10 * energy), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: diameter * 0.045
            )
            .blur(radius: diameter * 0.025)
            .blendMode(.screen)
    }

    /// Darkening toward the silhouette, so the edge has falloff instead of a hard cut. The rim
    /// tightens as the orb gathers — the visual half of "condensing".
    private func rim(unsettled: Double) -> some View {
        // Three stops, not two: the middle one keeps the darkening off the orb's centre so
        // only the outer third falls away. A two-stop version dims the whole sphere and the
        // orb goes muddy instead of round.
        RadialGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: Color.black.opacity(0.28), location: 0.88),
                .init(color: Color.black.opacity(0.62 + 0.10 * (1 - unsettled)), location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.5
        )
    }

    // MARK: - Breath

    /// The breath — the gesture that makes this read as a thing that is alive rather than a
    /// shape that is present. Unconditional across modes: during complete silence the
    /// listening orb still breathes over the turbulence floor, so a pause to think never
    /// reads as the orb going dead.
    ///
    /// The first version scaled the amplitude DOWN as the orb grew, reasoning that a fixed
    /// percentage would be a lurch at full size. The direction was right and the magnitude was
    /// absurd: at 360pt it worked out to **±1.7% on an 11-second period**, which is to say a
    /// sphere that measurably moved and perceptibly did not. Both numbers are now what the
    /// gesture actually needs, and the size compensation is a gentle floor rather than a
    /// division that collapses toward nothing.
    private func breathScale(elapsed: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let travel = max(0.030, min(0.042, 14.0 / max(diameter, 1)))
        let phase = sin(elapsed * 2 * .pi / Motion.orbBreathPeriod)
        return 1 + CGFloat(phase) * travel
    }

    /// Light swelling with the breath, a beat behind it. A sphere that only changes SIZE reads
    /// as mechanical; one that also brightens as it expands reads as something gathering
    /// itself. The lag (a quarter period) is what keeps the two from looking like one effect.
    private func breathGlow(elapsed: TimeInterval) -> Double {
        guard !reduceMotion else { return 0 }
        let phase = sin(elapsed * 2 * .pi / Motion.orbBreathPeriod - .pi / 2)
        return 0.5 + 0.5 * phase  // 0…1
    }

    /// 1 at the moment the orb appears, easing to 0 over `Motion.orbGatherSeconds`, then
    /// staying there. Smoothstep rather than linear so the settle has no perceptible start or
    /// finish — a linear ramp reaching zero at a specific second is a progress bar you can
    /// read if you are watching for it.
    static func unsettled(at elapsed: TimeInterval) -> Double {
        let t = min(max(elapsed / Motion.orbGatherSeconds, 0), 1)
        let eased = t * t * (3 - 2 * t)  // smoothstep
        return 1 - eased
    }

    /// The gather run FROM the listening floor: the same smoothstep, scaled so the first
    /// thinking frame equals the last listening frame — `thinkingUnsettled(0) ==
    /// Motion.orbListeningUnsettledFloor`, pinned in tests. The contraction is a decay from
    /// where the orb already was, never a restart.
    static func thinkingUnsettled(sinceSwitch t: TimeInterval) -> Double {
        Motion.orbListeningUnsettledFloor * unsettled(at: t)
    }
}

/// Per-frame scratch the orb's timeline closure mutates WITHOUT invalidating the view — the
/// `LiveParseState` precedent: a plain reference box held in `@State` for identity only,
/// deliberately NOT `@Observable` and never written through a state property, so smoothing at
/// 30fps cannot start an invalidation loop.
final class OrbLevelSmoother {
    /// The level the orb is currently displaying (pre-knee).
    var displayed: Double = 0
    /// When the last glide step ran — the other half of dt.
    var lastAt: Date?
    /// Whether this orb has ever listened; decides which gather the thinking mode runs.
    var wasListening = false
    /// The moment listening ended — the clock `thinkingUnsettled` decays on.
    var modeSwitchedAt: Date?
}

#Preview("Thinking") {
    GeometryReader { proxy in
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)
            RambleOrb(diameter: min(proxy.size.width, proxy.size.height) * 0.85)
            Text("Making sense of it")
                .font(.sectionHeader)
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
    .background(Palette.background)
}

#Preview("Listening") {
    @Previewable @State var monitor = AudioLevelMonitor()
    GeometryReader { proxy in
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)
            RambleOrb(
                diameter: min(proxy.size.width, proxy.size.height) * 0.85,
                mode: .listening(monitor)
            )
            Text("Listening")
                .font(.sectionHeader)
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
    .background(Palette.background)
    .task {
        // Silence → whisper → conversational → emphatic → trailing pause, looped: the same
        // ladder the reception test judges on video.
        let envelope: [Double] = [
            0, 0, 0, 0.02, 0.03, 0.02, 0,  // silence — the breath alone
            0.10, 0.14, 0.12, 0.16, 0.11, 0.13,  // whisper — must visibly register
            0.30, 0.42, 0.38, 0.45, 0.35, 0.40,  // conversational
            0.62, 0.75, 0.68, 0.80, 0.70, 0.66,  // emphatic — swells, never jitters
            0.20, 0.08, 0.02, 0, 0, 0, 0,  // pause — the drain
        ]
        while !Task.isCancelled {
            for raw in envelope {
                monitor.ingest(rawLevel: raw)
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }
}
