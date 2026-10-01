//
//  TasksHomeView.swift
//  Project-Ezra
//
//  "My Tasks" — the system of record, redrawn to Linear's "My issues": a large title,
//  a top-right [search][…] pill, and one header row carrying two INDEPENDENT
//  dimensions — an Assigned / Created ownership pair (whose tasks am I looking at?)
//  and the filter (what subset of them do I want?). Assigned groups your work into the
//  status sections in focus order (In Progress → Todo → Done → Canceled); Created is a
//  flat authorship record, newest first. The AI is invisible here: it helps you
//  retrieve, it never decides what to show.
//
//  The header's composition rules — and why the filter may never be a passenger of the
//  tabs again — live in `MyTasksHeader` (Models/MyTasksSlices.swift), where they are
//  testable. Read that contract before changing what this header renders.
//
//  Since 2026-09-23 this is a SHEET (`TasksSheet`), one tap behind the Ask home's list
//  button — the grammar Ask had when this was the home, swapped. The sheet supplies the
//  stack, so this carries none of its own; the roster and Settings it used to present
//  are the sheet's host's (`\.openRoster`, `\.openSettings`), reachable from both "…"
//  menus. It closes like a summoned sheet: Done, or a swipe down.
//

import CoreData
import SwiftUI

struct TasksHomeView: View {
    /// What the sheet opens ON (2026-09-23): the glance strip's count deep-links here
    /// with a tab, a status or an attention already set. Applied once, on appear —
    /// after that the header owns its state as it always did. `.plain` for a plain open.
    var preset: TasksPreset = .plain

    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    /// Activity is the shell's screen, not this one's — it is reachable from the Brief
    /// too, so it has exactly one mount point and neither surface owns it.
    @Environment(\.openActivity) private var openActivity
    @Environment(\.openRoster) private var openRoster
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    /// At accessibility text sizes three pills and a filter no longer fit one row, and a
    /// row that cannot shrink its children overflows off the screen — the filter was the
    /// first thing to go. There the header WRAPS (`FlowLayout`), the filter following the
    /// pills onto a second line with its summary intact; the `GeometryReader` host follows
    /// the measured height. At the default sizes nothing changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var tab: MyTasksTab = .assigned
    @State private var statusFilter: TaskStatus?
    @State private var categoryFilter: String?
    /// The third filter axis (`TasksAttention`): overdue, due today, waiting, decisions,
    /// urgent, or one person's — the row markers as a subset.
    @State private var attentionFilter: TasksAttention?
    /// When the sheet appeared, for the dwell meter on the way out.
    @State private var appearedAt: Date?
    @State private var showSearch = false
    @State private var selectedTask: TaskItem?
    @State private var notice: UndoNotice?
    @Namespace private var tabPill
    /// The header's measured widths — the row, the ownership pills, and what the filter
    /// capsule would take WITH its summary — so `filterShowsSummary` is arithmetic. See
    /// `filterControl` for why this is measured rather than left to `ViewThatFits`.
    @State private var pillsWidth: CGFloat = 0
    @State private var labelledFilterWidth: CGFloat = 0
    /// The header row's own height, so the `GeometryReader` that hosts it (see
    /// `headerRow`) can be given a frame: a reader is greedy, and without this it would
    /// take the whole screen. Starts at the row's floor and follows Dynamic Type.
    @State private var headerRowHeight: CGFloat = LayoutMetrics.tasksHeaderRow

    /// LIVE rows only (2026-09-18). A destructive clear deletes every task and saves,
    /// and for the render between the delete and the fetch refresh the results still
    /// hand back objects Core Data has torn down — every attribute answers empty, so
    /// the rows lose their identity and the list crashes on duplicate ids. A deleted or
    /// context-less object is not a task any more; it simply leaves the list, which is
    /// also exactly what the clear means.
    private var tasks: [TaskItem] { tasksResults.filter(\.isLiveRow) }
    private var members: [FamilyMember] { Array(membersResults) }
    private var profiles: [UserProfile] { Array(profilesResults) }

    private var currentUserID: UUID? { profiles.first?.linkedMemberID }
    /// Roster minus the current user, so your own tasks render badge-free.
    private var othersRoster: [FamilyMember] {
        members.filter { !$0.isRemoved && $0.uuid != currentUserID }
    }

    private var filtersActive: Bool {
        statusFilter != nil || categoryFilter != nil || attentionFilter != nil
    }

