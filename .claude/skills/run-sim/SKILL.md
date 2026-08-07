---
name: run-sim
description: Build Project Ezra for the iOS 27 simulator, install, launch, and screenshot. Use when asked to run the app, check a change in the simulator, or capture a screen. Supports seeding sample data and choosing a starting tab.
---

# Run Project Ezra in the simulator

The reliable loop for building and visually verifying this app. Requires the **Xcode 27 toolchain** (see CLAUDE.md — the build fails under Xcode 26).

## Steps

1. **Confirm the toolchain** (once per session):
   ```bash
   xcodebuild -version    # expect Xcode 27.x
   ```
   If it shows 26.x: `sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer` (needs the user's password — ask them to run it via `! ...`).

2. **Build** for the iOS 27 simulator:
   ```bash
   xcodebuild -project Project-Ezra.xcodeproj -scheme Project-Ezra \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
     -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
   ```
   Fix compile errors one cycle at a time before moving on.

3. **Install & launch.** Boot the iOS 27 `iPhone 17 Pro`, then:
   ```bash
   SIM="iPhone 17 Pro"; BID="amanze-studios.Project-Ezra"
   xcrun simctl bootstatus "$SIM" -b 2>/dev/null || true
   APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Project-Ezra.app" -path "*Debug-iphonesimulator*" | head -1)
   xcrun simctl terminate "$SIM" "$BID" 2>/dev/null || true
   xcrun simctl uninstall "$SIM" "$BID" 2>/dev/null || true    # clean state; omit to keep data
   xcrun simctl install "$SIM" "$APP"
   xcrun simctl launch "$SIM" "$BID"        # add launch args below as needed
   open -a Simulator
   ```
   Make sure the resolved simulator is the **iOS 27.0** one (`xcrun simctl list devices available | grep -A5 "iOS 27"`); there are same-named devices under iOS 26.

4. **Screenshot** into the scratchpad and Read it back:
   ```bash
   xcrun simctl io "$SIM" screenshot /tmp/ezra-shot.png
   ```

## Launch arguments (verification seams)

Append to the `simctl launch` line:
- `-SeedSampleData` — populate real tasks via the AI engine and skip onboarding (the sim uses the heuristic engine; Foundation Models isn't available there).
- `-SeedFlowFixtures` — populate deterministic fixture data covering every core user flow except onboarding (Daily Brief, Needs Decision Resolution, Weekly Retro, Dependency Chain Resurfacing), bypassing the AI engine so results are exact and identical every run. See `docs/mock-data-user-flows.md` for what each fixture produces.
- `-InitialTab N` — start on tab N: `0` Today, `1` Inbox, `2` My Tasks, `3` Household.
- `-OpenCapture ["text"]` — present the capture composer at launch; with a text argument it parks + resumes that text, driving the live parse loop so the results are screenshot-observable.

Example — land on the seeded My Tasks surface:
```bash
xcrun simctl launch "$SIM" "$BID" -SeedFlowFixtures -InitialTab 2
```

Example — land on Today with the full flow-fixture set:
```bash
xcrun simctl launch "$SIM" "$BID" -SeedFlowFixtures -InitialTab 0
```

## Notes

- Synthetic AppleScript taps are blocked by macOS Accessibility here — drive screen state with the launch args above, not scripted clicks.
- To reset to a clean first-run (onboarding) state: `xcrun simctl uninstall "$SIM" "$BID"`.
