//
//  AdvisorView.swift
//  Project-Ezra
//
//  The Advisor — one surface, one behavior: an observation, guidance, and the next
//  move. The thought leads and the intervention is subordinate, because the product
//  magic is "it understood what is going on", not "AI generated a button". The UI
//  never names a capability and never says "nothing to do here": silence allocates
//  zero visual attention.
//
//  Replaced the three capability cards (Thinking Partner · Breakdown · Unstick). The
//  moves compose into this one card body; the store owns the judgment and its cache,
//  this view only renders `AdvisorState` and hands taps to the parent's mutation
//  closures — the reading itself mutates nothing.
//
//  Two structural invariants live here:
//  - A flagged decision ALWAYS gets its reason line and "Mark decided", regardless of
//    the model's move or availability — `resolveDecision()` stays the only clearer.
//  - The loading treatment is calm, not computational: the kicker resolves in place;
//    no spinner, no progress, no "analyzing…" copy. The reading arrives as one thought.
//

import SwiftUI

struct AdvisorView: View {
    let state: AdvisorState
    /// `needsDecision && !resolved` — the flagged-decision block renders whenever this
    /// is true, independent of everything else.
    let flagged: Bool
    let isJudgmentCall: Bool
    let deferralCount: Int
    /// The deterministic diagnosis, for the off-device fallback content.
    let diagnosis: StallDiagnosis?
    /// Active blockers, for the openBlocker move's rows.
    let blockers: [TaskItem]

