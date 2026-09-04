//
//  TaskDetailView.swift
//  Project-Ezra
//
//  The full-screen task page, merged with Linear's issue layout: a category kicker, a
//  big editable title, a wrapping row of property chips (status · owner · urgent · due ·
//  category · effort · waiting-on), a description, and a per-task Activity timeline built
//  from the change log. Every field is editable in place; all state changes route through
//  the shared `TaskItem` mutations so the page can never drift from the lists. Manual
//  field edits ARE logged now (as `.human` "edited" entries) — they feed this page's own
//  Linear-style Activity timeline (`DetailActivityTimeline`) but are kept OUT of the
//  global Inbox, which stays the AI's + resolutions' feed. Scalar edits log through the
//  `set…` seams below; the freely-typed title/description diff on focus loss so a row
//  appears without leaving the screen.
//
//  This is ONE PAGE, not the whole surface: `TaskDetailPager` owns the chrome (nav bar,
//  back chevron, "…" menu, edge-swipe dismiss) and hosts a horizontally-paged stack of
//  these so a swipe moves to the neighbouring task. Two inputs come from the pager:
//  `isActive` (this page is the one on screen) and `onResolved` (the task left the
//  working set — the pager advances to the next peer, or dismisses when it was the last).
//

import CoreData
import SwiftUI

struct TaskDetailView: View {
    @ObservedObject var task: TaskItem
    /// True when this page is the one on screen. Neighbours stay mounted in the pager, so
    /// anything with a cost or a side effect (model prewarm, held keyboard focus) gates on it.
    let isActive: Bool
    /// The task left the working set (done / canceled). The pager decides what that means
    /// — advance to the next peer, or dismiss when there is no next.
    let onResolved: () -> Void
    /// The transient undo pill, owned and presented by the pager (a page that resolves
    /// gets swiped away, so it can't present its own).
    ///
    /// Resolving used to be the one mutation whose reversibility depended on WHICH
    /// SCREEN you were standing on: the same completion offered an undo — and named the
    /// dependents it freed — from a row, and nothing at all from here.
    @Binding var notice: UndoNotice?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    private var allTasks: [TaskItem] { Array(allTasksResults) }
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    private var profiles: [UserProfile] { Array(profilesResults) }
    /// This task's own change-log history — the Activity feed (predicate built in init).
    @FetchRequest private var activityResults: FetchedResults<ChangeLogEntry>
    private var activityEntries: [ChangeLogEntry] { Array(activityResults) }

    private var currentUserID: UUID? { profiles.first?.linkedMemberID }
    private var otherMembers: [FamilyMember] { familyMembers.filter { $0.uuid != currentUserID } }

    @State private var showDatePicker = false
    @State private var showAddPerson = false
    @State private var newPersonName = ""
    @State private var appeared = false
    /// The kickoff line under the relabeled CTA, once it lands. Never persisted.
    @State private var kickoffStep: String?
    @State private var kickoffWork: Task<Void, Never>?
    @State private var actionPulse = 0
    /// The one haptic that differs from the rest: finishing a task is `.success`,
    /// every edit and lifecycle nudge is the soft impact on `actionPulse`. The capture
    /// commit already makes this distinction; the page's own resolution earned it too.
    @State private var resolvePulse = 0
    @State private var showAllActivity = false
    /// Guards the primary CTA against a double-tap firing `performPrimary` twice
    /// before the page reacts to the first one — `completeAndResurface` and its
    /// siblings insert a ChangeLogEntry unconditionally on every call, so a second
    /// firing produces a duplicate Activity row rather than a duplicate task.
    @State private var isPerformingPrimary = false
    /// Set when `context.saveChanges()` reports a dropped write after the primary
    /// action — the button already animated success, so this is the one honest
    /// way left to tell the user the mutation didn't actually land.
    @State private var showSaveFailedAlert = false
    /// The action and its resurfaced dependents, held across a failed save so
    /// "Try Again" can finish the same action rather than re-running the mutation.
    @State private var pendingPrimaryAction: RecommendedAction?
    @State private var pendingUnblocked: [TaskItem] = []
    /// "Why this is here" + Activity, collapsed behind one quiet toggle. Provenance
    /// and history are inputs, not content the page must always show — every field
    /// stays one tap away, and the glance shows what is consequential.
    @State private var showDetails = false
    /// The Mark-decided prompt, for the paths where no option carries the outcome.
    /// The confirm IS the clearing tap — cancel leaves the flag set, because the
    /// user just said they are not done deciding after all.
    @State private var showDecisionPrompt = false
    @State private var decisionChoice = ""
    /// The Advisor's judgment cache — ambient, fingerprint-keyed, shared across pages.
    @ObservedObject private var advisorStore = TaskAdvisorStore.shared
    /// The pager owns the task chat sheet; the bar's advisor line opens it.
    @Environment(\.openTaskChat) private var openTaskChat
    /// A related task opened from this page — a blocker from the waiting spine or
    /// the Advisor's openBlocker move, or a step from the container spine. A nested
    /// single-page detail, because the pager's peer list is snapshotted and the
    /// related task may not be a peer.
    @State private var openedRelated: TaskItem?
    /// The in-flight re-classification, held so it can be cancelled. Unlike the card
    /// views this runs unprompted, so it is the one most likely to outlive the user's
    /// interest in this page.
    @State private var classifyWork: Task<Void, Never>?

    /// Freely-typed fields diff on focus loss (title/description) — snapshots of what they
    /// held when editing began, so a change logs exactly one "edited" row per commit.
    private enum EditField { case title, notes, newStep }
    /// The container spine's inline "Add a step" field. Cleared on commit.
    @State private var newStepTitle = ""
    @FocusState private var focusedField: EditField?
    @State private var originalTitle = ""
    @State private var originalNotes: String?

