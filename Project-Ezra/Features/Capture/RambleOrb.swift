//
//  RambleOrb.swift
//  Project-Ezra
//
//  The one object the whole Ramble arc transforms through: the capture field's rect becomes
//  this orb at submit, and the orb becomes the card composition at the reveal
//  (`matchedGeometryEffect`).
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
//  orb costs nothing to render.
//

import SwiftUI

struct RambleOrb: View {
    /// The orb's diameter, handed down from the surface's geometry (see
    /// `LayoutMetrics.rambleOrbScreenFraction`). Not self-sizing: the orb should be as big as
    /// the screen allows, and only the screen knows that.
    var diameter: CGFloat = LayoutMetrics.rambleOrbMin

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When this orb appeared — the clock every drift period is measured from, so the motion
    /// starts at a known phase rather than wherever the wall clock happens to be.
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(
            .animation(minimumInterval: Motion.orbFrameInterval, paused: reduceMotion)
        ) { timeline in
            let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)
            // Gather: 1 → 0 across `orbGatherSeconds`. Everything that should calm down as the
            // wait lengthens reads from this one number.
            let unsettled = Self.unsettled(at: elapsed)

            ZStack {
                mesh(elapsed: elapsed, unsettled: unsettled)
                specular(elapsed: elapsed, unsettled: unsettled)
                rim(unsettled: unsettled)
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            // The glow lives OUTSIDE the clip so the orb sits in its own light. It draws in as
            // the orb gathers, which is the same gesture as the turbulence decaying.
            .shadow(
                color: Palette.accentGlow,
                radius: diameter * (0.10 + 0.07 * unsettled)
            )
            .scaleEffect(breathScale(elapsed: elapsed))
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
    private func mesh(elapsed: TimeInterval, unsettled: Double) -> some View {
        MeshGradient(
            width: 4, height: 4,
            points: Self.points(elapsed: elapsed, unsettled: unsettled),
            colors: Self.colors,
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
        .blur(radius: diameter * (0.018 + 0.022 * unsettled))
    }

    /// The interior control points, displaced on incommensurate periods.
    ///
    /// Each interior point orbits its home position on its OWN period, and the x and y axes
    /// use different periods from each other — so a point traces a slow Lissajous wander, not
    /// a circle. A circle would be rotation, and rotation is the one motion this object is not
    /// allowed to have.
    static func points(elapsed: TimeInterval, unsettled: Double) -> [SIMD2<Float>] {
        let periods = Motion.orbDriftPeriods
        // Turbulence decays as the orb gathers, but never to zero: a perfectly still orb
        // would read as finished, and the system is still thinking. The floor matters more
        // than it looks — it is what the user sees for most of a long wait.
        let amplitude = Float(0.075 + 0.085 * unsettled)

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
    static let colors: [Color] = {
        let cobalt = Palette.accentStart
        let cyan = Palette.accentEnd
        func shade(_ base: Color, _ towardBlack: Double) -> Color {
            base.mix(with: .black, by: towardBlack, in: .perceptual)
        }
        func light(_ base: Color, _ towardWhite: Double) -> Color {
            base.mix(with: .white, by: towardWhite, in: .perceptual)
        }
        return [
            // Row 0 — deep shoulder.
            shade(cobalt, 0.72), shade(cobalt, 0.52), shade(cyan, 0.58), shade(cyan, 0.74),
            // Row 1 — the FIRST pool (upper-left interior), cyan and hot.
            shade(cobalt, 0.55), light(cyan, 0.48), shade(cobalt, 0.42), shade(cyan, 0.58),
            // Row 2 — the SECOND pool (lower-right interior), cobalt-bright, so the two pools
            // differ in hue as well as position and the surface never looks symmetric.
            shade(cobalt, 0.58), shade(cyan, 0.50), light(cobalt, 0.42), shade(cyan, 0.52),
            // Row 3 — back into shadow.
            shade(cobalt, 0.74), shade(cobalt, 0.56), shade(cyan, 0.60), shade(cyan, 0.76),
        ]
    }()

    // MARK: - Sphericity

    /// A soft off-centre highlight that drifts on its own slow period. This is what makes the
    /// orb read as a SPHERE rather than a disc with a pattern on it: a real ball has one place
    /// the light lands, and it is never dead centre.
    private func specular(elapsed: TimeInterval, unsettled: Double) -> some View {
        let period = Motion.orbDriftPeriods[2]
        let dx = CGFloat(sin(elapsed * 2 * .pi / period)) * diameter * 0.06
        let dy = CGFloat(cos(elapsed * 2 * .pi / (period * 1.4))) * diameter * 0.05
        return RadialGradient(
            colors: [
                Color.white.opacity(0.30 - 0.12 * unsettled),
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

    /// Scale oscillation, with amplitude scaled DOWN as the orb grows: ±4% is a nudge at 96pt
    /// and a lurch at 360pt, so a fixed percentage would make the big orb read as agitated.
    /// What should stay constant is the perceived movement, which is roughly a fixed number of
    /// points.
    private func breathScale(elapsed: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let travel = min(0.04, 6.0 / max(diameter, 1))
        let period = Motion.orbDriftPeriods[1]
        return 1 + CGFloat(sin(elapsed * 2 * .pi / period)) * travel
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
