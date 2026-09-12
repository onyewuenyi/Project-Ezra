//
//  WeeklyDigestScheduler.swift
//  Project-Ezra
//
//  The notification-centre half of `WeeklyDigest`: permission, scheduling, and the open.
//
//  `refresh` is called wherever the week's shape can change — foreground, commit,
//  completion — and is idempotent: it composes the edition from the CURRENT store,
//  replaces the one pending request under `WeeklyDigest.identifier`, or removes it when
//  there is nothing to say / the digest is off / the kill switch is engaged. A request
//  scheduled Monday therefore describes the week as it stood at the LAST refresh before
//  Sunday 18:00, which for anyone using the app during the week is the week as it is.
//
//  Permission is asked ONCE, at the moment the household becomes shared (the owner
//  making an invite link; the invitee linking their identity) — the moment the person is
//  thinking about the other caretaker, and the only moment the product asks. A denial is
//  their opt-out; nothing asks again.
//
//  As the notification-centre delegate it does two things: suppresses the banner while
//  the app is already in the foreground (the person is here; the digest would be noise),
//  and records a tap so the next `.active` is NOT counted as a self-initiated open.
//

import Foundation
import UserNotifications

@MainActor
final class WeeklyDigestScheduler: NSObject, UNUserNotificationCenterDelegate {

    static let shared = WeeklyDigestScheduler()

    /// Set by `didReceive`, consumed by the app's `.active` handler.
    private var openedFromDigest = false
    /// Guards the one permission request.
    static let permissionAskedKey = "digest.permissionAsked"

    private override init() {
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Scheduling

    /// Recompose and reschedule (or remove). Never asks permission — a refresh with no
    /// grant simply schedules nothing, and `UNUserNotificationCenter` drops it silently.
    func refresh(
        tasks: [TaskItem], caretakerCount: Int, now: Date = Date(), defaults: UserDefaults = .standard
    ) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [WeeklyDigest.identifier])

        guard WeeklyDigest.isEnabled(caretakerCount: caretakerCount, defaults: defaults) else {
            Telemetry.log(.digestSkipped(reason: .optedOut))
            return
        }
        guard !Telemetry.isKilled(.killWeeklyDigest, defaults: defaults) else {
            Telemetry.log(.digestSkipped(reason: .killed))
            return
        }
        guard let digest = WeeklyDigest.compose(tasks: tasks, now: now) else {
            Telemetry.log(.digestSkipped(reason: .nothingToSay))
            return
        }

        let content = UNMutableNotificationContent()
        content.title = digest.title
        content.body = digest.body
        content.sound = nil  // a glance, not an alarm
        content.interruptionLevel = .passive

        let fire = WeeklyDigest.nextFireDate(after: now)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(
            UNNotificationRequest(identifier: WeeklyDigest.identifier, content: content, trigger: trigger)
        ) {
            error in
            if error == nil { Telemetry.log(.digestScheduled) }
        }
    }

    /// Ask once, at the moment the household became shared. Returns whether permission is
    /// held afterwards (so a caller can refresh immediately on a grant).
    @discardableResult
    func requestPermissionIfNeeded(defaults: UserDefaults = .standard) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            guard !defaults.bool(forKey: Self.permissionAskedKey) else { return false }
            defaults.set(true, forKey: Self.permissionAskedKey)
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            if !granted { Telemetry.log(.digestSkipped(reason: .noPermission)) }
            return granted
        @unknown default: return false
        }
    }

    // MARK: - Opens

    /// True exactly once after a digest tap, so the app can leave that foreground out of
    /// `selfInitiatedOpens`.
    func consumeNotificationOpen() -> Bool {
        defer { openedFromDigest = false }
        return openedFromDigest
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == WeeklyDigest.identifier else { return }
        await MainActor.run {
            openedFromDigest = true
            Telemetry.log(.digestOpened)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Already here: the record is on screen, so the digest has nothing to add.
        []
    }
}
