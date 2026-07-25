//
//  HouseholdSync.swift
//  Project-Ezra
//
//  The one compile-time gate for "is there anybody else's device in this graph?".
//  Mirrors the `PCCEntitlement.isGranted` precedent in `AI/TodayPlanService.swift`:
//  a single `false` constant that routing checks *before* it can do something that
//  only makes sense in a real multi-device household.
//
//  Why this exists: without sync, a task assigned to another member has nowhere to
//  go — they have no device in the graph. Two behaviors must therefore stay inert
//  until it flips (see `docs/task-model.md`, "The sync gate"):
//
//  1. `OwnerProposer`'s INFERRED non-self rungs (`.adjacency`, `.affinity`). The AI
//     must not infer a hand-off to someone unreachable. `.spoken` is deliberately
//     NOT gated — that is the user explicitly saying "ask Maya", it already ships,
//     and honoring their own words is never a black hole.
//  2. Today's ownership filter (`TodaySequenceModel.candidateTasks`). Single-device
//     installs keep every task in Today regardless of nominal owner, preserving the
//     pre-ownership behavior exactly, so nothing can silently vanish from execution.
//
//  Flipping this to `true` turns both on together, and is done in the same change
//  that enables CloudKit sharing (`PersistenceStack.cloudKitContainerID` + the
//  iCloud entitlement). It also gates the schema-freeze review — see the clean-break
//  budget note in the plan: the wipe-on-mismatch escape hatch closes the day this
//  becomes true.
//

import Foundation

enum HouseholdSync {

    /// Whether household data actually reaches other people's devices.
    ///
    /// `false` until CloudKit sharing is provisioned. Deliberately a compile-time
    /// constant rather than a runtime check: the point is that the gated code paths
    /// cannot run at all, not that they run and find nothing.
    static let isLive = false
}
