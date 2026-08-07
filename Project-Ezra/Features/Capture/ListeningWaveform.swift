//
//  ListeningWaveform.swift
//  Project-Ezra
//
//  The live level display beside the voice hero button — the visible proof the app
//  is hearing you. Deliberately a LEAF observer: this is the only view that reads
//  `AudioLevelMonitor.level`, so per-buffer invalidation (~12/s) re-renders seven
//  capsules and nothing else — never the composer.
//
//  Center-weighted bars scale with the smoothed level (fast attack, slow decay —
//  the envelope lives in the monitor, not here). Under Reduce Motion the bars
//  still track the level — a level meter is data, not decoration — but by direct
//  value change, no eased animation.
//

import SwiftUI

struct ListeningWaveform: View {
    let monitor: AudioLevelMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Center-weighted multipliers — speech energy reads tallest in the middle,
    /// the way every familiar level meter draws it.
    private static let barWeights: [Double] = [0.45, 0.7, 1.0, 0.85, 1.0, 0.7, 0.45]
    private static let barWidth: CGFloat = 3
    private static let maxBarHeight: CGFloat = 28
    private static let minBarHeight: CGFloat = 4

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(Self.barWeights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Palette.accentFlat)
                    .frame(width: Self.barWidth, height: height(at: index))
            }
        }
        .frame(height: Self.maxBarHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: monitor.level)
        // The meter is reinforcement for sighted users; VoiceOver already hears the
        // listening state from the hero button's label.
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        let scaled = monitor.level * Self.barWeights[index]
        return Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(scaled)
    }
}
