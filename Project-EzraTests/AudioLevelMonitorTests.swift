//
//  AudioLevelMonitorTests.swift
//  Project-EzraTests
//
//  The envelope math behind the listening waveform. Pure functions, no audio
//  session: the dBFS mapping's edges, and the fast-attack / slow-decay shape —
//  speech onset must land on the first buffer, release must fall smoothly rather
//  than flicker at raw RMS.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct AudioLevelMonitorTests {

    @Test("Normalization maps the dBFS window onto 0…1 with clamped edges")
    func normalizationEdges() {
        #expect(AudioLevelMonitor.normalizedLevel(rms: 0) == 0)  // silence, no -inf
        #expect(AudioLevelMonitor.normalizedLevel(rms: 1) == 1)  // full scale
        #expect(AudioLevelMonitor.normalizedLevel(rms: 2) == 1)  // clipped input clamps
        // −50 dB floor: rms 10^(−50/20) ≈ 0.00316 lands at the bottom of the window.
        #expect(abs(AudioLevelMonitor.normalizedLevel(rms: 0.00316) - 0) < 0.01)
        // −25 dB is the middle of the window.
        let mid = AudioLevelMonitor.normalizedLevel(rms: pow(10, -25.0 / 20))
        #expect(abs(mid - 0.5) < 0.01)
    }

    @Test("Attack is instant; decay is multiplicative and floored by the incoming level")
    func envelopeShape() {
        // Rising input lands immediately — speech onset felt on the first buffer.
        #expect(AudioLevelMonitor.smoothed(current: 0.1, incoming: 0.8) == 0.8)
        // Falling input decays from the current level, not a cliff to the new one.
        let decayed = AudioLevelMonitor.smoothed(current: 0.8, incoming: 0.1)
        #expect(abs(decayed - 0.8 * AudioLevelMonitor.decayFactor) < 1e-9)
        // …but never below the true incoming level once decay catches up.
        #expect(AudioLevelMonitor.smoothed(current: 0.11, incoming: 0.1) == 0.1)
    }

    @Test("The monitor's ingest applies the envelope and reset returns to zero")
    func monitorLifecycle() {
        let monitor = AudioLevelMonitor()
        monitor.ingest(rawLevel: 0.6)
        #expect(monitor.level == 0.6)
        monitor.ingest(rawLevel: 0.0)
        #expect(abs(monitor.level - 0.6 * AudioLevelMonitor.decayFactor) < 1e-9)
        monitor.reset()
        #expect(monitor.level == 0)
    }
}
