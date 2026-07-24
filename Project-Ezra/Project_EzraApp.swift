//
//  Project_EzraApp.swift
//  Project-Ezra
//
//  Managing Chaos, Effortlessly — an AI-managed personal task system.
//

import CoreData
import SwiftUI

@main
struct Project_EzraApp: App {
    /// One AppBrain for the whole app: owns engine selection + processing state.
    @State private var brain = AppBrain()
    @Environment(\.scenePhase) private var scenePhase

    let container: NSPersistentContainer = {
        // Bump whenever a model change alters the *meaning* of stored data (renamed
        // enum raw values, repurposed fields), not just its shape. Core Data has no
        // lightweight path for a meaning change here, so this deterministic reset is the
        // clean-break policy. Generation 2 = the status/priority/flags redirect;
        // Generation 3 = the multi-user ownership inversion (`ownerID == nil` flips from
        // "you" to "shared"); Generation 4 = the SwiftData → Core Data + CloudKit swap;
        // Generation 5 = the attention-surface → Today-sequence redirect (adds the
        // `CapacityLog` entity; retro/attention data retired). Generation 6 = the Linear
        // redesign (adds TaskItem `stageRaw`/`creatorID` + ChangeLogEntry `actorID` — the
        // stage sub-state, task authorship, and human-actor attribution for the Inbox
        // feed). Generation 7 = the attention-substrate redirect: retires user-facing
        // Priority (drops TaskItem `priorityRaw`/`parentTaskID`/`blockersData`) for the
        // `isUrgent`/`isPinned` signals + a persisted `attentionData` score and a
        // `relationshipsData` graph blob (absorbing blockers + parent edges), plus a
        // `workIntentRaw` classification. Generation 8 = retires the Pinned signal
        // (drops TaskItem `isPinned`), leaving `isUrgent` as the only user Signal — a
        // manual float-to-top override competed with the computed attention score.
        // Generation 9 = the relevance + suppression substrate: TaskItem gains the
        // deferral/engagement facts (`deferralCount`/`carriedOverCount`/`lastSurfacedAt`/
        // `lastUnblockedAt`/`lastHumanTouchAt`), `relationshipsData` moves to v2
        // (`Origin` replaces provenance+confidence; dismissed tombstones leave the
        // type for the pair-owned suppression store), and two entities land —
        // `SuppressionRecord` and `EmbeddingCache`.
        // Wipes existing stores, TestFlight users included — accepted under the
        // clean-break policy.
        let schemaGeneration = 9
        let generationKey = "appSchemaGeneration"
        if UserDefaults.standard.integer(forKey: generationKey) != schemaGeneration {
            PersistenceStack.destroyStore()
            UserDefaults.standard.set(schemaGeneration, forKey: generationKey)
        }

        let container = PersistenceStack.makeContainer()
        container.loadPersistentStores { _, error in
            if let error {
                // Container-open failure on an incompatible shape change: self-heal by
                // resetting the store and retrying once.
                PersistenceStack.destroyStore()
                container.loadPersistentStores { _, retryError in
                    if let retryError {
                        fatalError("Could not load the store even after reset: \(retryError)")
                    }
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return container
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(brain)
                .environment(\.managedObjectContext, container.viewContext)
                .preferredColorScheme(.dark)  // dark-first reads premium; matches the "quiet" thesis
                // Every foreground is a self-initiated open (the app sends no notifications).
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        brain.metrics.recordOpen()
                        // Hourly-debounced maintenance: the reversible stale auto-archive.
                        brain.runMaintenanceSweepsIfDue(in: container.viewContext)
                    }
                }
        }
    }
}
