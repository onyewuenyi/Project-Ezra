//
//  ConfirmCreationCard.swift
//  Project-Ezra
//
//  The Confirm-Creation card list: every candidate task from a capture, each with
//  every AI-inferred field pre-filled and individually editable — title, category,
//  due, owner, urgent, effort. Each field wears a quiet ✦ "assumed" marker so
//  the inference is honest without shouting AI branding. A row is one tap to
//  drop; every edit the user makes here is diffed against the AI's frozen
//  snapshot at commit and becomes a Correction row (the learning signal).
//
//  Operates purely on `TaskDraft`, so it is identical whichever engine produced
//  the candidates.
//

import CoreData
import SwiftUI

/// The editable list of candidates awaiting the user's confirm.
struct ConfirmCreationList: View {
    @Binding var drafts: [TaskDraft]

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach($drafts) { $draft in
                ConfirmCreationCard(draft: $draft, onRemove: { remove(draft) })
                    .transition(Motion.cardEntry)
            }
        }
        .animation(Motion.settle, value: drafts.map(\.id))
    }

    private func remove(_ draft: TaskDraft) {
        Motion.withMotion(Motion.decide) {
            drafts.removeAll { $0.id == draft.id }
        }
    }
}

// MARK: - One candidate card

struct ConfirmCreationCard: View {
    @Binding var draft: TaskDraft
    let onRemove: () -> Void

