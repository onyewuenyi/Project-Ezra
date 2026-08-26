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
    @State private var showAllActivity = false
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
    private enum EditField { case title, notes }
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
    /// The tasks the current reading cites, resolved against the live set. A cited
    /// id that no longer resolves renders nothing — a dead reference must not become
    /// a dead row.
    private var citedTasks: [TaskItem] {
        let ids: [UUID]
        switch advisorStore.state(for: task) {
        case .revealed(let reading): ids = reading.citedTaskIDs
        case .fallback(let reading): ids = reading?.citedTaskIDs ?? []
        default: ids = []
        }
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in allTasks.first { $0.uuid == id } }
    }

    /// What bears on the choice, for the obligation block — only on the deciding
    /// page, and only when no decide reading below is already showing its own
    /// what-matters lines (the same fact twice in two boxes is worse than either).
    private var obligationContextLines: [String] {
        guard shape == .deciding else { return [] }
        if case .revealed(let reading) = advisorStore.state(for: task),
            reading.move == .decide, !reading.evidence.isEmpty
        {
            return []
        }
        return TaskAdvisorFacts.make(task: task, among: allTasks).decisionContextLines
    }

    private var advisorVisible: Bool {
        AdvisorView.isVisible(
            state: advisorStore.state(for: task),
            flagged: task.needsDecision && !task.status.isResolved,
            diagnosis: StallDetector.diagnose(task, among: allTasks))
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
        .taskDetailSheet($openedRelated)
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
    }

    // MARK: - Title (kicker + big editable title)

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(task.category.uppercased())
                .metadataStyle()
                .tracking(0.8)
            TextField("Task title", text: $task.title, axis: .vertical)
                .font(.screenTitle)
                .tracking(-0.4)
                .foregroundStyle(Palette.primaryText)
                .textInputAutocapitalization(.sentences)
                .focused($focusedField, equals: .title)
            provenanceLine
            parentLine
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
                categoryChip
                effortChip
                addBlockerChip
            }
            if showDatePicker {
                DatePicker("Due date", selection: dueBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Palette.accentFlat)
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
            Button("Pick a date…") {
                if task.dueDate == nil { setDue(dayOffset: 0) }
                showDatePicker = true
            }
            if task.dueDate != nil {
                Divider()
                Button("Clear", role: .destructive) {
                    setDue(nil)
                    showDatePicker = false
                }
            }
        } label: {
            chip(muted: task.dueDate == nil) {
                Image(systemName: "calendar").font(.glyphCaption())
                Text(task.dueDate.map(dueText) ?? "No due date")
            }
        }
    }

    private var categoryChip: some View {
        Menu {
            ForEach(TaskCategory.all, id: \.self) { cat in
                Button {
                    setCategory(cat)
                } label: {
                    Label(cat, systemImage: TaskCategory.symbol(for: cat))
                }
            }
        } label: {
            chip {
                Image(systemName: TaskCategory.symbol(for: task.category))
                    .font(.glyphCaption())
                Text(task.category)
            }
        }
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
    private func blockerChipRow(_ blocker: Blocker) -> some View {
        let title: String
        switch blocker.kind {
        case .task:
            title = blocker.taskID.flatMap { id in allTasks.first { $0.uuid == id }?.title } ?? "Another task"
        case .external:
            title = blocker.note ?? "Something else"
        }
        return HStack(spacing: Spacing.sm) {
            Image(systemName: blocker.kind == .task ? "arrow.turn.down.right" : "hourglass")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
            Text(title)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
            // The wait's age, everywhere a wait renders — the spine taught the
            // vocabulary; the card keeps it.
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

    private func stepRow(_ step: TaskItem) -> some View {
        let done = step.status.isResolved
        return HStack(spacing: Spacing.sm) {
            StatusGlyphView(task: step, allTasks: allTasks, interactive: false)
            Text(step.title)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .strikethrough(done, color: Palette.mutedText)
                .lineLimit(1)
                .recessed(done)
            Spacer(minLength: Spacing.sm)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step: \(step.title), \(done ? "done" : "open")")
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
            if let target {
                StatusGlyphView(task: target, allTasks: allTasks, interactive: false)
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
                onPick: { state in
                    actionPulse += 1
                    Motion.withMotion(Motion.decide) { step.setStatus(state, in: context) }
                    context.saveChanges()
                    advisorStore.ensure(task: task, among: allTasks)
                    refreshContainerKickoff()
                }
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
            citedTasks: citedTasks,
            contextLines: obligationContextLines,
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
            onCreateSteps: { accepted, proposed in
                advisorActed(.createSteps) { accept(accepted, proposed: proposed) }
            },
            onOpenBlocker: { blocker in
                advisorActed(.openBlocker) { openedRelated = blocker }
            },
            onDoItNow: { advisorActed(.advise) { applyStatus(.doing) } },
            onDefer: { advisorActed(.advise) { setDue(dayOffset: 7) } },
            onKill: { advisorActed(.advise) { applyStatus(.canceled) } },
            onDismiss: { advisorStore.dismiss(taskID: task.uuid) },
            onOpenCited: { cited in
                advisorActed(.advise) { openedRelated = cited }
            }
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

    /// Accept a breakdown: create the selected steps as real child tasks.
    ///
    /// `proposed` is the full set the model offered, so each deselection is recorded as
    /// a `Correction` — the user telling the model it over-reached is exactly the
    /// signal the correction loop wants, and it exists nowhere else.
    private func accept(_ steps: [BreakdownStep], proposed: [BreakdownStep]) {
        guard !steps.isEmpty else { return }
        actionPulse += 1
        Motion.withMotion(Motion.decide) {
            task.splitInto(steps, in: context)
        }
        let kept = Set(steps.map(\.title))
        for declined in proposed where !kept.contains(declined.title) {
            context.insert(
                Correction(
                    taskUUID: task.uuid, captureID: task.captureID,
                    fieldCorrected: "split", aiValue: declined.title, userValue: "declined",
                    in: context))
        }
        // A task that has just become a container is a different kind of work than it
        // was a moment ago — see `reclassifyWorkIntent`.
        reclassifyWorkIntent()
        context.saveChanges()
        // The same pill a resolution gets. An AI-authored structural act with no
        // in-place receipt made the page reshape FEEL unilateral — the steps appeared,
        // the reading vanished, and the way back lived two screens away in Activity.
        // Undo routes through `ChangeLogUndo.revert` (the split entry's own arm), so
        // there is exactly one revert path and this pill cannot drift from it.
        let count = steps.count
        let taskUUID = task.uuid
        let undoContext = context
        notice = UndoNotice(
            message: "Split into \(count) step\(count == 1 ? "" : "s")"
        ) {
            let request = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
            request.predicate = NSPredicate(
                format: "action == %@ AND taskUUID == %@ AND undone == NO",
                "split", (taskUUID ?? UUID()) as CVarArg)
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)
            ]
            request.fetchLimit = 1
            guard let entry = try? undoContext.fetch(request).first else { return }
            ChangeLogUndo.revert(entry, in: undoContext)
            undoContext.saveChanges()
        }
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
                HStack(spacing: Spacing.xs) {
                    Text("Details")
                        .sectionHeaderStyle()
                    Image(systemName: "chevron.down")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
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

            // The kickoff line: the one concrete first move, under the button that just
            // relabeled — the moment of commitment is when activation energy is highest.
            // Shown only while the commitment is live; silence is the fallback.
            if task.status == .doing, let step = kickoffStep {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.accentFlat)
                    Text(step)
                        .supportingStyle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
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
        actionPulse += 1
        var unblocked: [TaskItem] = []
        Motion.withMotion(Motion.decide) {
            unblocked = task.performRecommendedAction(action, among: allTasks, in: context)
        }
        context.saveChanges()
        // The Start tap is the strongest "doing this now" signal in the app — the
        // moment the kickoff line earns its fetch. Deterministic trigger, model
        // content, silent fallback.
        if action == .start || action == .resume { fetchKickoff() }
        // Only the resolving arm leaves the working set, and it is the only one that can
        // free dependents — so it is the only one that owes the user a way back.
        if action.dismissesDetail {
            offerUndo(verb: "Completed", unblocked: unblocked)
            onResolved()
        }
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
        actionPulse += 1
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
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.removeBlocker(blockerID, among: allTasks) }
        task.logHumanEdit(
            field: "blockers", oldValue: blockerID.uuidString, newValue: nil,
            summary: "Removed blocker", reversible: false, coalescable: false, in: context)
        context.saveChanges()
        reclassifyWorkIntent()  // losing a blocker is a structural change
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
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { task.dueDate ?? Calendar.current.startOfDay(for: Date()) },
            set: { setDue($0) }
        )
    }

    // MARK: - Freely-typed field commits (title / description, on focus loss)

    private func commitTitleEdit() {
        let updated = task.title
        guard updated != originalTitle else { return }
        task.logHumanEdit(
            field: "title", oldValue: originalTitle, newValue: updated, summary: "Renamed task",
            in: context)
        originalTitle = updated
        context.saveChanges()
        reclassifyWorkIntent()  // a material title change may change what kind of work this is
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
    func taskDetailSheet(_ task: Binding<TaskItem?>, peers: [TaskItem] = []) -> some View {
        fullScreenCover(item: task) { item in
            TaskDetailPager(opened: item, peers: peers)
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
