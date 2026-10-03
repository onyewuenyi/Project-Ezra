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
   If it shows 26.x: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (needs the user's password — ask them to run it via `! ...`).

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
   # TWO traps, both of which silently install a binary that isn't yours:
   # 1. The indexer builds its own copy of the .app WITHOUT a bundle ID, so exclude
   #    Index.noindex (installing it fails with "Missing bundle ID").
   # 2. `find` returns TRAVERSAL order, not time order — and a second DerivedData root
   #    (a git worktree build, an old checkout) will happily win. Sort by mtime and
   #    take the newest. This has cost a full round of "verifying" the old UI.
   APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Project-Ezra.app" \
     -path "*Build/Products/Debug-iphonesimulator*" -not -path "*Index.noindex*" \
     -exec ls -dt {} + | head -1)
   echo "installing: $APP"   # read this line; it is the cheapest guard against trap 2
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
- `-SeedSampleData` — populate real tasks via the AI engine and skip onboarding (the sim runs the real on-device model when the host's Apple Intelligence is on — read the DEBUG footer; it degrades to the heuristic engine otherwise).
- `-SeedFlowFixtures` — populate deterministic fixture data covering the core user flows (Needs Decision resolution, a dependency chain, owned tasks), bypassing the AI engine so results are exact and identical every run.
- `-InitialTab N` — a no-op since 2026-09-02: there is no tab bar. Since 2026-09-23 **Ask is the home** (`RootTabView` shows `HouseholdChatView` at the root of one `NavigationStack`, the orb in its composer bar) and the Tasks list is a SHEET behind the header's list button: `-OpenTasks` presents it (the shell also presents it unasked for `-OpenTaskDetail`, the filters, `-DeckPage` and the grouping seams), `-DismissTasksAfter N` closes it again. A FRESH install on a seeded shared household shows the "Since you last looked" line under the day answer. `-AskHousehold "question"` / `-HouseholdChatFixture` act on the home. The Activity screen is reachable with `-OpenActivity`.
- `-OpenCapture ["text"]` — present the capture composer at launch; with a text argument it parks + resumes that text and auto-submits (add `-NoSubmit` to hold the canvas). A BARE `-OpenCapture` lands on the listening orb — or the typed canvas wherever the mic can't lead, which on the sim (no SpeechTranscriber) proves the degrade chain for free.
- `-HoldListening` — hold the Ramble arc on the Listening beat without starting the mic, so the listening surface is screenshot-reachable. Pair with a bare `-OpenCapture`.
- `-DriveListeningLevel` — `-HoldListening` plus a canned reception-test envelope (silence → whisper → conversational → emphatic → pause) fed to the level monitor: record video of this run to judge the audio-reactive orb with no microphone.
- `-HoldUnderstanding` — hold the arc on the thinking orb instead of parsing. Pair with `-OpenCapture "text"`.
- `-OpenTaskDetail [N]` — open the full-screen detail pager on the Nth visible row. 
- `-OpenAdvisorChat` — present the Advisor chat sheet over the opened detail; add `-ChatFixture` to seed a canned thread (question · answer · reply in flight) so the surface is reviewable with no model; or `-AskAdvisor "question"` to send one live question. Pair with `-InitialTab 1 -OpenTaskDetail 0`.
- `-AskHousehold "question"` sends one question through the live store (floor questions answer with rows even with no model — try `"What's overdue?"` with `-SeedFlowFixtures`; `-SeedTodayFixtures` went with the Brief); `-HouseholdChatFixture` seeds a canned thread. `-HouseholdChatEval -EvalToFile` writes the eval report to the app container's Documents.
- `-OpenAsk` — a no-op since 2026-09-23: a bare launch IS the Ask home (the day answer + glance strip, or the nothing-to-ask state on an empty store). On a FRESH install pre-grant the mic first or the permission alert covers the sheet: `xcrun simctl privacy <udid> grant microphone amanze-studios.Project-Ezra`.
- The calm home (2026-09-23): a bare seeded launch shows the hero + three rows and the news line; the counts strip lives on the Tasks sheet now (`-OpenTasks`), and the suggestions sit under the field.
- `-HomeHour N` — move the home's clock to that hour today (`-HomeHour 20` for the evening voice and recap; `-HomeHour 8` for the morning lead).
- `-OpenSearch ["query"]` — present search over the Tasks sheet, optionally prefilled.
- **Fresh-install trap:** `simctl spawn <udid> defaults write <bundle> hasOnboarded …` lands in the simulator's shared prefs and survives `uninstall`; `defaults delete` it to see real onboarding.
- `-PressHomeVerb` — complete the hero's task through the row's seam 1.5 s after the answer seats (2026-09-25): record with `xcrun simctl io <udid> recordVideo` and tile with `ffmpeg -vf "fps=12,scale=200:-1,tile=6x4" -frames:v 1` to judge the advance; a still at +1.9 s shows the hold, at +3 s the re-seated answer with the undo pill above the bar.
- `-TasksPreset overdue|dueToday|inProgress|waiting|decisions|done` — open the Tasks sheet the way a glance-strip count does (Everyone scope, the attention or status filter set and named in the capsule). The strip's tap is blocked here; this is the only way to the filtered state.
- `-DraftAsk "text"` — prefill the Ask home's field (Send appears inside the pill beside the orb).
- `-SendAsk "text"` — send a line through the PERSON's path on the home; a to-do-shaped line ("call the dentist tomorrow") shows the capture offer, a question answers as usual.
- `-FocusAsk` — raise the Ask home's keyboard at launch (with the Simulator's hardware keyboard OFF: `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`, then restart Simulator) to check the composer and the orb against it. NOTE: two devices named "iPhone 17 Pro" (iOS 26.4 and 27.0) may both be booted; `simctl launch` by NAME then hangs — use the iOS 27 device's UDID.

Example — land on the seeded Tasks list:
```bash
xcrun simctl launch "$SIM" "$BID" -SeedFlowFixtures -OpenTasks
```

Example — land on Tasks with the full flow-fixture set:
```bash
xcrun simctl launch "$SIM" "$BID" -SeedFlowFixtures
```

## Notes

- Synthetic AppleScript taps are blocked by macOS Accessibility here — drive screen state with the launch args above, not scripted clicks.
- To reset to a clean first-run (onboarding) state: `xcrun simctl uninstall "$SIM" "$BID"`.