    /// Roster for the owner picker — every field on this card is editable, and
    /// "who does this belong to" needs real people to pick from.
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }

    /// Low confidence is a VISUAL state, never a queue: the candidate appears
    /// immediately, dimmed with a quiet question mark, and resolves (undims) if
    /// more talking or a re-parse raises the model's confidence. Judgment calls
    /// stay crisp — the model is certain; the call is just yours.
    private var isUncertain: Bool {
        draft.confidence < 0.5 && !draft.isJudgmentCall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                if isUncertain {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: IconSize.caption, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .padding(.top, 3)
                        .transition(.opacity)
                }
                TextField("Task", text: $draft.title, axis: .vertical)
                    .font(.taskTitle)
                    .foregroundStyle(Palette.primaryText)
                    .textInputAutocapitalization(.sentences)

                Spacer(minLength: 0)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: IconSize.caption, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressableIcon)
                .accessibilityLabel("Remove \(draft.title)")
            }

            chipRow

            // The one visible flag, present from birth: a judgment call announces
            // itself on the card, not after some later triage pass.
            if draft.isJudgmentCall {
                Label("Your call to make", systemImage: "hand.raised")
                    .font(.metadata)
                    .foregroundStyle(Palette.decisionAccent)
            }
        }
        .padding(Spacing.md)
        .background(
            Palette.primarySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
        .opacity(isUncertain ? 0.75 : 1)
        .animation(Motion.fade, value: isUncertain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isUncertain
                ? "\(draft.title), uncertain — keep talking or edit to firm it up"
                : draft.title)
    }

    // Every metadata field renders — pre-filled when the AI extracted or inferred
    // it, an add-affordance otherwise. The confirm glance only works if the user
    // can SEE every field the task will carry (creation-confirmation spec).
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                duplicateChip
                childChip
                // When the card will MERGE, its own fields are moot — recede them so the
                // merge chip is the clear headline.
                Group {
                    categoryChip
                    dueChip
                    ownerChip
                    urgentChip
                    effortChip
                    if draft.blockedBy != nil { blockerChip }
                    ForEach(draft.blocks, id: \.id) { dependent in
                        dependentChip(dependent)
                    }
                }
                .opacity(mergeAccepted ? 0.4 : 1)
            }
        }
    }

    /// True when an accepted duplicate proposal will fold this card into an existing task.
    private var mergeAccepted: Bool { draft.acceptedDuplicate != nil }

    private func setDecision(_ kind: EdgeProposal.Kind, _ decision: EdgeProposal.Decision) {
        guard let index = draft.edgeProposals.firstIndex(where: { $0.kind == kind }) else { return }
        draft.edgeProposals[index].decision = decision
    }

    // The duplicate proposal: accepted reads as a filled "Merges into…"; undecided as an
    // outline "Same as…?"; rejected as a quiet "Keeping both". All ✦ assumed, tokens only.
    @ViewBuilder private var duplicateChip: some View {
        if let dup = draft.edgeProposals.first(where: { $0.kind == .duplicateOf }) {
            Menu {
                if dup.decision == .accepted {
                    Button("Keep both") { setDecision(.duplicateOf, .rejected) }
                } else {
                    Button("Merge") { setDecision(.duplicateOf, .accepted) }
                    Button("Keep both") { setDecision(.duplicateOf, .rejected) }
                }
            } label: {
                switch dup.decision {
                case .accepted:
                    pill {
                        assumedMark
                        Image(systemName: "arrow.triangle.merge").font(.system(size: IconSize.caption))
                        Text("Merges into “\(dup.targetTitle)”").font(.metadata.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.accentFlat)
                case .undecided:
                    pill {
                        assumedMark
                        Image(systemName: "questionmark.circle").font(.system(size: IconSize.caption))
                        Text("Same as “\(dup.targetTitle)”?").font(.metadata.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.secondaryText)
                case .rejected:
                    pill {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: IconSize.caption))
                        Text("Keeping both").font(.metadata.weight(.medium))
                    }
                    .foregroundStyle(Palette.mutedText)
                }
            }
            .accessibilityLabel("Duplicate of \(dup.targetTitle), \(dup.decision.rawValue)")
        }
    }

    // The child proposal: "Step of '<parent>'".
    @ViewBuilder private var childChip: some View {
        if let child = draft.edgeProposals.first(where: { $0.kind == .childOf }) {
            Menu {
                if child.decision == .accepted {
                    Button("Keep separate") { setDecision(.childOf, .rejected) }
                } else {
                    Button("Make it a step") { setDecision(.childOf, .accepted) }
                    Button("Keep separate") { setDecision(.childOf, .rejected) }
                }
            } label: {
                pill {
                    assumedMark
                    Image(systemName: "arrow.turn.down.right").font(.system(size: IconSize.caption))
                    Text("Step of “\(child.targetTitle)”").font(.metadata.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(child.decision == .accepted ? Palette.secondaryText : Palette.mutedText)
            }
            .accessibilityLabel("Step of \(child.targetTitle), \(child.decision.rawValue)")
        }
    }

    // Category is always engine-inferred, so it wears the ✦ "assumed" marker.
    private var categoryChip: some View {
        Menu {
            ForEach(TaskCategory.all, id: \.self) { cat in
                Button {
                    draft.category = cat
                } label: {
                    Label(cat, systemImage: TaskCategory.symbol(for: cat))
                }
            }
        } label: {
            pill {
                assumedMark
                Image(systemName: TaskCategory.symbol(for: draft.category))
                    .font(.system(size: IconSize.caption))
                Text(draft.category)
                    .font(.metadata.weight(.medium))
            }
            .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityLabel("Category, assumed \(draft.category)")
    }

    private var dueChip: some View {
        Menu {
            Button("Today") { setDue(0) }
            Button("Tomorrow") { setDue(1) }
            Button("Next week") { setDue(7) }
            if draft.dueDate != nil {
                Divider()
                Button("Clear", role: .destructive) { draft.dueDate = nil }
            }
        } label: {
            if let due = draft.dueDate {
                pill {
                    assumedMark
                    Image(systemName: "calendar").font(.system(size: IconSize.caption))
                    Text(dueText(due)).font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.secondaryText)
            } else {
                pill {
                    Image(systemName: "plus").font(.system(size: IconSize.caption))
                    Text("due").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.mutedText)
            }
        }
        .accessibilityLabel(draft.dueDate == nil ? "Add due date" : "Due date")
    }

    // Ownership is always visible — "You" is a value, not an empty state. Inferred
    // delegation wears the ✦ "assumed" marker; the menu offers the real roster.
    private var ownerChip: some View {
        Menu {
            Button("You") { draft.ownerName = nil }
            if !familyMembers.isEmpty {
                Divider()
                ForEach(
                    familyMembers.filter { !$0.isRemoved }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                ) { member in
                    Button(member.name) { draft.ownerName = member.name }
                }
            }
        } label: {
            pill {
                if draft.ownerName != nil { assumedMark }
                OwnerAvatarBadge(
                    name: draft.ownerName ?? "Me", isMe: draft.ownerName == nil, size: 16)
                Text(draft.ownerName ?? "You")
                    .font(.metadata.weight(.medium))
            }
            .foregroundStyle(draft.ownerName == nil ? Palette.mutedText : Palette.secondaryText)
        }
        .accessibilityLabel("Owner, \(draft.ownerName ?? "you")")
    }

    // The reverse dependency: an existing task the AI thinks should wait on this
    // new one. Visible and removable before commit links the real edge.
    private func dependentChip(_ dependent: OpenTaskSnapshot) -> some View {
        Menu {
            Button("Don't link these", role: .destructive) {
                draft.blocks.removeAll { $0.id == dependent.id }
            }
        } label: {
            pill {
                assumedMark
                Image(systemName: "arrow.turn.down.right").font(.system(size: IconSize.caption))
                Text("blocks “\(dependent.title)”")
                    .font(.metadata.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityLabel("“\(dependent.title)” will wait on this task, assumed")
    }

    // The captured wait, visible and removable before it becomes a real blocker
    // at commit (a matching task, or an external note in the user's words).
    private var blockerChip: some View {
        Menu {
            Button("Not waiting on this", role: .destructive) { draft.blockedBy = nil }
        } label: {
            pill {
                assumedMark
                Image(systemName: "hourglass").font(.system(size: IconSize.caption))
                Text("after \(draft.blockedBy ?? "")")
                    .font(.metadata.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityLabel("Waiting on \(draft.blockedBy ?? ""), assumed")
    }

    // The Urgent signal as a toggle: on wears the ✦ "assumed" marker (the AI proposed
    // it from the wording) in the warning tint; off is a quiet add-affordance. Priority
    // is retired — attention is a computed score, not something set at capture.
    private var urgentChip: some View {
        Button {
            draft.isUrgent.toggle()
        } label: {
            if draft.isUrgent {
                pill {
                    assumedMark
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: IconSize.caption))
                    Text("Urgent").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.priorityUrgent)
            } else {
                pill {
                    Image(systemName: "exclamationmark.circle").font(.system(size: IconSize.caption))
                    Text("urgent").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.mutedText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.isUrgent ? "Urgent, on, assumed" : "Mark urgent")
    }

    private var effortChip: some View {
        Menu {
            Button("15 min") { draft.effortMinutes = 15 }
            Button("30 min") { draft.effortMinutes = 30 }
            Button("1 hour") { draft.effortMinutes = 60 }
            Button("2 hours") { draft.effortMinutes = 120 }
            Divider()
            Button("Clear", role: .destructive) { draft.effortMinutes = nil }
        } label: {
            if draft.effortMinutes != nil {
                pill {
                    assumedMark
                    Image(systemName: "timer").font(.system(size: IconSize.caption))
                    Text(effortLabel)
                        .font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.secondaryText)
            } else {
                pill {
                    Image(systemName: "plus").font(.system(size: IconSize.caption))
                    Text("effort").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.mutedText)
            }
        }
        .accessibilityLabel(
            draft.effortMinutes == nil ? "Add effort estimate" : "Effort, assumed \(effortLabel)")
    }

    private var effortLabel: String { TaskItem.effortLabel(draft.effortMinutes) ?? "" }

    /// The quiet "assumed" marker — `accentFlat`, NOT the sanctioned gradient
    /// AITag; that stays within its budget.
    private var assumedMark: some View {
        Image(systemName: "sparkle")
            .font(.system(size: IconSize.nano, weight: .semibold))
            .foregroundStyle(Palette.accentFlat)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        MetadataChip(density: .compact) { content() }
    }

    private func setDue(_ dayOffset: Int) {
        let cal = Calendar.current
        draft.dueDate = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

#Preview {
    @Previewable @State var drafts = [
        TaskDraft(
            title: "Renew passport", category: "Travel", proposedStatus: .inbox, confidence: 0.85,
            autonomy: .silent, isJudgmentCall: false, reasoning: "Filed under Travel.", dueDate: nil,
            effortMinutes: 30),
        TaskDraft(
            title: "Should I quit the gym", category: "Health", proposedStatus: .inbox,
            confidence: 0.4,
            autonomy: .ask, isJudgmentCall: true, reasoning: "Your call to make.", dueDate: nil),
    ]

    return ScrollView {
        ConfirmCreationList(drafts: $drafts)
            .padding()
    }
    .background(Palette.background)
}
