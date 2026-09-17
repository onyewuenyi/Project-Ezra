//
//  GroupProposalRow.swift
//  Project-Ezra
//
//  **A question, not a badge.** The grouping sweep's one proposal, as a quiet row at the
//  top of My Tasks in the same register as the parked-captures row: a place to look,
//  never a thing that asks to be visited — no colour, no count, no notification. Tap →
//  the members and three answers: Group them (the umbrella is written, with Undo),
//  Not these (the pairs are suppressed; the sweep never asks again), Not now (hidden
//  for this launch). Renders nothing when there is nothing to ask.
//
//  The AI names membership; the deterministic layer (`GroupingSweep.validated`) decides
//  what may be shown; the person decides what is written. The row never writes.
//

import CoreData
import SwiftUI

struct GroupProposalRow: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    @State private var proposals = GroupProposals.shared
    @State private var asking: GroupProposal?
    @Binding var notice: UndoNotice?

    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    /// The first proposal whose members are still open and loose. One the household has
    /// moved past (a member resolved, or grouped by hand) simply stops showing.
    private var proposal: GroupProposal? {
        let live = Set(
            tasksResults.filter { !$0.status.isResolved && $0.parentTaskID == nil }.compactMap(\.uuid))
        return proposals.pending.first { candidate in
            candidate.memberIDs.filter(live.contains).count >= GroupingSweep.minClusterSize
        }
    }

    var body: some View {
        Group {
            if let proposal {
                Button {
                    asking = proposal
                } label: {
                    row(proposal)
                }
                .buttonStyle(.pressableLink)
                .contextMenu {
                    Button("Group them", systemImage: "rectangle.3.group") { accept(proposal) }
                    Button("Not these", systemImage: "xmark") {
                        GroupingSweep.reject(proposal, currentUserID: currentUserID, in: context)
                    }
                    Button("Not now") { proposals.dismissForNow(proposal) }
                }
                .accessibilityLabel(
                    "Group \(proposal.memberTitles.count) tasks as \(proposal.title)? "
                        + proposal.memberTitles.joined(separator: ", ")
                )
                .accessibilityHint("Shows the tasks and asks")
            }
        }
        .onAppear { seedIfRequested() }
        .confirmationDialog(
            asking.map { "Group as “\($0.title)”?" } ?? "", isPresented: askingPresented,
            titleVisibility: .visible
        ) {
            if let asking {
                Button("Group them") { accept(asking) }
                Button("Not these") {
                    GroupingSweep.reject(asking, currentUserID: currentUserID, in: context)
                }
                Button("Not now", role: .cancel) { proposals.dismissForNow(asking) }
            }
        } message: {
            if let asking { Text(asking.memberTitles.joined(separator: " · ")) }
        }
    }

    /// Deterministic verification seam. `-SeedGroupProposal` proposes the first two loose
    /// open tasks as “Sample outcome”, so the row and its dialog are screenshot-reachable
    /// without a model run. Never fires in normal runs; compiled out of Release.
    private func seedIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-SeedGroupProposal"), proposals.pending.isEmpty
        else {
            return
        }
        let loose = tasksResults.filter { !$0.status.isResolved && $0.parentTaskID == nil }.prefix(2)
        guard loose.count == 2 else { return }
        proposals.seed([
            GroupProposal(
                id: UUID(), title: "Sample outcome", memberIDs: loose.compactMap(\.uuid),
                memberTitles: loose.map(\.title), confidence: 0.7)
        ])
        #endif
    }

    private var askingPresented: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    private func accept(_ proposal: GroupProposal) {
        guard
            let umbrella = GroupingSweep.apply(proposal, currentUserID: currentUserID, in: context)
        else { return }
        // The same receipt every AI structural act gets: the pill, and the trail's
        // "grouped" entry, whose undo unlinks the steps and removes the umbrella.
        let request = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
        let entry = (try? context.fetch(request)).flatMap { entries in
            entries.filter { $0.action == "grouped" && $0.taskUUID == umbrella.uuid }
                .max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        }
        notice = UndoNotice(
            message: "Grouped \(proposal.memberTitles.count) tasks as “\(proposal.title)”",
            undoAction: entry.map { entry in
                {
                    ChangeLogUndo.revert(entry, in: context)
                    context.saveChanges()
                }
            })
    }

    private func row(_ proposal: GroupProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "rectangle.3.group")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
            Text("Group as “\(proposal.title)”?")
                .supportingStyle()
                .lineLimit(1)
                .layoutPriority(1)
            Text("\(proposal.memberTitles.count) tasks")
                .supportingStyle()
                .foregroundStyle(Palette.mutedText)
                .lineLimit(1)
            Spacer(minLength: Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