    init(
        task: TaskItem, isActive: Bool = true, onResolved: @escaping () -> Void = {},
        notice: Binding<UndoNotice?> = .constant(nil)
    ) {
        self.task = task
        self.isActive = isActive
        self.onResolved = onResolved
        _notice = notice
        _activityResults = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)],
            predicate: task.uuid.map { NSPredicate(format: "taskUUID == %@", $0 as CVarArg) }
                ?? NSPredicate(value: false)
        )
    }

    /// What kind of page this task needs — derived from facts, never stored, never
    /// model-decided, and provably a function of the Advisor fingerprint's inputs,
    /// so the layout can only change when the reading was going to change anyway.
    private var shape: TaskShape { TaskShape.of(task, among: allTasks) }

    /// Whether the Advisor section occupies any geometry at all. Hoisted out of
    /// `AdvisorView` so a quiet task — the common case — has NO advisor slot in the
    /// stack, instead of an empty view silently doubling the section gap.
    /// What bears on the choice, for the obligation block — the deciding page's
    /// what-matters lines. Always the page's to show now: the decide reading's own
    /// lines live in the chat, so there is no second box to duplicate.
    private var obligationContextLines: [String] {
        guard shape == .deciding else { return [] }
        return TaskAdvisorFacts.make(task: task, among: allTasks).decisionContextLines
    }

    /// The page's Advisor section is the OBLIGATION block only (2026-09-02). The
    /// reading itself never enters the body: it reaches the page as one line in the
    /// pinned bar (`advisorLine`) and opens into the task chat.
    private var advisorVisible: Bool {
        AdvisorView.isVisible(
            state: advisorStore.state(for: task),
            flagged: task.needsDecision && !task.status.isResolved,
            diagnosis: StallDetector.diagnose(task, among: allTasks),
            readingRendered: false)
    }

    /// The one sentence the bar carries under the CTA. Rung 0 first: a `.doing`
    /// task's kickoff step (the first move, stored or generated); otherwise the
    /// reading's observation — model or floor. Nil renders nothing; the bar never
    /// reserves a blank line.
    /// The bar's one line: a kickoff step, a reading, or — new with F-09 — SILENCE that
    /// can be felt. A model-judged "nothing" used to render as nothing at all, which is
    /// indistinguishable from the Advisor not being there; now it renders as evidence
    /// that Ezra looked, and when. Muted, never a badge, and it still opens the chat —
    /// asking is the natural follow-up to silence.
    struct BarLine: Equatable {
        enum Kind: Equatable {
            case kickoff
            case reading
            case silence
        }
        let text: String
        let kind: Kind
        var opensChat: Bool { kind != .kickoff }
    }

    private var advisorLine: BarLine? {
        if task.status == .doing, let step = kickoffStep { return BarLine(text: step, kind: .kickoff) }
        switch advisorStore.state(for: task) {
        case .revealed(let reading): return BarLine(text: reading.observation, kind: .reading)
        case .fallback(let reading):
            if let reading, !reading.observation.isEmpty {
                return BarLine(text: reading.observation, kind: .reading)
            }
            return nil
        case .quiet(.model):
            return BarLine(text: Self.silenceLine(judgedAt: advisorStore.judgedAt(for: task)), kind: .silence)
        default: return nil
        }
    }

    /// "Looked just now — nothing to add." The timestamp is the fact that makes silence
    /// legible: the fingerprint means Ezra knows exactly when it last considered this.
    static func silenceLine(judgedAt: Date?, now: Date = Date()) -> String {
        guard let judgedAt else { return "Looked — nothing to add." }
        let seconds = now.timeIntervalSince(judgedAt)
        let when: String
        if seconds < 90 {
            when = "just now"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            when = formatter.localizedString(for: judgedAt, relativeTo: now)
        }
        return "Looked \(when) — nothing to add."
    }

    var body: some View {
        ScrollView {
            // The shape picks the SPINE — the one thing most demanding attention
            // renders directly under the title. Chrome stays constant across shapes
            // (title, chips, description, the pinned CTA), so a shape change reads
            // as a fact about the task, never as a transition effect. Slot indices
            // stay fixed whether or not a slot renders: the stagger is positional.
            VStack(alignment: .leading, spacing: Spacing.lg) {
                titleSection.rise(0, appeared, reduceMotion)
                if shape == .waiting {
                    blockerSpine.rise(1, appeared, reduceMotion)
                }
                if shape == .container {
                    stepsSpine.rise(1, appeared, reduceMotion)
                }
                // The forward direction — shares slot 1 with the spines because it lives
                // in the same "relations, under the title" band, and a task can be both
                // blocked and blocking. Rises with them rather than after.
                if !dependents.isEmpty {
                    dependentsSection.rise(1, appeared, reduceMotion)
                }
                if advisorVisible {
                    advisorSection.rise(2, appeared, reduceMotion)
                }
                propertyCard.rise(3, appeared, reduceMotion)
                descriptionSection.rise(4, appeared, reduceMotion)
                detailsSection.rise(5, appeared, reduceMotion)
            }
            .padding(Spacing.lg)
        }
        // Hosts every related-task push from this page (spine rows, advisor rows) —
        // attached to the scroll view, not to a section that may not be in the tree.
        // `relatedPeers` hands the nested pager the list the tapped row came from, so
        // a step pages through its siblings the way a My Tasks row pages through its
        // section — "what neighbouring means belongs to the presenting surface".
        .taskDetailSheet($openedRelated, peers: relatedPeers)
        // The undo pill renders on the ACTIVE page, above the pinned bar. Applied
        // BEFORE the inset so the overlay lives in the reduced safe area and lands over
        // the content, never over the CTA — on the pager it sat on top of the next
        // page's "Start" for the four seconds the way back was on offer. The notice
        // itself stays the pager's state, so the page that resolves can slide away and
        // the next page inherits the pill.
        .undoNotice(isActive ? $notice : .constant(nil))
        // The recommended action stays persistently available — a product decision,
        // not a layout preference: on exactly the busy tasks where guidance matters
        // (decision card + breakdown + unstick + timeline), the one accented control
        // must not scroll out of reach. Conditioned here so a task with no honest
        // next move (someone else's work) collapses the inset entirely, and hidden
        // while a field is being edited — a pinned CTA over the keyboard is noise.
        .safeAreaInset(edge: .bottom) {
            if focusedField == nil,
                let action = task.recommendedAction(among: allTasks, currentUserID: currentUserID)
            {
                footer(action)
            }
        }
        .background(Palette.background)
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
        .sensoryFeedback(.success, trigger: resolvePulse)
        // The keyboard's way out. Title and notes both edit in place with no field
        // chrome, and `scrollDismissesKeyboard` is a gesture nobody is told about — a
        // Done above the keyboard is the honest end of an edit. Conditional on focus,
        // so only the page being edited contributes it (neighbours stay mounted).
        .toolbar {
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .font(.controlLabel)
                }
            }
        }
        .task {
            Motion.withMotion(Motion.settle) { appeared = true }
            // The Advisor's ambient trigger — a no-op unless the facts fingerprint
            // changed. Mounted neighbours prewarm the model instead (the pager keeps
            // them mounted, so a swipe lands on a warm model without spending a
            // generation on a page nobody is looking at).
            if isActive {
                advisorStore.ensure(task: task, among: allTasks)
            } else {
                // Warm the ADVISOR'S OWN prefix, not an anonymous session. This used to
                // call `ModelWarmup.prewarmSharedSession()`, which paid the cost and left
                // the Advisor's ~2KB instruction block cold anyway — the same mistake
                // CLAUDE.md records for capture.
                //
                // The `advisorWorthy` condition is gone too. It was about to become a
                // guard that lies: the gate inversion makes nearly every neighbour worthy,
                // so it would filter nothing while still reading as a filter. `isActive`
                // is the real bound, and it is the one the pager already uses.
                TaskAdvisorService.prewarm()
            }
            // A task re-entered mid-flight gets its first move too — the commitment is
            // still live, and the bar it renders in is now always on screen. Bounded
            // (60-token cap) and silent on any non-success, like the tap path.
            if isActive, task.status == .doing, kickoffStep == nil { fetchKickoff() }
            // Work changes shape. A parent whose last step just completed elsewhere is
            // no longer planning work, and nothing else would notice — resolution
            // happens on rows, in Today, and on other devices, none of which can run an
            // async on-device classify. Re-reading on open is the one place that sees
            // every route. Gated on having children so this is rare, not per-open.
            if isActive, !task.children(among: allTasks).isEmpty {
                reclassifyWorkIntent()
            }
        }
        .onAppear {
            originalTitle = task.title
            originalNotes = task.notes
        }
        .onChange(of: focusedField) { previous, _ in
            // Log the freely-typed field the moment focus leaves it, so its timeline row
            // appears while the user is still on the page.
            if previous == .title { commitTitleEdit() }
            if previous == .notes { commitNotesEdit() }
            // Leaving the add-step field with words in it adds the step — the keyboard
            // Done and a tap elsewhere both mean "that's the step", never "forget it".
            if previous == .newStep { commitNewStep() }
        }
        // Return in the title means "done", never a line break. The field wraps
        // (`axis: .vertical`) so a long title is readable, but a task title is one
        // line of intent — the return key used to insert a newline into it, and the
        // only way to finish renaming was to scroll the keyboard away. Strip the
        // break and drop focus, which runs the commit path above.
        .onChange(of: task.title) { _, updated in
            guard focusedField == .title, let single = Self.titleAfterReturn(updated) else { return }
            task.title = single
            focusedField = nil
        }
        .onChange(of: isActive) { _, active in
            // Swiping to the next task doesn't unmount this page, so `.onDisappear` can't
            // be the backstop for an in-flight edit. Dropping focus runs the commit path
            // above, which logs the edit before the page leaves the screen.
            if !active {
                focusedField = nil
                // Same reasoning for model work: the user has left this task, so a
                // classification still running is spend with nobody waiting on it.
                classifyWork?.cancel()
                kickoffWork?.cancel()
                advisorStore.cancel(taskID: task.uuid)
            } else {
                // `.task` ran at mount, when a pager neighbour wasn't active yet —
                // becoming the page on screen is the moment the Advisor judges.
                advisorStore.ensure(task: task, among: allTasks)
                if task.status == .doing, kickoffStep == nil { fetchKickoff() }
            }
        }
        // THE LOOP CLOSES HERE. Act → the task changes → the Advisor re-judges → the
        // reading becomes the next reading. Without this the Advisor is a static
        // recommendation generator: it would still say "this is blocked" after the
        // blocker was cleared.
        //
        // Keying on `updatedAt` rather than per-action calls is deliberate — EVERY
        // mutation helper bumps it (a documented model invariant), so one hook covers
        // advisor actions, property-chip edits, and status changes alike. `ensure`
        // no-ops on an unchanged fingerprint, so an edit that doesn't change the
        // judgment costs nothing.
        .onChange(of: task.updatedAt) { _, _ in
            guard isActive else { return }
            advisorStore.ensure(task: task, among: allTasks)
        }
        // Resolving a blocker changes the BLOCKER's state, not this task's `updatedAt`,
        // so the hook above cannot see it — and this is exactly the "blocker cleared →
        // you're ready to continue" moment.
        .onChange(of: openedRelated == nil) { _, closed in
            guard closed, isActive else { return }
            advisorStore.ensure(task: task, among: allTasks)
            // A step or blocker just resolved (or didn't) on its own page — the
            // container's next step may have moved with it.
            refreshContainerKickoff()
        }
        .onDisappear {
            // Backstop for a dismiss mid-edit (focus never formally left the field). The
            // coalescing in `logHumanEdit` makes a double-fire with the focus path harmless.
            // These commits (and every chip edit) already stamp the human clock via
            // `logHumanEdit` — so there is deliberately NO blanket `touchHuman` here:
            // `task.hasChanges` is authorship-blind, and a stray pending change (a failed
            // save elsewhere, an unrelated bump) opening/closing the detail must not fake
            // engagement on the clock staleness and the deferral discriminator trust.
            commitTitleEdit()
            commitNotesEdit()
            context.saveChanges()
            // The detail was dismissed outright (not just swiped past), so nothing is
            // waiting on a classification either.
            classifyWork?.cancel()
        }
        .alert("Mark decided", isPresented: $showDecisionPrompt) {
            TextField("What did you decide? (optional)", text: $decisionChoice)
            Button("Mark decided") {
                let trimmed = decisionChoice.trimmingCharacters(in: .whitespacesAndNewlines)
                advisorActed(.decide) { markDecided(choice: trimmed.isEmpty ? nil : trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The outcome goes on the record — notes and the activity trail.")
        }
        .alert("New person", isPresented: $showAddPerson) {
            TextField("Name", text: $newPersonName)
            Button("Add") { addPerson() }
            Button("Cancel", role: .cancel) { newPersonName = "" }
        } message: {
            Text("Who is this task for?")
        }
        .alert("Couldn't save", isPresented: $showSaveFailedAlert) {
            Button("Try Again") { retryPrimarySave() }
            // Deliberately does NOT re-enable the primary button: the mutation is
            // still pending on `task` (never rolled back), so a fresh tap would
            // re-run `performRecommendedAction` and double-insert its ChangeLogEntry
            // on top of the one already pending — exactly the duplicate this guard
            // exists to prevent. "Try Again" is the only retry path from here; the
            // page's own teardown save is the backstop if the user navigates away.
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your change didn't save. Check your storage and try again.")
        }
    }

    // MARK: - Title (kicker + big editable title)

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            categoryKicker
            TextField("Task title", text: $task.title, axis: .vertical)
                .font(.screenTitle)
                .tracking(-0.4)
                .foregroundStyle(Palette.primaryText)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($focusedField, equals: .title)
            provenanceLine
            lifecycleLine
            parentLine
        }
    }

    /// The kicker IS the category editor. It used to be a static label above the title
    /// with an identical "Finance" chip in the card below — the same fact twice, one of
    /// them dead. Linear's breadcrumb kicker is the model: the small caps line names
    /// where the task lives and opens the menu that moves it. The chevron is the only
    /// tell that it is a control, sized so it never competes with the title.
    private var categoryKicker: some View {
        Menu {
            ForEach(TaskCategory.all, id: \.self) { cat in
                Button {
                    setCategory(cat)
                } label: {
                    Label {
                        Text(cat)
                    } icon: {
                        Image(systemName: cat == task.category ? "checkmark" : TaskCategory.symbol(for: cat))
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text(task.category.uppercased())
                    .metadataStyle()
                    .tracking(0.8)
                Image(systemName: "chevron.down")
                    .font(.glyphMicro(.semibold))
                    .foregroundStyle(Palette.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .minimumHitTarget(around: IconSize.caption)
        .accessibilityLabel("Category: \(task.category)")
        .accessibilityHint("Change category")
    }

    /// A title edit that contains a line break is a return key pressed: the title
    /// with the break collapsed to a space, or nil when there was no break. Pure, so
    /// the rule is testable without a keyboard.
    static func titleAfterReturn(_ title: String) -> String? {
        guard title.contains(where: \.isNewline) else { return nil }
        let joined = title.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined
    }

    /// Where the task is in its life, said plainly under the title — "Started 2 hours
    /// ago" while the commitment is live, "Done yesterday" / "Canceled 3 days ago" once
    /// it is a record. Nothing for a plain to-do. The status chip shows the STATE; this
    /// line shows the TIME, which the page used to keep behind the Details disclosure
    /// where nobody read it. Same quiet register as provenance; it is a fact, not a badge.
    @ViewBuilder private var lifecycleLine: some View {
        if let caption = TaskTimeline.caption(for: task) {
            Text(caption)
                .font(.chipLabel)
                .foregroundStyle(Palette.secondaryText)
                .transition(.opacity)
        }
    }

    /// The graph's upward direction. A step's page shows what it belongs to, the way
    /// the container's page shows its steps — down, sideways (blockers) and up are
    /// the three ways out of a task, and this was the missing one. Same quiet caption
    /// register as provenance; tappable because the whole point is going there.
    @ViewBuilder private var parentLine: some View {
        if let parentID = task.parentTaskID,
            let parent = allTasks.first(where: { $0.uuid == parentID })
        {
            Button {
                openedRelated = parent
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.glyphCaption())
                    Text("Part of “\(parent.title)”")
                        .font(.chipLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.glyphCaption())
                }
                .foregroundStyle(Palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableLink)
            .minimumHitTarget()
            .accessibilityLabel("Part of \(parent.title)")
            .accessibilityHint("Open the containing task")
        }
    }

    /// Where this task came from, when it didn't come from you. One quiet caption —
    /// material, never a badge.
    ///
    /// A task that ARRIVED on your plate carries information a task you wrote does
    /// not: who sent it. That is what lets the assignee hand it back without guessing,
    /// and it is the same provenance instinct the relationship work already applies to
    /// edges. Both facts are already stored (`creatorID`, and the `actorID` on the most
    /// recent `"assigned"` entry) and were simply never read.
    @ViewBuilder private var provenanceLine: some View {
        if let line = provenanceText {
            Text(line)
                .font(.chipLabel)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var provenanceText: String? {
        // A reassignment is the more recent fact, so it wins over authorship.
        if let assigned = activityEntries.first(where: { $0.action == "assigned" && !$0.undone }),
            let actor = assigned.actorID, actor != currentUserID,
            let name = familyMembers.first(where: { $0.uuid == actor })?.name
        {
            return "Assigned by \(name)"
        }
        if let creator = task.creatorID, creator != currentUserID,
            let name = familyMembers.first(where: { $0.uuid == creator })?.name
        {
            return "Created by \(name)"
        }
        return nil
    }

    // MARK: - Property chips (Linear-style wrapping row)

    private var propertyCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
                statusChip
                ownerChip
                urgentChip
                dueChip
                // No category chip: the kicker above the title is the category editor.
                effortChip
                addBlockerChip
            }
            // The inline picker is an EXPANSION of the card, not a mode: it opens from
            // "Pick a date…", closes the moment a date is picked (the chip above shows
            // the result — leaving the calendar open under a chip that already answers
            // it read as a picker that never finished), and carries a Done for the
            // person who opened it to look and chose nothing.
            if showDatePicker {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Due date")
                            .metadataStyle()
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Spacer(minLength: Spacing.sm)
                        Button("Done") {
                            Motion.withMotion(Motion.settle) { showDatePicker = false }
                        }
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                        .buttonStyle(.pressableLink)
                    }
                    DatePicker("Due date", selection: dueBinding, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .tint(Palette.accentFlat)
                }
                .transition(.opacity)
            }
            // When a spine owns these rows they render under the title instead —
            // the same rows twice on one page teaches the user to read neither. A
            // deciding page that ALSO has blockers or steps keeps them here, because
            // its spine is the obligation.
            if shape != .waiting {
                ForEach(task.activeBlockers(among: allTasks)) { blocker in
                    blockerChipRow(blocker)
                }
            }
            if shape != .container {
                stepsSection
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Palette.primarySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
    }

    /// The detail's property chip — the shared `MetadataChip` at standard density.
    private func chip<Content: View>(
        muted: Bool = false, @ViewBuilder content: () -> Content
    )
        -> some View
    {
        MetadataChip(density: .standard, muted: muted) { content() }
    }

    private var statusChip: some View {
        Menu {
            ForEach(TaskStatus.pickable) { state in
                Button {
                    applyStatus(state)
                } label: {
                    Label {
                        Text(state.label)
                    } icon: {
                        Image(systemName: state == task.status ? "checkmark" : state.symbol)
                    }
                }
            }
        } label: {
            chip {
                Image(systemName: task.status.symbol)
                    .font(.glyphCaption())
                    .foregroundStyle(task.status.tint)
                Text(task.status.label)
            }
        }
    }

    private var ownerChip: some View {
        Menu {
            Button("You") { setOwner(currentUserID) }
            if !otherMembers.isEmpty {
                Divider()
                ForEach(
                    otherMembers.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                ) { member in
                    Button(member.name) { setOwner(member.uuid) }
                }
            }
            Divider()
            // Handing a task back to the household. Every task is now born owned, so
            // this is the ONLY way an unowned task comes to exist — and until this
            // existed the state was reachable only by undoing an assignment.
            Button("Shared / up for grabs") { setOwner(nil) }
            Button("Add person…") { showAddPerson = true }
        } label: {
            chip {
                if task.ownerID == nil {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.glyphCaption())
                    Text("Up for grabs")
                } else if let name = task.ownerDisplayName(among: otherMembers) {
                    OwnerAvatarBadge(
                        name: name, photoData: task.ownerPhotoData(among: otherMembers), size: 18)
                    Text(name)
                } else {
                    AvatarView(profile: profiles.first, size: 18)
                    Text("You")
                }
            }
        }
    }

    /// The attention Signal as a toggle chip (creation-time priority is retired).
    private var urgentChip: some View {
        Button {
            toggleUrgent()
        } label: {
            chip(muted: !task.isUrgent) {
                Image(systemName: task.isUrgent ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                    .font(.glyphCaption())
                    .foregroundStyle(task.isUrgent ? Palette.priorityUrgent : Palette.mutedText)
                Text(task.isUrgent ? "Urgent" : "Not urgent")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isUrgent ? "Urgent, on" : "Urgent, off")
    }

    private var dueChip: some View {
        Menu {
            Button("Today") { setDue(dayOffset: 0) }
            Button("Tomorrow") { setDue(dayOffset: 1) }
            Button("Next week") { setDue(dayOffset: 7) }
            // Opening the picker no longer stamps today onto an undated task — that
            // wrote a due date (and an Activity row) before the person had chosen
            // anything, and closing without picking left it there. The picker shows
            // today as its cursor; the date is set only when one is tapped.
            Button("Pick a date…") {
                Motion.withMotion(Motion.settle) { showDatePicker = true }
            }
            if task.dueDate != nil {
                Divider()
                Button("Clear", role: .destructive) {
                    setDue(nil)
                    Motion.withMotion(Motion.settle) { showDatePicker = false }
                }
            }
        } label: {
            // The chip says WHEN in the same vocabulary as the row — and, unlike the
            // row, this is the one place a person reads the task properly, so overdue
            // has to be stated here or it is stated nowhere that matters. Live work
            // only: a resolved task's due is a plain date, because "overdue" on
            // finished work is a scold about the past.
            let due = DueLabel.make(for: task, style: .full)
            let overdue = due?.isOverdue == true
            chip(muted: task.dueDate == nil) {
                Group {
                    Image(systemName: overdue ? "calendar.badge.exclamationmark" : "calendar")
                        .font(.glyphCaption())
                    Text(due?.text ?? task.dueDate.map(dueText) ?? "No due date")
                }
                .foregroundStyle(
                    overdue
                        ? Palette.overdue : task.dueDate == nil ? Palette.mutedText : Palette.primaryText)
            }
        }
        .accessibilityLabel(dueAccessibilityLabel)
    }

    /// VoiceOver hears the same fact the chip shows — "Due 3 days overdue" reads wrong,
    /// so overdue is voiced as a state rather than a date.
    private var dueAccessibilityLabel: String {
        guard let label = DueLabel.make(for: task, style: .full) else {
            return task.dueDate.map { "Due \(dueText($0))" } ?? "No due date"
        }
        return label.isOverdue ? "Overdue, \(label.text)" : "Due \(label.text)"
    }

    private var effortChip: some View {
        Menu {
            Button("15 min") { setEffort(15) }
            Button("30 min") { setEffort(30) }
            Button("1 hour") { setEffort(60) }
            Button("2 hours") { setEffort(120) }
            if task.effortMinutes != nil {
                Divider()
                Button("Clear", role: .destructive) { setEffort(nil) }
            }
        } label: {
            chip(muted: task.effortLabel == nil) {
                Image(systemName: "timer").font(.glyphCaption())
                Text(task.effortLabel.map { "~\($0)" } ?? "No estimate")
            }
        }
    }

    private var addBlockerChip: some View {
        BlockerPicker(
            candidates: TaskItem.eligibleBlockerCandidates(for: task, among: allTasks),
            onPickTask: { addTaskBlocker($0) },
            onPickExternal: { addExternalBlocker($0) }
        ) {
            chip(muted: true) {
                Image(systemName: "plus").font(.glyphCaption())
                Text(task.activeBlockers(among: allTasks).isEmpty ? "Waiting on" : "Add wait")
            }
        }
    }

    /// A tracked dependency (title from the graph) or an untracked wait (user's words).
    ///
    /// THE SAME ROW THE WAITING SPINE DRAWS (2026-09-04). It used to be a lesser copy —
    /// a static glyph, an untappable title — so a deciding page with a blocker could
    /// see the wait but not act on it or go to it, while the identical wait one shape
    /// over was a cockpit. One row, one set of affordances, wherever a wait renders:
    /// the blocker's own lifecycle glyph (resolve it here, with the way back), the
    /// title through to its page, the age, and the release.
    private func blockerChipRow(_ blocker: Blocker) -> some View {
        spineBlockerRow(blocker)
    }

    /// The steps this task was broken into, with how far they have got.
    ///
    /// Sits below the waits and reads deliberately unlike them. A step is not an
    /// obstacle: there is no dismiss button (you finish or delete a step, you don't stop
    /// waiting on it), and the state is stated as progress — "1 of 3 steps" — because a
    /// task you have usefully decomposed has moved forward, not stalled. Read-only by
    /// design: the steps are real rows on My Tasks, where every action already lives.
    @ViewBuilder
    private var stepsSection: some View {
        if let progress = task.stepProgress(among: allTasks) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(progress.label)
                    .metadataStyle()
                    .textCase(.uppercase)
                    .tracking(0.6)
                ForEach(task.children(among: allTasks)) { step in
                    stepRow(step)
                }
            }
            .padding(.top, Spacing.xs)
        }
    }

    /// A step row on the card — a deciding or waiting page that also has steps. The
    /// glyph is the list's one-tap fast path (resolve the step here, with the way
    /// back) and the title opens the step, exactly as the container spine's rows do:
    /// the card used to render the same step read-only, so which affordances a step
    /// had depended on which SHAPE its parent happened to be.
    private func stepRow(_ step: TaskItem) -> some View {
        let done = step.status.isResolved
        return HStack(spacing: Spacing.sm) {
            StatusGlyphView(
                task: step, allTasks: allTasks,
                onPick: { state in pickStepStatus(step, state) }
            )
            Button {
                openedRelated = step
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text(step.title)
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                        .strikethrough(done, color: Palette.mutedText)
                        .lineLimit(1)
                        .recessed(done)
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step: \(step.title), \(done ? "done" : "open")")
            .accessibilityHint("Open this step")
        }
    }

    // MARK: - What this frees up (the FORWARD direction)

    /// The still-open tasks waiting on THIS one, tappable through to each.
    ///
    /// The page was navigable in three directions — DOWN via the container spine's steps,
    /// SIDEWAYS via the waiting spine's blockers, UP via the "Part of …" caption — and not
    /// forward. That was survivable while the list's chain stack expanded in place; when
    /// the expander was removed (2026-09-01) it became a hole, because **the common chain
    /// is rooted on the task that unblocks the others**: "Renew passport" has no blockers
    /// and no steps, so it drew no spine at all, and its three dependents had nowhere to
    /// be seen. Verified in the sim before this existed — the root's page was chips and
    /// nothing else.
    ///
    /// Not a `TaskShape`: blocking others is a RELATION, not a shape of the work, and the
    /// four shapes are pinned. So it renders whenever the relation exists, alongside
    /// whatever spine the shape picked — a task can be both blocked and blocking.
    ///
    /// The glyph is deliberately an INDICATOR here, unlike the blocker and step spines.
    /// Their glyphs are interactive because clearing them is the useful next act; a
    /// dependent is blocked BY this task, so completing it from here would be finishing
    /// work out of the order the graph says it runs in. You go there to look, and act there.
    private var dependentsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(dependents.count == 1 ? "Frees up 1 task" : "Frees up \(dependents.count) tasks")
                .sectionHeaderStyle()
            ForEach(dependents) { dependent in
                Button {
                    openedRelated = dependent
                } label: {
                    HStack(spacing: Spacing.sm) {
                        StatusGlyphView(task: dependent, allTasks: allTasks, interactive: false)
                        Text(dependent.title)
                            .font(.supporting)
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.sm)
                        // WHEN, in the row's own vocabulary: whether freeing this one
                        // matters today is the question the section exists to answer.
                        if let due = DueLabel.make(for: dependent, style: .compact) {
                            Text(due.text)
                                .font(.chipLabel)
                                .foregroundStyle(due.isOverdue ? Palette.overdue : Palette.mutedText)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.mutedText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableLink)
                .accessibilityLabel("\(dependent.title), waiting on this task")
            }
        }
    }

    /// The reverse `.blocks` edge, walked in the one place that owns that walk.
    private var dependents: [TaskItem] { task.dependents(among: allTasks) }

    /// The ordered list a related task was opened FROM — its siblings become the nested
    /// pager's peers. Steps page through the steps, dependents through the dependents,
    /// blockers through the blockers; a task cited from nowhere in particular (the
    /// Advisor's "frees up" rows) opens alone, exactly as before.
    private var relatedPeers: [TaskItem] {
        guard let opened = openedRelated else { return [] }
        let lists = [
            task.children(among: allTasks), dependents, task.activeBlockerTasks(among: allTasks),
        ]
        return lists.first { list in list.contains { $0.objectID == opened.objectID } } ?? []
    }

    // MARK: - The waiting spine (shape == .waiting)

    /// The blocker IS the page. What this task waits on, directly under the title:
    /// what · since when — tappable through to the blocking task, because the next
    /// useful act on a waiting page usually happens on the other task. The absence
    /// of a next move here is the message; no reading needs to say "you are blocked".
    private var blockerSpine: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Waiting on")
                .sectionHeaderStyle()
            ForEach(task.activeBlockers(among: allTasks)) { blocker in
                spineBlockerRow(blocker)
            }
        }
    }

    @ViewBuilder
    private func spineBlockerRow(_ blocker: Blocker) -> some View {
        let target = blocker.taskID.flatMap { id in allTasks.first { $0.uuid == id } }
        let title = target?.title ?? blocker.note ?? "Something else"
        HStack(spacing: Spacing.sm) {
            // The blocker's own lifecycle, not a generic wait glyph: "already in
            // motion" and "not started" are different chases, and the fact was one
            // lookup away the whole time. External waits keep the hourglass — they
            // have no lifecycle to show.
            //
            // INTERACTIVE, mirroring the container spine's step glyph. It was read-only
            // while the step glyph next door was not, which no user could have explained
            // — and it became a real gap when the list's chain expander was removed
            // (2026-09-01): clearing a prerequisite from the list used to be expand-then-
            // act, and without this it would be tap, tap, act. Resolving a blocker changes
            // THIS page's shape (the waiting spine may empty), so it re-judges here, the
            // same way the step glyph refreshes the container.
            if let target {
                StatusGlyphView(
                    task: target, allTasks: allTasks,
                    onPick: { state in pickBlockerStatus(target, state) }
                )
            } else {
                Image(systemName: "hourglass")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.mutedText)
            }
            if let target {
                Button {
                    openedRelated = target
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(title)
                            .font(.supporting)
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.mutedText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableLink)
                .accessibilityLabel("Open blocker: \(title)")
            } else {
                // An external wait has no task to open — the words are the whole
                // fact, so no chevron promises a page that does not exist.
                Text(title)
                    .font(.supporting)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
            }
            if let label = sinceLabel(blocker.since) {
                Text(label)
                    .font(.chipLabel)
                    .foregroundStyle(Palette.mutedText)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                removeBlocker(blocker.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.mutedText)
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("Stop waiting on \(title)")
        }
    }

    /// "since 3d" — the wait's age from the edge's own clock. Nil for a same-day
    /// wait: announcing "since today" adds urgency theatre to a fact nobody needs.
    private func sinceLabel(_ since: Date?) -> String? {
        guard let since else { return nil }
        let days =
            Calendar.current.dateComponents(
                [.day], from: Calendar.current.startOfDay(for: since),
                to: Calendar.current.startOfDay(for: Date())
            ).day ?? 0
        return days >= 1 ? "since \(days)d" : nil
    }

    // MARK: - The container spine (shape == .container)

    /// The steps ARE the page: progress in the header, the next open step marked,
    /// each row tappable into the step's own detail so the container and the pager
    /// agree about what "next" means. Read-only beyond navigation — steps are real
    /// rows on My Tasks, where every action already lives.
    ///
    /// Display order IS the model's proposed sequence: `splitInto` persists it as
    /// `sortIndex`, and `children(among:)` is the one ordered derivation every step
    /// surface shares.
    private var stepsSpine: some View {
        // `children(among:)` is the one ordered derivation: `sortIndex` (the model's
        // proposed sequence, stamped by `splitInto`), then createdAt + uuid for
        // pre-`sortIndex` stores.
        let steps = task.children(among: allTasks)
        let currentID = task.nextOpenStep(among: allTasks)?.uuid
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            if let progress = task.stepProgress(among: allTasks) {
                // The count moves IN PLACE when a step resolves from the row below —
                // progress reads as motion in the number, not a redraw.
                Text(progress.label)
                    .sectionHeaderStyle()
                    .contentTransition(.numericText())
            }
            ForEach(steps) { step in
                spineStepRow(step, isCurrent: step.uuid == currentID)
            }
            if !task.status.isResolved { addStepRow }
        }
    }

    /// The one write the container spine offers beyond status: a step the person
    /// thought of that the breakdown didn't. Inline, in the rows' own register —
    /// a muted plus in the glyph column and a bare field — because a "+ Add step"
    /// button would be a second CTA under the pinned one. Return or leaving the
    /// field commits; the row is absent on a resolved container.
    private var addStepRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "plus")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
                .frame(width: LayoutMetrics.recordGlyphColumn, height: LayoutMetrics.recordGlyphColumn)
            TextField("Add a step", text: $newStepTitle)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($focusedField, equals: .newStep)
                .onSubmit { commitNewStep() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a step")
    }

    /// Append the typed step through the model's seam and clear the field. Silent on
    /// blank input — leaving an empty field is not an act.
    private func commitNewStep() {
        let typed = newStepTitle
        newStepTitle = ""
        guard
            let step = Motion.withMotion(
                Motion.decide,
                {
                    task.addStep(typed, among: allTasks, in: context)
                })
        else { return }
        actionPulse += 1
        context.saveChanges()
        advisorStore.ensure(task: task, among: allTasks)
        refreshContainerKickoff()
        // Adding a step has the same receipt a breakdown does: one pill, one revert path.
        // The entry is looked up at UNDO time, by the child's id, rather than read
        // from the fetched results now — the fetch refreshes after this call returns.
        let stepID = step.uuid?.uuidString ?? ""
        let context = context
        notice = UndoNotice(message: "Added step “\(step.title)”") {
            let request = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
            request.predicate = NSPredicate(format: "action == %@ AND newValue == %@", "split", stepID)
            guard let entry = (try? context.fetch(request))?.first, !entry.undone else { return }
            entry.undone = true
            ChangeLogUndo.revert(entry, in: context)
            context.saveChanges()
        }
    }

    private func spineStepRow(_ step: TaskItem, isCurrent: Bool) -> some View {
        let done = step.status.isResolved
        // The glyph sits OUTSIDE the navigation button: it is the list's one-tap
        // fast path, composed into the container's cockpit — complete a step without
        // leaving the umbrella, and the progress header, pointer and kickoff line all
        // move because they are derivations of the same fact. `onPick` mirrors the
        // glyph's own seam (`setStatus`) plus this page's re-judge hooks, which key on
        // THIS task's clock and cannot see a child's.
        return HStack(spacing: Spacing.sm) {
            StatusGlyphView(
                task: step, allTasks: allTasks,
                // ONE step-status seam for the spine and the card's step rows: the
                // re-judge, the kickoff refresh and the way back all live in
                // `pickStepStatus`, so the two surfaces cannot drift.
                onPick: { state in pickStepStatus(step, state) }
            )
            Button {
                openedRelated = step
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text(step.title)
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                        .strikethrough(done, color: Palette.mutedText)
                        .lineLimit(1)
                        .recessed(done)
                    if isCurrent {
                        // The pointer, not a label: the next open step in a container is
                        // the same "one concrete first move" the kickoff line renders.
                        Image(systemName: "arrow.turn.down.right")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.accentFlat)
                    }
                    Spacer(minLength: Spacing.sm)
                    // WHEN, when a step has its own date — rare, and exactly then worth ink.
                    if let due = DueLabel.make(for: step, style: .compact) {
                        Text(due.text)
                            .font(.chipLabel)
                            .foregroundStyle(due.isOverdue ? Palette.overdue : Palette.mutedText)
                            .monospacedDigit()
                    }
                    // Sizing at a glance, matching the proposal rows the steps came from.
                    if !done, let label = TaskItem.effortLabel(step.effortMinutes) {
                        Text("~\(label)")
                            .font(.chipLabel)
                            .foregroundStyle(Palette.mutedText)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Step: \(step.title), \(done ? "done" : isCurrent ? "next" : "open")"
            )
            .accessibilityHint("Open this step")
        }
    }

    // MARK: - Advisor (the judgment layer)

    /// The one Advisor surface — replaced the decision / breakdown / unstick cards.
    /// The store owns the judgment; this section only renders its state and wires the
    /// moves to the existing mutation seams. The flagged-decision affordances render
    /// regardless of what the model chose to talk about.
    private var advisorSection: some View {
        AdvisorView(
            state: advisorStore.state(for: task),
            flagged: task.needsDecision && !task.status.isResolved,
            isJudgmentCall: task.isJudgmentCall,
            deferralCount: Int(task.deferralCount),
            diagnosis: StallDetector.diagnose(task, among: allTasks),
            blockers: task.activeBlockerTasks(among: allTasks),
            blockersRenderedElsewhere: shape == .waiting,
            contextLines: obligationContextLines,
            showsReading: false,
            onDecide: { choice in
                if let choice {
                    advisorActed(.decide) { markDecided(choice: choice) }
                } else {
                    // No option carried the outcome — ask for it, optionally. A
                    // decision is the product's crown primitive, and "decided" with
                    // no record of WHAT was the difference between a trail and a
                    // checkbox. One extra tap, field skippable, and the outcome
                    // lands in the notes, the entry and the undo encoding through
                    // the one seam that writes them.
                    decisionChoice = ""
                    showDecisionPrompt = true
                }
            },
            // Escalating is a human act accepting the reading's suggestion — the
            // axis-3 flag, through the same seam Unstick's rung used.
            onEscalate: {
                advisorActed(.decide) {
                    Motion.withMotion(Motion.decide) {
                        task.escalateToDecision()
                        task.touchHuman()
                    }
                    context.saveChanges()
                }
            },
            onDismiss: { advisorStore.dismiss(taskID: task.uuid) }
        )
    }

    /// Every Advisor action funnels here: one acted record (with the lifecycle
    /// position it acted FROM — the progression metric's baseline), the stall-clearing
    /// rule (a card its own buttons can't dismiss is a scold — any action taken while
    /// a stall diagnosis is present resets the deferral clock via `touchHuman`), then
    /// the move itself.
    private func advisorActed(_ move: AdvisorMove, _ action: () -> Void) {
        AdvisorMetrics.shared.recordActed(move, taskID: task.uuid, status: task.status)
        if StallDetector.diagnose(task, among: allTasks) != nil {
            task.touchHuman()
        }
        actionPulse += 1
        action()
    }

    private func markDecided(choice: String? = nil) {
        actionPulse += 1
        Motion.withMotion(Motion.decide) {
            task.resolveDecisionAndLog(in: context, choice: choice)
        }
        context.saveChanges()
    }

    // MARK: - Description

    private var descriptionSection: some View {
        TextField("Add a description…", text: notesBinding, axis: .vertical)
            .font(.supporting)
            .foregroundStyle(Palette.primaryText)
            .lineLimit(1...10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedField, equals: .notes)
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { task.notes ?? "" },
            set: { task.notes = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Why this is here (provenance)

    private var whySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Why this is here")
                .sectionHeaderStyle()

            ConfidenceRow(task: task)

            if !task.reasoning.isEmpty {
                Text(task.reasoning)
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !task.rawCapture.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("You said")
                        .metadataStyle()
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Text(task.rawCapture)
                        .font(.supporting.italic())
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Spacing.sm)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.border).frame(width: 2)
                        }
                }
                .padding(.top, Spacing.xxs)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Captured \(task.createdAt.formatted(.relative(presentation: .named)))")
                    .metadataStyle()
                if let timeline = TaskTimeline.summary(for: task) {
                    Text(timeline).metadataStyle()
                }
            }
            .padding(.top, Spacing.xxs)
        }
    }

    // MARK: - Activity feed (per-task change log)

    private var activitySection: some View {
        // `activityEntries` is newest-first (fetch sorts descending); the timeline reads a
        // story top-down oldest→newest, so reverse the sliced set for display. Grounded by
        // a creation anchor so it's never empty, even on a task with zero edits.
        let recent = showAllActivity ? activityEntries : Array(activityEntries.prefix(5))
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Activity")
                .sectionHeaderStyle()
            DetailActivityTimeline(
                entries: Array(recent.reversed()),
                creation: creationAnchor,
                members: familyMembers, currentUserID: currentUserID, profile: profiles.first,
                onUndo: undoEntry)
            if activityEntries.count > 5 && !showAllActivity {
                Button("Show all \(activityEntries.count)") {
                    Motion.withMotion(Motion.settle) { showAllActivity = true }
                }
                .font(.controlLabel)
                .foregroundStyle(Palette.accentFlat)
                .buttonStyle(.pressableLink)
            }
        }
    }

    // MARK: - Footer (the one obvious next move)

    /// One slot, and only when there is an honest move to put in it. A task owned by
    /// someone else resolves to nil upstream — better no button than the most accented
    /// control on screen offering something that isn't the user's to do. Its proxy
    /// actions live in `TaskMoreMenu`.
    /// The pinned action bar: solid surface (glass never carries primary text), a
    /// full-bleed top hairline, and the kickoff line riding under the button — the
    /// user's eyes are already there when it lands.
    // MARK: - Details (provenance + history, one tap away)

    /// "Why this is here" and Activity, collapsed by default behind one quiet row.
    /// They are the page's receipts — essential to trust, rarely the reason the page
    /// was opened — so they cost one tap instead of permanent scroll height.
    /// Expanding is not an action and is never counted as one.
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Button {
                Motion.withMotion(Motion.settle) { showDetails.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text("Details")
                        .sectionHeaderStyle()
                    Image(systemName: "chevron.down")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                    // A closed row that says what it holds: "Details" alone is mute,
                    // and a person deciding whether to open it deserves the count.
                    // Gone once open — the rows below are the count.
                    if !showDetails, let hint = Self.detailsHint(changes: activityEntries.count) {
                        Text(hint)
                            .metadataStyle()
                            .monospacedDigit()
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .minimumHitTarget()
            .accessibilityLabel("Details")
            .accessibilityHint(showDetails ? "Collapse" : "Expand provenance and activity")

            if showDetails {
                whySection.transition(.opacity)
                activitySection.transition(.opacity)
            }
        }
    }

    /// "3 changes" · "1 change" · nil when the trail holds nothing but the task's birth.
    static func detailsHint(changes: Int) -> String? {
        guard changes > 0 else { return nil }
        return changes == 1 ? "1 change" : "\(changes) changes"
    }

    private func footer(_ action: RecommendedAction) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                performPrimary(action)
            } label: {
                Text(ctaTitle(action))
                    .font(.ctaLabel)
                    .foregroundStyle(Palette.onAccent)
                    // Start doesn't dismiss — it relabels to "Mark done" under the tap,
                    // so the lifecycle is taught by the button rather than documented.
                    // The transition is what makes that read as a state change rather
                    // than a redraw.
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressableProminent)
            .disabled(isPerformingPrimary)

            // The Advisor's ONE line on this page, under the button — the kickoff step
            // while the commitment is live, otherwise the reading's observation. A
            // reading is tappable and opens the task chat, where the guidance and the
            // move (options, steps, the blocker) live as the conversation's opener. It
            // lands in a fixed place with a fade: the bar is where the eyes already are,
            // and nothing above it moves.
            if let line = advisorLine {
                Button {
                    guard line.opensChat else { return }
                    openTaskChat()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(
                            systemName: line.kind == .kickoff
                                ? "arrow.turn.down.right" : line.kind == .silence ? "circle" : "text.bubble"
                        )
                        .font(.glyphCaption())
                        .foregroundStyle(line.kind == .silence ? Palette.mutedText : Palette.accentFlat)
                        Text(line.text)
                            .supportingStyle()
                            .foregroundStyle(
                                line.kind == .silence ? Palette.mutedText : Palette.secondaryText
                            )
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if line.opensChat {
                            Spacer(minLength: Spacing.xs)
                            Image(systemName: "chevron.right")
                                .font(.glyphCaption())
                                .foregroundStyle(Palette.mutedText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableLink)
                .disabled(!line.opensChat)
                .accessibilityLabel(line.kind == .kickoff ? "First step: \(line.text)" : "Ezra: \(line.text)")
                .accessibilityHint(line.opensChat ? "Opens the conversation about this task" : "")
                .transition(.opacity)
                .animation(reduceMotion ? nil : Motion.settle, value: line.text)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 0.5)
        }
    }

    /// The CTA's label on this page. A deliberate, narrow reversal of "the verb
    /// never voices the type": on a DECIDING page, "Start" undersells what starting
    /// means — the work is the choice — so `.start` reads "Decide". View-layer only:
    /// `RecommendedAction` is untouched, `.resume` keeps its honest history, and
    /// `.resolve` stays "Mark done" because it runs `completeAndResurface` and never
    /// touches `needsDecision` — a "Mark decided" label there would report a decision
    /// nothing recorded (`resolveDecision()` is the only clearer, and the obligation
    /// block owns that control).
    private func ctaTitle(_ action: RecommendedAction) -> String {
        guard shape == .deciding, action == .start else { return action.title }
        return "Decide"
    }

    private func performPrimary(_ action: RecommendedAction) {
        // A dismissing action leaves this true deliberately — the page is going
        // away, so there's no later tap to re-enable it for. A non-dismissing
        // action (Start, Unblock, claim) resets it once the mutation lands, since
        // the same button stays live and legitimately tappable again.
        guard !isPerformingPrimary else { return }
        isPerformingPrimary = true
        // The resolving arm earns `.success` once the save lands (see `finishPrimary`);
        // firing the soft impact here too would stack two haptics on one tap.
        if !action.dismissesDetail { actionPulse += 1 }
        var unblocked: [TaskItem] = []
        Motion.withMotion(Motion.decide) {
            unblocked = task.performRecommendedAction(action, among: allTasks, in: context)
        }
        // A failed save must NOT proceed to `onResolved()` — that dismisses (or
        // pages past) this task as if the resolution landed, and the alert would
        // never be seen. `performRecommendedAction`'s mutation stays pending on
        // `task` regardless (`saveChanges` never rolls back), so the retry below
        // only needs to ask the store to save again, never to redo the mutation.
        guard context.saveChanges() else {
            pendingPrimaryAction = action
            pendingUnblocked = unblocked
            showSaveFailedAlert = true
            return
        }
        finishPrimary(action, unblocked: unblocked)
    }

    /// The post-save half of `performPrimary`, shared with a successful retry.
    private func finishPrimary(_ action: RecommendedAction, unblocked: [TaskItem]) {
        // The Start tap is the strongest "doing this now" signal in the app — the
        // moment the kickoff line earns its fetch. Deterministic trigger, model
        // content, silent fallback.
        if action == .start || action == .resume { fetchKickoff() }
        // Only the resolving arm leaves the working set, and it is the only one that can
        // free dependents — so it is the only one that owes the user a way back.
        if action.dismissesDetail {
            resolvePulse += 1
            offerUndo(verb: "Completed", unblocked: unblocked)
            onResolved()
        } else {
            isPerformingPrimary = false
        }
    }

    /// "Try Again" on the save-failed alert.
    private func retryPrimarySave() {
        guard let action = pendingPrimaryAction, context.saveChanges() else {
            showSaveFailedAlert = true
            return
        }
        finishPrimary(action, unblocked: pendingUnblocked)
    }

    /// Ask for the one concrete first move. Any non-success renders nothing — the
    /// button already did its job, and an absent line is not an error to manage.
    /// Keep a container's kickoff line true to the CURRENT next step. Steps resolve
    /// from the spine's glyph or from their own nested page — and a child's clock
    /// never bumps the parent's, so the hooks that re-judge the Advisor could not
    /// refresh the bar. Deterministic, so recomputing on every signal costs nothing;
    /// non-containers deliberately keep their fetched line (regenerating a model line
    /// on every edit would be churn wearing a freshness costume).
    private func refreshContainerKickoff() {
        guard task.stepProgress(among: allTasks) != nil else { return }
        Motion.withMotion(Motion.settle) {
            kickoffStep = task.nextOpenStep(among: allTasks)?.title
        }
    }

    private func fetchKickoff() {
        kickoffWork?.cancel()
        // A deciding task gets NO kickoff line: the options are the move, and a
        // generated "first step" under a Decide button is the model answering a
        // question nobody asked. Silence is the honest fallback the kickoff always had.
        guard !task.needsDecision else {
            kickoffStep = nil
            return
        }
        // A container's first move is ALREADY STORED — the next open step, in the
        // model's own breakdown order. Rung 0 beats a generation wherever the answer
        // exists as a fact: instant, free, and it can never contradict the spine's
        // pointer because `nextOpenStep` is the one derivation both read.
        if let next = task.nextOpenStep(among: allTasks) {
            Motion.withMotion(Motion.settle) { kickoffStep = next.title }
            return
        }
        let facts = KickoffFacts(task: task)
        kickoffWork = Task {
            if case .success(let step) = await KickoffService().firstStep(facts),
                !step.isEmpty
            {
                Motion.withMotion(Motion.settle) { kickoffStep = step }
            }
        }
    }

    // MARK: - Mutations wiring

    private func applyStatus(_ state: TaskStatus) {
        guard state != task.status else { return }
        if state.isResolved { resolvePulse += 1 } else { actionPulse += 1 }
        Motion.withMotion(Motion.decide) { task.setStatus(state, in: context) }
        context.saveChanges()
        if state.isResolved {
            offerUndo(verb: state == .canceled ? "Canceled" : "Completed")
            onResolved()
        }
    }

    /// One pill, one way back — matching `completeTask`/`cancelTask`'s contract on the
    /// record surfaces so a resolution reads the same wherever it was made. Reopen
    /// restores the live status the task left via its timeline, so undoing a completion
    /// mid-flight returns it to `.doing` rather than stranding it at the start.
    private func offerUndo(verb: String, unblocked: [TaskItem] = []) {
        let task = self.task
        let context = self.context
        notice = .resolution(
            verb, task.title, unblocked: unblocked, steps: task.stepProgress(among: allTasks)
        ) {
            task.reopenAndReblock(in: context)
            context.saveChanges()
        }
    }

    /// The way back from a CLEARING edit — clear due, clear effort, stop waiting. Every
    /// setting edit is one tap to redo from the same chip; a clearing edit is not: the
    /// value is gone from the screen and the person has to remember it (or, for a wait,
    /// re-find the task). Same pill, same four seconds, as a resolution's — a mis-tap
    /// on a small × must cost a tap, never a memory. The restore re-runs the mutation
    /// through the logging seam, so the Activity trail shows the round trip honestly
    /// (`logHumanEdit` coalesces a same-field round trip into nothing net changed).
    private func offerEditUndo(_ message: String, restore: @escaping () -> Void) {
        notice = UndoNotice(message: message, undoAction: restore)
    }

    /// A blocker's status picked from ITS glyph on this page (the waiting spine, or the
    /// card's wait row). Mirrors the glyph's own seam, re-judges this page (resolving a
    /// blocker is the "you're ready to continue" moment), and — new — offers the same
    /// way back a row resolution does. Resolving the last wait names THIS task as the
    /// one freed, which is what the person came here to make happen.
    private func pickBlockerStatus(_ target: TaskItem, _ state: TaskStatus) {
        guard state != target.status else { return }
        if state.isResolved { resolvePulse += 1 } else { actionPulse += 1 }
        Motion.withMotion(Motion.decide) { target.setStatus(state, in: context) }
        context.saveChanges()
        advisorStore.ensure(task: task, among: allTasks)
        guard state.isResolved else { return }
        let freed = task.hasActiveBlockers(among: allTasks) ? [] : [task]
        let context = self.context
        notice = .resolution(
            state == .canceled ? "Canceled" : "Completed", target.title, unblocked: freed
        ) {
            target.reopenAndReblock(in: context)
            context.saveChanges()
        }
    }

    /// A step's status picked from its glyph on this page (the card's step row; the
    /// container spine's rows may share it). The container's derivations — progress
    /// header, next-step pointer, kickoff line — all move because they read the same
    /// fact; a child's clock never bumps the parent's, so the bar is refreshed here.
    /// A resolved step offers the way back.
    private func pickStepStatus(_ step: TaskItem, _ state: TaskStatus) {
        guard state != step.status else { return }
        if state.isResolved { resolvePulse += 1 } else { actionPulse += 1 }
        Motion.withMotion(Motion.decide) { step.setStatus(state, in: context) }
        context.saveChanges()
        advisorStore.ensure(task: task, among: allTasks)
        refreshContainerKickoff()
        guard state.isResolved else { return }
        let context = self.context
        notice = .resolution(state == .canceled ? "Canceled" : "Completed", step.title) {
            step.reopenAndReblock(in: context)
            context.saveChanges()
        }
    }

    private func setOwner(_ id: UUID?) {
        guard id != task.ownerID else { return }
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.claimAndLog(ownerID: id, among: allTasks, in: context) }
        context.saveChanges()
    }

    private func addPerson() {
        let trimmed = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPersonName = ""
        guard !trimmed.isEmpty else { return }
        let member = FamilyMember(name: trimmed, in: context)
        setOwner(member.uuid)
    }

    private func toggleUrgent() {
        actionPulse += 1
        task.setUrgent(!task.isUrgent, among: allTasks, in: context)
        context.saveChanges()
    }

    private func setCategory(_ cat: String) {
        guard cat != task.category else { return }
        let old = task.category
        actionPulse += 1
        task.category = cat
        task.logHumanEdit(
            field: "category", oldValue: old, newValue: cat,
            summary: "Recategorized to \(cat)", in: context)
        context.saveChanges()
    }
    private func setEffort(_ minutes: Int?) {
        guard minutes != task.effortMinutes else { return }
        let old = task.effortMinutes
        actionPulse += 1
        task.effortMinutes = minutes
        let summary = minutes.map { "Set effort to \(effortText($0))" } ?? "Cleared effort"
        task.logHumanEdit(
            field: "effortMinutes", oldValue: old.map(String.init),
            newValue: minutes.map(String.init), summary: summary, in: context)
        context.saveChanges()
        if minutes == nil, let old {
            let task = self.task
            let context = self.context
            offerEditUndo("Cleared effort") {
                task.effortMinutes = old
                task.logHumanEdit(
                    field: "effortMinutes", oldValue: nil, newValue: String(old),
                    summary: "Restored effort", in: context)
                context.saveChanges()
            }
        }
    }

    private func effortText(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "1 hour"
        case 120: return "2 hours"
        default: return "\(minutes) min"
        }
    }

    private func addTaskBlocker(_ blocker: TaskItem) {
        guard let id = blocker.uuid else { return }
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.addTaskBlocker(id, among: allTasks) }
        // Blockers are a collection, not a scalar — each add/remove is a distinct event, so
        // they never coalesce. A task-blocker add is reversible (undo removes the edge).
        task.logHumanEdit(
            field: "blockers", oldValue: nil, newValue: id.uuidString, summary: "Added blocker",
            coalescable: false, in: context)
        context.saveChanges()
        reclassifyWorkIntent()  // gaining a blocker is a structural change
    }

    private func addExternalBlocker(_ note: String?) {
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.addExternalBlocker(note, among: allTasks) }
        // An untracked wait has no task edge to remove on undo → non-reversible. `newValue`
        // just needs to differ from `oldValue` to clear the no-op guard.
        task.logHumanEdit(
            field: "blockers", oldValue: nil, newValue: note ?? "something else",
            summary: "Added blocker", reversible: false, coalescable: false, in: context)
        context.saveChanges()
        reclassifyWorkIntent()
    }

    private func removeBlocker(_ blockerID: UUID) {
        // Read the wait BEFORE the edge goes, so the way back can rebuild it exactly.
        let removed = task.activeBlockers(among: allTasks).first { $0.id == blockerID }
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.removeBlocker(blockerID, among: allTasks) }
        task.logHumanEdit(
            field: "blockers", oldValue: blockerID.uuidString, newValue: nil,
            summary: "Removed blocker", reversible: false, coalescable: false, in: context)
        context.saveChanges()
        reclassifyWorkIntent()  // losing a blocker is a structural change
        // The release is one tap on a small ×, and the Activity row it writes is not
        // reversible (the edge is gone). So the way back lives here instead: the pill
        // re-adds the same wait — the task edge, or the external note in the person's
        // own words.
        guard let removed else { return }
        let title: String
        switch removed.kind {
        case .task:
            title = removed.taskID.flatMap { id in allTasks.first { $0.uuid == id }?.title } ?? "another task"
        case .external:
            title = removed.note ?? "something else"
        }
        let task = self.task
        let context = self.context
        let tasks = allTasks
        offerEditUndo("Stopped waiting on “\(title)”") {
            switch removed.kind {
            case .task:
                guard let id = removed.taskID else { return }
                task.addTaskBlocker(id, among: tasks)
            case .external:
                task.addExternalBlocker(removed.note, among: tasks)
            }
            task.logHumanEdit(
                field: "blockers", oldValue: nil,
                newValue: removed.taskID?.uuidString ?? removed.note ?? "something else",
                summary: "Restored blocker", reversible: false, coalescable: false, in: context)
            context.saveChanges()
        }
    }

    private func setDue(dayOffset: Int) {
        let cal = Calendar.current
        setDue(cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())))
    }

    private func setDue(_ date: Date?) {
        guard date != task.dueDate else { return }
        let old = task.dueDate
        actionPulse += 1
        task.dueDate = date
        let summary = date.map { "Set due date to \(dueText($0))" } ?? "Cleared due date"
        task.logHumanEdit(
            field: "dueDate", oldValue: ChangeLogEntry.encodeDate(old),
            newValue: ChangeLogEntry.encodeDate(date), summary: summary, in: context)
        context.saveChanges()
        if date == nil, let old {
            let task = self.task
            let context = self.context
            offerEditUndo("Cleared due date") {
                task.dueDate = old
                task.logHumanEdit(
                    field: "dueDate", oldValue: ChangeLogEntry.encodeDate(nil),
                    newValue: ChangeLogEntry.encodeDate(old), summary: "Restored due date", in: context)
                context.saveChanges()
            }
        }
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { task.dueDate ?? Calendar.current.startOfDay(for: Date()) },
            set: { date in
                setDue(date)
                // A pick is the end of the interaction — the chip now says the answer.
                Motion.withMotion(Motion.settle) { showDatePicker = false }
            }
        )
    }

    // MARK: - Freely-typed field commits (title / description, on focus loss)

    private func commitTitleEdit() {
        // Never save a blank title. Clearing the field and leaving used to persist an
        // empty string, which rendered as a nameless row in the list — the one edit the
        // page must refuse. Trimmed, and restored to what it was when it comes back empty.
        let updated = Self.committedTitle(task.title, fallback: originalTitle)
        if updated != task.title { task.title = updated }
        guard updated != originalTitle else { return }
        task.logHumanEdit(
            field: "title", oldValue: originalTitle, newValue: updated, summary: "Renamed task",
            in: context)
        originalTitle = updated
        context.saveChanges()
        reclassifyWorkIntent()  // a material title change may change what kind of work this is
    }

    /// The title that gets saved: the typed one, trimmed — or the title the edit began
    /// from when the typed one is empty. Pure, so the refusal is testable.
    static func committedTitle(_ typed: String, fallback: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func commitNotesEdit() {
        let updated = task.notes
        guard updated != originalNotes else { return }
        task.logHumanEdit(
            field: "notes", oldValue: originalNotes, newValue: updated,
            summary: updated == nil ? "Cleared description" : "Updated description", in: context)
        originalNotes = updated
        context.saveChanges()
        reclassifyWorkIntent()
    }

    /// Re-classify the task's `WorkIntent` after a material/structural change. Device-only
    /// (a no-op in the simulator, where the classifier returns nil); the cached value is
    /// only overwritten when a fresh classification arrives. Constitutional guard: this
    /// only ever writes `workIntent`, never `needsDecision`.
    ///
    /// **Resolved tasks are never reclassified.** Changing which module renders on
    /// something already finished helps nobody and burns a model call.
    private func reclassifyWorkIntent() {
        guard !task.status.isResolved else { return }
        let snapshot = WorkIntentContext(task: task, among: allTasks)
        // Replace any classification still in flight — a second edit supersedes the first,
        // and letting both land would race to write `workIntent`.
        classifyWork?.cancel()
        classifyWork = Task {
            let outcome = await WorkIntentClassifier().classify(snapshot)
            // Only a success writes. `.unavailable` / `.timedOut` / `.failed` all leave
            // the cached value alone — this path must never clobber a good classification
            // with a guess. `.cancelled` must not write at all: the user has moved on and
            // a stale intent landing behind them is exactly what cancellation prevents.
            guard case .success(let intent) = outcome, !Task.isCancelled else { return }
            // Routed through the mutation seam rather than writing `workIntent` directly,
            // so every classifier write lands in one place.
            task.reclassify(to: intent, in: context)
            context.saveChanges()
        }
    }

    // MARK: - Activity timeline

    /// A synthesized creation anchor for the timeline — used only when no real capture
    /// entry ("filed"/"confirmed") already grounds it, so the timeline is never empty.
    private var creationAnchor: DetailActivityTimeline.Creation? {
        if activityEntries.contains(where: { $0.action == "filed" || $0.action == "confirmed" }) {
            return nil
        }
        return DetailActivityTimeline.Creation(date: task.createdAt, actorID: task.creatorID)
    }

    /// Revert one timeline entry (the "edited" rows Activity doesn't surface). Mirrors the
    /// Inbox's action-aware undo: mark undone, revert the field, save.
    private func undoEntry(_ entry: ChangeLogEntry) {
        actionPulse += 1
        Motion.withMotion(Motion.snap) {
            entry.undone = true
            ChangeLogUndo.revert(entry, in: context)
        }
        context.saveChanges()
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Staggered rise (the BriefView entrance pattern, capped ≤0.15s spread)

extension View {
    fileprivate func rise(_ index: Int, _ appeared: Bool, _ reduceMotion: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(
                reduceMotion ? nil : Motion.settle.delay(Double(index) * Motion.staggerStep),
                value: appeared
            )
    }
}

// MARK: - Presentation

extension View {
    /// Present the task detail full-screen (Linear-style): an opaque page with a back
    /// chevron + edge-swipe dismiss. The name is kept so all call sites (My Tasks,
    /// Today, Household, search) ride the one surface.
    ///
    /// `peers` is the ordered task list the presenting surface is CURRENTLY showing — the
    /// detail pages horizontally through it, so a swipe lands where the eye expects (the
    /// row above / below the one you tapped). Omit it and the detail is a single page,
    /// exactly as before.
    ///
    /// `handOffNotice` receives an undo pill the pager could not keep — the cover
    /// dismissed (the last page resolved, or Back was tapped) while the way back was
    /// still on offer. The presenter shows it on its own surface; omit it and the
    /// notice dies with the cover, which was the behaviour before 2026-09-04.
    func taskDetailSheet(
        _ task: Binding<TaskItem?>, peers: [TaskItem] = [],
        handOffNotice: ((UndoNotice) -> Void)? = nil
    ) -> some View {
        fullScreenCover(item: task) { item in
            TaskDetailPager(opened: item, peers: peers, handOffNotice: handOffNotice)
        }
    }
}

#Preview {
    @Previewable @State var task: TaskItem? = {
        TaskItem(
            title: "Renew passport", category: "Travel", status: .doing,
            confidence: 0.85, reasoning: "Filed under Travel from the wording.",
            isUrgent: true, rawCapture: "renew my passport before the trip")
    }()

    return Color.clear
        .taskDetailSheet($task)
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
