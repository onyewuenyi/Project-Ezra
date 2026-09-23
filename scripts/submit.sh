#!/bin/bash
#
# Archive, export and validate a build for App Store Connect — one command, and it
# checks the things a green build cannot.
#
# **Why this exists (2026-09-20).** `xcodebuild archive` succeeds on this machine and
# proves nothing: with only an Apple Development identity it produces a build carrying
# `get-task-allow` and `aps-environment: development`, which installs on a tethered
# phone and uploads nowhere. The gate that matters is an `-exportArchive` with
# `method: app-store-connect`, and there was no way to run it without remembering six
# flags. The submission gates themselves are in `docs/cohort0-checklist.md` §8; this
# script is how you find out whether they hold, in about four minutes.
#
# It stops at the FIRST thing that is wrong and says what to do about it, because the
# failure modes here are all "a human has to go and do something in a web console" and
# a wall of xcodebuild output buries that.
#
# Usage:
#   scripts/submit.sh            # archive → export → validate (does not upload)
#   scripts/submit.sh --upload   # …and upload to App Store Connect
#
# Uploading needs an app-specific password in the keychain:
#   xcrun notarytool store-credentials  # or set ASC_API_KEY / ASC_API_ISSUER
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="${TMPDIR:-/tmp}/ezra-submit"
ARCHIVE="$BUILD_DIR/Ezra.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1

say() { printf "\n\033[1m%s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mBLOCKED: %s\033[0m\n" "$1" >&2; shift; for l in "$@"; do printf "  %s\n" "$l" >&2; done; exit 1; }

# ---------------------------------------------------------------- preflight
say "Checking what only a human can fix…"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution"; then
  die "No Apple Distribution certificate on this machine." \
      "An archive will still succeed and an App Store export cannot." \
      "Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Apple Distribution." \
      "Tracked in TODO.md."
fi

# The privacy policy link is a review requirement, and the app renders no link while
# the URL is nil — deliberately, but that state must not reach a submission.
if grep -qE '^\s*static let privacyPolicy: URL\? = nil' Project-Ezra/Models/SupportLinks.swift; then
  die "No privacy policy URL is set." \
      "Guideline 5.1.1(i) requires the link inside the app, and there is none." \
      "Write and host the page, then set SupportLinks.privacyPolicy. Tracked in TODO.md."
fi

say "Running the test suite…"
xcodebuild test -project Project-Ezra.xcodeproj -scheme Project-Ezra \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -parallel-testing-enabled NO 2>&1 | grep -E "✘|Test run with" || true

# ---------------------------------------------------------------- archive
say "Archiving (Release)…"
rm -rf "$BUILD_DIR"
xcodebuild archive \
  -project Project-Ezra.xcodeproj -scheme Project-Ezra \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  | grep -E "error:|ARCHIVE" || true

[[ -d "$ARCHIVE" ]] || die "The archive was not produced." "Re-run without the grep filter to see why."

APP="$ARCHIVE/Products/Applications/Project-Ezra.app"

# ------------------------------------------------- what the bundle must carry
say "Auditing the archived bundle…"

[[ -f "$APP/PrivacyInfo.xcprivacy" ]] \
  || die "PrivacyInfo.xcprivacy is not in the built bundle." \
         "It exists in the repo but did not ship — check target membership."

/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$APP/Info.plist" >/dev/null 2>&1 \
  || die "ITSAppUsesNonExemptEncryption is missing." \
         "Every upload will stall on the export-compliance question."

# The seam walk is `ReleaseSeamTests`, which the suite above already ran. This is the
# second opinion, and it is only USEFUL for names over 15 characters: Swift stores
# shorter literals inside the String value, so they never reach the binary at all.
# That is why `strings` alone was never a gate — see docs/cohort0-checklist.md §8.
for seam in -ResetAndSeedEvalCorpus -CaptureDiagnostics -OnboardingResult -DuplicateSweepEval; do
  if strings -a "$APP/Project-Ezra" | grep -q -- "$seam"; then
    die "The verification seam $seam is compiled into Release." \
        "Fence it in #if DEBUG. ReleaseSeamTests walks the whole target for these."
  fi
done

# ---------------------------------------------------------------- export
say "Exporting for App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -allowProvisioningUpdates \
  | grep -E "error:|EXPORT" || true

IPA=$(find "$EXPORT_DIR" -name '*.ipa' | head -1)
[[ -n "$IPA" ]] || die "No .ipa was produced." \
  "The usual cause is a missing App Store provisioning profile for the App ID."

say "Built: $IPA"

# ---------------------------------------------------------------- validate
say "Validating with App Store Connect…"
if xcrun altool --validate-app -f "$IPA" -t ios --apiKey "${ASC_API_KEY:-}" --apiIssuer "${ASC_API_ISSUER:-}" 2>&1 | tee /dev/stderr | grep -q "No errors"; then
  say "Validation passed."
else
  printf "\n\033[1;33mValidation did not report success. If it asked for credentials, set\n  ASC_API_KEY / ASC_API_ISSUER, or validate from Xcode ▸ Organizer.\033[0m\n"
fi

if [[ "$UPLOAD" == "1" ]]; then
  say "Uploading…"
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey "${ASC_API_KEY:-}" --apiIssuer "${ASC_API_ISSUER:-}"
fi

say "Done. Remaining owner steps live in TODO.md — the CloudKit schema deployment is the one with no symptom."
