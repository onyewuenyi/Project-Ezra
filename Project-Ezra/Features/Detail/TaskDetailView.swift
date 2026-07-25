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
    @State private var actionPulse = 0
    @State private var showAllActivity = false

    /// Freely-typed fields diff on focus loss (title/description) — snapshots of what they
    /// held when editing began, so a change logs exactly one "edited" row per commit.
    private enum EditField { case title, notes }
    @FocusState private var focusedField: EditField?
    @State private var originalTitle = ""
    @State private var originalNotes: String?

    init(task: TaskItem, isActive: Bool = true, onResolved: @escaping () -> Void = {}) {
        self.task = task
        self.isActive = isActive
        self.onResolved = onResolved
        _activityResults = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)],
            predicate: task.uuid.map { NSPredicate(format: "taskUUID == %@", $0 as CVarArg) }
                ?? NSPredicate(value: false)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                titleSection.rise(0, appeared, reduceMotion)
                decisionSection.rise(1, appeared, reduceMotion)
                propertyCard.rise(2, appeared, reduceMotion)
                descriptionSection.rise(3, appeared, reduceMotion)
                whySection.rise(4, appeared, reduceMotion)
                activitySection.rise(5, appeared, reduceMotion)
                footer.rise(6, appeared, reduceMotion)
            }
            .padding(Spacing.lg)
        }
        .background(Palette.background)
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
        .task {
            Motion.withMotion(Motion.settle) { appeared = true }
            // Prewarm the on-device model when the Thinking Partner will render, so the
            // first framing tap isn't paying the cold model-load cost. Only for the page
            // actually on screen — a neighbour in the pager hasn't earned the load.
            if isActive, TaskCapabilities.available(for: task).contains(.thinkingPartner) {
                ModelWarmup.prewarmSharedSession()
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
            if !active { focusedField = nil }
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
            try? context.save()
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
                workIntentChip
                addBlockerChip
            }
            if showDatePicker {
                DatePicker("Due date", selection: dueBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Palette.accentFlat)
            }
            ForEach(task.activeBlockers(among: allTasks)) { blocker in
                blockerChipRow(blocker)
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
                    .font(.system(size: IconSize.caption))
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
                        .font(.system(size: IconSize.caption))
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
                    .font(.system(size: IconSize.caption))
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
                Image(systemName: "calendar").font(.system(size: IconSize.caption))
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
                    .font(.system(size: IconSize.caption))
                Text(task.category)
            }
        }
    }

    /// The work-intent correction. Reachable but unprominent, on purpose.
    ///
    /// Type gates which capability the detail offers (`TaskCapabilities.available`), so
    /// a misclassification silently withholds the Thinking Partner from a task that
    /// needed it — and the classifier will sometimes read a decision as an action. This
    /// is the human's one-tap fix, and the correction it writes is exactly the training
    /// signal the correction-as-data architecture wants.
    ///
    /// On the heuristic path (and for any user whose Apple Intelligence is off or
    /// unavailable) `workIntent` is nil, so this renders as a muted add-affordance
    /// rather than hiding — it is one of the few places that path can be corrected at all.
    private var workIntentChip: some View {
        Menu {
            ForEach(WorkIntent.allCases) { intent in
                Button(intent.label) { setWorkIntent(intent) }
            }
            if task.workIntent != nil {
                Divider()
                Button("Clear", role: .destructive) { setWorkIntent(nil) }
            }
        } label: {
            chip(muted: task.workIntent == nil) {
                Image(systemName: "square.stack.3d.up").font(.system(size: IconSize.caption))
                Text(task.workIntent?.label ?? "Kind of work")
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
                Image(systemName: "timer").font(.system(size: IconSize.caption))
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
                Image(systemName: "plus").font(.system(size: IconSize.caption))
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
                .font(.system(size: IconSize.caption))
                .foregroundStyle(Palette.mutedText)
            Text(title)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button {
                removeBlocker(blocker.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: IconSize.caption))
                    .foregroundStyle(Palette.mutedText)
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("Stop waiting on \(title)")
        }
    }

    // MARK: - Decision (the judgment-call resolution)

    /// Capability-driven: the detail renders whatever `TaskCapabilities` returns. V1 has one
    /// capability — the Thinking Partner — offered when the task is a genuine decision (the
    /// `needsDecision` flag OR a `.decision` work-intent). A flagged decision shows the full
    /// card (reason + "Mark decided" + framing); an intent-only decision shows the lighter
    /// card (framing, no flag fabricated, no clear button).
    @ViewBuilder
    private var decisionSection: some View {
        if TaskCapabilities.available(for: task).contains(.thinkingPartner) {
            let flagged = task.needsDecision && !task.status.isResolved
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: IconSize.small))
                        .foregroundStyle(Palette.decisionAccent)
                    Text(flagged ? "Needs a decision" : "A decision to make")
                        .font(.sectionHeader)
                        .foregroundStyle(Palette.primaryText)
                }
                if flagged {
                    Text(decisionReasonText)
                        .supportingStyle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                ThinkingPartnerView(context: DecisionContext(task: task, among: allTasks))
                if flagged {
                    Button {
                        markDecided()
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
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Palette.primarySurface,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        flagged ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Palette.border),
                        lineWidth: flagged ? 1.5 : 0.5)
            }
        }
    }

    private var decisionReasonText: String {
        task.isJudgmentCall
            ? "This is a values call only you can make — Ezra won't decide it for you."
            : "Ezra wasn't confident enough to file this cleanly. Take a look and set it straight."
    }

    private func markDecided() {
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.resolveDecisionAndLog(in: context) }
        try? context.save()
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

    private var footer: some View {
        let action = task.recommendedAction(among: allTasks)
        return Button {
            performPrimary(action)
        } label: {
            Text(action.title)
                .font(.ctaLabel)
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Palette.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressableProminent)
    }

    private func performPrimary(_ action: RecommendedAction) {
        actionPulse += 1
        Motion.withMotion(Motion.decide) {
            task.performRecommendedAction(among: allTasks, in: context)
        }
        try? context.save()
        if action.dismissesDetail { onResolved() }
    }

    // MARK: - Mutations wiring

    private func applyStatus(_ state: TaskStatus) {
        guard state != task.status else { return }
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.setStatus(state, in: context) }
        try? context.save()
        if state.isResolved { onResolved() }
    }

    private func setOwner(_ id: UUID?) {
        guard id != task.ownerID else { return }
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.claimAndLog(ownerID: id, among: allTasks, in: context) }
        try? context.save()
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
        try? context.save()
    }

    private func setCategory(_ cat: String) {
        guard cat != task.category else { return }
        let old = task.category
        actionPulse += 1
        task.category = cat
        task.logHumanEdit(
            field: "category", oldValue: old, newValue: cat,
            summary: "Recategorized to \(cat)", in: context)
        try? context.save()
    }

    /// A HUMAN type correction. Logged as a plain field edit (coalescing, out of the
    /// Inbox feed) plus a `Correction` row — distinct from the classifier's own
    /// `reclassify`, which writes an `.ai` entry when it crosses the workload boundary.
    private func setWorkIntent(_ intent: WorkIntent?) {
        guard intent != task.workIntent else { return }
        let old = task.workIntent
        actionPulse += 1
        task.workIntent = intent
        task.logHumanEdit(
            field: "workIntent", oldValue: old?.rawValue, newValue: intent?.rawValue,
            summary: intent.map { "Set kind to \($0.label)" } ?? "Cleared the kind of work",
            in: context)
        if let old {
            context.insert(
                Correction(
                    taskUUID: task.uuid, captureID: task.captureID,
                    fieldCorrected: "workIntent", aiValue: old.rawValue,
                    userValue: intent?.rawValue ?? "none", in: context))
        }
        try? context.save()
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
        try? context.save()
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
        try? context.save()
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
        try? context.save()
        reclassifyWorkIntent()
    }

    private func removeBlocker(_ blockerID: UUID) {
        actionPulse += 1
        Motion.withMotion(Motion.decide) { task.removeBlocker(blockerID, among: allTasks) }
        task.logHumanEdit(
            field: "blockers", oldValue: blockerID.uuidString, newValue: nil,
            summary: "Removed blocker", reversible: false, coalescable: false, in: context)
        try? context.save()
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
        try? context.save()
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
        try? context.save()
        reclassifyWorkIntent()  // a material title change may change what kind of work this is
    }

    private func commitNotesEdit() {
        let updated = task.notes
        guard updated != originalNotes else { return }
        task.logHumanEdit(
            field: "notes", oldValue: originalNotes, newValue: updated,
            summary: updated == nil ? "Cleared description" : "Updated description", in: context)
        originalNotes = updated
        try? context.save()
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
        Task {
            guard let intent = await WorkIntentClassifier().classify(snapshot) else { return }
            // Routed through the mutation seam so a move across the workload boundary
            // is logged and reversible rather than silently re-scoping five systems.
            task.reclassify(to: intent, in: context)
            try? context.save()
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

    /// Revert one timeline entry (the "edited" rows the Inbox doesn't surface). Mirrors the
    /// Inbox's action-aware undo: mark undone, revert the field, save.
    private func undoEntry(_ entry: ChangeLogEntry) {
        actionPulse += 1
        Motion.withMotion(Motion.snap) {
            entry.undone = true
            ChangeLogUndo.revert(entry, in: context)
        }
        try? context.save()
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Staggered rise (the TodayView entrance pattern, capped ≤0.15s spread)

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
