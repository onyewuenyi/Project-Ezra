//
//  HouseholdSync.swift
//  Project-Ezra
//
//  The one compile-time gate for "is there anybody else's device in this graph?".
//  Mirrors the compile-time gate precedent set by the cloud rung (`CloudModelProvider`,
//  whose `isAvailable` must answer from something cheap and local before anything
//  touches a model): a single `false` constant that routing checks *before* it can do
//  something that only makes sense in a real multi-device household.
//
//  Why this exists: without sync, a task assigned to another member has nowhere to
//  go — they have no device in the graph. Two behaviors must therefore stay inert
//  until it flips (see `docs/task-model.md`, "The sync gate"):
//
//  1. `OwnerProposer`'s INFERRED non-self rungs (`.adjacency`, `.affinity`). The AI
//     must not infer a hand-off to someone unreachable. `.spoken` is deliberately
//     NOT gated — that is the user explicitly saying "ask Maya", it already ships,
//     and honoring their own words is never a black hole.
//  2. Today's ownership filter (`BriefSequenceModel.candidateTasks`). Single-device
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
    /// **`true` since 2026-09-12** — flipped in the same change that set
    /// `PersistenceStack.cloudKitContainerID`, added the iCloud container to the
    /// entitlements, and shipped the invite flow (`HouseholdSharing`). It stays a
    /// compile-time constant rather than a runtime check: the gated paths (the inferred
    /// ownership rungs, the day answer's ownership filter, the publish boundary) now run
    /// unconditionally, and `SyncGateTests` had already exercised every one of them at
    /// `true` before the flip. The door it closed behind it: `schemaGeneration` is frozen
    /// (`Project_EzraApp.frozenSchemaGeneration`); every model change from here is a NEW
    /// version, never a wipe.
    static let isLive = true
}
