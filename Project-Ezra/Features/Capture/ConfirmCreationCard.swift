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
    /// Ids already on screen — what tells an entering card its place in the batch,
    /// so a multi-card arrival CASCADES instead of landing as one slab.
    @State private var knownIDs: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A parse that lands several cards at once staggers them by arrival order
        // (`Motion.staggerStep`, the detail screen's idiom) — capped so a big paste
        // doesn't turn into a slow reveal. Reduce Motion: no stagger.
        let entering = drafts.map(\.id).filter { !knownIDs.contains($0) }
        // Lazy on purpose: a big paste renders only what's visible. Safe now that
        // `DraftMerge` keeps ids stable — under the old merge, per-partial identity
        // churn would have made laziness thrash instead of save.
        LazyVStack(spacing: Spacing.sm) {
            ForEach($drafts) { $draft in
                let batchIndex = entering.firstIndex(of: draft.id) ?? 0
                ConfirmCreationCard(
                    draft: $draft, ownerOptions: ownerOptions, rosterNames: rosterNames,
                    onAddToRoster: onAddToRoster, onRemove: { remove(draft) },
                    // One candidate gets the whole surface — the single-task capture
                    // is the fast path, and it should read like a task, not a row.
                    presentation: drafts.count == 1 ? .hero : .listRow
                )
                // Structural skipping, explicitly: the card holds closures, so
                // SwiftUI would otherwise rebuild every card's body on every list
                // invalidation — each keystroke into any title, each streamed
                // partial. `==` compares the VALUES (draft + rosters); the closures
                // are deliberately excluded (behaviorally stable — they route
                // through DraftMerge keys and live fetches, never captured state).
                .equatable()
                // Swipe is the second remove affordance (the X button stays — it is
                // the guaranteed and accessible path). OUTSIDE `.equatable()` so the
                // closure doesn't disturb structural skipping; `allowsFullSwipe:
                // false` because destroying a candidate with one flick is too cheap
                // for a decisive act.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        remove(draft)
                    } label: {
                        Label("Remove", systemImage: "xmark")
                    }
                }
                .transition(
                    Motion.cardEntry.animation(
                        reduceMotion
                            ? nil
                            : Motion.settle.delay(Double(min(batchIndex, 5)) * Motion.staggerStep))
                )
            }
        }
        .animation(Motion.settle, value: drafts.map(\.id))
        .onChange(of: drafts.map(\.id), initial: true) { _, ids in
            knownIDs = Set(ids)
        }
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

struct ConfirmCreationCard: View, Equatable {
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
    /// How much room this card has. `.listRow` is the dense multi-candidate shape;
    /// `.hero` is the single-task confirm — the fast path's own surface, where there
    /// is vertical room to show every field at once instead of hiding most of them
    /// behind a horizontal scroller (the audit's K3, closed for this case).
    var presentation: Presentation = .listRow

    enum Presentation { case listRow, hero }

    /// The due chip's three shortcuts cover the common cases; anything else needs a real
    /// calendar, and making the user commit first and fix it in the detail is the kind of
    /// small tax the confirm glance exists to remove.
    @State private var showDatePicker = false
    /// Whether the non-essential metadata is revealed on this card.
    @State private var expanded = false

