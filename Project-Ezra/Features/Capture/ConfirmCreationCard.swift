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
    /// The delegatable roster — everyone but the current user — computed ONCE by the
    /// composer from fetches it already holds. A value list, deliberately: each card
    /// used to own two live NSFetchedResultsControllers for data that never varies
    /// card-to-card, which at N cards meant 2N context observers torn down and
    /// rebuilt with every identity change.
    var ownerOptions: [String] = []
    /// EVERY live roster name, the current user included — the set `resolveOwners`
    /// actually matches against at commit. Distinct from `ownerOptions` (which excludes
    /// you, because "You" is its own menu entry): resolvability must be judged against
    /// the real roster, or a task owned by your own named member would read unresolvable.
    var rosterNames: [String] = []
    /// Add a name to the household roster. The card can't do it itself — the composer
    /// owns the context and the household — and this is deliberately the ONLY way a
    /// name becomes a member from here: an explicit human tap, never a silent mint.
    var onAddToRoster: ((String) -> Void)? = nil
    /// Called with the removed draft BEFORE it leaves the array, so the composer can
    /// record it — a removed card must stay removed across re-parses (`DraftMerge`
    /// filters re-proposals against the session's `RemovedDraftSet`).
    var onRemove: ((TaskDraft) -> Void)? = nil
    /// Counts removals so the card leaving can be FELT, not just seen. Dropping a
    /// candidate is a decisive act on a surface where everything else is a
    /// reversible edit; the animation alone left it oddly weightless.
    @State private var removals = 0

    var body: some View {
        // Lazy on purpose: a big paste renders only what's visible. Safe now that
        // `DraftMerge` keeps ids stable — under the old merge, per-partial identity
        // churn would have made laziness thrash instead of save.
        LazyVStack(spacing: Spacing.sm) {
            ForEach($drafts) { $draft in
                ConfirmCreationCard(
                    draft: $draft, ownerOptions: ownerOptions, rosterNames: rosterNames,
                    onAddToRoster: onAddToRoster, onRemove: { remove(draft) }
                )
                .transition(Motion.cardEntry)
            }
        }
        .animation(Motion.settle, value: drafts.map(\.id))
        // Container semantics so VoiceOver announces the list as a group with its
        // size, rather than dropping the user into an unlabeled run of cards.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            drafts.count == 1 ? "1 task to review" : "\(drafts.count) tasks to review"
        )
        .sensoryFeedback(.impact(weight: .light), trigger: removals)
    }

    private func remove(_ draft: TaskDraft) {
        removals += 1
        onRemove?(draft)
        Motion.withMotion(Motion.decide) {
            drafts.removeAll { $0.id == draft.id }
        }
    }
}

// MARK: - One candidate card

struct ConfirmCreationCard: View {
    @Binding var draft: TaskDraft
    /// Names the owner chip may delegate to (never includes "You" — that's the
    /// explicit first entry). Passed as values from the composer's own fetches.
    var ownerOptions: [String] = []
    /// EVERY live roster name, the current user included — the set `resolveOwners`
    /// actually matches against at commit. Distinct from `ownerOptions` (which excludes
    /// you, because "You" is its own menu entry): resolvability must be judged against
    /// the real roster, or a task owned by your own named member would read unresolvable.
    var rosterNames: [String] = []
    /// Add a name to the household roster. The card can't do it itself — the composer
    /// owns the context and the household — and this is deliberately the ONLY way a
    /// name becomes a member from here: an explicit human tap, never a silent mint.
    var onAddToRoster: ((String) -> Void)? = nil
    let onRemove: () -> Void

    /// The due chip's three shortcuts cover the common cases; anything else needs a real
    /// calendar, and making the user commit first and fix it in the detail is the kind of
    /// small tax the confirm glance exists to remove.
    @State private var showDatePicker = false

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
                TextField("Task", text: titleBinding, axis: .vertical)
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

