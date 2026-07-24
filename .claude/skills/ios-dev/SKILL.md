---
name: ios-dev
description: "Use this skill whenever working on iOS, iPadOS, or macOS (Catalyst/native) development. Triggers include writing SwiftUI views, building UIKit components, implementing Swift concurrency (including Swift 6.2 approachable concurrency, @concurrent, and main-actor-by-default), designing data models with SwiftData or CoreData, setting up navigation, creating custom UI components, adopting Liquid Glass / .glassEffect on iOS 26, adding animations, integrating Apple frameworks (Foundation Models on-device AI, HealthKit, StoreKit, CloudKit, CoreData, CoreLocation, etc.), reviewing or refactoring iOS code, architecting iOS app features, or using Xcode MCP tools to build, run, or debug an app. Also trigger when the user mentions Xcode projects, Swift packages, simulators, previews, performance, build errors, or any iOS-specific patterns like MVVM, TCA, or Combine. If the user is building anything for Apple platforms, use this skill, even for quick questions about APIs or patterns."
---

# iOS Development Skill

Claude tends to produce generic, "safe" iOS code - UIKit patterns when SwiftUI is more appropriate, vanilla state management when modern `@Observable` would be cleaner, and architectures that ignore Swift 6 concurrency. This skill corrects for that distributional convergence and produces idiomatic, modern Apple-platform code.

## Core Orientation

**Default assumption: iOS 26, SwiftUI, Swift 6.2 (approachable) concurrency.** As of 2026 the shipping OS is iOS 26 with Liquid Glass and the Xcode 26 toolchain. Treat **iOS 18 as the practical deployment floor** unless the project says otherwise, since it still covers nearly all active devices. Flag explicitly when an API requires a specific version, and provide an availability guard or fallback when the deployment target predates an API you want to use (Liquid Glass and several concurrency defaults are iOS 26 / Swift 6.2 only).

Before writing any code, establish:
- **iOS deployment target**: SwiftUI capabilities and the default visual language differ across iOS 18 vs 26 (Liquid Glass, mesh gradients, newer symbol effects). Ask if unclear.
- **Framework choice**: See UIKit vs SwiftUI section below
- **Data persistence**: SwiftData (iOS 17+) for new projects; CoreData for existing stacks or complex migration needs, see `references/frameworks.md`
- **Concurrency model**: Swift 6.2 approachable concurrency (main-actor-by-default, `nonisolated(nonsending)`, opt into background with `@concurrent`); `async/await` and `actors`; never raw `DispatchQueue` unless bridging legacy code. See the Swift Concurrency section.

## Agentic Dev Loop (Claude Code, terminal)

This skill runs inside Claude Code from the terminal. That means you have three tool layers; use the right one for each job rather than defaulting to any single surface:

- **Native Claude Code tools (Read, Edit, Write, Glob, Grep): your default for reading, editing, and searching Swift files.** They're faster and more direct than the Xcode MCP file tools, which are redundant here. Don't route file edits through `XcodeWrite`/`XcodeUpdate` when you have native Edit/Write.
- **Shell (Bash): the baseline for build, test, and run** via `xcodebuild`, `swift test`, and `xcrun simctl`. Always available, no IDE required. See the shell commands below.
- **Xcode MCP server (optional accelerator, if connected): for things the shell can't do well** structured build/test results, `RenderPreview` (visual UI verification), `DocumentationSearch` (Apple docs + WWDC), live diagnostics, and the `ExecuteSnippet` REPL. Prefer it for build/test feedback when present because the results are structured instead of raw log text.

Follow this loop for every change. Never skip steps; the most common agent failure is editing code before understanding the project.

**0. Read the project's agent context first**
Read `CLAUDE.md` (Claude Code loads it automatically) and/or `AGENTS.md` for repo-specific architecture, conventions, known gotchas, the scheme/simulator to use, and the exact build/test commands. This is the source of truth for *this* project; the skill is general iOS knowledge. If neither exists, ask the user for the scheme, deployment target, and how they build (plain `xcodebuild`, a Makefile, Tuist/XcodeGen, fastlane) before proceeding.

