//
//  BreakdownView.swift
//  Project-Ezra
//
//  "Break this down" inside the detail — the capability that reduces COMPLEXITY. On
//  demand it asks the on-device model for the steps a big task decomposes into, shown as
//  deselectable chips. Nothing is created until the user taps the CTA, and nothing is
//  ever persisted before that: the proposal is generated, shown, and discarded.
//
//  Same four-phase shape as `ThinkingPartnerView`, and the same absence rule — but the
//  absence is now decided BEFORE this view is drawn: the detail checks model availability
//  and omits the whole card off-device. So `.failed` here can only mean a real attempt
//  that failed, and it offers a retry rather than collapsing to nothing (which used to
//  make the button the user just tapped disappear).
//
//  The one difference from the Thinking Partner: this capability COMMITS. Framing a
//  decision changes nothing; accepting a breakdown creates real tasks. So the accept is
//  an explicit, counted CTA ("Create 3 steps") rather than a passive read.
//

import SwiftUI

struct BreakdownView: View {
    let context: BreakdownContext
    /// Why the card is being offered — rendered so the user can see what the app
    /// noticed, the same rule the owner chip's reason line follows.
    let reason: BreakdownEligibility.Reason
    /// False once this page stops being the one on screen. The pager keeps neighbours
    /// MOUNTED, so `.onDisappear` never fires for a swiped-past page — this is the only
    /// signal that the user moved on, and an in-flight generation must stop.
    var isActive: Bool = true
    /// The accept, handed BOTH the kept steps and everything the model proposed — the
    /// difference between them is the user correcting the classifier, and this view is
    /// the only place that difference exists. The parent owns the mutation, so this
    /// stays a pure proposal surface with no `NSManagedObjectContext` of its own.
    let onAccept: (_ accepted: [BreakdownStep], _ proposed: [BreakdownStep]) -> Void

    @State private var phase: Phase = .idle
    @State private var work: Task<Void, Never>?
    /// Titles the user has deselected — a chip they said no to. Keyed on title because
    /// `BreakdownStep` is a generated value with no stable id.
    @State private var declined: Set<String> = []

    private enum Phase {
        case idle
        case loading
        case proposed([BreakdownStep])
        /// A real attempt that produced nothing usable — a timeout, a refusal, or output
        /// that sanitized below two steps. Distinct from "no model here", which never
        /// reaches this view.
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
                Label("Break this down", systemImage: "sparkles")
                    .font(.controlLabel)
                    .foregroundStyle(Palette.accentFlat)
            }
            .buttonStyle(.pressableLink)

        case .loading:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Palette.accentFlat)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Working out the steps…")
                    .supportingStyle()
            }
            .transition(.opacity)

        case .proposed(let steps):
            proposedContent(steps).transition(.opacity)

        case .failed:
            RetryLine(message: "That didn't finish.") { start() }
        }
    }

    /// Start (or restart) a proposal, replacing any run already in flight.
    private func start() {
        work?.cancel()
        work = Task { await propose() }
    }

    private func propose() async {
        withAnimation(Motion.settle) { phase = .loading }
        let outcome = await TaskBreakdownService().steps(context)
        switch outcome {
        case .success(let steps):
            withAnimation(Motion.settle) { phase = .proposed(steps) }
        case .cancelled:
            // The user left mid-generation. Say nothing — surfacing an error for their
            // own navigation would be noise.
            break
        case .unavailable, .timedOut, .failed:
            withAnimation(Motion.settle) { phase = .failed }
        }
    }

    @ViewBuilder
    private func proposedContent(_ steps: [BreakdownStep]) -> some View {
        let accepted = steps.filter { !declined.contains($0.title) }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(reason.rationale)
                .font(.chipLabel)
                .foregroundStyle(Palette.mutedText)

            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                stepRow(step, isAccepted: !declined.contains(step.title))
            }

            Button {
                onAccept(accepted, steps)
            } label: {
                Text(accepted.count == 1 ? "Create 1 step" : "Create \(accepted.count) steps")
                    .font(.controlLabel)
                    .foregroundStyle(accepted.isEmpty ? Palette.mutedText : Palette.accentFlat)
            }
            .buttonStyle(.pressableLink)
            .disabled(accepted.isEmpty)
            .padding(.top, Spacing.xxs)
        }
    }

    /// One proposed step. Tapping toggles it — a deselection is the user telling the
    /// model it was wrong, which the parent records as a `Correction`.
    private func stepRow(_ step: BreakdownStep, isAccepted: Bool) -> some View {
        Button {
            Motion.withMotion(Motion.decide) {
                if isAccepted {
                    declined.insert(step.title)
                } else {
                    declined.remove(step.title)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: isAccepted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: IconSize.caption))
                    .foregroundStyle(isAccepted ? Palette.accentFlat : Palette.mutedText)
                Text(step.title)
                    .font(.controlLabel)
                    .foregroundStyle(isAccepted ? Palette.primaryText : Palette.mutedText)
                    .strikethrough(!isAccepted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.xs)
                if let label = TaskItem.effortLabel(step.effortMinutes) {
                    Text("~\(label)")
                        .font(.chipLabel)
                        .foregroundStyle(Palette.mutedText)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.title), \(isAccepted ? "included" : "excluded")")
        .accessibilityHint(isAccepted ? "Exclude this step" : "Include this step")
    }
}
