//
//  GroupingSweepTests.swift
//  Project-EzraTests
//
//  The grouping sweep's deterministic halves: the prefilter (who is even asked about),
//  the validator (what a judgment may become), and the person's two answers (accept
//  writes one reversible "grouped" entry; reject writes sibling suppressions the
//  prefilter honours). The judge itself is device-only.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Grouping sweep — prefilter, validator, answers")
struct GroupingSweepTests {

    private func snap(_ title: String, blocked: Bool = false, parent: String? = nil) -> OpenTaskSnapshot {
        OpenTaskSnapshot(
            id: UUID(), title: title, category: "Travel", isBlocked: blocked, parentTitle: parent)
    }

    @Test("Loose tasks sharing a long word cluster; short words, waits and stepped tasks do not")
    func clusters() {
        let flights = snap("Book flights to Lagos")
        let pack = snap("Pack for Lagos")
        let passport = snap("Renew passport")
        let water = snap("Pay the water bill")
        let phone = snap("Pay the phone bill", blocked: true)
        let step = snap("Pack the Lagos gifts", parent: "Lagos trip")
        let clusters = GroupingSweep.clusters(
            among: [flights, pack, passport, water, phone, step], suppressions: [])
        #expect(clusters.count == 1)
        #expect(Set(clusters[0].members.map(\.id)) == [flights.id, pack.id])
        // A rejected pair is cut before clustering, so the question is never re-asked.
        let no = RelationshipSuppression(
            kind: .siblingGroup, pairKey: RelationshipSuppression.symmetricKey(flights.id, pack.id),
            targetID: nil, normalizedTitle: nil, createdAt: Date())
        #expect(GroupingSweep.clusters(among: [flights, pack, passport], suppressions: [no]).isEmpty)
        // Oversized clusters are trimmed to the cap, never dropped.
        let many = (0..<8).map { snap("Lagos errand \($0)") }
        let capped = GroupingSweep.clusters(among: many, suppressions: [])
        #expect(capped.count == 1)
        #expect(capped[0].members.count == GroupingSweep.maxClusterSize)
    }

    @Test(
        "A bare chain is a candidate ahead of word clusters; one with an umbrella or a rejected pair is not")
    func chainCandidates() {
        let context = TestStore.makeContext()
        let passport = TaskItem(title: "Renew passport", category: "Travel", in: context)
        let flights = TaskItem(
            title: "Book flights", category: "Travel", blockedBy: [passport.uuid!], in: context)
        _ = TaskItem(title: "Pack for Lagos", category: "Travel", in: context)
        _ = TaskItem(title: "Lagos gifts", category: "Travel", in: context)
        let all = TaskItem.fetchAll(in: context)
        let chained = GroupingSweep.chainClusters(in: all, suppressions: [])
        #expect(chained.count == 1)
        #expect(Set(chained[0].members.map(\.id)) == [passport.uuid!, flights.uuid!])
        // Ordered: the chain on screen first, the Lagos word-cluster after it.
        let snapshots = all.map { OpenTaskSnapshot(id: $0.uuid!, title: $0.title, category: $0.category) }
        let candidates = GroupingSweep.candidates(in: all, snapshots: snapshots, suppressions: [])
        #expect(candidates.count == 2)
        #expect(candidates[0] == chained[0])
        // A rejected pair leaves the chain alone.
        let no = RelationshipSuppression(
            kind: .siblingGroup, pairKey: RelationshipSuppression.symmetricKey(passport.uuid!, flights.uuid!),
            targetID: nil, normalizedTitle: nil, createdAt: Date())
        #expect(GroupingSweep.chainClusters(in: all, suppressions: [no]).isEmpty)
        // Once named, the umbrella takes it out of the candidate set.
        let proposal = GroupProposal(
            id: UUID(), title: "Lagos trip", memberIDs: [passport.uuid!, flights.uuid!],
            memberTitles: [passport.title, flights.title], confidence: 0.8)
        #expect(GroupingSweep.apply(proposal, currentUserID: nil, in: context) != nil)
        #expect(GroupingSweep.chainClusters(in: TaskItem.fetchAll(in: context), suppressions: []).isEmpty)
    }