            chipRowWithRationale

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
                // merge chip is the clear headline, and DISABLE them so the recede means
                // what it shows. They were still tappable, so a user could set a due date
                // on a card that was about to fold into another task and watch the value
                // vanish at commit. Recede-but-live is a promise the commit can't keep;
                // one tap on "Keep both" brings them back.
                Group {
                    kindChip
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
                .disabled(mergeAccepted)
            }
        }
        // The overflow affordance the glance was missing: chips past the fold used
        // to be invisible with zero cue (no indicator, no fade), which is how a
        // wrong owner survived the one moment it was cheap to catch. The trailing
        // fade is the cheapest honest "there is more" (mask alpha only — the colors
        // here are opacity, not paint).
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
                )
                .frame(width: Spacing.lg)
            }
        )
    }

    /// The chip row plus the owner rationale beneath it, so "why Maya?" is answerable
    /// without tapping anything — the guardrails' "every AI decision is explainable" clause
    /// at the one moment the decision is still cheap to change.
    private var chipRowWithRationale: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            chipRow
            ownerReasonLine
            dueReasonLine
            if showDatePicker {
                DatePicker("Due date", selection: dueBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Palette.accentFlat)
                    .labelsHidden()
            }
        }
    }

    /// Every user edit marks its field, so `DraftMerge` knows to re-apply it over a
    /// fresh AI reading — an edit a re-parse can silently discard isn't an edit.
    private var titleBinding: Binding<String> {
        Binding(
            get: { draft.title },
            set: {
                draft.title = $0
                draft.markEdited(.title)
            }
        )
    }

    /// Non-optional for the picker's sake. The fallback (today) is DISPLAY-ONLY:
    /// opening the picker no longer writes anything to the draft — the old "seed
    /// today first" arm meant browsing the calendar and backing out silently
    /// committed "due today", which becomes a real date at commit and a false
    /// Overdue tomorrow. The draft changes only when the user actually picks a day
    /// (the graphical picker's `set` fires on selection, never on display).
    private var dueBinding: Binding<Date> {
        Binding(
            get: { draft.dueDate ?? Calendar.current.startOfDay(for: Date()) },
            set: {
                draft.dueDate = $0
                draft.dueReason = nil
                draft.markEdited(.dueDate)
            }
        )
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
                // Rejected gets its OWN reading, mirroring the duplicate chip: tapping
                // "Keep separate" used to produce no visible change (rejected differed
                // from accepted only by a muted tint on 12pt type), so a decision with
                // a 180-day suppression consequence looked like it never registered.
                if child.decision == .rejected {
                    pill {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: IconSize.caption))
                        Text("Keeping separate").font(.metadata.weight(.medium))
                    }
                    .foregroundStyle(Palette.mutedText)
                } else {
                    pill {
                        assumedMark
                        Image(systemName: "arrow.turn.down.right").font(.system(size: IconSize.caption))
                        Text("Step of “\(child.targetTitle)”").font(.metadata.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityLabel(
                child.decision == .rejected
                    ? "Keeping separate from \(child.targetTitle)"
                    : "Step of \(child.targetTitle), \(child.decision.rawValue)")
        }
    }

    // Category is always engine-inferred, so it wears the ✦ "assumed" marker.
    private var categoryChip: some View {
        Menu {
            ForEach(TaskCategory.all, id: \.self) { cat in
                Button {
                    draft.category = cat
                    draft.markEdited(.category)
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

    /// What KIND of work this is (axis 2). It leads the row on purpose: "what sort of
    /// thing is this" reads ahead of "what area of life does it belong to".
    ///
    /// It is here at all because this classification is not cosmetic — it voices the
    /// detail's primary CTA and decides which capability the task is offered. Stamping
    /// it silently at commit made a field with real consequences the only one the
    /// confirm glance didn't show.
    private var kindChip: some View {
        Menu {
            ForEach(WorkIntent.allCases) { intent in
                Button(intent.label) {
                    draft.workIntent = intent
                    draft.markEdited(.workIntent)
                }
            }
            if draft.workIntent != nil {
                Divider()
                Button("Clear", role: .destructive) {
                    draft.workIntent = nil
                    draft.markEdited(.workIntent)
                }
            }
        } label: {
            if let intent = draft.workIntent {
                pill {
                    assumedMark
                    Image(systemName: "square.stack.3d.up").font(.system(size: IconSize.caption))
                    Text(intent.label).font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.secondaryText)
            } else {
                // Unreachable after the resolver's backfill, but kept so a fixture or a
                // cleared value degrades to the same add-affordance its neighbours use.
                pill {
                    Image(systemName: "plus").font(.system(size: IconSize.caption))
                    Text("kind").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.mutedText)
            }
        }
        .accessibilityLabel(
            draft.workIntent.map { "Kind of work, assumed \($0.label)" } ?? "Add kind of work")
    }

    private var dueChip: some View {
        Menu {
            Button("Today") { setDue(0) }
            Button("Tomorrow") { setDue(1) }
            Button("Next week") { setDue(7) }
            Button("Pick a date…") { showDatePicker = true }
            if draft.dueDate != nil {
                Divider()
                Button("Clear", role: .destructive) {
                    draft.dueDate = nil
                    draft.dueReason = nil
                    draft.markEdited(.dueDate)
                    showDatePicker = false
                }
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

    // Ownership is always visible — "You" is a value, not an empty state.
    //
    // Two rules the AI's involvement imposes here:
    //
    // 1. The ✦ "assumed" mark keys off `ownerReason`, NOT off "the owner isn't you".
    //    The proposer leaves the reason nil for its default-to-capturer rung, which
    //    catches most captures — marking that as an inference would claim the AI
    //    worked something out when it didn't, which is worse for trust than the
    //    abstention this replaced.
    // 2. This is the last moment to catch a wrong owner — and delegating a task the
    //    AI left with you is exactly as consequential as un-delegating one it sent
    //    away, so BOTH states need the full tap target. That no longer takes a
    //    density fork: `.compact` now carries the same invisible 44pt touch region
    //    as `.standard` (the old fork was inverted anyway — the common "You" state
    //    got the small target its own comment argued against).
    //
    // No directional arrow yet. `→ Aisha` reads as transmission, and nothing is
    // transmitted until sync — it ships with delivery, not before.
    /// The name on the chip that `resolveOwners` will NOT be able to resolve at commit.
    ///
    /// The no-mint policy is right — a phantom `FamilyMember` conjured from a misheard
    /// name becomes an *existing* person who can accrue category ownership and be
    /// proposed as an owner for future work. But the card said "Maya" in confident type
    /// and commit then produced an unowned task, silently. That's the policy leaking as
    /// a broken promise. Say so on the chip instead, while it is still one tap to fix.
    private var unresolvableOwner: String? {
        guard let name = draft.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty,
            // Same comparison `AppBrain.resolveOwners` uses, so the chip and the commit
            // can never disagree about what "resolvable" means.
            !rosterNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    private var ownerChip: some View {
        Menu {
            if let missing = unresolvableOwner, let onAddToRoster {
                Button("Add \(missing) to household…", systemImage: "person.badge.plus") {
                    onAddToRoster(missing)
                }
                Divider()
            }
            Button("You") {
                draft.ownerName = nil
                draft.markEdited(.ownerName)
            }
            if !ownerOptions.isEmpty {
                Divider()
                ForEach(ownerOptions, id: \.self) { name in
                    Button(name) {
                        draft.ownerName = name
                        draft.markEdited(.ownerName)
                    }
                }
            }
        } label: {
            MetadataChip(density: .compact) {
                if draft.ownerReason != nil, unresolvableOwner == nil { assumedMark }
                if let missing = unresolvableOwner {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: IconSize.caption))
                    Text("\(missing) · not in household")
                        .font(.metadata.weight(.medium))
                        .lineLimit(1)
                } else {
                    OwnerAvatarBadge(
                        name: draft.ownerName ?? "Me", isMe: draft.ownerName == nil, size: 16)
                    Text(draft.ownerName ?? "You")
                        .font(.metadata.weight(.medium))
                }
            }
            .foregroundStyle(ownerChipTint)
        }
        .accessibilityLabel(ownerAccessibilityLabel)
    }

    /// `warning` is the literal-warning token (the only other user is Settings' store-reset
    /// notice) — deliberately NOT one of the three attention hues, which mean urgency,
    /// in-progress, and overdue on a *task*. This is a warning about the card itself.
    private var ownerChipTint: Color {
        if unresolvableOwner != nil { return Palette.warning }
        return draft.ownerName == nil ? Palette.mutedText : Palette.secondaryText
    }

    private var ownerAccessibilityLabel: String {
        if let missing = unresolvableOwner {
            return
                "Owner, \(missing), not in your household — this task will be shared unless you add them"
        }
        return "Owner, \(draft.ownerName ?? "you")\(draft.ownerReason != nil ? ", assumed" : "")"
    }

    /// Why the AI chose this owner, in one line. Only ever present for a real
    /// inference — never for the default-to-you rung.
    @ViewBuilder private var ownerReasonLine: some View {
        if let reason = draft.ownerReason {
            Text(reason)
                .font(.chipLabel)
                .foregroundStyle(Palette.mutedText)
                .lineLimit(2)
        }
    }

    /// Why a due date the user never spoke is sitting on the card. Only ever present for
    /// a date inferred from the task's nature — a date they actually said explains
    /// itself, and captioning it would claim an inference that didn't happen.
    @ViewBuilder private var dueReasonLine: some View {
        if let reason = draft.dueReason, draft.dueDate != nil {
            Text(reason)
                .font(.chipLabel)
                .foregroundStyle(Palette.mutedText)
                .lineLimit(2)
        }
    }

    // The reverse dependency: an existing task the AI thinks should wait on this
    // new one. Visible and removable before commit links the real edge.
    private func dependentChip(_ dependent: OpenTaskSnapshot) -> some View {
        Menu {
            Button("Don't link these", role: .destructive) {
                draft.blocks.removeAll { $0.id == dependent.id }
                draft.markEdited(.blocks)
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
            Button("Not waiting on this", role: .destructive) {
                draft.blockedBy = nil
                draft.markEdited(.blockedBy)
            }
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
            draft.markEdited(.isUrgent)
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
            Button("15 min") { setEffort(15) }
            Button("30 min") { setEffort(30) }
            Button("1 hour") { setEffort(60) }
            Button("2 hours") { setEffort(120) }
            Divider()
            Button("Clear", role: .destructive) { setEffort(nil) }
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

    private func setEffort(_ minutes: Int?) {
        draft.effortMinutes = minutes
        draft.markEdited(.effortMinutes)
    }

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

    /// Any hand-picked date drops the rationale with it — the caption explains the AI's
    /// proposal, and once the user has overridden it there is no proposal left to explain.
    private func setDue(_ dayOffset: Int) {
        let cal = Calendar.current
        draft.dueDate = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))
        draft.dueReason = nil
        draft.markEdited(.dueDate)
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
            title: "Renew passport", category: "Travel", confidence: 0.85,
            autonomy: .silent, isJudgmentCall: false, reasoning: "Filed under Travel.", dueDate: nil,
            effortMinutes: 30),
        TaskDraft(
            title: "Should I quit the gym", category: "Health", confidence: 0.4,
            autonomy: .ask, isJudgmentCall: true, reasoning: "Your call to make.", dueDate: nil),
    ]

    return ScrollView {
        ConfirmCreationList(drafts: $drafts)
            .padding()
    }
    .background(Palette.background)
}
