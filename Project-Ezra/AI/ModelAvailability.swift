//
//  ModelAvailability.swift
//  Project-Ezra
//
//  The two questions every model seam asks before it does anything — *is there an
//  on-device model at all?* and *what do we call this failure?* — plus the typed error
//  the cloud provider throws when it is not configured. These lived inside the Brief's
//  plan service as an `AppBrain` extension; when the Brief was cut (2026-09-02) they
//  moved here, because they were never the Brief's — `ModelRun`, the Advisor, capture,
//  the sweeps and the inquiries all read them.
//
//  `onDeviceModelAvailable()` is hard-false under the unit-test host, deliberately: a
//  test that wants a model injects one.
//

import Foundation
import FoundationModels

/// The cloud provider's own two failures, distinct from `LanguageModelSession`'s so the
/// error label can say WHICH seam refused. (Renamed from `PlanGenerationError` when the
/// Brief was cut: it was never the plan's.)
enum ModelUnavailableError: Error {
    case unavailable
    case timedOut
}


extension AppBrain {
    static func errorLabel(_ error: Error) -> String {
        if let e = error as? ModelUnavailableError {
            switch e {
            case .timedOut: return "timedOut"
            case .unavailable: return "unavailable"
            }
        }
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize(_): return "exceededContextWindowSize"
            case .assetsUnavailable(_): return "assetsUnavailable"
            case .guardrailViolation(_): return "guardrailViolation"
            case .unsupportedGuide(_): return "unsupportedGuide"
            case .unsupportedLanguageOrLocale(_): return "unsupportedLanguageOrLocale"
            case .decodingFailure(_): return "decodingFailure"
            case .rateLimited(_): return "rateLimited"
            case .concurrentRequests(_): return "concurrentRequests"
            case .refusal(_, _): return "refusal"
            @unknown default: return "generationError"
            }
        }
        // iOS 27's model-level error vocabulary — a second surface the new session
        // APIs can throw from. Losing the case to a bare type name would blunt the
        // one diagnostic the footer exists to sharpen.
        if let m = error as? LanguageModelError {
            switch m {
            case .contextSizeExceeded(_): return "contextSizeExceeded"
            case .rateLimited(_): return "rateLimited"
            case .guardrailViolation(_): return "guardrailViolation"
            case .refusal(_): return "refusal"
            case .unsupportedCapability(_): return "unsupportedCapability"
            case .unsupportedTranscriptContent(_): return "unsupportedTranscriptContent"
            @unknown default: return "languageModelError"
            }
        }
        // An error from NEITHER public vocabulary. The bare type name was all this used
        // to report, which is how `[TodayPlan] tier onDevice failed: GenerativeError`
        // stood in the log as an unactionable fact: `GenerativeError` is not in the public
        // SDK at all — a private type leaking through the API — so there is no case to
        // switch on and the name alone says nothing about what went wrong.
        //
        // Carry the description too. It is the only channel an unmapped error has, and a
        // diagnostic that names a failure without describing it costs a device round-trip
        // per guess (the `unsupportedCapability` hunt is the worked example).
        let name = String(describing: type(of: error))
        let detail = String(describing: error)
        return detail.isEmpty || detail == name ? name : "\(name): \(detail)"
    }

    /// The current on-device model availability, as a short label for the footer.
    static func availabilityLabel() -> String {
        if AppBrain.isRunningUnderXCTest { return "test" }
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "deviceNotEligible"
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            @unknown default: return "unavailable"
            }
        @unknown default: return "unknown"
        }
    }

    // MARK: Prewarm

    /// Warm the on-device model while the Recap cover plays, so the first real
    /// generation isn't paying the cold model-load cost against the deadline. A no-op
    /// off-device / under tests. Fire-and-forget; the shared model load benefits the
    /// per-call session that runs moments later.
    static func prewarmTodayModel() { ModelWarmup.prewarmSharedSession() }

    /// Whether the on-device advisor is available right now (for the self-heal upgrade).
    static func todayAdvisorAvailable() -> Bool { onDeviceModelAvailable() }

    // MARK: Availability

    /// The shared on-device-model gate — the one predicate every on-device feature routes
    /// through (Today advisor, prewarm, decision framing, work-intent classification), so a
    /// change to the availability check happens in exactly one place.
    static func onDeviceModelAvailable() -> Bool { onDeviceAvailable() }

    private static func onDeviceAvailable() -> Bool {
        // Never probe Foundation Models under XCTest (the sim has no on-device model
        // and the probe can fault the beta sim's intelligence daemon under a heavy run).
        guard !AppBrain.isRunningUnderXCTest else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Cloud-rung availability — the installed provider's, whoever that is. The
    /// defensive ordering that used to live here (entitlement gate before touching the
    /// model, because constructing PCC unentitled traps the process) is now a
    /// documented requirement of `CloudModelProvider.isAvailable`, where it applies to
    /// every future provider rather than only this one.
    /// REACHABILITY, not configuration. A configured-but-failing provider used to keep
    /// the cloud tier at the head of the chain all day, so every Brief paid a doomed
    /// call before falling through to the on-device voice it was going to use anyway.
    private static func cloudAvailable() -> Bool { CloudModel.isReachable }

    // MARK: ChangeLog

}
