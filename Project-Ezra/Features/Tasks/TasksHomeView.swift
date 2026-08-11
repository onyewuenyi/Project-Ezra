//
//  TasksHomeView.swift
//  Project-Ezra
//
//  "My Tasks" — the system of record, redrawn to Linear's "My issues": a large
//  title, a top-right [search][…] pill, and an Assigned / Created tab pair whose
//  selected pill carries a filter menu. Assigned groups your work into the six Linear
//  status sections (In Progress → In Review → Todo → Backlog, plus the Done/Canceled
//  ledger via the filter); Created is a flat authorship record, newest first. The AI
//  is invisible here: it helps you retrieve, it never decides what to show.
//

import CoreData
import SwiftUI

struct TasksHomeView: View {
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

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

    /// Assigned and Created answer the same question until somebody else is in the
    /// household: with a roster of one, every task you created is a task assigned to
    /// you, so the pill is a two-tab control over two identical lists on the most-used
    /// screen. It appears the moment a second member exists.
    private var showsTabs: Bool { !othersRoster.isEmpty }

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
                if showsTabs {
                    tabBar
                        .padding(.horizontal, Spacing.lg)
                        .padding(.top, Spacing.xs)
                }

                Group {
                    switch slice {
                    case .assigned(let sections):
                        AssignedSectionsView(
                            sections: sections, allTasks: tasks, othersRoster: othersRoster,
                            searchIsActive: filtersActive,
                            selectedTask: $selectedTask, notice: $notice)
                    case .created(let entries):
                        CreatedFlatView(
                            entries: entries, allTasks: tasks, othersRoster: othersRoster,
                            searchIsActive: filtersActive,
                            selectedTask: $selectedTask, notice: $notice)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .animation(Motion.fade, value: tab)
            .background(Palette.background)
            .navigationTitle("My Tasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search tasks")

                    Menu {
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

    /// Deterministic verification seam. Launch with `-OpenSettings` to present the
    /// Settings sheet, which is otherwise two taps deep behind the "…" menu. It now holds
    /// the destructive clears, and a screen that can delete everything should be reviewable
    /// without a synthetic tap (blocked by Accessibility here). Never fires in normal runs.
    private func openSettingsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-OpenSettings") else { return }
        showSettings = true
    }

    // MARK: - Tab bar (Assigned / Created + the filter pill)

    private var tabBar: some View {
        // The selected pill is a SOLID raised surface, not Liquid Glass: glass carries a
        // vibrancy that dims the label riding on it (verified — the selected text read
        // dimmer than the unselected one, and no scrim behind the text could fix it, since
        // the material desaturates the foreground itself). A text-bearing selection chip
        // therefore uses a solid surface; the morph is a plain `matchedGeometryEffect`.
        tabRow
    }

    private var tabRow: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(MyTasksTab.allCases) { candidate in
                tabButton(candidate)
            }
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ candidate: MyTasksTab) -> some View {
        let isSelected = tab == candidate
        return HStack(spacing: Spacing.xs) {
            Button {
                Motion.withMotion(Motion.snap) { tab = candidate }
            } label: {
                Text(candidate.label)
                    .font(.sectionHeader)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Palette.primaryText : Palette.secondaryText)
            }
            .buttonStyle(.pressable)

            // The filter menu rides the SELECTED tab's pill, behind a vertical hairline.
            if isSelected {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: 0.5, height: 16)
                filterMenu
            }
        }
        .padding(.horizontal, isSelected ? Spacing.sm : 0)
        .padding(.vertical, Spacing.xxs)
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

    private var filterMenu: some View {
        Menu {
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
            Image(
                systemName: filtersActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            .font(.glyphSmall(.semibold))
            .foregroundStyle(filtersActive ? Palette.accentFlat : Palette.secondaryText)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(filtersActive ? "Filters, active" : "Filters")
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