For a brand new project starting from an empty folder: initialize git immediately and commit as you go, including early, incomplete states, not just the final result. Keep a short running doc of intent alongside the code, not just outcomes: why a decision was made, not only what was built. This matters most across context compaction or multi-session work, where the code history alone won't explain why something looks the way it does.

**1. Inspect the project first**
Read the project structure, targets, schemes, and key dependencies before touching any file. Run `xcodebuild -list` to see schemes and targets. Understand what already exists.

**2. Locate relevant files**
Use Grep/Glob to find the specific files that need to change. Typical structure:
```
Views/          ViewModels/       Models/
Services/       Repositories/     Extensions/
```
Never edit `DerivedData/`, `build/`, or `.xcodeproj` internal files directly.

**3. Propose minimal changes**
Default to the smallest possible diff: single-file changes, additive edits. Avoid rewrites unless explicitly asked. State what you plan to change and why before doing it.

**4. Apply the change**
Edit the Swift code with the native Edit/Write tools. Verify SwiftUI view structure is valid, property wrappers are correct, and state management is consistent with the rest of the file. **If you create a new file, confirm it will actually be compiled into the target** (see "New files and the target" in Safety Rules) before relying on a build.

**5. Build immediately**
Build after every change. Don't batch multiple changes before building; it makes failures harder to isolate. Use the Xcode MCP `BuildProject` if connected, otherwise `xcodebuild` (below).

**6. Fix build failures methodically**
Read the full compiler error (`GetBuildLog`, or pipe `xcodebuild` through `xcbeautify`). Fix the minimal cause. Rebuild. Never guess at large structural changes to resolve an error; read the error, understand it, fix precisely. When unsure about an API or its availability on the target OS, use `DocumentationSearch` (or check docs) rather than guessing.

**7. Verify, including visually**
For UI changes, don't stop at "it compiles." If the Xcode MCP is connected, `RenderPreview` captures the actual SwiftUI `#Preview` as an image. From the shell, boot a simulator and capture a screenshot: `xcrun simctl io booted screenshot /tmp/shot.png`, then read that image back. Check layout at multiple text sizes (small + accessibility large) and in both light and dark. `ExecuteSnippet` is useful for validating a piece of logic without a full build.

**8. Run tests if available**
Run the relevant suite (`RunSomeTests`/`RunAllTests` via MCP, or `xcodebuild test` / `swift test`). Fix any tests broken by the change before moving on.

---

**Shell commands (the always-available path)**

```bash
# Discover schemes/targets
xcodebuild -list -project MyApp.xcodeproj    # or -workspace MyApp.xcworkspace

# Build for a simulator (pick a destination that exists: see `xcrun simctl list devices`)
xcodebuild -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' build | xcbeautify

# Test
xcodebuild -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' test | xcbeautify

# SwiftPM packages
swift build ; swift test

# Simulator control + screenshot for visual verification
xcrun simctl boot "iPhone 16"
xcrun simctl io booted screenshot /tmp/shot.png
```

`xcodebuild` output is extremely verbose; pipe through `xcbeautify` (or `xcpretty`) for readable results, and grep for `error:` to isolate failures. Prefer the Xcode MCP's structured build/test results when the server is connected.

---

