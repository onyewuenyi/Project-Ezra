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

        // **BEFORE `configure()`, and the order is the whole point.** `configure()` is
        // what builds the App Check component and freezes its provider factory; setting
        // the factory afterwards is accepted silently, leaves the default in place, and
        // fails at the first token request with nothing wrong in the code you are
        // reading. App Check enforcement turns on for this project on 2026-11-02 and
        // cannot be turned back off — see `AppCheckSetup` for what installing it does and
        // does not do. Enforcement itself is a console setting, deliberately still off:
        // wire the client, prove one attested call serves, then enforce.
        AppCheckSetup.install()
        FirebaseApp.configure()
        return true
    }
}
