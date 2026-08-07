//
//  VoiceHeroBar.swift
//  Project-Ezra
//
//  The composer's LISTENING state, with voice as the hero it is: a large gradient
//  stop control flanked by live level bars, with the silence auto-stop made
//  visible in its final stretch. The small "Speak instead" capsule morphs into
//  this via matched geometry — the moment is earned, not popped.
//
//  Design-system notes: the hero is a gradient CTA surface (`Palette
//  .accentGradient`), NOT glass — glass is chrome and never carries the primary
//  affordance of a content surface; the capture FAB remains the app's one
//  app-chrome glass exception. The draining ring renders only for the last
//  stretch of the silence window — a countdown from the start would read as
//  pressure to keep talking, which is the opposite of a ramble. Under Reduce
//  Motion the ring is dropped entirely and the "finishing…" microcopy carries
//  the message alone (a comprehension fade, allowed).
//

import SwiftUI

struct VoiceHeroBar: View {
    let monitor: AudioLevelMonitor
    /// When the silence auto-stop will fire — rescheduled on every transcript
    /// delta; nil when dictation is not running down.
    let silenceDeadline: Date?
    /// The full silence window (`ComposerView.silenceStopSeconds`), for the ring's
    /// denominator.
    let silenceWindow: TimeInterval
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring (and microcopy) appear only for the tail of the window.
    static let countdownVisibleSeconds: TimeInterval = 2

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                ListeningWaveform(monitor: monitor)
                stopButton
                ListeningWaveform(monitor: monitor)
            }
            .frame(maxWidth: .infinity)
            countdownLine
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(Palette.accentGradient)
                    .frame(width: LayoutMetrics.voiceHero, height: LayoutMetrics.voiceHero)
                    .shadow(color: Palette.accentGlow, radius: 12)
                Image(systemName: "stop.fill")
                    .font(.glyphControl(.semibold))
                    .foregroundStyle(Palette.onAccent)
                if !reduceMotion {
                    countdownRing
                }
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Stop dictation")
        .accessibilityHint("Dictation also stops on its own after a pause.")
    }

    /// The visible tail of the silence window: a ring draining clockwise around
    /// the hero. TimelineView-driven — it only runs while a deadline is set and
    /// inside the visible stretch.
    @ViewBuilder private var countdownRing: some View {
        if let silenceDeadline {
            TimelineView(.animation) { timeline in
                let remaining = silenceDeadline.timeIntervalSince(timeline.date)
                if remaining > 0, remaining <= Self.countdownVisibleSeconds {
                    Circle()
                        .trim(from: 0, to: remaining / Self.countdownVisibleSeconds)
                        .stroke(
                            Palette.onAccent.opacity(0.9),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(
                            width: LayoutMetrics.voiceHero - 6,
                            height: LayoutMetrics.voiceHero - 6)
                }
            }
        }
    }

    /// Microcopy for the same stretch — and the whole message under Reduce Motion.
    @ViewBuilder private var countdownLine: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let remaining = silenceDeadline.map { $0.timeIntervalSince(timeline.date) } ?? 0
            Text("Finishing up — keep talking to continue.")
                .metadataStyle()
                .opacity(remaining > 0 && remaining <= Self.countdownVisibleSeconds ? 1 : 0)
                .animation(Motion.fade, value: remaining <= Self.countdownVisibleSeconds)
        }
        .frame(height: Spacing.md)
    }
}

#Preview("Listening levels") {
    let quiet = AudioLevelMonitor()
    let mid = AudioLevelMonitor()
    let loud = AudioLevelMonitor()
    mid.ingest(rawLevel: 0.45)
    loud.ingest(rawLevel: 0.9)
    return VStack(spacing: Spacing.xl) {
        VoiceHeroBar(monitor: quiet, silenceDeadline: nil, silenceWindow: 5, onStop: {})
        VoiceHeroBar(monitor: mid, silenceDeadline: nil, silenceWindow: 5, onStop: {})
        VoiceHeroBar(
            monitor: loud, silenceDeadline: Date().addingTimeInterval(1.4), silenceWindow: 5,
            onStop: {})
    }
    .padding()
    .background(Palette.background)
}