    /// Both header decisions come from the contract, never from view nesting.
    private var showsTabs: Bool { MyTasksHeader.showsTabs(othersRoster: othersRoster.count) }

    /// Both header decisions come from the contract, never from view nesting — and so
    /// does what the screen calls itself: "Our Tasks" over Everyone, "My Tasks" over
    /// the two scopes that are yours.
    private var title: String {
        MyTasksHeader.title(othersRoster: othersRoster.count, tab: effectiveTab)
    }

    /// The visible tab's rows, sliced once.
    ///
    /// Slicing is not free — both cases run `TaskRanking.rankKeys` over the FULL working
    /// set plus chain construction. They used to be computed properties read twice per
    /// render (once to build the list, once to hand the detail its peer order), so every
    /// redraw of the record surface paid for two complete ranking passes over every task
    /// the user owns. `body` resolves this once and passes it to both.
    private enum VisibleSlice {
        /// Assigned and Everyone — the same sectioned render over a different scope.
        case sectioned([MyTasksSection], scope: MyTasksTab)
        case created([TaskLaneEntry])

        /// What the detail pages through: exactly the rows on screen, in order, with
        /// chain stacks unrolled root-first.
        var peers: [TaskItem] {
            switch self {
            case .sectioned(let sections, _): return TaskDetailPeers.flatten(sections)
            case .created(let entries): return TaskDetailPeers.flatten(entries)
            }
        }
    }

    /// The tab actually in effect. Reading `tab` directly would strand a user who had
    /// selected Created and then lost the control — the roster can shrink back to one
    /// (a member removed), and the pill would vanish leaving no way back to Assigned.
    private var effectiveTab: MyTasksTab { showsTabs ? tab : .assigned }

    private var visibleSlice: VisibleSlice {
        switch effectiveTab {
        case .assigned:
            return .sectioned(
                MyTasksSlices.assigned(
                    tasks: tasks, currentUserID: currentUserID, status: statusFilter,
                    category: categoryFilter, attention: attentionFilter), scope: .assigned)
        case .everyone:
            return .sectioned(
                MyTasksSlices.everyone(
                    tasks: tasks, status: statusFilter, category: categoryFilter,
                    attention: attentionFilter),
                scope: .everyone)
        case .created:
            return .created(
                MyTasksSlices.createdEntries(
                    tasks: tasks, currentUserID: currentUserID, status: statusFilter,
                    category: categoryFilter, attention: attentionFilter))
        }
    }

    var body: some View {
        let slice = visibleSlice
        return VStack(spacing: Spacing.sm) {
            headerRow
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xs)
            // The household's counts, the list's own glance (2026-09-23): each one sets
            // the filter in place. They left the home, where six capsules were the most
            // dashboard-like thing on the screen; here they are inventory over inventory.
            let counts = TasksCounts.items(tasks: tasks)
            if !counts.isEmpty {
                ChatSummaryStrip(items: counts) { item in
                    Telemetry.log(.glanceOpened(kind: item.kind))
                    Motion.withMotion(Motion.snap) { apply(item.preset) }
                }
                // Leading, under the scopes: a short strip centred itself (2026-09-25).
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.lg)
            }
            // The parked-captures row and the grouping sweep's question used to sit
            // here. They are the AI's own proposals, and since 2026-09-23 they live on
            // the home — the AI's surface, which is also the first thing on screen — so
            // the list is a plain workbench: the header, then the rows.

