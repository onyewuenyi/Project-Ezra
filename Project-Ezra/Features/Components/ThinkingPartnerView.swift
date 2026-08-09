//
//  ThinkingPartnerView.swift
//  Project-Ezra
//
//  The Thinking Partner expansion inside the detail's decision section (Decision Framing,
//  P0). On demand it asks the on-device model to FRAME the choice — the options with
//  their tradeoffs, the cost of waiting, and (when the facts clearly favor one) a
//  grounded "best fit". Still no action buttons: the recommendation is content, and
//  `resolveDecisionAndLog` stays the only clearer — the human decides.
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
    /// Deciding happens ON the option (the recommendation is the decision surface):
    /// present only for FLAGGED tasks, where there is an open decision to resolve.
    /// The framing itself never executes anything — these are the human's taps.
    var onDecide: ((String) -> Void)? = nil
    /// Wording-only tasks (no flag) instead get one quiet escalation: pin the task to
    /// the top of the stack as a visible decision. Same human seam Unstick used.
    var onEscalate: (() -> Void)? = nil

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

    /// Start (or restart) a framing, replacing any run already in flight. Engaging IS
    /// the acted-on signal for this card — the framing has no other button.
    private func start() {
        CapabilityMetrics.shared.recordActed(.thinkingPartner)
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
                        // The decision surface IS the option list: one tap resolves
                        // the flag and records WHICH option won. Quiet by design —
                        // the emphasized affordance lives on the Best fit below.
                        if let onDecide {
                            Spacer(minLength: Spacing.xs)
                            Button("Decide") { onDecide(option.label) }
                                .font(.controlLabel)
                                .foregroundStyle(Palette.accentFlat)
                                .buttonStyle(.pressableLink)
                        }
                    }
                    Text(option.tradeoff)
                        .supportingStyle()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Spacing.md)
                }
            }
            // The grounded recommendation — rendered only when it names one of the
            // framing's own options (`groundedRecommendation` drops anything else).
            // Content, not a control: there is no button here, because resolving
            // stays the human's tap.
            if let best = framing.groundedRecommendation {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "sparkles")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.accentFlat)
                        Text("Best fit · \(best.label)")
                            .font(.controlLabel)
                            .foregroundStyle(Palette.primaryText)
                        // The pre-highlighted default — one tap from recommendation to
                        // resolution, never auto-executed. The human decides.
                        if let onDecide {
                            Spacer(minLength: Spacing.xs)
                            Button("Decide this") { onDecide(best.label) }
                                .font(.controlLabel)
                                .foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, 3)
                                .background(Palette.accentFlat, in: Capsule())
                                .buttonStyle(.pressableLink)
                        }
                    }
                    if !best.why.isEmpty {
                        Text(best.why)
                            .supportingStyle()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Spacing.md)
                    }
                }
                .padding(.top, Spacing.xxs)
            }
            // Wording-only tasks (no open flag) get the escalation instead: pin it to
            // the top of the stack as a visible decision — the power Unstick's folded
            // choice rung used to carry, now living where the choice is framed.
            if onDecide == nil, let onEscalate {
                Button {
                    onEscalate()
                } label: {
                    Label("Pin to top as a decision", systemImage: "pin")
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                }
                .buttonStyle(.pressableLink)
                .padding(.top, Spacing.xxs)
            }
            if !framing.costOfWaiting.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.glyphCaption())
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
