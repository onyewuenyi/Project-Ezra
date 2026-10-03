# TODO

Owner-only items — things the code cannot do for itself. Each one names the check that
proves it done, so a ticked box means the thing happened, not that it was started.

## First internal TestFlight build — in this order (2026-09-30)

The app side is done: the participant's phone was fixed end to end (`docs/decisions.md`,
"The participant's phone is a first-class place"), and `scripts/submit.sh --internal`
skips the one gate internal testing does not need. What is left needs a person.

1. [ ] **Apple Distribution certificate** — Xcode ▸ Settings ▸ Accounts ▸ Manage
       Certificates ▸ + ▸ Apple Distribution. *Done when:* `security find-identity -v -p
       codesigning` lists it. (Detail in the App Store section below.)
2. [ ] **App Store Connect app record** for bundle id `amanze-studios.Project-Ezra`, named
       Ezra (the Kinly name check is still open). SKU anything; primary language English.
3. [ ] **App ID capabilities** (developer portal ▸ Identifiers): iCloud with the container
       `iCloud.amanze-studios.Project-Ezra`, Push Notifications, and **App Attest**. App
       Attest is owed before App Check enforcement on **2026-11-02** — once it is on, the
       `com.apple.developer.devicecheck.appattest-environment` entitlement can be added
       (adding it first breaks signing).
4. [ ] **CloudKit schema: initialize Development, then deploy to Production.** Run a DEBUG
       build on a device signed into iCloud with the launch argument
       `-InitializeCloudKitSchema` (Xcode ▸ Scheme ▸ Run ▸ Arguments); wait for
       `CLOUDKIT-SCHEMA ok` in the console. Then CloudKit Console ▸ the container ▸ Schema ▸
       **Deploy Schema Changes ▸ Production**. *Done when:* Production lists all fourteen
       `CD_*` record types (`docs/app-store-listing.md` §4). Skipping this is invisible:
       every tester syncs to nothing.
5. [ ] **Upload.** `scripts/submit.sh --internal --upload` (needs `ASC_API_KEY` /
       `ASC_API_ISSUER` — an App Store Connect API key), or Xcode ▸ Product ▸ Archive ▸
       Organizer ▸ Distribute App ▸ **TestFlight Internal Only**. Build 1 the first time;
       bump `CURRENT_PROJECT_VERSION` in both configurations before every later upload.
6. [ ] **Internal testers** — App Store Connect ▸ Users and Access: add the second person
       (an App Store Connect user on a DIFFERENT Apple ID), then TestFlight ▸ Internal
       Testing ▸ a group with both of you and the build.
7. [ ] **The two-phone sitting** (below), on TestFlight builds on BOTH phones — a link made
       by an Xcode-installed build lives in the Development environment and will not open
       in a Production one. Run the accept twice: once on a fresh install, once on a phone
       that already has tasks and a few household members. Watch Console.app ▸ the phone ▸
       subsystem `com.projectezra.app`, category `sync`: a `SCHEMA NOT DEPLOYED` line means
       step 4 did not take.

## Kinly launch — after the 2026-09-12 landing (`docs/kinly-launch-plan.md`)

- [x] **Register the iCloud container on the App ID — BEFORE anything else on this list,
      because no device build from `main` signs until it is done.** The sync flip added
      `iCloud.amanze-studios.Project-Ezra` to the entitlements; the team profile does not
      carry it, and from the CLI `xcodebuild -allowProvisioningUpdates` answers *No
      Accounts*. Xcode ▸ Signing & Capabilities on the target, signed in, regenerates the
      profile in one click (or the developer portal: App ID ▸ iCloud ▸ add the container).
      Until then `scripts/device-evals.sh` builds with the pre-iCloud entitlements into an
      isolated DerivedData — a workaround for evals, not a fix. *Done when:*
      `xcodebuild -destination 'id=<phone>' build` from a clean `main` prints
      **BUILD SUCCEEDED**, and `xcrun devicectl device install app` installs it.
      **Done 2026-09-17:** a clean `main` built for the phone from the CLI, the signed bundle's
      entitlements carry the container, and `devicectl device install app` installed it.

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

## App Store submission — the gates no build failure will ever mention (2026-09-20)