    @Test("The validator grounds every member in what was shown and bounds the title")
    func validator() {
        let shown = [snap("Book flights to Lagos"), snap("Pack for Lagos"), snap("Renew passport")]
        func judgment(
            _ together: Bool = true, confidence: Double = 0.9, title: String = "Lagos trip",
            members: [String] = ["book flights to lagos", "Pack for Lagos"]
        ) -> GroupJudgment {
            GroupJudgment(
                belongsTogether: together, confidence: confidence, outcomeTitle: title, memberTitles: members)
        }
        let ok = GroupingSweep.validated(judgment(), shown: shown)
        #expect(ok?.title == "Lagos trip")
        #expect(ok?.memberIDs == [shown[0].id, shown[1].id])
        // One invented member rejects the whole judgment — a phantom member is a wrong group.
        #expect(
            GroupingSweep.validated(judgment(members: ["Pack for Lagos", "Buy sunscreen"]), shown: shown)
                == nil)
        #expect(GroupingSweep.validated(judgment(members: ["Pack for Lagos"]), shown: shown) == nil)
        #expect(GroupingSweep.validated(judgment(false), shown: shown) == nil)
        #expect(GroupingSweep.validated(judgment(confidence: 0.4), shown: shown) == nil)
        #expect(GroupingSweep.validated(judgment(title: "Pack for Lagos"), shown: shown) == nil)
        #expect(GroupingSweep.validated(judgment(title: "a b c d e f g"), shown: shown) == nil)
        #expect(GroupingSweep.validated(judgment(title: "  "), shown: shown) == nil)
    }

    @Test("Accept writes the umbrella and its edges as one reversible entry; undo removes both")
    func acceptThenUndo() throws {
        let context = TestStore.makeContext()
        let flights = TaskItem(title: "Book flights to Lagos", category: "Travel", in: context)
        let pack = TaskItem(title: "Pack for Lagos", category: "Travel", in: context)
        let proposal = GroupProposal(
            id: UUID(), title: "Lagos trip", memberIDs: [flights.uuid!, pack.uuid!],
            memberTitles: [flights.title, pack.title], confidence: 0.8)
        let umbrella = try #require(GroupingSweep.apply(proposal, currentUserID: nil, in: context))
        let all = TaskItem.fetchAll(in: context)
        #expect(umbrella.title == "Lagos trip")
        #expect(umbrella.category == "Travel")
        #expect(flights.parentTaskID == umbrella.uuid)
        #expect(pack.parentTaskID == umbrella.uuid)
        #expect(umbrella.children(among: all).count == 2)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "grouped" }
        #expect(entries.count == 1)
        #expect(entries[0].isReversible)
        #expect(entries[0].taskUUID == umbrella.uuid)
        ChangeLogUndo.revert(entries[0], in: context)
        #expect(flights.parentTaskID == nil)
        #expect(pack.parentTaskID == nil)
        #expect(!TaskItem.fetchAll(in: context).contains { $0.title == "Lagos trip" })
        // Fewer than two live loose members: nothing is written.
        flights.complete()
        #expect(GroupingSweep.apply(proposal, currentUserID: nil, in: context) == nil)
    }

    @Test("Reject suppresses every member pair, and the prefilter honours it")
    func reject() {
        let context = TestStore.makeContext()
        let ids = [UUID(), UUID(), UUID()]
        let proposal = GroupProposal(
            id: UUID(), title: "Lagos trip", memberIDs: ids, memberTitles: ["a", "b", "c"], confidence: 0.8)
        GroupingSweep.reject(proposal, in: context)
        let loaded = SuppressionStore.load(in: context, existingTaskIDs: Set(ids))
        #expect(loaded.filter { $0.kind == .siblingGroup }.count == 3)
        #expect(loaded.contains { $0.suppressesPair(kind: .siblingGroup, ids[2], ids[0]) })
        let snaps = ids.map { OpenTaskSnapshot(id: $0, title: "Lagos thing", category: "Travel") }
        #expect(GroupingSweep.clusters(among: snaps, suppressions: loaded).isEmpty)
        // The veto is one reversible trail entry; undoing it lifts every pair at once.
        let entries =
            (try? context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")))?
            .filter { $0.action == GroupingSweep.rejectedAction } ?? []
        #expect(entries.count == 1)
        #expect(entries.first?.isReversible == true)
        ChangeLogUndo.revert(entries[0], in: context)
        let lifted = SuppressionStore.load(in: context, existingTaskIDs: Set(ids))
        #expect(lifted.filter { $0.kind == .siblingGroup }.isEmpty)
        #expect(GroupingSweep.clusters(among: snaps, suppressions: lifted).count == 1)
    }
}
