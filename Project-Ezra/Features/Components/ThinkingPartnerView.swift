//
//  ThinkingPartnerView.swift
//  Project-Ezra
//
//  The Thinking Partner expansion inside the detail's decision section (Decision Framing,
//  P0). On demand it asks the on-device model to FRAME the choice — the options with
//  their tradeoffs and the cost of waiting — shown calmly, no action buttons (framing
//  doesn't decide; `resolveDecisionAndLog` stays the only clearer). Absent off-device:
//  `DecisionFramingService.frame` returns nil there and the view collapses to nothing.
//

import SwiftUI

struct ThinkingPartnerView: View {
    let context: DecisionContext

    @State private var phase: Phase = .idle

    private enum Phase {
        case idle
        case loading
        case framed(DecisionFraming)
        case unavailable
    }

    var body: some View {
        switch phase {
        case .idle:
            Button {
                Task { await think() }
            } label: {
                Label("Think it through", systemImage: "sparkles")
                    .font(.controlLabel)
                    .foregroundStyle(Palette.accentFlat)
            }
            .buttonStyle(.pressableLink)

        case .loading:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Palette.accentFlat)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Thinking it through…")
                    .supportingStyle()
            }
            .transition(.opacity)

        case .framed(let framing):
            framedContent(framing).transition(.opacity)

        case .unavailable:
            EmptyView()
        }
    }

    private func think() async {
        withAnimation(Motion.settle) { phase = .loading }
        if let framing = await DecisionFramingService().frame(context) {
            withAnimation(Motion.settle) { phase = .framed(framing) }
        } else {
            withAnimation(Motion.settle) { phase = .unavailable }
        }
    }

    @ViewBuilder
    private func framedContent(_ framing: DecisionFraming) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(framing.options.enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Palette.accentFlat)
                        Text(option.label)
                            .font(.controlLabel)
                            .foregroundStyle(Palette.primaryText)
                    }
                    Text(option.tradeoff)
                        .supportingStyle()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Spacing.md)
                }
            }
            if !framing.costOfWaiting.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: IconSize.caption))
                        .foregroundStyle(Palette.mutedText)
                    Text(framing.costOfWaiting)
                        .supportingStyle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Spacing.xxs)
            }
        }
    }
}
