//
//  ThinkingPartnerView.swift
//  Project-Ezra
//
//  The Thinking Partner expansion inside the detail's decision section (Decision Framing,
//  P0). On demand it asks the on-device model to FRAME the choice — the options with
//  their tradeoffs and the cost of waiting — shown calmly, no action buttons (framing
//  doesn't decide; `resolveDecisionAndLog` stays the only clearer).
//
//  Off-device this view is never DRAWN — the detail checks availability before rendering
//  the section, so there is no button to tap that could vanish. That means `.failed` here
//  can only mean a real attempt that failed, which is why it now offers a retry instead
//  of collapsing to nothing.
//

import SwiftUI

struct ThinkingPartnerView: View {
    let context: DecisionContext
    /// False once this page stops being the one on screen. The pager keeps neighbours
    /// MOUNTED, so `.onDisappear` never fires for a swiped-past page — this is the only
    /// signal that the user has moved on, and an in-flight generation must stop.
    var isActive: Bool = true

    @State private var phase: Phase = .idle
    @State private var work: Task<Void, Never>?

    private enum Phase {
        case idle
        case loading
        case framed(DecisionFraming)
        /// A real attempt that produced nothing usable — a timeout, a refusal, or a
        /// decode failure. Distinct from "no model here", which never reaches this view.
        case failed
    }

    var body: some View {
        Group {
            phaseContent
        }
        .onChange(of: isActive) { _, active in
            // The pager keeps neighbouring pages mounted, so a swipe never fires
            // `.onDisappear` — this is the moment the user actually left.
            if !active { work?.cancel() }
        }
        .onDisappear { work?.cancel() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .idle:
            Button {
                start()
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

        case .failed:
            RetryLine(message: "That didn't finish.") { start() }
        }
    }

    /// Start (or restart) a framing, replacing any run already in flight.
    private func start() {
        work?.cancel()
        work = Task { await think() }
    }

    private func think() async {
        withAnimation(Motion.settle) { phase = .loading }
        let outcome = await DecisionFramingService().frame(context)
        switch outcome {
        case .success(let framing):
            withAnimation(Motion.settle) { phase = .framed(framing) }
        case .cancelled:
            // The user left mid-generation. Say nothing and keep the card as it was —
            // surfacing an error for their own navigation would be noise.
            break
        case .unavailable, .timedOut, .failed:
            withAnimation(Motion.settle) { phase = .failed }
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
