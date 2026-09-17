# TODO

Owner-only items — things the code cannot do for itself. Each one names the check that
proves it done, so a ticked box means the thing happened, not that it was started.

## Build is broken on this Mac since the 2026-09-17 Xcode update

- [ ] **Firebase `wwdc26-preview` no longer compiles against the updated iOS 27.0 SDK.**
      Xcode 27.0 (27A266a) as updated 2026-09-17 06:22 ships a FoundationModels where
      `Transcript.Segment.custom` became `.attachment`; the pinned Firebase commit `5d9b338`
      conforms four parts to `Transcript.CustomSegment` (`FirebaseAI/Sources/Types/Public/Part.swift`
      lines 356–394, under `#if compiler(>=6.4)`) and fails with `'CustomSegment' is not a
      member type of struct 'FoundationModels.Transcript'`. Nothing in the app references it.
      Upstream `wwdc26-preview` had no newer commit that day. Options, in order: (a) check
      https://github.com/firebase/firebase-ios-sdk/tree/wwdc26-preview for a commit after
      `5d9b338` and re-resolve; (b) fork the branch, replace the four `CustomSegment`
      conformances with the GA `AttachmentSegment` shape (or delete the block — the app
      sends no inline/file/code parts through the FM bridge), point `project.pbxproj`'s
      package reference at the fork. *Done when:* the simulator build command in `CLAUDE.md`
      prints **BUILD SUCCEEDED** from a clean `main`, and `-CaptureDiagnostics` still
      reaches the cloud rung on device.

## Kinly launch — after the 2026-09-12 landing (`docs/kinly-launch-plan.md`)

- [ ] **Register the iCloud container on the App ID — BEFORE anything else on this list,
      because no device build from `main` signs until it is done.** The sync flip added
      `iCloud.amanze-studios.Project-Ezra` to the entitlements; the team profile does not
      carry it, and from the CLI `xcodebuild -allowProvisioningUpdates` answers *No
      Accounts*. Xcode ▸ Signing & Capabilities on the target, signed in, regenerates the
      profile in one click (or the developer portal: App ID ▸ iCloud ▸ add the container).
      Until then `scripts/device-evals.sh` builds with the pre-iCloud entitlements into an
      isolated DerivedData — a workaround for evals, not a fix. *Done when:*
      `xcodebuild -destination 'id=<phone>' build` from a clean `main` prints
      **BUILD SUCCEEDED**, and `xcrun devicectl device install app` installs it.

- [ ] **Two-phone sitting for the CloudKit round trip.** Two signed-in iCloud phones: on
      one, Tasks ▸ … ▸ Manage household ▸ a member's … ▸ *Invite to share this household*,
      send the link; on the other, open the link, land in the household, confirm the tasks
      already assigned to that member arrive OWNED (no "which one are you?" when exactly one
      invitation is pending). Then complete one task on each phone and watch the trail on
      both. If device signing complains, register the iCloud container
      `iCloud.amanze-studios.Project-Ezra` on the App ID — Xcode ▸ Signing & Capabilities
      does it automatically. The simulator proves none of this (no iCloud account).
      *Done when:* the roster on the inviting phone reads **Joined** for that member.

- [ ] **Statsig console.** Create the project; drop the **client** key into
      `Project-Ezra/Info.plist` → `StatsigClientKey` (an empty value means no sink and
      nothing leaves; a `secret-` key is refused); create the three gates exactly as named —
      `kill_cloud_capture`, `kill_cloud_advisor`, `kill_weekly_digest` (each OFF: they are
      kill switches, and ON turns the thing off). *Done when:* the Settings diagnostics card
      reads `telemetry: on · sharing` and one event shows in the console.

- [ ] **The name check — App Store + trademark — before anything public.** Kinly is
      already a video-conferencing brand. The rename stays undone until this is answered
      either way; the code and copy say Ezra.