**Xcode MCP (Apple's official server) - optional, setup and tool names**

Apple ships a built-in MCP server in Xcode 26.3+. It's optional for terminal work but worth connecting for structured build/test results and visual verification. Enable it in **Xcode → Settings → Intelligence → Model Context Protocol → Xcode Tools (ON)**, then register it with Claude Code: `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. Xcode must be running with the project open; the `mcpbridge` binary auto-detects it.

The server exposes ~20 tools. In a Claude Code terminal session, the file-system tools (`XcodeRead`/`XcodeWrite`/`XcodeGlob`/etc.) are redundant with your native Read/Edit/Glob/Grep, so the ones that actually earn their keep are the build, test, preview, docs, and diagnostics tools:

- **Workspace / context:** `XcodeListWindows` (returns each open window's `tabIdentifier` and `workspacePath`)
- **Build & test:** `BuildProject`, `GetBuildLog`, `RunAllTests`, `RunSomeTests`, `GetTestList`
- **Diagnostics:** `XcodeListNavigatorIssues`, `XcodeRefreshCodeIssuesInFile`
- **Intelligence:** `DocumentationSearch`, `RenderPreview`, `ExecuteSnippet`
- **File system (rarely needed in Claude Code):** `XcodeRead`, `XcodeWrite`, `XcodeUpdate`, `XcodeGlob`, `XcodeGrep`, `XcodeLS`, `XcodeMakeDir`, `XcodeRM`, `XcodeMV`

Two tools are easy to forget but high-leverage:
- **`DocumentationSearch`** queries Apple's full documentation corpus *and* WWDC transcripts with semantic search. Reach for it instead of guessing at an API signature or whether something is available on the target OS. This is the single best defense against hallucinated APIs.
- **`RenderPreview`** returns a real screenshot of a SwiftUI preview, so you can visually confirm a UI change rather than assuming it looks right.

**The `tabIdentifier` protocol.** Most tools require a valid `tabIdentifier`; never guess or hardcode one. At the start of a session call `XcodeListWindows` to discover open workspaces, then pass the matching `tabIdentifier` to subsequent calls:
```
XcodeListWindows
→ tabIdentifier: "windowtab1", workspacePath: "/Users/.../MyApp.xcodeproj"

BuildProject(tabIdentifier: "windowtab1")
RunAllTests(tabIdentifier: "windowtab1")
```

- **If a call fails because the tab is stale** (window closed or Xcode restarted), call `XcodeListWindows` again and retry with the refreshed identifier.
- **Multiple windows open:** match by `workspacePath`, not by position. Never assume `windowtab1` is the right project.
- **No windows returned:** ask the user to open the project in Xcode before proceeding.

Tool names and the exact set can change between Xcode releases. If a name here doesn't match what's actually exposed in the session, list the available tools and map by capability (list windows, build, run tests, render preview, search docs) rather than forcing these literal names. Fall back to filesystem inspection if the MCP project graph is incomplete.

## External Service Credentials

Some tasks need a cloud service that Foundation Models cannot cover: image generation for app icons, onboarding art, or App Store assets, for example. Do not block on this and do not ask the user to paste a key into chat. The working pattern: restricted, service-scoped API keys live in a local `.env` sourced by the shell profile, so terminal agents already have them in the environment.

When asked for a capability like "generate an app icon" or "use image gen" without a named provider:

1. Check the environment for a plausible key (`GEMINI_API_KEY`, `OPENAI_API_KEY`, and similar). If the user says keys are available, they mean the shell environment, not a file to go find and open.
2. Web search for the current state of small, fast image generation models rather than defaulting to whatever provider is most familiar from training data. Provider offerings, model names, and endpoints change often enough that a hardcoded choice will likely be stale or wrong.
3. Read the current docs (`web_search` and `web_fetch`; `DocumentationSearch` only covers Apple frameworks) before writing the integration code.
4. Not every image model handles transparency well. If the asset needs an alpha channel, an app icon mask or an overlay, check for that support specifically rather than assuming it.

**Safety:** never print, log, or echo the contents of a `.env` file or an API key value, even partially. Confirm the file is gitignored before any commit touches the repo. If no key is available, say so plainly rather than fabricating a call or silently skipping the feature.

## Safety Rules

These protect the project from hard-to-reverse mistakes:

- **New files and the target (read this before creating files from the terminal).** Creating `Foo.swift` on disk does not always add it to the build. It depends on how the project references files:
  - **Xcode 16+ buildable folders / synchronized groups** (`PBXFileSystemSynchronizedRootGroup`): files dropped into a synced folder are picked up and compiled automatically. New files just work, which is the common case for projects created on Xcode 16/26.
  - **Old-style group references** (each file listed individually in `.pbxproj`): a terminal-created file is *not* in the target and won't compile until it's added. Don't hand-edit `.pbxproj` to fix this. Instead, if the project uses Tuist/XcodeGen, regenerate; otherwise tell the user to add the file in Xcode (or use the Xcode MCP if it can set target membership), and prefer adding code to an existing already-compiled file when a new file isn't necessary.
  - Quick check: if a brand-new file's symbols come back as "cannot find in scope" at build time despite correct code, suspect target membership first. You can confirm by checking whether the enclosing folder appears as a synchronized group in the project.
- **Never edit `.pbxproj` manually** - let Xcode, the Xcode MCP, or the project's generator (Tuist/XcodeGen) manage it
- **Never delete project files** - move to a disabled state or comment out; deletion is permanent
- **Never modify build settings** unless the task explicitly requires it
- **Prefer additive changes.** When adding significant new functionality a new file is good, but only if the target picks it up automatically (see "New files and the target"); otherwise extend an already-compiled file.
- **One logical change per build cycle** - mixing multiple changes makes failures ambiguous
- **When a build error is confusing**, clean before concluding there's a real bug: `xcodebuild clean -scheme MyApp`, or remove the project's DerivedData (`rm -rf ~/Library/Developer/Xcode/DerivedData/MyApp-*`), then rebuild
- **Never print, log, or echo** API keys, tokens, or the contents of a `.env` / credentials file, and confirm such files are gitignored before any commit

## The Five Convergence Traps

Claude commonly defaults to these - actively avoid them:

### 1. Stale SwiftUI Patterns
Don't use `@StateObject`/`@ObservedObject` + `ObservableObject` for new code.
Use `@Observable` macro (iOS 17+) with `@State` at the view level - simpler, more performant, no retain cycle footguns.

```swift
// Old
class ItemViewModel: ObservableObject { @Published var items: [Item] = [] }
@StateObject private var vm = ItemViewModel()

// Modern (iOS 17+)
@Observable class ItemViewModel { var items: [Item] = [] }
@State private var vm = ItemViewModel()
```

### 2. Flat Navigation
Don't use `NavigationView` or imperative push.
Use `NavigationStack` with `navigationDestination(for:)` - type-safe, testable, deeplink-ready.

### 3. Generic Visual Design
Don't hardcode colors or use `List` with zero customization.
Use semantic system colors, `#Preview` macros, `.contentShape`/`.buttonStyle` for hit targets, `.sensoryFeedback` for micro-interactions. On iOS 26, reach for native Liquid Glass (`.glassEffect()` / `GlassEffectContainer`) on floating chrome rather than hand-rolling translucency.

### 4. Ignoring the Platform Contract
- SF Symbols: weights must match surrounding text
- Safe areas: never hardcode insets
- Dynamic Type: `.font(.body)` scalable styles, not fixed sizes
- Prefer adaptive system colors over manual `colorScheme` checks
- Liquid Glass (iOS 26): recompiling against the iOS 26 SDK makes system controls (toolbars, tab bars, sheets) adopt Liquid Glass automatically. Don't fight it by forcing solid backgrounds or custom blurs on system chrome. See the Liquid Glass section and `references/ui-craft.md`.

### 5. Outdated Concurrency Defaults
Don't reflexively sprinkle `@MainActor` everywhere or hop through `DispatchQueue.main.async`. Under Swift 6.2 approachable concurrency (the Xcode 26 default for new app targets), app and UI code is already on the main actor by default, and nonisolated async functions run on the caller's actor. Stay on main by default and opt *into* the background with `@concurrent` for genuine CPU work. See the Swift Concurrency section.

## UIKit vs SwiftUI

Default to SwiftUI for all new code. Choose UIKit - or bridge via representables - when:

| Situation | Reason |
|-----------|--------|
| Existing UIKit codebase | Incremental migration beats a rewrite |
| Large collection with complex cell reuse (10k+ items) | `UICollectionView` recycling outperforms `LazyVGrid`/`LazyVStack` |
| Custom interactive `UIViewController` transitions | SwiftUI's transition API doesn't expose the same depth |
| `AVFoundation` camera/capture UI | UIKit integration is more reliable |
| `WKWebView`, `MKMapView`, `SCNView`, `ARSCNView` | Wrap with `UIViewRepresentable` |

**Mixing the two:**
- Embed SwiftUI inside UIKit: `UIHostingController(rootView: MyView())`
- Embed UIKit inside SwiftUI: `UIViewRepresentable` / `UIViewControllerRepresentable`
- Keep the bridge thin - share state via a common `@Observable` model rather than passing `@Binding` across the boundary

See `references/frameworks.md` for UIKit-specific patterns (compositional layout, diffable data sources).

## Architecture Guidance

For most features, use this layered approach:

```
View (SwiftUI) -> ViewModel (@Observable) -> Repository -> Data Source
```

- Views are dumb: rendering + forwarding user intent only
- ViewModels own domain logic, expose `async` methods called with `.task {}` or button actions
- Repositories abstract persistence; inject via initializer for testability
- Use `actor` for shared mutable state accessed from multiple async contexts
- For CloudKit sync: isolate sync logic in a dedicated `SyncActor`

**When NOT to use a ViewModel:** A simple read-only view with no user actions or state changes doesn't need one. Match architecture complexity to feature complexity.

**Folder structure** - prefer feature-based organization for anything beyond a small app:
```
Features/
  ItemList/
    ItemListView.swift
    ItemListViewModel.swift
  ItemDetail/
    ItemDetailView.swift
    ItemDetailViewModel.swift
Services/
  APIClient.swift
  StorageService.swift
Shared/
  Components/
  Extensions/
  Models/
```
Flat `Views/` + `ViewModels/` folders work fine for small projects; switch to feature-based when a flat list becomes hard to navigate.

## Swift Concurrency

**The Swift 6.2 mental model (Xcode 26 default for new app targets): stay on the main actor by default, and opt *into* the background.** This is a real shift from the Swift 6.0 habit of annotating `@MainActor` everywhere and manually hopping executors. Three pieces:

- **Main actor by default.** With "Use Main Actor by Default" enabled (the default for new app targets), your app and UI code runs on the main actor without explicit `@MainActor` annotations. You stop sprinkling `@MainActor` and stop fighting Sendable errors for ordinary single-threaded UI code.
- **`nonisolated(nonsending)` by default (SE-0461).** A nonisolated `async` function now runs on the *caller's* actor instead of silently jumping to the global executor. Called from the main actor, it stays on main; called from a nonisolated context, it runs off-main. No surprise thread hops, and far less `Sendable` boilerplate because you're not crossing isolation boundaries.
- **`@concurrent` to leave main.** When you genuinely want parallel, off-main execution (CPU-bound work, parsing, image processing), mark the function `@concurrent`. It's mutually exclusive with `@MainActor` and `nonisolated(nonsending)`: each says where code runs, so pick one.

```swift
// Parallel async work (structured concurrency)
func loadDashboard() async throws -> Dashboard {
    async let user = fetchCurrentUser()
    async let items = fetchItems()
    return try await Dashboard(user: user, items: items)
}

// CPU-bound work you want off the main actor: opt in explicitly
@concurrent func decodeAndIndex(_ data: Data) async throws -> Index { ... }

// You rarely need @MainActor on app/UI code anymore - it's the default.
// Reach for it only to pin a type to main from a context that isn't already main.

// Never use DispatchQueue.main.async in new code.
// Never use DispatchSemaphore with async/await - it deadlocks.
```

If a project hasn't enabled approachable concurrency yet (existing codebase on the old defaults), the Swift 6.0 rules still apply: nonisolated async hops to the global executor, and you annotate `@MainActor` for UI. Check the build settings / target before assuming which world you're in, and migrate incrementally rather than flipping the flag on a large codebase blindly (it changes where existing nonisolated async code runs).

**Actor reentrancy:** Actors are reentrant at suspension points. Code after an `await` inside an actor may observe different state than before the await, because another caller can run in between. Re-check invariants after every `await` in actor methods.

```swift
actor Cache {
    private var data: [String: Data] = [:]

    func value(for key: String) async -> Data {
        if let cached = data[key] { return cached }
        let fetched = await fetch(key) // ← actor can process other calls here
        // Re-check: another caller may have populated this key while we awaited
        if let cached = data[key] { return cached }
        data[key] = fetched
        return fetched
    }
}
```

**`.task` vs `Task {}`:** Use `.task {}` for work scoped to a view's lifetime (auto-cancelled on disappear). Use `Task {}` in button handlers where you own cancellation. Never create an unstructured `Task {}` inside a ViewModel init: it escapes the structured tree and leaks.

**Sendable:** Sending a non-`Sendable` type across an actor boundary is still a compile error. Mark value types `Sendable` explicitly when they do cross boundaries; use `@unchecked Sendable` only as a documented last resort. Approachable concurrency reduces how often you hit this, because less code crosses boundaries in the first place.

## Error Handling

Never use `try!` in production. Never silently swallow errors with empty `catch {}`.

```swift
@Observable class ItemViewModel {
    var items: [Item] = []
    var error: Error?

    func load() async {
        do {
            items = try await repository.fetchItems()
        } catch {
            self.error = error
        }
    }
}

// In the view
.alert("Couldn't Load", isPresented: $vm.hasError, presenting: vm.error) { _ in
    Button("Retry") { Task { await vm.load() } }
} message: { error in Text(error.localizedDescription) }
```

Define domain errors with `LocalizedError` so messages are meaningful to users, not "The operation couldn't be completed."

## Accessibility

Every interactive element needs `.accessibilityLabel` and `.accessibilityHint`. Minimum touch target: 44x44pt.

```swift
// Grouped row: combine so VoiceOver reads as one element
HStack { Text(item.title); Spacer(); Text(item.dueDate) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.title), due \(item.dueDate)")

// Icon-only button: must have a label
Button(action: delete) { Image(systemName: "trash") }
    .accessibilityLabel("Delete \(item.title)")
```

Check `@Environment(\.accessibilityReduceMotion)` and skip or simplify animations for users who need it.
Test with VoiceOver before every PR - not as a final pass.

## Performance

Measure with Instruments before optimizing (Time Profiler, Hangs, Core Data instrument). Avoid these structural mistakes without measuring first:

- **Main thread I/O**: Move any network, disk, or heavy parsing off-main with `Task.detached` or a background actor
- **Unnecessary redraws**: `@Observable` only invalidates views reading changed properties - but flat monolithic models still cause wide redraws; prefer granular models
- **List performance**: `List` is lazy by default - prefer it over `ScrollView + ForEach` for variable-height rows. For very large datasets with complex cells, use `UICollectionView` via representable
- **Image loading**: Never load full-res images synchronously. Use `AsyncImage` for remote; load local assets in a `Task` and cache with `NSCache`

See `references/frameworks.md` for CoreData fetch optimization and batch operations.

## Auditing Motion and Animation

You can't watch an animation play from here, so don't fabricate critiques of motion you can't see. Build the audit from artifacts you can actually inspect, run the objective measurements that exist, and flag the rest for on-device review. Production iOS teams test motion on three levels, and a good audit mirrors all of them:

1. **Read the literals** (free, always): pull every spring `response`/`dampingFraction`, duration, delay, and animation trigger from the code and judge them against the known-good ranges in `ui-craft.md`. Catch linear easing on physical motion, missing Reduce Motion fallbacks, double/conflicting animations, and unpaired `matchedGeometryEffect`. These findings cite exact values, so they're defensible.
2. **Measure smoothness with numbers**: a hitch is a late frame; the metric is hitch time ratio (ms of hitch per second), target <= 5 ms/s (60Hz budgets 16.67ms/frame, 120Hz ProMotion 8.33ms). Use XCTest `XCTOSSignpostMetric` (scroll/navigation/custom), the Animation Hitches instrument, and `MXAnimationMetric` via MetricKit for real-device field data. This is objective, not eyeballed.
3. **Record the flow and inspect a frame strip**: drive the user story (XCUITest, manually, or with `idb` for scripted taps/swipes), record with `xcrun simctl io booted recordVideo`, slice it with `ffmpeg` into frames, and view the frames to assess choreography, continuity, and mid-transition layout. The simulator's frame rate isn't representative, so use the strip for choreography, never for judging smoothness (that's step 2's job). For a dedicated pixel-perfect pass, go further: diff adjacent frames programmatically with Python/Pillow to catch popping and misalignment a glance at the strip would miss.
4. **Verify Reduce Motion** by re-recording with it enabled, and **flag the genuinely perceptual parts** (ProMotion feel, haptic sync, gesture tracking, perceived latency) for on-device review instead of guessing.

Read `references/motion-audit.md` for the full workflow, the XCTest/ffmpeg/idb commands, the frame-diffing pattern, and the audit output format.

## Testing and Previews

Every non-trivial view gets a `#Preview` with at least two states (empty + populated). ViewModels get unit tests using Swift Testing:

```swift
@Test func itemsSortByPriority() async throws {
    let vm = ItemViewModel(repository: MockRepository())
    await vm.load()
    #expect(vm.items.first?.priority == .high)
}
```

## UI Craft: Commit to an Aesthetic Direction

Claude defaults to generic iOS UIs: SF Pro Regular at system sizes, `Color.blue` accents, plain `List` rows, no animations. This is the iOS equivalent of web's Inter-on-white-with-purple-gradients problem. **Before writing any UI code, commit to a deliberate aesthetic direction across four axes:**

**1. Typography character** - SF Pro is the default but it has range. Make deliberate choices:
- Weight contrast: pair `.ultraLight` headlines with `.semibold` labels for drama
- Size scale: use jumps of 3×+ (e.g., 11pt captions → 34pt hero), not timid 1.5× steps
- For truly distinctive apps: `UIFont(name:)` with a custom font loaded via `CTFontManagerRegisterFontsForURL` - but only if it serves the brand

**2. Color commitment** - pick a direction and execute it fully:
- Monochromatic + one sharp accent beats five competing accent colors
- Dark-first (`.black` / `.systemGray6` base) often reads more premium than light-first
- Tinted materials: `Color(.systemBackground).opacity(0.85)` + `.ultraThinMaterial` background for layered depth
- Never leave `Color.accentColor` as the default blue unless blue is genuinely correct

**3. Motion intentionality** - one well-crafted transition creates more delight than ten micro-animations:
- Use `withAnimation(.spring(response: 0.35, dampingFraction: 0.7))` for list insertions and card reveals
- `.matchedGeometryEffect` for shared-element transitions between list and detail
- `.symbolEffect(.bounce)` on SF Symbols for completion moments
- Check `accessibilityReduceMotion` and provide instant alternatives

**4. Surface and material** - how elements sit in space:
- `RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)` for cards that feel light
- Subtle shadow: `.shadow(color: .black.opacity(0.06), radius: 12, y: 4)` - not `.shadow(radius: 10)`
- Layer backgrounds intentionally: `ZStack` with a blurred image or gradient base reads as designed, not default

**The question to ask before shipping any screen:** *What is the one thing someone will remember about this UI?* If the answer is "nothing in particular," the design needs more commitment.

Read `references/ui-craft.md` for detailed SwiftUI implementation patterns for each axis.

## Liquid Glass (iOS 26)

Liquid Glass is the iOS 26 system material: translucent chrome that refracts and reflects the content beneath it. Two facts shape how you adopt it:

1. **System controls adopt it for free.** Recompiling against the iOS 26 SDK gives toolbars, tab bars, navigation bars, and sheets the glass look automatically. Most apps get the redesign mostly by building against the new SDK and *not* overriding it with custom backgrounds.
2. **Glass is for chrome, not content.** Apply it to floating controls and overlays, never to dense text or data surfaces.

For custom chrome, the native APIs are `.glassEffect(_:in:)` on a view, `GlassEffectContainer` to group nearby glass elements so they blend and morph as one, and `.glassEffectID(_:in:)` to animate an element across states. Variants are `.regular`, `.clear`, and `.identity`, with `.tint(_:)` and `.interactive()` modifiers.

```swift
Button { save() } label: { Label("Save", systemImage: "tray.and.arrow.down") }
    .glassEffect(.regular.tint(.accentColor).interactive())
```

Guardrails (these are the common mistakes): don't stack glass on glass (it turns muddy), don't put `.blur`, `.opacity`, or a solid `.background` directly on a glass view, and always check legibility with **Reduce Transparency** enabled. If the deployment target is below iOS 26, the hand-rolled `.ultraThinMaterial` card in `references/ui-craft.md` is the fallback. See that file for full patterns.

## On-Device Intelligence (Foundation Models)

For on-device language tasks (summarizing, extracting structure from free text, classifying, tagging, short generation), use Apple's **Foundation Models** framework (iOS 26+) before reaching for a cloud model. It runs privately on device, works offline, has no per-call cost, and adds nothing to app size.

The shape of it: get `SystemLanguageModel.default`, check `.availability` before use, run prompts through a `LanguageModelSession`, and get **type-safe structured output** by annotating a Swift type with `@Generable` and its fields with `@Guide`. You can also stream partial results (`PartiallyGenerated` snapshots) to animate UI as it fills in, and expose app functions to the model via tool calling.

**On-device vs cloud, briefly:** choose Foundation Models when privacy, offline support, latency, or cost dominate and the task is focused (the on-device model is tuned for practical device-scale tasks, not world-knowledge trivia). Choose a cloud model (e.g. a Haiku-first, escalate-to-Sonnet pattern) when you need broad knowledge, larger context, or higher-quality long-form reasoning. Many apps use both: on-device for fast/private parsing, cloud for the heavy lift.

See `references/foundation-models.md` for the full API surface, guided-generation patterns, availability handling, and the decision checklist.

## Product Design Thinking

Good iOS code that ships bad product design is still a failure. Read `references/product-design.md` when designing a new screen, reviewing UI, or any mention of "feel", "polish", or user experience.

Every screen must answer: **Where am I? What can I do here? Where can I go from here?**
Design every state: empty, loading, error, success.

### Two-Pass Design Workflow: Build, Then Polish

For a new feature or app, split the work into two focused passes rather than asking for both functionality and pixel-perfect polish in one prompt. One prompt trying to do both tends to produce weaker results on both fronts than two passes in sequence.

**Pass one: build the functional app.** Give real latitude here. Interpret loosely-specified requirements with reasonable judgment rather than asking clarifying questions unless genuinely stuck. Verify all interactions and transitions actually work in the simulator before considering the pass done.

**Pass two: a dedicated aesthetics pass, run separately, after the app already works.** The agent is no longer carrying the architecture burden, so full attention goes to visual polish: pixel accuracy, transition smoothness, removing anything that reads as a generic AI default (unearned gradients, template layouts, uneven spacing, generic card shadows). When asked for frame-level or pixel-level verification specifically, actually build the tooling to do that (see the Motion and Animation section) rather than eyeballing a single screenshot and calling it done. That specific instruction, verify at the frame and pixel level, is what pushes toward real verification instead of a vibe check.

## Reference Files

- `references/ui-craft.md`: iOS aesthetic craft: typography, color, motion, surface patterns, and Liquid Glass (native `.glassEffect()` plus the `.ultraThinMaterial` fallback) for distinctive SwiftUI UIs
- `references/motion-audit.md`: auditing animation and motion without watching it play: reading literals, hitch metrics (XCTest/Instruments/MetricKit), recording a flow and inspecting a frame strip, Reduce Motion, and what to flag for on-device review
- `references/frameworks.md`: UIKit patterns (compositional layout, diffable), CoreData BKMs, SwiftData BKMs, CloudKit integration patterns, UIKit/SwiftUI interop
- `references/foundation-models.md`: on-device AI: SystemLanguageModel, @Generable/@Guide guided generation, streaming, tool calling, availability handling, and the on-device-vs-cloud decision
- `references/product-design.md`: HIG philosophy, WWDC design foundations, Liquid Glass, what makes great iOS apps
- `references/hig-patterns.md`: controls, spacing, typography, navigation quick reference
- `references/swiftui-gotchas.md`: SwiftUI bugs, version-specific issues (incl. iOS 26 and Swift 6.2 concurrency), and general patterns (side effects, view decomposition, debugging re-renders)

Read the relevant file(s) before starting any non-trivial implementation.
