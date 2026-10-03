//
//  AppDelegate.swift
//  Project-Ezra
//
//  The one piece of UIKit in the app, and it exists for exactly one reason: Firebase
//  wants to be configured once, at launch, before anything asks it for a model.
//
//  **Why a delegate rather than `App.init()`.** Firebase's own AI Logic sample configures
//  from `init()`, and for `FirebaseApp.configure()` alone that would work and cost one
//  fewer type. The delegate is here because the Firebase project this app points at has
//  messaging enabled, and every one of those surfaces (push registration, the APNs token
//  callback, notification opens) arrives through `UIApplicationDelegate` and nowhere
//  else. Adding the seam now is cheap; retrofitting it under a half-built push feature is
//  the sort of thing that gets done badly at 1am. If messaging never ships, this type is
//  three lines of dead weight and can collapse back into `init()`.
//
//  **Nothing else belongs in here.** This is not a second composition root. State, model
//  wiring, and scene lifecycle all live in `Project_EzraApp` and stay there — a delegate
//  that grows becomes the file where startup order goes to hide.
//

import FirebaseCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The test host must not configure Firebase. `GeminiProvider.isAvailable` answers
        // "is Firebase configured", so configuring it here would flip the cloud rung ON
        // for the whole suite: routing tests that assert the chain falls through to the
        // deterministic tail would instead attempt live Gemini calls — slow, billable,
        // network-dependent, and green or red depending on the wifi. The suite wants the
        // rung dormant, which is exactly what not configuring gives it.
        guard !Project_EzraApp.isHostingUnitTests else { return true }

        // The one notification's delegate, set before launch finishes so a cold-start tap
        // on the Sunday digest is delivered to it rather than dropped.
        WeeklyDigestScheduler.shared.install()

        // **BEFORE `configure()`, and the order is the whole point.** `configure()` is
        // what builds the App Check component and freezes its provider factory; setting
        // the factory afterwards is accepted silently, leaves the default in place, and
        // fails at the first token request with nothing wrong in the code you are
        // reading. App Check enforcement turns on for this project on 2026-11-02 and
        // cannot be turned back off — see `AppCheckSetup` for what installing it does and
        // does not do. Enforcement itself is a console setting, deliberately still off:
        // wire the client, prove one attested call serves, then enforce.
        // **Only when there is something to configure WITH (2026-09-20).**
        // `GoogleService-Info.plist` is gitignored, and `FirebaseApp.configure()` raises
        // an uncaught ObjC exception when it cannot find one — so a build from a clean
        // clone (a cloud session, a second machine, CI) crashed on launch, in both
        // configurations, with a stack that names Firebase and nothing that names the
        // missing file. The app is already designed for a dormant cloud rung: without
        // `configure()`, `GeminiProvider.isAvailable` is false, routing keeps every
        // capture on the device, and `DataBoundary` stops claiming anything is
        // transmitted. That is a correct build, not a broken one — so it should boot and
        // say so in the diagnostics card, not die.
        if FirebaseOptions.defaultOptions() != nil {
            AppCheckSetup.install()
            FirebaseApp.configure()
        }
        // Product telemetry — the ONE vendor the domain never names (`Telemetry` owns the
        // allowlist and the opt-out; `StatsigSink` is the only file importing the SDK).
        // Absent with no client key in Info.plist, so an unconfigured build sends nothing.
        Telemetry.sink = StatsigSink.make()
        return true
    }

    /// Names `SceneDelegate` so a tapped household share link has somewhere to land —
    /// `CKShare.Metadata` only ever arrives through a window-scene delegate. SwiftUI keeps
    /// hosting the `WindowGroup`; this only adds the delegate beside it.
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
