//
//  RambleOrbEnergyTests.swift
//  Project-EzraTests
//
//  The listening orb's pure math: energy threading (pinned edges, monotone widening,
//  a bit-identical no-energy path), the listening → thinking continuity rule, the
//  glide, and the soft-knee level → energy curve. All statics — no TimelineView, no
//  mic, no view mounted.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct RambleOrbEnergyTests {

    // MARK: - Points

    @Test("Edge and corner control points stay pinned at every energy")
    func pinnedEdges() {
        // Rows 0 and 3, plus the edge columns of rows 1 and 2 — displacing any of
        // these tears the mesh and shows the backing rectangle through the clip.
        let pinned = [0, 1, 2, 3, 4, 7, 8, 11, 12, 13, 14, 15]
        let base = RambleOrb.points(elapsed: 2.7, unsettled: 0.5)
        for energy in [0.0, 0.25, 0.5, 1.0] {
            let points = RambleOrb.points(elapsed: 2.7, unsettled: 0.5, energy: energy)
            for index in pinned {
                #expect(points[index] == base[index])
            }
        }
    }

    @Test("energy: 0 is bit-identical to the pre-voice geometry")
    func zeroEnergyRegression() {
        for elapsed in [0.0, 1.3, 7.9, 20.0] {
            for unsettled in [0.0, 0.4, 1.0] {
                let old = RambleOrb.points(elapsed: elapsed, unsettled: unsettled)
                let new = RambleOrb.points(elapsed: elapsed, unsettled: unsettled, energy: 0)
                #expect(old == new)
            }
        }
    }

    @Test("Interior wander widens monotonically with energy — more travel, same period")
    func amplitudeMonotoneInEnergy() {
        // At a fixed instant the wander direction is fixed, so displacement from home
        // isolates the amplitude term. Presence, never speed: energy may only scale
        // this distance, and the pinned-period claim is that the SAME elapsed gives a
        // colinear, longer displacement.
        let home = SIMD2<Float>(0.33, 0.33)
        let elapsed = 1.234
        var last = Float(-1)
        for energy in [0.0, 0.3, 0.6, 1.0] {
            let point = RambleOrb.points(elapsed: elapsed, unsettled: 0.6, energy: energy)[5]
            let dx = point.x - home.x
            let dy = point.y - home.y
            let distance = (dx * dx + dy * dy).squareRoot()
            #expect(distance > last)
            last = distance
        }
    }

    // MARK: - The listening → thinking swap

    @Test("The contraction decays FROM the listening floor — never a gather restart")
    func thinkingContinuity() {
        // The first thinking frame equals the last listening frame; a restart at 1.0
        // would step turbulence UP at the exact beat the orb should read as settling.
        #expect(
            RambleOrb.thinkingUnsettled(sinceSwitch: 0) == Motion.orbListeningUnsettledFloor)
        var last = Motion.orbListeningUnsettledFloor
        for t in stride(from: 0.5, through: Motion.orbGatherSeconds, by: 0.5) {
            let unsettled = RambleOrb.thinkingUnsettled(sinceSwitch: t)
            #expect(unsettled <= last)
            #expect(unsettled >= 0)
            last = unsettled
        }
        #expect(RambleOrb.thinkingUnsettled(sinceSwitch: Motion.orbGatherSeconds) == 0)
    }

    // MARK: - The swell

    @Test("Energy clamps its input, so the swell can never exceed its ceiling")
    func swellClamp() {
        #expect(RambleOrb.energy(level: -0.5) == 0)
        #expect(RambleOrb.energy(level: 5) == 1)
        let maxScale = 1 + RambleOrb.energy(level: 5) * Motion.orbLevelSwellMax
        #expect(maxScale <= 1 + Motion.orbLevelSwellMax + 1e-12)
    }

    // MARK: - The glide

    @Test("The glide approaches monotonically and is frame-rate independent")
    func approachBehavior() {
        // Toward the target from both sides, never past it.
        let up = RambleOrb.approach(current: 0.2, target: 0.8, dt: 1.0 / 30)
        #expect(up > 0.2 && up < 0.8)
        let down = RambleOrb.approach(current: 0.8, target: 0.2, dt: 1.0 / 30)
        #expect(down < 0.8 && down > 0.2)
        // dt-robust: two half steps land exactly where one full step does, so a
        // dropped frame can never kick the surface.
        let full = RambleOrb.approach(current: 0.1, target: 0.9, dt: 0.1)
        let halfway = RambleOrb.approach(current: 0.1, target: 0.9, dt: 0.05)
        let twoHalves = RambleOrb.approach(current: halfway, target: 0.9, dt: 0.05)
        #expect(abs(full - twoHalves) < 1e-12)
        // The half-life is literal: half the gap closes in exactly that long.
        let half = RambleOrb.approach(
            current: 0, target: 1, dt: Motion.orbLevelSmoothingHalfLife)
        #expect(abs(half - 0.5) < 1e-9)
        // The first frame (no dt yet) holds still rather than jumping.
        #expect(RambleOrb.approach(current: 0.3, target: 0.9, dt: 0) == 0.3)
    }

    // MARK: - The soft knee

    @Test("The soft knee: silence is zero, a whisper visibly registers, full stays full")
    func energyCurve() {
        #expect(RambleOrb.energy(level: 0) == 0)
        #expect(RambleOrb.energy(level: 1) == 1)
        var last = -1.0
        for step in 0...20 {
            let energy = RambleOrb.energy(level: Double(step) / 20)
            #expect(energy > last)
            last = energy
        }
        // The whisper band (~0.15 smoothed level) produces a perceptible fraction of
        // the ceiling — the user reads this surface as "was I heard?", and a mute orb
        // over a quiet voice says no.
        #expect(RambleOrb.energy(level: 0.15) >= 0.2)
        // Compression at the top: the last quarter of level moves energy less than
        // the first quarter does — emphatic speech swells, never jumps.
        let lowGain = RambleOrb.energy(level: 0.25) - RambleOrb.energy(level: 0)
        let highGain = RambleOrb.energy(level: 1.0) - RambleOrb.energy(level: 0.75)
        #expect(lowGain > highGain)
    }
}
