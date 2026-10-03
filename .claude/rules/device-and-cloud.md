---
paths:
  - "Project-Ezra/{AppDelegate,SceneDelegate}.swift"
  - "Project-Ezra/AI/{AppCheckSetup,GeminiProvider}.swift"
  - "scripts/**"
  - "Project-Ezra/*.entitlements"
---

<!-- Moved verbatim from CLAUDE.md on 2026-10-02 (lossless move). Loads only when Claude reads a matching file. Change a rule here AND in docs/decisions.md. -->

## Device notes

- **The cloud rung is inert until Firebase is configured** (`AppDelegate` → `FirebaseApp.configure()`; the unit-test host skips it). **App Check's client half is wired; the console half is not — deadline 2026-11-02.** `AppCheckSetup.install()` runs BEFORE `configure()` (after is accepted silently and fails at the first token). App Attest on device with a DeviceCheck fallback; the App Attest entitlement is deliberately ABSENT until the App ID capability is on (adding it first breaks signing). `AppCheckSetup.statusLine()` counts down in the diagnostics card.
- `GoogleService-Info.plist` is gitignored; it sits in the synchronized group and needs no pbxproj entry.
- **Device signing carries the iCloud container since 2026-09-17** (`xcodebuild -destination id=<phone> -allowProvisioningUpdates` from a clean `main` signs with `iCloud.amanze-studios.Project-Ezra` in the entitlements and installs). Before the App ID had the capability it answered *No Accounts* / *profile doesn't support the iCloud Identifier*, and a failed signing step leaves a HALF-SIGNED bundle in the shared DerivedData that every later install trips on (`0xe8008001 integrity could not be verified` — this masqueraded as a locked phone for an hour on 2026-09-12); `scripts/device-evals.sh` builds into an isolated `-derivedDataPath` for that reason.
- **The phone must not auto-lock for the length of a device eval** (Settings ▸ Display & Brightness ▸ Auto-Lock ▸ Never): a suspended run keeps its process and its report freezes mid-file. Both device harnesses print a heartbeat per judgment so a stalled count can be told from a slow one.
- Owner-only steps live in `TODO.md`.