            Group {
                switch slice {
                case .sectioned(let sections, let scope):
                    AssignedSectionsView(
                        sections: sections, allTasks: tasks, othersRoster: othersRoster,
                        currentUserID: currentUserID,
                        scope: scope,
                        searchIsActive: filtersActive,
                        filteredEmptyMessage: filteredEmptyMessage,
                        onShowAll: { status in
                            Motion.withMotion(Motion.settle) { statusFilter = status }
                        },
                        onClearFilters: clearFilters,
                        selectedTask: $selectedTask, notice: $notice)
                case .created(let entries):
                    CreatedFlatView(
                        entries: entries, allTasks: tasks, othersRoster: othersRoster,
                        currentUserID: currentUserID,
                        searchIsActive: filtersActive,
                        filteredEmptyMessage: filteredEmptyMessage,
                        onClearFilters: clearFilters,
                        selectedTask: $selectedTask, notice: $notice)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(Motion.fade, value: tab)
        // A column, not a sheet of glass: on an iPad the list ran edge to edge with
        // the due label a screen-width from its title (2026-09-18).
        .readableWidth()
        .background(Palette.background)
        .navigationTitle(title)
        // A pushed page defaults to an inline title; the record keeps its large one.
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // A summoned sheet closes like one (the Ask sheet's Done, swapped over).
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search tasks")

                Menu {
                    // The trust surface, demoted from a tab but not from the
                    // product: every AI action has to be understandable and
                    // undoable, and merged-pair entries have no other home. It
                    // leads the menu because it is the only item here that is
                    // about what the SYSTEM did.
                    Button {
                        openActivity()
                    } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        openRoster()
                    } label: {
                        Label("Manage Household", systemImage: "person.2")
                    }
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showSearch) { TaskSearchView() }
        .taskDetailSheet($selectedTask, peers: slice.peers, handOffNotice: { notice = $0 })
        // Above the capture orb (2026-09-26): at the default inset the 62pt orb sat on
        // the pill's trailing edge and covered its Undo — the list's only reversal.
        .undoNotice($notice, bottomInset: ShellSurfaces<EmptyView>.captureButtonDiameter + Spacing.md)
        .task {
            applyPreset()
            applyFilterArgsIfRequested()
            openDetailIfRequested()
            await completeRowIfRequested()
        }
        .onAppear { appearedAt = Date() }
        // The modal-depth meter (2026-09-23): a sheet is a place you visit; one that
        // stays up for minutes is the home in exile, and the number says which.
        .onDisappear {
            guard let appearedAt else { return }
            Telemetry.log(
                .tasksSheetDwell(elapsed: DurationBucket(seconds: Date().timeIntervalSince(appearedAt))))
        }
    }

    /// The deep-link's state, applied once. A tab the roster does not show falls back
    /// through `effectiveTab` as it always did.
    private func applyPreset() { apply(preset) }

    /// One preset, applied whole: a count under the header replaces the status and
    /// attention axes with its own (never stacks on them), and moves the scope when it
    /// names one.
    private func apply(_ preset: TasksPreset) {
        if let presetTab = preset.tab { tab = presetTab }
        statusFilter = preset.status
        attentionFilter = preset.attention
    }

