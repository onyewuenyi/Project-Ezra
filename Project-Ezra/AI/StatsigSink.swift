//
//  StatsigSink.swift
//  Project-Ezra
//
//  The one file that knows the telemetry vendor exists.
//
//  `Telemetry` (`Models/Telemetry.swift`) owns the allowlist and the opt-out; this is the
//  conformance that puts an allowed event on the wire. Statsig rather than Firebase
//  Analytics — which is already linked — because the questions the research preview has
//  to answer are experiment-shaped (does the Advisor's advice move anything; does a
//  five-second silence window beat three) and kill-switch-shaped (turn a pillar's cloud
//  arm off from a console when a quota goes wrong), and Statsig is a control plane for
//  both where Firebase Analytics is a counter. `TelemetryAllowlistTests` pins that this
//  is the ONLY file importing the vendor, so a vendor change is one conformance.
//
//  **What the vendor is told about the person: an install id.** `StatsigUser(userID:)`
//  is `Telemetry.installID` — a UUID minted on first use — with `optOutNonSdkMetadata`
//  so the SDK's own device/session harvest is minimal, `disableCurrentVCLogging` so
//  screen names never ride along, and `logNetworkMetadata` off. No name, no email, no
//  iCloud identity, no household. The client key lives in `Info.plist` under
//  `StatsigClientKey` and is a CLIENT key by construction (`Statsig.initialize` refuses a
//  `secret-` prefix); with no key the sink is simply absent and nothing leaves.
//
//  The kill switches are read through `checkGateWithExposureLoggingDisabled`: a kill
//  switch is not an experiment, and logging an exposure for every routing decision would
//  turn the cheapest check in the app into an event stream.
//

import Foundation
import Statsig

final class StatsigSink: TelemetrySink {

    /// The Info.plist key holding the CLIENT SDK key. Absent or empty → no sink.
    static let infoPlistKey = "StatsigClientKey"

    /// Build the sink if this install is configured for one. Never throws, never blocks:
    /// initialization is asynchronous inside the SDK and events queue until it lands.
    static func make(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> StatsigSink? {
        guard let key = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
            !key.isEmpty, !key.hasPrefix("secret-")
        else { return nil }
        return StatsigSink(key: key, installID: Telemetry.installID(defaults: defaults))
    }

    private init(key: String, installID: String) {
        #if DEBUG
        let tier = StatsigEnvironment(tier: .Development)
        #else
        let tier = StatsigEnvironment(tier: .Production)
        #endif
        let user = StatsigUser(userID: installID, optOutNonSdkMetadata: true)
        let options = StatsigOptions(
            disableCurrentVCLogging: true,
            logNetworkMetadata: false,
            environment: tier,
            eventLoggingEnabled: true)
        Statsig.initialize(sdkKey: key, user: user, options: options) { _ in
            // A failed initialization is a vendor problem, not a product event: the SDK
            // keeps queued events for a retry, and there is nothing the app should do
            // differently because a dashboard is unreachable.
        }
    }

    func log(name: String, metadata: [String: String]) {
        Statsig.logEvent(name, metadata: metadata)
    }

    func isKilled(_ gate: String) -> Bool? {
        guard Statsig.isInitialized() else { return nil }
        return Statsig.checkGateWithExposureLoggingDisabled(gate)
    }
}
