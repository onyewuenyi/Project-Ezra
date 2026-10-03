# Release

A successful `xcodebuild archive` proves nothing about submission. Read the product.

1. **Source checks:** `python3 scripts/ai/debug-fences.py <app sources>` (no launch-argument seam outside `#if DEBUG`; do not use `strings` for this, since Swift hides literals of 15 bytes or fewer); the test suite green.
2. **Archive a Release build:**
   `xcodebuild archive -scheme <S> -destination 'generic/platform=iOS' -archivePath <dir>/App.xcarchive -derivedDataPath <isolated dir>`
   If signing fails, stop: a failed signing step leaves a half-signed bundle in DerivedData that breaks later installs. Report precisely which certificate or profile is missing; that is an owner step.
3. **Audit the archive:** `scripts/ai/release.sh <App.xcarchive>` (it runs the bundle audit with your sources). Every FAIL is fixed before export. Read every WARN and either fix it or state why it does not apply.
4. **Check what only a human can check,** and list each as done or owed: privacy policy URL reachable from inside the app and in App Store Connect; the App Privacy answers in App Store Connect agree with the manifest; account deletion in-app if accounts exist; Sign in with Apple if third-party login exists; the review notes and a demo account if login is required; CloudKit schema deployed to Production; App Check / API keys restricted.
5. **Export and validate:** `xcodebuild -exportArchive -exportOptionsPlist <plist with method app-store-connect>` then `xcrun altool --validate-app` (or Xcode Organizer ▸ Validate). Validation errors are FAILs.
6. **Screenshots** from seeded state with a 9:41 status bar, at the sizes App Store Connect requires (6.9" iPhone, 13" iPad if shipped), captured through seams so they are reproducible.
7. **Upload is an outward act:** ask before uploading.

**Reply:** the audit output (FAIL/WARN counts and each resolution), validation result, the owner steps still owed, and the archive path.