    /// Value equality for `.equatable()` — the draft and the roster values are the
    /// card's whole rendered identity; the closures are excluded on purpose (see the
    /// call site) and `showDatePicker` is view storage SwiftUI tracks itself.
    static func == (lhs: ConfirmCreationCard, rhs: ConfirmCreationCard) -> Bool {
        lhs.draft == rhs.draft && lhs.ownerOptions == rhs.ownerOptions
            && lhs.rosterNames == rhs.rosterNames && lhs.presentation == rhs.presentation
    }

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
                        .font(.glyphCaption(.semibold))
                        .foregroundStyle(Palette.mutedText)
                        .padding(.top, 3)
                        .transition(.opacity)
                }
                TextField("Task", text: titleBinding, axis: .vertical)
                    .font(presentation == .hero ? .sectionHeader : .taskTitle)
                    .foregroundStyle(Palette.primaryText)
                    .textInputAutocapitalization(.sentences)

                Spacer(minLength: 0)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.glyphCaption(.semibold))
                        .foregroundStyle(Palette.mutedText)
                        // Visual glyph stays quiet; the TOUCHABLE region meets the
                        // HIG minimum — this is a destructive control operated at
                        // speed, exactly where a miss-tap lands on the title field
                        // instead. It reaches into the surrounding padding rather
                        // than reserving 44pt of layout: a one-line card was being
                        // stretched to the height of its delete button.
                        .minimumHitTarget(around: IconSize.small)
                }
                .buttonStyle(.pressableIcon)
                .accessibilityLabel("Remove \(draft.title)")
            }

            // Gated, not merely empty: a zero-height subview still consumes a VStack
            // spacing slot, so a card the AI understood plainly ("Buy diapers") would
            // carry the vertical rhythm of one that carries a due date and a reason.
            if hasEssentialChips || expanded {
                chipRowWithRationale
            }

            consequenceLine

            Button {
                Motion.withMotion(Motion.settle) { expanded.toggle() }
            } label: {
                Label(
                    expanded ? "Fewer details" : "Details",
                    systemImage: expanded ? "chevron.up" : "chevron.down"
                )
                .font(.metadata)
                .foregroundStyle(Palette.mutedText)
                .minimumHitTarget(around: IconSize.small)
            }
            .buttonStyle(.pressableLink)
            .accessibilityLabel(expanded ? "Hide details" : "Show category and effort")
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

    // A REVISION of the creation-confirmation spec's "the glance only works if the user
    // can SEE every field the task will carry": every field is now reachable in ONE TAP,
    // and the glance shows what's consequential. Rendering all eight made the two chips
    // that carried information look exactly like the six that were empty invitations —
    // which is the opposite of a glance, and the reason the old rule defeated itself.
    @ViewBuilder private var chipRow: some View {
        // Both presentations now WRAP: the horizontal scroller existed because every
        // chip always rendered, and a dense row had no width for eight of them. Showing
        // only what the AI understood makes them fit — and a chip that fits is a chip
        // the user can actually check.
        FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
            duplicateChip
            childChip
            essentialChips
            if expanded { detailChips }
        }
    }

    /// Does this chip carry information, or is it an empty "add…" affordance? The
    /// reveal shows only what the AI actually understood; everything else is one tap
    /// away behind Details. A confirm glance that lists eight identical-looking
    /// affordances is not a glance.
    /// Whether `essentialChips` (or an edge proposal) will render anything at all.
    /// Mirrors that view's conditions exactly — if one gains a chip, so must this.
    private var hasEssentialChips: Bool {
        draft.dueDate != nil || draft.ownerName != nil || draft.isUrgent
            || draft.blockedBy != nil || !draft.blocks.isEmpty
            || draft.edgeProposals.contains { $0.kind == .duplicateOf || $0.kind == .childOf }
    }

    private var essentialChips: some View {
        Group {
            if draft.dueDate != nil { dueChip }
            if draft.ownerName != nil { ownerChip }
            if draft.isUrgent { urgentChip }
            if draft.blockedBy != nil { blockerChip }
            ForEach(draft.blocks, id: \.id) { dependent in
                dependentChip(dependent)
            }
        }
        .opacity(mergeAccepted ? 0.4 : 1)
        .disabled(mergeAccepted)
    }

    /// Everything else — category, effort, and the empty affordances — revealed
    /// on demand. Nothing becomes uneditable; it becomes uncluttered.
    private var detailChips: some View {
        Group {
            categoryChip
            if draft.dueDate == nil { dueChip }
            if draft.ownerName == nil { ownerChip }
            if !draft.isUrgent { urgentChip }
            effortChip
        }
        .opacity(mergeAccepted ? 0.4 : 1)
        .disabled(mergeAccepted)
    }

    /// The consequence, never the classifier. `workIntent` is an internal axis; what
    /// the user needs to know is what it MEANS for them — that this one needs deciding
    /// or planning before it can be done.
    @ViewBuilder private var consequenceLine: some View {
        if draft.needsDecision || draft.isJudgmentCall {
            Label("Needs a decision", systemImage: "hand.raised")
                .font(.metadata)
                .foregroundStyle(Palette.decisionAccent)
        } else if draft.workIntent == .planning {
            Label("Needs a plan", systemImage: "list.bullet.indent")
                .font(.metadata)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    @ViewBuilder private var chipContent: some View {
        duplicateChip
        childChip
        // When the card will MERGE, its own fields are moot — recede them so the
        // merge chip is the clear headline, and DISABLE them so the recede means
        // what it shows.
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
        .disabled(mergeAccepted)
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
                        Image(systemName: "arrow.triangle.merge").font(.glyphCaption())
                        Text("Merges into “\(dup.targetTitle)”").font(.metadata.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.accentFlat)
                case .undecided:
                    pill {
                        assumedMark
                        Image(systemName: "questionmark.circle").font(.glyphCaption())
                        Text("Same as “\(dup.targetTitle)”?").font(.metadata.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.secondaryText)
                case .rejected:
                    pill {
                        Image(systemName: "rectangle.on.rectangle").font(.glyphCaption())
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
                        Image(systemName: "rectangle.on.rectangle").font(.glyphCaption())
                        Text("Keeping separate").font(.metadata.weight(.medium))
                    }
                    .foregroundStyle(Palette.mutedText)
                } else {
                    pill {
                        assumedMark
                        Image(systemName: "arrow.turn.down.right").font(.glyphCaption())
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
                    .font(.glyphCaption())
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
                    Image(systemName: "calendar").font(.glyphCaption())
                    Text(dueText(due)).font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.secondaryText)
            } else {
                pill {
                    Image(systemName: "plus").font(.glyphCaption())
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
        // One resolvability check per build — as a computed property it was
        // re-evaluated (a trim + roster scan) at every one of its ~5 read sites.
        let missing = unresolvableOwner
        return Menu {
            if let missing, let onAddToRoster {
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
                if draft.ownerReason != nil, missing == nil { assumedMark }
                if let missing {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.glyphCaption())
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
            .foregroundStyle(ownerChipTint(missing: missing))
        }
        .accessibilityLabel(ownerAccessibilityLabel(missing: missing))
    }

    /// `warning` is the literal-warning token (the only other user is Settings' store-reset
    /// notice) — deliberately NOT one of the three attention hues, which mean urgency,
    /// in-progress, and overdue on a *task*. This is a warning about the card itself.
    private func ownerChipTint(missing: String?) -> Color {
        if missing != nil { return Palette.warning }
        return draft.ownerName == nil ? Palette.mutedText : Palette.secondaryText
    }

    private func ownerAccessibilityLabel(missing: String?) -> String {
        if let missing {
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
                Image(systemName: "arrow.turn.down.right").font(.glyphCaption())
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
                Image(systemName: "hourglass").font(.glyphCaption())
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
                    Image(systemName: "exclamationmark.circle.fill").font(.glyphCaption())
                    Text("Urgent").font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.priorityUrgent)
            } else {
                pill {
                    Image(systemName: "exclamationmark.circle").font(.glyphCaption())
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
                    Image(systemName: "timer").font(.glyphCaption())
                    Text(effortLabel)
                        .font(.metadata.weight(.medium))
                }
                .foregroundStyle(Palette.secondaryText)
            } else {
                pill {
                    Image(systemName: "plus").font(.glyphCaption())
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
            .font(.glyphNano(.semibold))
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
