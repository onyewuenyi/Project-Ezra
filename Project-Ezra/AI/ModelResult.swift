//
//  ModelResult.swift
//  Project-Ezra
//
//  What a model call produced, in PRODUCT terms.
//
//  The states below are the ones a view actually has to render differently. Before this
//  existed, all four non-success cases collapsed into `nil` and then into `EmptyView()` —
//  so "there is no model on this device" and "the model timed out" looked identical, and
//  the second one silently ate the button the user had just tapped.
//
//  The split that matters: **absence is decided before rendering, failure after trying.**
//  `.unavailable` means the capability should never have drawn a button; `.timedOut` and
//  `.failed` mean it drew one, the user tapped, and we owe them a way to try again.
//  `.cancelled` is neither — the user left, and showing them anything would be noise.
//
//  Keeping this vocabulary here is also what stops `LanguageModelSession.GenerationError`
//  from leaking into SwiftUI: a view should never pattern-match a guardrail violation.
//

import Foundation

/// Which capability made the call. The metrics key, and the label in the DEBUG footer.
enum ModelFeature: String, CaseIterable, Sendable {
    /// The Task Advisor's one ambient reading — the judgment layer on task detail
    /// (absorbed the retired breakdown / decisionFraming / unstickNarration calls).
    /// Its timeout row is the re-entry tripwire for streaming + salvage.
    case taskAdvisor
    case workIntent
    /// The composer's live parse — the most-executed model call in the product, and
    /// (until this) the only one generating no evidence to tune its deadline with.
    /// Recorded at the `AppBrain.triage` seam, never per debounce cancellation.
    case captureTriage
    /// The Household surface's one-sentence status phrasing. The last call site to
    /// join the seam — it previously constructed its session directly, which meant
    /// no deadline (a cold model hung the narrative task indefinitely) and no metrics.
    case householdNarrative
    /// The existing-pair duplicate judge (`DuplicateSweep`) — background-tier,
    /// hard-capped per run; the metrics row is how a wrong floor gets caught.
    case duplicateSweep
    /// The one concrete first move offered under the CTA the moment the user taps
    /// Start — the execution system's activation-energy remover. Silence on any
    /// non-success; the button behaves identically without it.
    case kickoff
    /// Private Capture's single-thought FM read — device-only by construction (the
    /// mode never touches `CloudModel`). Recorded per capture: perceived
    /// capture-end→reveal latency and whether the speculative run was used.
    case privateCapture
    /// The Advisor chat — one reply per question the person asks inside a task
    /// (`InquiryService`, task scope). On-device only; recorded per turn, salvage
    /// counted apart from a clean success so the deadline is tuned on evidence.
    case advisorChat
    /// The household chat — the Ask tab's model arm (`InquiryService`, household scope). Floor
    /// answers never reach here: only questions the model actually took.
    case householdChat
    /// The boundary pass — the on-device model naming where each outcome begins inside a
    /// run-on that the deterministic read under-segmented (`OnDeviceSegmenter`). Recorded
    /// per attempt, so the arm's served ratio and its latency tail are readable before
    /// anyone argues about whether it should be on.
    case captureSegment
    /// The grouping sweep — the on-device model naming which loose tasks serve one
    /// outcome (`GroupingSweep`). Background-tier, capped; it PROPOSES, never writes.
    case groupingSweep
    /// The capture judge — the on-device model saying what ONE piece of a capture is:
    /// a task, several, or nothing to do (`CaptureJudge`). Recorded per call.
    case captureJudge

    /// Short label for the diagnostics footer.
    var label: String {
        switch self {
        case .taskAdvisor: return "advisor"
        case .workIntent: return "workIntent"
        case .captureTriage: return "capture"
        case .householdNarrative: return "narrative"
        case .duplicateSweep: return "dupSweep"
        case .kickoff: return "kickoff"
        case .privateCapture: return "privCapture"
        case .advisorChat: return "chat"
        case .householdChat: return "askChat"
        case .captureSegment: return "segment"
        case .groupingSweep: return "groupSweep"
        case .captureJudge: return "judge"
        }
    }
}

enum ModelResult<T: Sendable>: Sendable {
    case success(T)
    /// No usable model on this device (or under tests). An absence, not a failure —
    /// never surface it as an error, and never offer a retry for it.
    case unavailable
    case timedOut
    /// The caller went away (the page was swiped, the sheet dismissed). Render nothing.
    case cancelled
    /// The model answered, but unusably — a guardrail refusal, a decode failure, or
    /// output that sanitized down to nothing. Carries the typed label the diagnostics
    /// footer shows; `AppBrain.errorLabel` is the single mapping, not a second taxonomy.
    case failed(String)

    /// The value, if there is one. Views that only care about the happy path use this.
    var value: T? {
        if case .success(let value) = self { return value }
        return nil
    }

    /// Should the card offer "Try again"? Only for outcomes a retry could plausibly fix.
    /// Explicitly false for `.unavailable` (nothing to retry — there is no model) and
    /// `.cancelled` (the user chose to leave; re-offering is nagging).
    var isRetryable: Bool {
        switch self {
        case .timedOut, .failed: return true
        case .success, .unavailable, .cancelled: return false
        }
    }

    /// Transform the payload, preserving every non-success case exactly. Lets a service
    /// sanitize its output without restating the error handling.
    func map<U: Sendable>(_ transform: (T) -> U) -> ModelResult<U> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .unavailable: return .unavailable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .failed(let label): return .failed(label)
        }
    }

    /// The label used when a response arrives but carries nothing usable — e.g. a
    /// breakdown that sanitized below two steps. A successful call with a useless answer
    /// is a failure from the user's side, so it reads as one.
    static var noUsableOutput: String { "noUsableOutput" }
}
