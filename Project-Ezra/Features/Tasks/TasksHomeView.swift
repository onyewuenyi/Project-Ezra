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

import CoreData
import SwiftUI

struct TasksHomeView: View {
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    /// Activity is the shell's screen, not this one's — it is reachable from the Brief
    /// too, so it has exactly one mount point and neither surface owns it.
    @Environment(\.openActivity) private var openActivity
    @Environment(\.openAsk) private var openAsk

    @State private var tab: MyTasksTab = .assigned
    @State private var statusFilter: TaskStatus?
    @State private var categoryFilter: String?
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showRoster = false
    @State private var selectedTask: TaskItem?
    @State private var notice: UndoNotice?
    @Namespace private var tabPill

    private var tasks: [TaskItem] { Array(tasksResults) }
    private var members: [FamilyMember] { Array(membersResults) }
    private var profiles: [UserProfile] { Array(profilesResults) }

    private var currentUserID: UUID? { profiles.first?.linkedMemberID }
    /// Roster minus the current user, so your own tasks render badge-free.
    private var othersRoster: [FamilyMember] {
        members.filter { !$0.isRemoved && $0.uuid != currentUserID }
    }

    private var filtersActive: Bool { statusFilter != nil || categoryFilter != nil }

    /// Both header decisions come from the contract, never from view nesting.
    private var showsTabs: Bool { MyTasksHeader.showsTabs(othersRoster: othersRoster.count) }

    /// Both header decisions come from the contract, never from view nesting — and so
    /// does what the screen calls itself.
    private var title: String { MyTasksHeader.title(othersRoster: othersRoster.count) }

    /// The visible tab's rows, sliced once.
    ///
    /// Slicing is not free — both cases run `TaskRanking.rankKeys` over the FULL working
    /// set plus chain construction. They used to be computed properties read twice per
    /// render (once to build the list, once to hand the detail its peer order), so every
    /// redraw of the record surface paid for two complete ranking passes over every task
    /// the user owns. `body` resolves this once and passes it to both.
    private enum VisibleSlice {
        case assigned([MyTasksSection])
        case created([TaskLaneEntry])

        /// What the detail pages through: exactly the rows on screen, in order, with
        /// chain stacks unrolled root-first.
        var peers: [TaskItem] {
            switch self {
            case .assigned(let sections): return TaskDetailPeers.flatten(sections)
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
            return .assigned(
                MyTasksSlices.assigned(
                    tasks: tasks, currentUserID: currentUserID, status: statusFilter,
                    category: categoryFilter))
        case .created:
            return .created(
                MyTasksSlices.createdEntries(
                    tasks: tasks, currentUserID: currentUserID, status: statusFilter,
                    category: categoryFilter))
        }
    }

    var body: some View {
        let slice = visibleSlice
        return NavigationStack {
            VStack(spacing: Spacing.sm) {
                headerRow
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.xs)
                // Unfinished captures are findable here, quietly (F-04). Renders nothing
                // when nothing is parked.
                ParkedCapturesRow()
                    .padding(.horizontal, Spacing.lg)

                Group {
                    switch slice {
                    case .assigned(let sections):
                        AssignedSectionsView(
                            sections: sections, allTasks: tasks, othersRoster: othersRoster,
                            currentUserID: currentUserID,
                            searchIsActive: filtersActive,
                            onShowAll: { status in
                                Motion.withMotion(Motion.settle) { statusFilter = status }
                            },
                            selectedTask: $selectedTask, notice: $notice)
                    case .created(let entries):
                        CreatedFlatView(
                            entries: entries, allTasks: tasks, othersRoster: othersRoster,
                            currentUserID: currentUserID,
                            searchIsActive: filtersActive,
                            selectedTask: $selectedTask, notice: $notice)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .animation(Motion.fade, value: tab)
            .background(Palette.background)
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Ask, from where you are (F-12) — the same bubble the task pager
                    // wears for its own scope. A verb beside the record, not a place.
                    Button {
                        openAsk()
                    } label: {
                        Image(systemName: "text.bubble")
                    }
                    .accessibilityLabel("Ask about your tasks")

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
                            showRoster = true
                        } label: {
                            Label("Manage Household", systemImage: "person.2")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .navigationDestination(isPresented: $showRoster) { HouseholdRosterView() }
            .sheet(isPresented: $showSearch) { TaskSearchView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .taskDetailSheet($selectedTask, peers: slice.peers)
            .undoNotice($notice)
            .task {
                applyFilterArgsIfRequested()
                openDetailIfRequested()
                openSettingsIfRequested()
            }
        }
    }

    /// Deterministic verification seam. Launch with `-OpenTaskDetail [N]` to open the
    /// full-screen detail pager on the Nth visible row (default 0), so the paged surface
    /// is reachable without a synthetic tap (blocked by Accessibility here). Never fires
    /// in normal runs.
    private func openDetailIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-OpenTaskDetail") else { return }
        let index = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 0 : 0
        let peers = visibleSlice.peers
        guard peers.indices.contains(index) else { return }
        selectedTask = peers[index]
    }

    /// Deterministic verification seam. `-FilterStatus <raw>` / `-FilterCategory <name>`
    /// preset the filter, so the ACTIVE control (`☰ Done`, `☰ 2 filters`) and a narrowed
    /// list are screenshot-reachable — the filter is a Menu, and opening one needs a tap
    /// that Accessibility blocks here. An unknown value is ignored rather than crashing,
    /// so a typo in a verification command reads as "no filter", not a failed launch.
    /// Never fires in normal runs.
    private func applyFilterArgsIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-FilterStatus"), args.indices.contains(flag + 1) {
            statusFilter = TaskStatus(rawValue: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "-FilterCategory"), args.indices.contains(flag + 1) {
            let value = args[flag + 1]
            categoryFilter = TaskCategory.all.contains(value) ? value : nil
        }
    }

    /// Deterministic verification seam. Launch with `-OpenSettings` to present the
    /// Settings sheet, which is otherwise two taps deep behind the "…" menu. It now holds
    /// the destructive clears, and a screen that can delete everything should be reviewable
    /// without a synthetic tap (blocked by Accessibility here). Never fires in normal runs.
    private func openSettingsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-OpenSettings") else { return }
        showSettings = true
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
    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            if showsTabs {
                ForEach(MyTasksTab.allCases) { candidate in
                    tabButton(candidate)
                }
                Spacer(minLength: Spacing.sm)
            }
            if MyTasksHeader.showsFilter(othersRoster: othersRoster.count) {
                filterControl
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
    private var filterControl: some View {
        Menu {
            // The menu is a state EDITOR, so it can undo itself in one tap rather than
            // making the user walk both axes back to All.
            if filtersActive {
                Button {
                    Motion.withMotion(Motion.snap) {
                        statusFilter = nil
                        categoryFilter = nil
                    }
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
            HStack(spacing: Spacing.xxs) {
                Image(
                    systemName: filtersActive
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
                )
                .font(.glyphSmall(.semibold))
                if let summary = filterSummary {
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
            // Interaction size still ≥ the visual size: the capsule now clears 44pt on
            // neither axis by itself, so this keeps the touchable region honest by growing
            // into the surrounding whitespace and giving the layout size back.
            .minimumHitTarget()
        }
        .accessibilityLabel(filtersActive ? "Filters, active" : "Filters")
        .accessibilityValue(filterSummary ?? "All")
    }

    /// What the control calls itself — the rule lives in the contract, where it's tested.
    private var filterSummary: String? {
        MyTasksHeader.filterSummary(status: statusFilter, category: categoryFilter)
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