    /// Deterministic verification seam. Launch with `-OpenTaskDetail [N]` to open the
    /// full-screen detail pager on the Nth visible row (default 0), so the paged surface
    /// is reachable without a synthetic tap (blocked by Accessibility here). Never fires
    /// in normal runs.
    private func openDetailIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-OpenTaskDetail") else { return }
        let index = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 0 : 0
        let peers = visibleSlice.peers
        guard peers.indices.contains(index) else { return }
        selectedTask = peers[index]
        #endif
    }

    /// `-CompleteListRow N` completes the Nth visible row through the same seam the glyph
    /// and the swipe use, 1.5 s after the list settles (2026-09-26): the reflow and the
    /// undo pill are a sequence no synthetic tap can reach. Never fires in normal runs.
    private func completeRowIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-CompleteListRow") else { return }
        let index = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 0 : 0
        try? await Task.sleep(for: .seconds(1.5))
        let peers = visibleSlice.peers
        guard peers.indices.contains(index) else { return }
        Motion.withMotion(Motion.settle) {
            completeTask(peers[index], in: context, tasks: tasks, notice: $notice)
        }
        #endif
    }

    /// Deterministic verification seam. `-FilterStatus <raw>` / `-FilterCategory <name>`
    /// preset the filter, so the ACTIVE control (`☰ Done`, `☰ 2 filters`) and a narrowed
    /// list are screenshot-reachable — the filter is a Menu, and opening one needs a tap
    /// that Accessibility blocks here. An unknown value is ignored rather than crashing,
    /// so a typo in a verification command reads as "no filter", not a failed launch.
    /// Never fires in normal runs.
    private func applyFilterArgsIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-FilterStatus"), args.indices.contains(flag + 1) {
            statusFilter = TaskStatus(rawValue: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "-FilterCategory"), args.indices.contains(flag + 1) {
            let value = args[flag + 1]
            categoryFilter = TaskCategory.all.contains(value) ? value : nil
        }
        // `-OpenSearch ["query"]` presents search (2026-09-26): the magnifier is a tap,
        // and search was the one list surface no seam reached, so it had never been
        // reviewed at accessibility sizes or against the importance audit.
        if let flag = args.firstIndex(of: "-OpenSearch") {
            if args.indices.contains(flag + 1), !args[flag + 1].hasPrefix("-") {
                UserDefaults.standard.set(args[flag + 1], forKey: "debug.searchSeed")
            }
            showSearch = true
        }
        // `-MyTasksTab created` lands on the Created tab — the ownership pill is a tap
        // too, and the flat authorship record was the one header state no seam reached.
        if let flag = args.firstIndex(of: "-MyTasksTab"), args.indices.contains(flag + 1),
            let candidate = MyTasksTab(rawValue: args[flag + 1])
        {
            tab = candidate
        }
        #endif
    }

    // MARK: - Header row (ownership navigation · filter — two independent dimensions)

    /// One row, two dimensions that do not own each other: the ownership tabs lead and
    /// come and go with the roster, the filter is ALWAYS there.
    ///
    /// The row itself is unconditional — that is the fix. The filter has exactly ONE
    /// mount point, and it is not inside anything the roster can switch off; the bug
    /// this replaced came from its only mount being a conditional one. The row's
    /// presence in both states also keeps the header's height fixed, so gaining or
    /// losing a household member never jumps the list below (`MyTasksHeader` rule 5).
    ///
    /// Alone, the filter takes the leading edge — anchored to the title and the list's
    /// content column, rather than floating in an otherwise empty corner. With tabs it
    /// yields the lead to them and trails, because ownership is the coarser question.
    @ViewBuilder
    private var headerRow: some View {
        if headerWraps {
            // A wrapping header sizes itself from its proposal — no offered-width
            // arithmetic, no reader, no state-fed frame (which lagged the wrapped height
            // and let the second line overlap the parked-captures row).
            FlowLayout(spacing: Spacing.sm, lineSpacing: Spacing.xs) {
                ForEach(MyTasksTab.allCases) { candidate in
                    tabButton(candidate)
                }
                if MyTasksHeader.showsFilter(othersRoster: othersRoster.count) {
                    filterControl(offeredWidth: 0)
                }
            }
            .frame(minHeight: LayoutMetrics.tasksHeaderRow)
            // Leading: the page's VStack centres what does not fill it, and a wrapped
            // row of pills started ~50pt in from the title's edge (2026-09-26).
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            headerRowMeasured
        }
    }

    private var headerRowMeasured: some View {
        // Hosted in a `GeometryReader` for ONE number: the width the row is OFFERED. A
        // row of one-line pills grows past its proposal rather than shrinking, and every
        // view sized by it — the row, its padding, a `Color` sibling in a ZStack (placed
        // with the stack's final size) — reports the overflow, so the summary would
        // never learn it has to yield. A reader is sized by its proposal alone. Its
        // height follows the row's measured height, because a reader is otherwise greedy.
        GeometryReader { proxy in
            headerRowContent(offeredWidth: proxy.size.width)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    headerRowHeight = $0
                }
        }
        .frame(height: headerRowHeight)
    }

    private var headerWraps: Bool { dynamicTypeSize.isAccessibilitySize && showsTabs }

    private func headerRowContent(offeredWidth: CGFloat) -> some View {
        HStack(spacing: Spacing.sm) {
            if showsTabs {
                HStack(spacing: Spacing.sm) {
                    ForEach(MyTasksTab.allCases) { candidate in
                        tabButton(candidate)
                    }
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    pillsWidth = $0
                }
                // No floor of its own: the stack's two gaps already keep 24pt between
                // the pills and the filter, and a third `sm` was the point by which
                // "Family" failed to fit beside three scopes on a 402pt phone.
                Spacer(minLength: 0)
            }
            if MyTasksHeader.showsFilter(othersRoster: othersRoster.count) {
                filterControl(offeredWidth: offeredWidth)
            }
            if !showsTabs { Spacer(minLength: 0) }
        }
        // Pinned so gaining or losing a household member changes WHAT the header holds,
        // never how tall it is — the list underneath doesn't reflow (rule 5). Without
        // this the row is only as tall as its tallest resident, so the tabs appearing
        // would nudge every task down by the difference.
        //
        // `minHeight`, not `height`: the tab label is `sectionHeader`, which scales with
        // Dynamic Type, and a fixed box would clip it at accessibility sizes. Stability
        // is worth having at the default sizes where a jump is the visible problem —
        // never at the cost of truncating the control's own text.
        .frame(minHeight: LayoutMetrics.tasksHeaderRow)
    }

    private func tabButton(_ candidate: MyTasksTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            Motion.withMotion(Motion.snap) { tab = candidate }
        } label: {
            Text(candidate.label)
                .font(.sectionHeader)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Palette.primaryText : Palette.secondaryText)
                // A pill never wraps. Three scopes plus a labelled filter contend for
                // one row, and without this the HStack broke "Everyone" over two lines
                // while the filter kept its word; the pill holds its width and the
                // filter's summary is what yields (see `filterControl`).
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, isSelected ? Spacing.sm : 0)
        .padding(.vertical, Spacing.xxs)
        // Both this pill and the filter capsule take the ROW's height as a floor, which is
        // what makes them the same size: each was otherwise as tall as its own content
        // happened to be — `sectionHeader` text here, a `glyphSmall` icon there — which is
        // why the filter sat visibly shorter beside it.
        //
        // A floor, not `maxHeight: .infinity`: the row is pinned with `minHeight` and so
        // has no ceiling, and greedy children make the HStack itself greedy — tried, and
        // both capsules stretched to fill the entire screen.
        .frame(minHeight: LayoutMetrics.tasksHeaderRow)
        .background { pillBackground(isSelected: isSelected) }
        // **Which scope is showing was carried entirely by pixels (2026-09-20).**
        // Selection here is a font weight, a text colour and a solid capsule — all of
        // them invisible to VoiceOver, which read three identically-named buttons. The
        // navigation title separates Mine from the other two and nothing separated
        // Everyone from Created, so the answer to "whose tasks am I looking at?" was
        // unavailable. The app already does this correctly on the composer's posture
        // chip; this is the same trait.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func pillBackground(isSelected: Bool) -> some View {
        if isSelected {
            // A solid raised chip (`elevatedSurface` + hairline) — NOT glass. Glass would
            // impose vibrancy on the label and sap its contrast; a solid surface keeps the
            // selected text crisp white. `matchedGeometryEffect` flows the pill between
            // Assigned↔Created. (The text-on-glass rule: glass chrome is for icons/press
            // affordances, never primary text — see Glass.swift.)
            Capsule().fill(Palette.elevatedSurface)
                .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
                .matchedGeometryEffect(id: "tabPill", in: tabPill)
        }
    }

    /// The filter — a query dimension, not a passenger of the tabs.
    ///
    /// It NAMES ITS OWN STATE, because a bare glyph has a specific failure mode on a
    /// task list: a filtered list is indistinguishable from a list with tasks missing,
    /// which is a trust problem rather than a discoverability one. One active axis
    /// shows its value ("Done"); both show a count ("2 filters") — deliberately not
    /// "Done · Work", which turns the control into a miniature query builder and
    /// fights for width with the tabs.
    private func filterControl(offeredWidth: CGFloat) -> some View {
        // Held to its ideal width, and the summary shown only when the row can hold it.
        //
        // Two things a plainer layout got wrong here, both measured. An HStack splits
        // its leftover EQUALLY between its flexible children — this and the Spacer — so
        // with a hundred points to spare the summary was still offered half and
        // truncated to "2…" (`layoutPriority` on a `Menu` did not change that). And a
        // glyph-only fallback via `ViewThatFits` was tried three ways (inside the label,
        // around two whole controls, with `.fixedSize` and with `.button` style) and
        // never chose the labelled control even with room: a `Menu` does not report a
        // finite ideal width under an unspecified proposal, so the first candidate never
        // "fits". So the decision is arithmetic over three measured widths, with the
        // labelled capsule probed hidden so the answer holds while the glyph is showing.
        //
        // The ACTIVE state survives the drop — the filled, accented glyph — and the words
        // survive in `accessibilityValue` and in the filtered-empty state, so a narrow
        // row loses the summary, never the fact that a filter is on.
        filterMenu(labelled: filterShowsSummary(offeredWidth: offeredWidth))
            .fixedSize(horizontal: true, vertical: false)
            .background {
                filterCapsule(labelled: true)
                    .hidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        labelledFilterWidth = $0
                    }
            }
            .accessibilityLabel(filtersActive ? "Filters, active" : "Filters")
            .accessibilityValue(filterSummary ?? "All")
    }

    /// Whether the labelled capsule fits beside the pills: pills + the two stack gaps +
    /// the capsule, against the row. True until measured, so the first frame renders the
    /// fuller control and the probe has something to measure.
    private func filterShowsSummary(offeredWidth: CGFloat) -> Bool {
        // A wrapping header always has room for the words — that is what wrapping buys.
        guard showsTabs, !headerWraps, offeredWidth > 0, labelledFilterWidth > 0 else { return true }
        return pillsWidth + 2 * Spacing.sm + labelledFilterWidth <= offeredWidth
    }

    private func filterMenu(labelled: Bool) -> some View {
        Menu {
            // The menu is a state EDITOR, so it can undo itself in one tap rather than
            // making the user walk both axes back to All.
            if filtersActive {
                Button {
                    clearFilters()
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
            }
            Section("Status") {
                Button {
                    statusFilter = nil
                } label: {
                    filterLabel("All", checked: statusFilter == nil)
                }
                ForEach(TaskStatus.pickable) { status in
                    Button {
                        statusFilter = status
                    } label: {
                        Label {
                            Text(status.label)
                        } icon: {
                            Image(systemName: statusFilter == status ? "checkmark" : status.symbol)
                        }
                    }
                }
            }
            Section("Attention") {
                Button {
                    attentionFilter = nil
                } label: {
                    filterLabel("All", checked: attentionFilter == nil)
                }
                ForEach(TasksAttention.pickable, id: \.self) { attention in
                    Button {
                        attentionFilter = attention
                    } label: {
                        Label {
                            Text(attention.label)
                        } icon: {
                            Image(systemName: attentionFilter == attention ? "checkmark" : attention.symbol)
                        }
                    }
                }
                // The owner arm is reached from the strip only; while it is on, the
                // menu names it so it can be seen and cleared.
                if case .ownedBy(_, let name)? = attentionFilter {
                    Button {
                    } label: {
                        Label("\(name)’s", systemImage: "checkmark")
                    }
                    .disabled(true)
                }
            }
            Section("Category") {
                Button {
                    categoryFilter = nil
                } label: {
                    filterLabel("All", checked: categoryFilter == nil)
                }
                ForEach(TaskCategory.all, id: \.self) { category in
                    Button {
                        categoryFilter = category
                    } label: {
                        Label {
                            Text(category)
                        } icon: {
                            Image(
                                systemName: categoryFilter == category
                                    ? "checkmark" : TaskCategory.symbol(for: category))
                        }
                    }
                }
            }
        } label: {
            filterCapsule(labelled: labelled)
                // Interaction size still ≥ the visual size: the capsule clears 44pt on
                // neither axis by itself, so this keeps the touchable region honest by
                // growing into the surrounding whitespace and giving the layout size back.
                .minimumHitTarget()
        }
    }

    /// The filter capsule as drawn: the glyph, and the summary while a filter is on and
    /// there is room for it. Also the hidden probe `filterControl` measures.
    private func filterCapsule(labelled: Bool) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(
                systemName: filtersActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            .font(.glyphSmall(.semibold))
            if labelled, let summary = filterSummary {
                Text(summary)
                    .font(.chipLabel)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(filtersActive ? Palette.accentFlat : Palette.secondaryText)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        // The same row-height floor the tab pill takes, so the two capsules match
        // rather than each being as tall as its own content: equal PADDING wasn't
        // enough, because this control's content is a `glyphSmall` icon where the
        // pill's is `sectionHeader` text.
        .frame(minHeight: LayoutMetrics.tasksHeaderRow)
        .background(Palette.secondarySurface, in: Capsule())
    }

    /// What the control calls itself — the rule lives in the contract, where it's tested.
    private var filterSummary: String? {
        MyTasksHeader.filterSummary(
            status: statusFilter, category: categoryFilter, attention: attentionFilter)
    }

    /// What an empty filtered list says — same contract, same file as the summary.
    private var filteredEmptyMessage: String? {
        MyTasksHeader.filteredEmptyMessage(
            status: statusFilter, category: categoryFilter, attention: attentionFilter)
    }

    /// The one clearer, shared by the menu and the empty state's button.
    private func clearFilters() {
        Motion.withMotion(Motion.snap) {
            statusFilter = nil
            categoryFilter = nil
            attentionFilter = nil
        }
    }

    private func filterLabel(_ text: String, checked: Bool) -> some View {
        Label {
            Text(text)
        } icon: {
            if checked { Image(systemName: "checkmark") }
        }
    }
}

#Preview {
    TasksHomeView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
