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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var tab: MyTasksTab = .assigned
    @State private var statusFilter: TaskDisplayStatus?
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

    private var assignedSections: [MyTasksSection] {
        MyTasksSlices.assigned(
            tasks: tasks, currentUserID: currentUserID, status: statusFilter, category: categoryFilter)
    }
    private var createdEntries: [TaskLaneEntry] {
        MyTasksSlices.createdEntries(
            tasks: tasks, currentUserID: currentUserID, status: statusFilter, category: categoryFilter)
    }

    /// What the detail pages through: exactly the rows the visible tab is rendering, in
    /// order, with chain stacks unrolled root-first.
    private var visiblePeers: [TaskItem] {
        switch tab {
        case .assigned: return TaskDetailPeers.flatten(assignedSections)
        case .created: return TaskDetailPeers.flatten(createdEntries)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.sm) {
                tabBar
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.xs)

                Group {
                    switch tab {
                    case .assigned:
                        AssignedSectionsView(
                            sections: assignedSections, allTasks: tasks, othersRoster: othersRoster,
                            searchIsActive: filtersActive,
                            selectedTask: $selectedTask, notice: $notice)
                    case .created:
                        CreatedFlatView(
                            entries: createdEntries, allTasks: tasks, othersRoster: othersRoster,
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
            .taskDetailSheet($selectedTask, peers: visiblePeers)
            .undoNotice($notice)
            .task { openDetailIfRequested() }
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
        let peers = visiblePeers
        guard peers.indices.contains(index) else { return }
        selectedTask = peers[index]
    }

    // MARK: - Tab bar (Assigned / Created + the filter pill)

    private var tabBar: some View {
        // The selected pill is Liquid Glass; the glass-merge morph between tabs needs a
        // GlassEffectContainer + glassEffectID (matchedGeometryEffect on a .glassEffect
        // capsule resamples mid-flight). Under Reduce Transparency, a flat capsule +
        // matchedGeometryEffect instead.
        Group {
            if reduceTransparency {
                tabRow
            } else {
                GlassEffectContainer { tabRow }
            }
        }
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
            // Neutral Liquid Glass — no tint. A 10% tint over the near-black list has
            // nothing to refract and reads muddy; selection is carried by the bright
            // semibold label instead. `interactive` gives the tappable pill the
            // system's native press response; `morph` flows the glass between
            // Assigned↔Created within the tabBar's single GlassEffectContainer.
            Color.clear.glassCapsule(interactive: true, morph: (id: "tabPill", ns: tabPill))
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
                ForEach(TaskDisplayStatus.allCases) { status in
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
            .font(.system(size: IconSize.small, weight: .semibold))
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