Found by archiving a Release build and reading the result rather than by reasoning about
it. Each of these is invisible to a green build and to the whole test suite.

- [ ] **Deploy the CloudKit schema to PRODUCTION. This is the one that breaks sync for
      every user on day one.** A development-signed build talks to the container's
      *Development* environment, which is the only place the schema has ever existed.
      TestFlight and the App Store use *Production*, where — until this is done — every
      record type is unknown, so every push fails and every device stays alone with its
      own store. Nothing in the app says so: sync degrades silently by design.
      CloudKit Console ▸ the `iCloud.amanze-studios.Project-Ezra` container ▸ Schema ▸
      **Deploy Schema Changes** ▸ Production. Re-deploy after EVERY `.xcdatamodel`
      version that adds a record type or field, because the schema freeze (generation 10)
      only promises the change is additive — it does not push it.
      *Done when:* the Production schema lists **all fourteen** record types — the full
      list is in `docs/app-store-listing.md` §4, kept in step with the model by
      `CloudKitSchemaListTests` — and a TestFlight build on two phones completes the round
      trip in the sitting above. **Not four.** This check named only the record types the
      household share carries until 2026-09-20, and it would have passed with ten missing:
      every entity in the private store mirrors, not just the shared ones.

- [ ] **An Apple Distribution certificate and an App Store provisioning profile.** This
      machine has exactly one signing identity, `Apple Development`, so `xcodebuild
      archive` succeeds and an App Store export cannot. The archive it produces carries
      `get-task-allow` and `aps-environment: development` — a build that can be installed
      on a tethered phone and uploaded nowhere. Xcode ▸ Settings ▸ Accounts ▸ Manage
      Certificates ▸ + ▸ Apple Distribution creates it.
      *Done when:* `security find-identity -v -p codesigning` lists an Apple Distribution
      identity, and `xcodebuild -exportArchive` with `method: app-store-connect` succeeds.

- [ ] **Host the privacy policy and the support page, then set `Models/SupportLinks.swift`.**
      **Hosting is wired (2026-10-01):** the repo is public, GitHub Pages is on, and
      `.github/workflows/pages.yml` publishes `docs/web` alone to
      `https://onyewuenyi.github.io/Project-Ezra/privacy.html` and `…/support.html` on
      every push to `main` that touches it — and REFUSES while either page still says
      `<CONTACT EMAIL>`. So the whole step is now: put the address in both markdown
      sources, `python3 scripts/render-pages.py`, merge, confirm both URLs load, then set
      the two constants and the same URLs in App Store Connect.
      **Both are WRITTEN** — `docs/privacy-policy.md` and `docs/support.md`, drafted from
      the manifest, `DataBoundary` and `Telemetry` so every claim is one the code already
      makes. Two things are left in each: fill in `<CONTACT EMAIL>`, and have the policy
      read by someone qualified if this ships beyond a research preview. **The HTML is
      generated and ready to host** — `docs/web/privacy.html` and `docs/web/support.html`,
      rebuilt from the markdown by `python3 scripts/render-pages.py`, which also warns
      while the contact placeholder is still there. Drop them on anything that serves
      static files, set both constants, and put the same two URLs in App Store Connect. Guideline 5.1.1(i) requires an app that collects data
      to link its privacy policy *from inside the app*, not only from the listing, and
      this app collects three things (`PrivacyInfo.xcprivacy`: product interaction, the
      anonymous install id, the raw words on an escalated capture). Both URLs are `nil`
      today, so the app renders no link — deliberately, because a 404 under "Privacy
      policy" is the first thing a reviewer taps.
      *Done when:* the Settings diagnostics line reads `links: ready`, and both links open
      from "What leaves this device".

- [ ] **The App Store Connect privacy answers must match `PrivacyInfo.xcprivacy`.** The
      nutrition-label questionnaire is answered by hand and is checked against the
      manifest; a mismatch is a rejection. The manifest declares no tracking, three
      collected types, all UNLINKED to identity, and one required-reason API
      (`UserDefaults`, CA92.1). Answer the questionnaire from the manifest, not from
      memory. *Done when:* the listing's privacy section says the same three things.
