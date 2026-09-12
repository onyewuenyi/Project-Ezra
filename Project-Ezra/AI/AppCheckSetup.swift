//
//  AppCheckSetup.swift
//  Project-Ezra
//
//  **The attestation that stops being optional on 2026-11-02.**
//
//  Firebase AI Logic accepts unattested requests today. On that date App Check
//  enforcement turns on for the project, it CANNOT be turned back off, and every request
//  arriving without a valid App Check token is refused outright. For this app that is not
//  a degraded rung — `GeminiProvider.isAvailable` would still answer true (Firebase is
//  configured; that is all it checks), so the cloud arm would keep being SELECTED and
//  keep failing, and every capture the router escalated would fall to the deterministic
//  tail while looking, from the inside, like a network problem. So this is a launch
//  blocker with a date on it (`docs/cohort0-checklist.md` §2), not a hardening task.
//
//  **Three things about the wiring are load-bearing, and each was a trap first.**
//
//  1. **Install BEFORE `FirebaseApp.configure()`.** `configure()` is what builds the App
//     Check component and freezes its provider factory. Setting the factory afterwards
//     is accepted silently, leaves the default in place, and the first token request
//     fails with nothing at all wrong in the code you are reading. There is no runtime
//     complaint to lead you there, which is exactly why it is stated here and asserted in
//     `AppCheckSetupTests` rather than left to the call order looking obvious.
//
//  2. **The simulator fence is `#if targetEnvironment(simulator)`, NOT `#if DEBUG`.**
//     App Attest requires real hardware and is unavailable on a simulator, so the
//     simulator needs the debug provider. But device runs are Debug too — Xcode's Run
//     action is Debug by default, and that is how this app is exercised on the phone — so
//     a `#if DEBUG` fence would hand the debug provider to the very device runs that are
//     supposed to be proving App Attest works. The distinction is the hardware, so the
//     condition is the hardware.
//
//  3. **The debug provider's token is a credential.** It prints once per simulator and
//     has to be registered in the Firebase console by hand; it is not committed, and it
//     is not logged anywhere this app writes to disk. Firebase prints it itself — we do
//     not copy it into our own diagnostics, where it would land in a report a person
//     might reasonably attach to a bug.
//
//  **Two things are deliberately NOT done here, and both are outside the code.**
//
//  *The App Attest entitlement is not in `Project_Ezra.entitlements`.* Adding
//  `com.apple.developer.devicecheck.appattest-environment` without first enabling the App
//  Attest capability on the App ID fails code signing outright — verified 2026-09-11:
//  *"Provisioning profile … doesn't include the App Attest capability"* — which would
//  break the device build this app is dogfooded on every day. The capability is one
//  toggle in Signing & Capabilities; until it is flipped, `AppAttestProviderFactory` below
//  falls through to **DeviceCheck**, which needs no entitlement, is a valid App Check
//  provider, and survives enforcement. So the un-upgraded state is attested and working
//  rather than broken — which is the whole reason the fallback is written as a fallback
//  and not as a nil return.
//
//  *Enforcement is not turned on.* It is a console setting, and the order matters: wire
//  the client, prove one attested call actually serves, and only then enforce. Enforcing
//  first blocks a working app with no local way to tell whether the client half was ever
//  right.
//

import FirebaseAppCheck
import FirebaseCore
import Foundation

enum AppCheckSetup {

    /// The date the project's enforcement turns on. Kept as a value rather than only in
    /// prose so the DEBUG diagnostics line can count down to it — a deadline nobody can
    /// see is a deadline nobody meets, and this one cannot be undone once passed.
    static let enforcementBegins = DateComponents(
        calendar: .init(identifier: .gregorian), timeZone: .init(identifier: "UTC"),
        year: 2026, month: 11, day: 2
    ).date ?? .distantFuture

    /// Which attestation this build will present. Named so the diagnostics card can say
    /// it without re-deriving the fence, and so a test can assert the fence is the
    /// hardware rather than the configuration.
    enum Provider: String {
        /// App Attest, falling back to DeviceCheck on hardware too old for it. Real
        /// devices only.
        case appAttest
        /// The console-registered debug token. Simulators only.
        case debug
    }

    static var provider: Provider {
        #if targetEnvironment(simulator)
        return .debug
        #else
        return .appAttest
        #endif
    }

    /// Install the provider factory. **Call this before `FirebaseApp.configure()`** — see
    /// the header; afterwards is a silent no-op that fails later and elsewhere.
    static func install() {
        switch provider {
        case .debug:
            // Prints its token on first launch. Register it once per simulator in the
            // console; it is a credential and belongs in neither the repo nor a log we
            // write.
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        case .appAttest:
            // The factory picks App Attest where the hardware supports it and falls back
            // to DeviceCheck where it does not, so one factory covers the fleet.
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        }
    }

    /// The DEBUG diagnostics line: which attestation this build presents, and how long is
    /// left before the project stops accepting anything else.
    ///
    /// A developer's line, in the card developer lines live in — it names a mechanism and
    /// a date, which is exactly what customer-facing copy may not do. It exists because a
    /// deadline that lives only in a header comment is a deadline nobody is counting, and
    /// this one is one-way.
    static func statusLine(now: Date = Date()) -> String {
        // Counted on the SAME clock the deadline is expressed in. A local calendar puts a
        // DST transition between here and November and makes the countdown disagree with
        // itself by a day depending on where the phone is.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let days = utc.dateComponents([.day], from: now, to: enforcementBegins).day ?? 0
        let when = days > 0 ? "enforced in \(days)d" : "ENFORCED"
        return "app check: \(provider.rawValue) · \(when)"
    }
}

/// The factory the device uses: App Attest where available, DeviceCheck beneath it.
///
/// Firebase ships its own App Attest factory, but that one returns nil where App Attest
/// is unavailable — which leaves such a device with NO provider rather than with the
/// weaker one. Unavailable covers two cases here, not one: hardware too old for App
/// Attest, and **any build whose entitlement is missing**, which is every build until the
/// capability is enabled on the App ID (see the header). Without the fallback the fleet
/// splits into attested devices and silently unattested ones, and after enforcement that
/// second group is simply broken.
final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app) ?? DeviceCheckProvider(app: app)
    }
}
