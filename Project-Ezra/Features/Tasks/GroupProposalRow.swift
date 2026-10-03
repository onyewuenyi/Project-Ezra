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
    @FetchRequest(sortDescriptors: UserProfile.chosenOrder) private var profilesResults: FetchedResults<UserProfile>
    @State private var proposals = GroupProposals.shared
    @State private var asking: GroupProposal?
    @Binding var notice: UndoNotice?

    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    /// The first proposal whose members are still open and loose. One the household has
    /// moved past (a member resolved, or grouped by hand) simply stops showing.
    private var proposal: GroupProposal? {
        let open = tasksResults.filter { !$0.status.isResolved }
        let live = Set(open.filter { $0.parentTaskID == nil }.compactMap(\.uuid))
        let openIDs = Set(open.compactMap(\.uuid))
        return proposals.pending.first { candidate in
            let members = candidate.memberIDs.filter(live.contains).count
            if let umbrellaID = candidate.umbrellaID {
                return members >= 1 && openIDs.contains(umbrellaID)
            }
            return members >= GroupingSweep.minClusterSize
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
                    Button(proposal.isAttach ? "Add it" : "Group them", systemImage: "rectangle.3.group") {
                        accept(proposal)
                    }
                    Button("Not these", systemImage: "xmark") {
                        GroupingSweep.reject(proposal, currentUserID: currentUserID, in: context)
                    }
                    Button("Not now") { proposals.dismissForNow(proposal) }
                }
                .accessibilityLabel(
                    Self.question(proposal) + " " + proposal.memberTitles.joined(separator: ", ")
                )
                .accessibilityHint("Shows the tasks and asks")
            }
        }
        // On a zero-size anchor, not the Group: with nothing to ask the Group is empty,
        // an empty view never appears, and the seed that would give it something to ask
        // never ran (2026-09-26, found when the row moved to the home).
        .background { Color.clear.frame(width: 0, height: 0).onAppear { seedIfRequested() } }
        .onChange(of: proposals.pending.count) { _, _ in acceptIfRequested() }
        .confirmationDialog(
            asking.map(Self.question) ?? "", isPresented: askingPresented,
            titleVisibility: .visible
        ) {
            if let asking {
                Button(asking.isAttach ? "Add it" : "Group them") { accept(asking) }
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

    /// Deterministic verification seam. `-AcceptGroupProposal` accepts the first proposal
    /// the moment one is offered, so the RESULT — a deck captioned by the named outcome,
    /// the Undo pill — is screenshot-reachable without a tap. Never fires in normal runs.
    private func acceptIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-AcceptGroupProposal"), let proposal else { return }
        accept(proposal)
        #endif
    }

    private var askingPresented: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    /// The row's and the dialog's one line: what is being asked, in the proposal's shape.
    static func question(_ proposal: GroupProposal) -> String {
        guard proposal.isAttach else { return "Group as “\(proposal.title)”?" }
        return proposal.memberTitles.count == 1
            ? "Add “\(proposal.memberTitles[0])” to “\(proposal.title)”?"
            : "Add \(proposal.memberTitles.count) tasks to “\(proposal.title)”?"
    }

    private func accept(_ proposal: GroupProposal) {
        let entries = GroupingSweep.apply(proposal, currentUserID: currentUserID, in: context)
        guard !entries.isEmpty else { return }
        // The same receipt every AI structural act gets: the pill, and the trail's
        // entries — "grouped" (undo unlinks the steps and removes the umbrella) or one
        // "linked" per added step (undo removes that link). The pill reverts them all.
        notice = UndoNotice(
            message: proposal.isAttach
                ? (proposal.memberTitles.count == 1
                    ? "Added “\(proposal.memberTitles[0])” to “\(proposal.title)”"
                    : "Added \(proposal.memberTitles.count) tasks to “\(proposal.title)”")
                : "Grouped \(proposal.memberTitles.count) tasks as “\(proposal.title)”",
            undoAction: {
                for entry in entries {
                    ChangeLogUndo.revert(entry, in: context)
                    entry.undone = true
                }
                context.saveChanges()
            })
    }

    private func row(_ proposal: GroupProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "rectangle.3.group")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
            Text(Self.question(proposal))
                .supportingStyle()
                .lineLimit(1)
                .layoutPriority(1)
            if !proposal.isAttach {
                Text("\(proposal.memberTitles.count) tasks")
                    .supportingStyle()
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
