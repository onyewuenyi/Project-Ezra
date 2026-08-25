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
//  Three rules decide almost every layout choice here:
//
//  1. **The reading is part of the task, not a card on top of it.** An interpretation
//     renders containerless, in the same rhythm as the task's own description and
//     provenance sections. Only the flagged-decision block keeps card chrome — that
//     is a persistent HUMAN OBLIGATION, not the Advisor's interpretation, and it
//     carries the design system's Needs-Decision edge stroke.
//  2. **Everything above the rule is understanding; everything below it is action.**
//     One hairline does the work a second container would have done badly.
//  3. **The Advisor never competes with the task's primary action.** The pinned CTA
//     owns `accentGradient` on a full-width capsule; nothing in here may wear it.
//     The Advisor recommends, the CTA executes — two gradient capsules on one screen
//     is the UI contradicting that sentence.
//
//  Absent by design: spinners, progress, "analyzing…" copy, sparkles, robots,
//  badges — and, since the shape-driven detail pass, the "ADVISOR" kicker and every
//  error string. The reading sits in the task's own body rhythm with no label
//  announcing that a model wrote it: the intelligence is the sentence being right,
//  not the frame around it. A failed generation renders NOTHING (rung 0 already
//  spoke where there was anything factual to say) — "That didn't finish. Try again."
//  taught the user the Advisor can fail and offered a retry that often could not
//  succeed. The re-judge loop (`updatedAt`, `isActive`, the blocker-sheet return)
//  is the retry.
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
    /// True when the page's WAITING spine already renders the blocker rows directly
    /// under the title. The `openBlocker` reading then keeps its observation and
    /// next move but drops its own rows — the same rows twice on one screen teaches
    /// the user to read neither copy.
    var blockersRenderedElsewhere = false

    let onDecide: (String?) -> Void
    let onEscalate: () -> Void
    let onCreateSteps: (_ accepted: [BreakdownStep], _ proposed: [BreakdownStep]) -> Void
    let onOpenBlocker: (TaskItem) -> Void
    let onDoItNow: () -> Void
    let onDefer: () -> Void
    let onKill: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Step titles the user deselected before creating — reset whenever the judgment
    /// changes, because a deselection belongs to one proposal.
    @State private var declined: Set<String> = []
    /// "Why this?" — collapsed by default. Expanding is not an action and is never
    /// counted as one.
    @State private var showEvidence = false

    var body: some View {
        if Self.isVisible(state: state, flagged: flagged, diagnosis: diagnosis) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // The obligation leads: a standing human duty outranks an
                // interpretation of it, and on a DECIDING page this block is the
                // spine the rest of the reading hangs under.
                if flagged { obligationBlock }
                if showsReading { readingSection }
            }
            .animation(reduceMotion ? nil : Motion.settle, value: state)
            .onChange(of: state) { _, _ in
                declined = []
                showEvidence = false
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Whether this view will draw ANYTHING — exposed as a static so the detail page
    /// can leave the section out of its layout entirely. Silence must have no
    /// geometry: an empty view still holding a slot in the parent's `Spacing.lg`
    /// stack reads as a mysterious double gap on exactly the tasks the Advisor is
    /// quiet about — which is most of them, by design.
    static func isVisible(
        state: AdvisorState, flagged: Bool, diagnosis: StallDiagnosis?
    ) -> Bool {
        if flagged { return true }
        switch state {
        case .unevaluated, .quiet, .dismissed: return false
        // A fallback with neither a diagnosis template nor a rung-0 reading has
        // nothing to say, and renders as true silence.
        case .fallback(let reading): return diagnosis != nil || reading != nil
        case .loading, .revealed: return true
        // A failure renders NOTHING. The floor already spoke wherever there was a
        // fact to state; an error string would teach the user the Advisor can fail,
        // and the re-judge loop retries without being asked.
        case .failed: return false
        }
    }

    /// Silence occupies zero visual attention. `.unevaluated` (no judgment yet) and
    /// `.quiet` (a judgment OF silence) render identically here and mean opposite
    /// things — the distinction lives in the store, where it is load-bearing.
    private var showsReading: Bool {
        switch state {
        case .unevaluated, .quiet, .dismissed, .failed: return false
        case .fallback(let reading): return diagnosis != nil || reading != nil
        case .loading, .revealed: return true
        }
    }

    // MARK: - The reading (containerless — part of the task)

    /// No kicker, no badge. The reading is part of the task; a label saying ADVISOR
    /// was the last piece of AI chrome on this surface, and it drew an orphaned
    /// heading over every degraded state besides.
    private var readingSection: some View {
        stateContent
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .unevaluated, .quiet, .dismissed:
            EmptyView()

        case .loading:
            // Reserved rhythm only — for every rung, including a deep read the user
            // is present for. The page renders in its deterministic form immediately,
            // space is reserved, the reading settles into it when it lands, and
            // nothing reflows. No mark, no narration: latency is never a product
            // event, and async arrival with reserved space is the calm version of
            // "working".
            Color.clear.frame(height: Spacing.lg)

        case .revealed(let reading):
            readingContent(reading).transition(.opacity)

        case .fallback(let reading):
            // One template per situation: a diagnosed stall keeps its richer template
            // (headline PLUS its action links), and everything else — the flagged
            // decision, the blocked task, the overdue one — gets rung 0's fact-only
            // reading through the same renderer the model path uses.
            if diagnosis != nil {
                fallbackContent
            } else if let reading {
                readingContent(reading, dismissable: false).transition(.opacity)
            }

        case .failed:
            // Nothing. `isVisible` already excluded this state; the arm exists so the
            // switch stays exhaustive and honest about the vocabulary.
            EmptyView()
        }
    }

    /// `dismissable` is false for a rung-0 fallback: `TaskAdvisorStore.dismiss` only
    /// accepts `.revealed`, so the row would silently no-op — and there is nothing to
    /// decline anyway. Dismissal records "the Advisor had an opinion and the human
    /// declined it"; fact-only content is an execution path, not an opinion.
    @ViewBuilder
    private func readingContent(
        _ reading: ValidatedReading, dismissable: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // ── Understanding ──
            // Secondary, plain, unframed: the intelligence is the sentence being
            // right. Primary weight belongs to the task's own content and — inside a
            // decide reading — to the options, which are the spine of that page.
            Text(reading.observation)
                .supportingStyle()
                .fixedSize(horizontal: false, vertical: true)
            if let guidance = reading.guidance {
                Text(guidance)
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reading.move == .decide {
                // The what-matters lines: at most three FACTS, inline, because a
                // person about to choose should not have to tap a disclosure to see
                // what bears on the choice. Sourced from the deterministic evidence
                // only — never model prose — so nothing here can be a guess wearing
                // a fact's clothes.
                whatMatters(reading)
            } else {
                evidenceDisclosure(reading)
            }

            // ── Action ──
            if hasActionSide(reading) {
                Rectangle()
                    .fill(Palette.border)
                    .frame(height: 0.5)
                    .padding(.vertical, Spacing.xxs)
                if let nextMove = reading.nextMove {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text("→")
                            .font(.controlLabel)
                            .foregroundStyle(Palette.accentFlat)
                        Text(nextMove)
                            .font(.controlLabel)
                            .foregroundStyle(Palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                moveBody(reading)
            }
            if dismissable { dismissRow }
        }
    }

    /// Is there anything below the rule? A words-only reading with nothing to point at
    /// draws no rule — the separator means "action follows", so it must not lie.
    private func hasActionSide(_ reading: ValidatedReading) -> Bool {
        if reading.nextMove != nil { return true }
        switch reading.move {
        case .decide, .createSteps: return true
        // When the waiting spine owns the rows, an openBlocker reading with no next
        // move has nothing below the rule — and a rule over nothing is a lie.
        case .openBlocker: return !blockersRenderedElsewhere
        case .advise, .nothing: return false
        }
    }

    private var dismissRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Dismiss") { onDismiss() }
                .font(.controlLabel)
                .foregroundStyle(Palette.mutedText)
                .buttonStyle(.pressableLink)
        }
    }

    /// The deciding page's context: up to three evidence lines, inline. The same
    /// vocabulary "Why this?" reveals elsewhere — deterministic fact lines, the model
    /// contributing nothing — surfaced without a tap because they bear on a choice
    /// the user is about to make.
    @ViewBuilder
    private func whatMatters(_ reading: ValidatedReading) -> some View {
        if !reading.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reading.evidence.prefix(3), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text("•")
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.chipLabel)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    // MARK: - Why this? (evidence, never reasoning)

    @ViewBuilder
    private func evidenceDisclosure(_ reading: ValidatedReading) -> some View {
        if !reading.evidence.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Button {
                    Motion.withMotion(Motion.settle) { showEvidence.toggle() }
                } label: {
                    Text(showEvidence ? "Hide" : "Why this?")
                        .font(.chipLabel)
                        .foregroundStyle(Palette.mutedText)
                }
                .buttonStyle(.pressableLink)
                if showEvidence {
                    // The facts the reading was made from, in the user's own terms —
                    // never the model's reasoning, and never a sentence it wrote.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(reading.evidence, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                                Text("•")
                                Text(line)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.chipLabel)
                            .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Per-move action bodies (at most one button)

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
            if !blockersRenderedElsewhere {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(blockers) { blocker in
                        blockerRow(blocker)
                    }
                }
            }
        }
    }

    // MARK: decide

    @ViewBuilder
    private func decideBody(_ reading: ValidatedReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(reading.options.enumerated()), id: \.offset) { _, option in
                optionRow(option, isBestFit: reading.recommendation?.label == option.label)
            }
            if let best = reading.recommendation {
                // Evidence favoured one — so there is one button, and it names the
                // choice. Secondary treatment: the pinned CTA is still the screen's
                // primary action.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if !best.why.isEmpty {
                        Text(best.why)
                            .supportingStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if flagged {
                        secondaryButton("Choose \(best.label)") { onDecide(best.label) }
                    }
                }
            }
            // No recommendation → NO primary button. The options are the action, and
            // the Advisor doesn't invent a conclusion because the UI wants a button.
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

    private func optionRow(_ option: AdvisorChoice, isBestFit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: isBestFit ? "largecircle.fill.circle" : "circle")
                    .font(.glyphCaption())
                    .foregroundStyle(isBestFit ? Palette.accentFlat : Palette.mutedText)
                Text(option.label)
                    .font(.controlLabel)
                    .foregroundStyle(Palette.primaryText)
                // Deciding happens ON the option — quiet, because the emphasized path
                // is the grounded best fit when there is one.
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

    // MARK: createSteps

    @ViewBuilder
    private func stepsBody(_ steps: [BreakdownStep]) -> some View {
        let accepted = steps.filter { !declined.contains($0.title) }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                stepRow(step, isAccepted: !declined.contains(step.title))
            }
            secondaryButton(accepted.count == 1 ? "Create 1 step" : "Create \(accepted.count) steps") {
                onCreateSteps(accepted, steps)
            }
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

    /// Deterministic template parity: the stall headline and the moves that work
    /// without a model. The breakdown is absent whole (its content was all model
    /// output), and a wording-only choice keeps its escalation.
    @ViewBuilder
    private var fallbackContent: some View {
        if let diagnosis {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(diagnosis.headline(deferralCount: deferralCount))
                    .font(.supporting)
                    .foregroundStyle(Palette.primaryText)
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

    // MARK: - The obligation (a card; not the Advisor's interpretation)

    /// An open decision flag is a standing human obligation, so unlike the reading it
    /// keeps card chrome and the Needs-Decision edge — and it renders whatever the
    /// model said, and whether or not a model exists. `resolveDecision()` is the only
    /// thing that clears the flag.
    private var obligationBlock: some View {
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

            // When the reading is already offering options, deciding happens THERE and
            // this demotes to the escape hatch. Either way it is never a full-width
            // gradient capsule — that treatment belongs to the pinned CTA alone.
            if offersOptions {
                Button("Mark decided") { onDecide(nil) }
                    .font(.controlLabel)
                    .foregroundStyle(Palette.accentFlat)
                    .buttonStyle(.pressableLink)
            } else {
                secondaryButton("Mark decided", fullWidth: true) { onDecide(nil) }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Palette.primarySurface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.accentGradient, lineWidth: 1.5)
        }
    }

    private var offersOptions: Bool {
        if case .revealed(let reading) = state { return !reading.options.isEmpty }
        return false
    }

    // MARK: - Shared secondary control

    /// The Advisor's one emphasis level: a bordered capsule. Deliberately NOT
    /// `accentGradient` — see the header's third rule.
    private func secondaryButton(
        _ title: String, fullWidth: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.controlLabel)
                .foregroundStyle(Palette.accentFlat)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .frame(minHeight: LayoutMetrics.hitTarget)
                .background(Palette.elevatedSurface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Palette.border, lineWidth: 0.5)
                }
        }
        .buttonStyle(.pressable)
    }
}
