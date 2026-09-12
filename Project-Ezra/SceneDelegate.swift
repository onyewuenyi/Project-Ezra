//
//  SceneDelegate.swift
//  Project-Ezra
//
//  The second piece of UIKit in the app, for exactly one reason: a tapped CloudKit share
//  link arrives as `CKShare.Metadata` through `UIWindowSceneDelegate` and nowhere else —
//  SwiftUI's `onOpenURL` never sees it, because the system resolves the share before the
//  app is involved. Two entry points, both handing the metadata to `HouseholdSharing`:
//  the warm one (`userDidAcceptCloudKitShareWith`) and the cold launch, where the metadata
//  rides `connectionOptions`. `AppDelegate.application(_:configurationForConnecting:)`
//  names this class; SwiftUI keeps hosting the `WindowGroup`.
//
//  Like `AppDelegate`: nothing else belongs here.
//

import CloudKit
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in await HouseholdSharing.shared.accept(metadata) }
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in await HouseholdSharing.shared.accept(cloudKitShareMetadata) }
    }
}
