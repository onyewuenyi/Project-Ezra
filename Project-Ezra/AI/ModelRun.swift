//
//  ModelRun.swift
//  Project-Ezra
//
//  The one door every model call goes through.
//
//  Before this, each service repeated the same preamble (`guard onDeviceModelAvailable`)
//  and then diverged: the plan service raced a deadline and recorded typed diagnostics,
//  while the three detail services did neither and returned a bare `nil` that erased the
//  difference between "no model here" and "the model hung". This puts availability, the
//  deadline, cancellation, error labelling, and metrics in one place so a service is
//  reduced to what actually distinguishes it — its prompt and its parsing.
//
//  It is deliberately NOT a base class. The shared surface across today's callers is
//  exactly these five concerns; model choice, sampling, streaming and fallback have no
//  second caller yet, and a one-caller abstraction is the kind this codebase deletes. If
//  a service ever needs a different model or sampling config, this grows a config
//  parameter rather than being replaced.
//

import Foundation

enum ModelRun {

    /// Run a model operation with a deadline, mapping every outcome to a product state.
    ///
    /// Never throws: a capability card's job is to degrade, not to propagate errors into
    /// SwiftUI. Availability is checked FIRST and short-circuits before any session is
    /// constructed — which is also what keeps this a no-op under XCTest, since
    /// `onDeviceModelAvailable()` is false there by design.
    static func perform<T: Sendable>(
        _ feature: ModelFeature, deadline: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> ModelResult<T> {
        guard AppBrain.onDeviceModelAvailable() else { return .unavailable }
        let started = Date()

        do {
            let value = try await ModelDeadline.race(timeout: deadline, operation)
            ModelMetrics.shared.record(feature, .success, latencyMs: Self.elapsedMs(since: started))
            return .success(value)
        } catch is CancellationError {
            // The user left. Not a failure, and deliberately unrecorded: it says nothing
            // about whether the deadline is well chosen, which is what the metrics are for.
            return .cancelled
        } catch is ModelDeadline.Exceeded {
            ModelMetrics.shared.record(feature, .timedOut, latencyMs: Self.elapsedMs(since: started))
            return .timedOut
        } catch {
            // A cancelled task can surface as the operation's own error rather than a
            // clean `CancellationError`, so check before calling it a failure — otherwise
            // backing out of a page would log a phantom model failure.
            if Task.isCancelled { return .cancelled }
            let label = AppBrain.errorLabel(error)
            ModelMetrics.shared.record(
                feature, .failed(label), latencyMs: Self.elapsedMs(since: started))
            return .failed(label)
        }
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
