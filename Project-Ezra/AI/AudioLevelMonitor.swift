//
//  AudioLevelMonitor.swift
//  Project-Ezra
//
//  The live microphone level behind the voice-first listening UI — the one signal
//  `SpeechCaptureService`'s tap had nowhere to put (buffers went straight to the
//  analyzer, so a waveform had nothing to bind to).
//
//  Deliberately its OWN `@Observable`, separate from the speech service: the level
//  moves at buffer cadence (~12/s at the tap's 4096-frame buffers) and only the leaf
//  view that renders it — the listening `RambleOrb` — should re-render at that rate.
//  Folding it into the service's observable state would invalidate every observer of
//  `state`/`transcript` — the whole composer — per buffer.
//
//  The math is pure and static (`normalizedLevel`, `smoothed`) so the envelope is
//  unit-testable without an audio session: RMS → dBFS → a 0…1 display range, then a
//  fast-attack / slow-decay envelope — the orb swells when speech starts and drains
//  away gracefully, instead of flickering at raw RMS.
//

import AVFoundation
import Accelerate
import Foundation
import Observation

@MainActor
@Observable
final class AudioLevelMonitor {

    /// Smoothed microphone level in 0…1 — the display value.
    private(set) var level: Double = 0

    /// Decay multiplier per update when the incoming level is below the current one.
    /// ~0.82 at 12 updates/s ≈ a comfortable fall of a full bar in ~½ second.
    nonisolated static let decayFactor = 0.82

    /// The dBFS window mapped onto 0…1: −50 dB (room quiet) → 0, 0 dB (clipping) → 1.
    nonisolated static let floorDecibels = -50.0

    /// Feed one raw sample (called on the main actor; the tap hops once per buffer).
    func ingest(rawLevel: Double) {
        level = Self.smoothed(current: level, incoming: rawLevel)
    }

    /// Reset for a fresh dictation session.
    func reset() { level = 0 }

    /// Fast attack, slow decay: a rising level lands immediately (speech onset must
    /// be felt on the first buffer), a falling one decays multiplicatively.
    nonisolated static func smoothed(current: Double, incoming: Double) -> Double {
        incoming >= current ? incoming : max(incoming, current * decayFactor)
    }

    /// RMS → dBFS → 0…1 against the display window. Pure; clamped at both ends.
    nonisolated static func normalizedLevel(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }

    /// RMS of a PCM buffer's first channel via vDSP. Pure and callable from the
    /// audio tap's thread; returns nil for a buffer with no float data.
    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var value: Float = 0
        vDSP_rmsqv(channel, 1, &value, vDSP_Length(buffer.frameLength))
        return Double(value)
    }
}
