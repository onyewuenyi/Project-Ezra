//
//  ModelWarmup.swift
//  Project-Ezra
//
//  A shared prewarm seam for the on-device model, so a feature that's about to generate
//  (decision framing on detail-open, the Today advisor while the Recap plays) isn't
//  paying the cold model-load cost against its deadline. Fire-and-forget; a no-op
//  off-device / under tests. The shared `SystemLanguageModel` load benefits any per-call
//  session that runs moments later.
//

import FoundationModels

enum ModelWarmup {
    /// Warm the default on-device model. Safe to call repeatedly and from any surface —
    /// it only touches the model when Apple Intelligence is actually available.
    static func prewarmSharedSession() {
        guard AppBrain.onDeviceModelAvailable() else { return }
        LanguageModelSession().prewarm()
    }
}