    let onDecide: (String?) -> Void
    let onEscalate: () -> Void
    let onCreateSteps: (_ accepted: [BreakdownStep], _ proposed: [BreakdownStep]) -> Void
    let onOpenBlocker: (TaskItem) -> Void
    let onDoItNow: () -> Void
    let onDefer: () -> Void
    let onKill: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Step titles the user deselected before creating — reset whenever the judgment
    /// changes, because a deselection belongs to one proposal.
    @State private var declined: Set<String> = []

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                kicker
                stateContent
                if flagged { flaggedDecisionBlock }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Palette.primarySurface,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        flagged
                            ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Palette.border),
                        lineWidth: flagged ? 1.5 : 0.5)
            }
            .animation(reduceMotion ? nil : Motion.settle, value: state)
            .onChange(of: state) { _, _ in declined = [] }
            .accessibilityElement(children: .contain)
        }
    }

    /// Silence occupies zero visual attention — unless the task carries an open
    /// decision flag, whose human affordances can never depend on what the model
    /// chose to talk about.
    private var isVisible: Bool {
        switch state {
        case .quiet, .dismissed: return flagged
        case .loading, .revealed, .fallback, .failed: return true
        }
    }

    private var kicker: some View {
        Text("Advisor")
            .metadataStyle()
            .textCase(.uppercase)
            .tracking(0.8)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .quiet, .dismissed:
            // Visible only when flagged — the decision block below carries the card.
            EmptyView()

        case .loading:
            // The kicker holds the space; this line resolves into the reading in
            // place. A bare hairline at rest — deliberately not a skeleton, not a
            // spinner, not copy about thinking.
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.border)
                .frame(width: 96, height: 2)
                .transition(.opacity)

        case .revealed(let reading):
            readingContent(reading).transition(.opacity)

        case .fallback:
            fallbackContent

        case .failed:
            RetryLine(message: "That didn't finish.") { onRetry() }
        }
    }

    // MARK: - The reading

    @ViewBuilder
    private func readingContent(_ reading: ValidatedReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // The thought leads: observation in primary ink, guidance beneath it.
            Text(reading.observation)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let guidance = reading.guidance {
                Text(guidance)
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let nextMove = reading.nextMove {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.accentFlat)
                    Text(nextMove)
                        .font(.controlLabel)
                        .foregroundStyle(Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            moveBody(reading)

            HStack(spacing: Spacing.md) {
                Spacer(minLength: 0)
                Button("Dismiss") { onDismiss() }
                    .font(.controlLabel)
                    .foregroundStyle(Palette.mutedText)
                    .buttonStyle(.pressableLink)
            }
        }
    }

    /// The intervention, subordinate to the thought. At most one action affordance.
    @ViewBuilder
    private func moveBody(_ reading: ValidatedReading) -> some View {
        switch reading.move {
        case .nothing, .advise:
            EmptyView()

        case .decide:
            decideBody(reading)

        case .createSteps:
            stepsBody(reading.steps)

        case .openBlocker:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(blockers) { blocker in
                    blockerRow(blocker)
                }
            }
        }
    }

    // MARK: decide

    @ViewBuilder
    private func decideBody(_ reading: ValidatedReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(reading.options.enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Palette.accentFlat)
                        Text(option.label)
                            .font(.controlLabel)
                            .foregroundStyle(Palette.primaryText)
                        // Deciding happens ON the option — one tap resolves the flag
                        // and records WHICH option won. Only for flagged tasks, where
                        // there is an open decision to resolve.
                        if flagged {
                            Spacer(minLength: Spacing.xs)
                            Button("Decide") { onDecide(option.label) }
                                .font(.controlLabel)
                                .foregroundStyle(Palette.accentFlat)
                                .buttonStyle(.pressableLink)
                        }
                    }
                    if !option.tradeoff.isEmpty {
                        Text(option.tradeoff)
                            .supportingStyle()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Spacing.md)
                    }
                }
            }
            // The grounded best fit — only ever one of the reading's own options
            // (`validated` drops anything else). Recommendation, never resolution:
            // the human decides.
            if let best = reading.recommendation {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "sparkles")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.accentFlat)
                        Text("Best fit · \(best.label)")
                            .font(.controlLabel)
                            .foregroundStyle(Palette.primaryText)
                        if flagged {
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
            }
            // Wording-only choices get the one escalation: pin it to the top of the
            // stack as a visible decision — a human act through the same seam.
            if !flagged {
                Button {
                    onEscalate()
                } label: {
                    Label("Pin to top as a decision", systemImage: "pin")
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                }
                .buttonStyle(.pressableLink)
            }
        }
    }

    // MARK: createSteps

    @ViewBuilder
    private func stepsBody(_ steps: [BreakdownStep]) -> some View {
        let accepted = steps.filter { !declined.contains($0.title) }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                stepRow(step, isAccepted: !declined.contains(step.title))
            }
            Button {
                onCreateSteps(accepted, steps)
            } label: {
                Text(accepted.count == 1 ? "Create 1 step" : "Create \(accepted.count) steps")
                    .font(.controlLabel)
                    .foregroundStyle(accepted.isEmpty ? Palette.mutedText : Palette.accentFlat)
            }
            .buttonStyle(.pressableLink)
            .disabled(accepted.isEmpty)
        }
    }

    /// One proposed step. Tapping toggles it — a deselection is the user telling the
    /// model it over-reached, which the parent records as a `Correction`.
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
                    .font(.glyphCaption())
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

    // MARK: openBlocker

    private func blockerRow(_ blocker: TaskItem) -> some View {
        Button {
            onOpenBlocker(blocker)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.mutedText)
                Text(blocker.title)
                    .font(.controlLabel)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open blocker: \(blocker.title)")
    }

    // MARK: - Off-device fallback (an execution path, not a judgment)

    /// Deterministic template parity with the old surface: the stall headline and the
    /// moves that work without a model. The breakdown is absent whole (its content was
    /// all model output), and a wording-only choice keeps its escalation.
    @ViewBuilder
    private var fallbackContent: some View {
        if let diagnosis {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(diagnosis.headline(deferralCount: deferralCount))
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.md) {
                    switch diagnosis {
                    case .blocked, .tooBig:
                        // The truth is the content: the blocker is the work, or the
                        // task is big — and with no model there are no steps to offer.
                        EmptyView()
                    case .reallyADecision:
                        fallbackLink("Make it a decision", action: onEscalate)
                    case .dying:
                        fallbackLink("Do it now", action: onDoItNow)
                        fallbackLink("Defer it", action: onDefer)
                        fallbackLink("Let it go", role: .destructive, action: onKill)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func fallbackLink(
        _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.controlLabel)
                .foregroundStyle(role == .destructive ? Palette.mutedText : Palette.accentFlat)
        }
        .buttonStyle(.pressableLink)
    }

    // MARK: - Flagged decision block (always renders while the flag is open)

    private var flaggedDecisionBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "hand.raised.fill")
                    .font(.glyphSmall())
                    .foregroundStyle(Palette.decisionAccent)
                Text("Needs a decision")
                    .font(.sectionHeader)
                    .foregroundStyle(Palette.primaryText)
            }
            Text(
                isJudgmentCall
                    ? "This is a values call only you can make — Ezra won't decide it for you."
                    : "Ezra wasn't confident enough to file this cleanly. Take a look and set it straight."
            )
            .supportingStyle()
            .fixedSize(horizontal: false, vertical: true)
            Button {
                onDecide(nil)
            } label: {
                Label("Mark decided", systemImage: "checkmark.seal")
                    .font(.controlLabel)
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressableProminent)
        }
    }
}
