# App Store Connect — the answers, derived

**What this is.** The App Store Connect fields that are *derived facts* rather than
marketing decisions, written down so they are answered from the code instead of from
memory at eleven o'clock on a submission evening.

**Why it exists (2026-09-20).** The privacy questionnaire is filled in by hand, in a web
form, and Apple checks it against `Project-Ezra/PrivacyInfo.xcprivacy`. A mismatch is a
rejection, and the two are edited months apart by the same person. Everything in §1 below
is a restatement of the manifest; if the manifest changes, this changes in the same
commit, and `SubmissionGateTests` fails if the two stop agreeing on the shape.

The marketing fields — name, subtitle, description, keywords, promotional text — are
deliberately NOT here. They are the owner's call and they are not derivable from code.

---

## 1. App Privacy — answer these from the manifest, not from memory

**"Do you or your third-party partners collect data from this app?" → Yes.**

**Tracking: No.** No advertising identifier, nothing joined with third-party data for
advertising or measurement. `NSPrivacyTracking` is false and the tracking-domain list is
empty. Answer **No** to every tracking question, including "Used for Tracking" on each
data type below.

Three data types, and every one of them is **Not Linked to You**:

| Data type | Category in the form | Purpose | Linked | Tracking |
|---|---|---|---|---|
| Product interaction | Usage Data | Analytics | No | No |
| Device ID | Identifiers | Analytics | No | No |
| Other User Content | User Content | App Functionality | No | No |

Notes for the three, in case the form asks for detail:

- **Product interaction** is the closed telemetry enum (`Models/Telemetry.swift`), whose
  every payload is an enum or a bucket — never a title, a name, a raw count or a
  duration, pinned by `TelemetryAllowlistTests`. There is an opt-out in Settings, and the
  whole sink is absent when no client key is configured.
- **Device ID** is the app's own anonymous install id, a UUID minted on first use and
  reset with the store. **It is not the IDFA and not the IDFV** — if the form offers
  "Device ID" under Identifiers, that is the right box; do not tick Advertising
  Identifier.
- **Other User Content** is a capture's raw words, and only when the router escalates a
  ramble to the cloud model so it can be read into tasks. Audio never leaves the device.
  Corrections and history never leave. The on-device posture keeps even this on the phone.

**Required-reason API:** `UserDefaults`, reason **CA92.1** (the app reads and writes only
its own defaults). Already declared in the manifest; nothing to enter in the form.

## 2. The mechanical fields

| Field | Value | Where it comes from |
|---|---|---|
| Bundle ID | `amanze-studios.Project-Ezra` | `PRODUCT_BUNDLE_IDENTIFIER` |
| Version | `1.0` | `MARKETING_VERSION` |
| Build | `1` | `CURRENT_PROJECT_VERSION` — bump deliberately; the export does not manage it |
| Category | Lifestyle | `INFOPLIST_KEY_LSApplicationCategoryType` |
| Devices | iPhone **and iPad** | `TARGETED_DEVICE_FAMILY = 1,2` — iPad screenshots are therefore required |
| Minimum OS | iOS 27.0 | `IPHONEOS_DEPLOYMENT_TARGET` |
| Encryption | No non-exempt encryption | `ITSAppUsesNonExemptEncryption` — already answered in the binary, so the upload will not ask |
| Privacy policy URL | *not yet hosted* | `Models/SupportLinks.privacyPolicy` — must be the same URL |
| Support URL | *not yet hosted* | `Models/SupportLinks.support` — must be the same URL |

**Age rating.** Nothing in the app is rated content. The one thing to declare honestly is
that it does not contain user-generated content *shared with strangers*: household sharing
is invite-only, to people the owner names, in their own iCloud. Expect 4+.

**Sign in with Apple** does not apply — there are no accounts. **Account deletion**
(guideline 5.1.1(v)) does not apply for the same reason; the nearest thing is Settings ▸
Reset everything, which wipes local and identity data and is reachable in two taps.

## 3. Screenshots

Required at the 6.9" iPhone size, and — because the app ships to iPad — at the 13" iPad
size too. Generate them rather than hand-collecting:

```bash
scripts/screenshots.sh
```

It drives the DEBUG launch seams (`docs/cohort0-checklist.md` lists them all) so the same
six states are captured on every device, in a known order, from a seeded store.

## 4. What is still owed before any of this can be submitted

These live in `TODO.md` because none of them is code:

1. **Deploy the CloudKit schema to Production.** The one with no symptom — a distribution
   build talks to Production, where the schema has never existed. Run the app once with
   `-InitializeCloudKitSchema` first so Development matches the current model, then
   CloudKit Console ▸ the `iCloud.amanze-studios.Project-Ezra` container ▸ Schema ▸
   **Deploy Schema Changes** ▸ Production.

   **All fourteen record types must be there afterwards**, not just the four the household
   share carries — every entity in the private store mirrors, and a partial check is a
   gate that passes while sync is broken. `CloudKitSchemaListTests` keeps this list in
   step with the model and fails if an entity is added without updating it:

   ```
   CD_CapacityLog        CD_Capture             CD_ChangeLogEntry    CD_Correction
   CD_EmbeddingCache     CD_FamilyMember        CD_Household         CD_HouseholdAIContext
   CD_HouseholdMemory    CD_HouseholdSettings   CD_Invitation        CD_SuppressionRecord
   CD_TaskItem           CD_UserProfile
   ```
2. **An Apple Distribution certificate.** `scripts/submit.sh` stops on this and says so.
3. **Host the privacy policy and the support page** — both are written (`docs/privacy-policy.md`, `docs/support.md`); fill in the contact address, publish, then set `SupportLinks`.
4. **The name check** — App Store and trademark — before anything is public.
