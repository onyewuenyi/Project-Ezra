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
    case breakdown
    case decisionFraming
    case workIntent
    /// The composer's live parse — the most-executed model call in the product, and
    /// (until this) the only one generating no evidence to tune its deadline with.
    /// Recorded at the `AppBrain.triage` seam, never per debounce cancellation.
    case captureTriage

    /// Short label for the diagnostics footer.
    var label: String {
        switch self {
        case .breakdown: return "breakdown"
        case .decisionFraming: return "framing"
        case .workIntent: return "workIntent"
        case .captureTriage: return "capture"
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
