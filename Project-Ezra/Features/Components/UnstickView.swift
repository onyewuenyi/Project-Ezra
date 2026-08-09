//
//  UnstickView.swift
//  Project-Ezra
//
//  The INERTIA capability's card. Names what the app noticed, then offers the move that
//  actually addresses it — routing into the other two capabilities where those are the
//  answer, rather than being a fourth isolated module.
//
//  Unlike the Thinking Partner and Break-this-down, this one is **never absent
//  off-device**: `StallDetector` is entirely deterministic, so the card and its actions
//  render identically with Apple Intelligence off. That is deliberate — a task going
//  quiet is exactly when a user with no on-device model still deserves help.
//

import SwiftUI

struct UnstickView: View {
    let diagnosis: StallDiagnosis
    let deferralCount: Int
    /// The facts for the voiced line — nil renders the deterministic headline only.
    var narrationFacts: UnstickFacts? = nil
    /// False once this page stops being the one on screen (the pager keeps neighbours
    /// mounted, so `.onDisappear` never fires for a swiped-past page).
    var isActive: Bool = true
    /// Route into the breakdown capability — the parent scrolls to / expands that card.
    let onBreakDown: () -> Void
    /// Escalate to a decision. A HUMAN act (the user accepting the card's suggestion) —
    /// the parent routes it through `escalateToDecision()` + `touchHuman()`.
    let onMakeDecision: () -> Void
    let onDoItNow: () -> Void
    let onDefer: () -> Void
    let onKill: () -> Void

    /// The model's phrasing of the diagnosis, once it lands. The deterministic headline
    /// renders immediately either way — narration is an upgrade, never a dependency,
    /// which is what keeps "Unstick renders identically off-device" true minus voice.
    @State private var narrated: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "hourglass")
                    .font(.glyphSmall())
                    .foregroundStyle(Palette.overdue)
                Text("This keeps sliding")
                    .font(.sectionHeader)
                    .foregroundStyle(Palette.primaryText)
            }

            // The voice ADDS a line, never replaces one: the template headline is
            // stable ground the user may already be reading — swapping text under a
            // reader is the one thing calm software doesn't do. The narrated
            // specifics fade in beneath.
            Text(diagnosis.headline(deferralCount: deferralCount))
                .supportingStyle()
                .fixedSize(horizontal: false, vertical: true)
            if let narrated {
                Text(narrated)
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            actions
        }
        // `.task(id:)` is the cancellation seam: flipping `isActive` cancels the
        // in-flight narration (the page was swiped past — the pager never unmounts it,
        // so `.onDisappear` can't be the signal).
        .task(id: isActive) {
            guard isActive, narrated == nil, let facts = narrationFacts else { return }
            if case .success(let sentence) = await UnstickNarrationService().narrate(facts),
                !sentence.isEmpty
            {
                withAnimation(Motion.settle) { narrated = sentence }
            }
            // Every other arm: the deterministic headline stays. No retry — the
            // template IS the content; an absent voice is not an error to manage.
        }
        .padding(Spacing.md)
        .background(
            Palette.primarySurface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    /// One row of quiet links. The offered set IS the diagnosis — the card never shows a
    /// move that doesn't address what it just named.
    @ViewBuilder private var actions: some View {
        HStack(spacing: Spacing.md) {
            switch diagnosis {
            case .blocked:
                // Nothing to offer but the truth: the blocker is the work. The unblock
                // affordance already lives in the property row, so this card doesn't
                // duplicate it — it explains why the task isn't moving.
                EmptyView()
            case .tooBig:
                link("Break it into steps", action: onBreakDown)
            case .reallyADecision:
                link("Make it a decision", action: onMakeDecision)
            case .dying:
                link("Do it now", action: onDoItNow)
                link("Defer it", action: onDefer)
                link("Let it go", role: .destructive, action: onKill)
            }
            Spacer(minLength: 0)
        }
    }

    private func link(
        _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.controlLabel)
                .foregroundStyle(role == .destructive ? Palette.mutedText : Palette.accentFlat)
        }
        .buttonStyle(.pressableLink)
    }
}
