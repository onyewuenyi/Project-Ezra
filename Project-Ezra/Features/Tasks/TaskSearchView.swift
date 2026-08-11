//
//  TaskSearchView.swift
//  Project-Ezra
//
//  The search sheet reached from the "My Tasks" title bar's magnifying glass. A
//  first-class, always-present search field over every task (any owner, any status),
//  rendering the same Linear-minimal rows that open to the full-screen detail. Search
//  is fast, local, and case-insensitive (`TaskSlice.matches`) — retrieval, never
//  re-ranking.
//

import CoreData
import SwiftUI

struct TaskSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \TaskItem.createdAt, ascending: false)])
    private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    @State private var searchText = ""
    @State private var selectedTask: TaskItem?
    @State private var notice: UndoNotice?

    private var tasks: [TaskItem] { Array(tasksResults) }
    private var members: [FamilyMember] { Array(membersResults) }
    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }
    private var othersRoster: [FamilyMember] {
        members.filter { !$0.isRemoved && $0.uuid != currentUserID }
    }

    private var matches: [TaskItem] {
        tasks.filter { TaskSlice.matches($0, search: searchText, category: nil) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "Search your tasks",
                        message: "Find anything by title — across every owner and every status.")
                } else if matches.isEmpty {
                    EmptyStateView(
                        symbol: "questionmark.circle",
                        title: "No matches",
                        message: "Nothing matches “\(searchText)”. Try a different word.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.objectID) { index, task in
                                if index > 0 { TaskRowDivider() }
                                TaskRow(
                                    task: task,
                                    allTasks: tasks,
                                    blockerSummary: task.blockerSummary(among: tasks),
                                    stepProgress: task.stepProgress(among: tasks),
                                    ownerDisplayName: task.ownerDisplayName(among: othersRoster),
                                    ownerPhotoData: task.ownerPhotoData(among: othersRoster),
                                    interactive: !task.status.isResolved,
                                    // Resolving from search routes through the SAME
                                    // undo-aware seams the record surface uses. Without
                                    // these the row still completed correctly, but did it
                                    // silently — no Undo pill, and no voice for the
                                    // dependents the completion just unblocked. The same
                                    // gesture on the same row must not mean two things.
                                    onComplete: task.status.isResolved
                                        ? nil
                                        : {
                                            completeTask(
                                                task, in: context, tasks: tasks, notice: $notice)
                                        },
                                    onCancel: task.status.isResolved
                                        ? nil
                                        : {
                                            cancelTask(
                                                task, in: context, tasks: tasks, notice: $notice)
                                        },
                                    onOpen: { selectedTask = task }
                                )
                            }
                        }
                        .padding(Spacing.lg)
                    }
                }
            }
            .background(Palette.background)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search tasks"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .taskDetailSheet($selectedTask, peers: matches)
            .undoNotice($notice)
        }
    }
}

#Preview {
    TaskSearchView()
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
