# SwiftUI Gotchas by iOS Version

## iOS 26

### Liquid Glass legibility
Glass adapts to whatever is behind it, so a control that looks fine over a calm background can become unreadable over a busy photo. Test every glass surface over your worst-case background, and with **Reduce Transparency** on (the system swaps glass for a more opaque material, which can change layout/contrast). Never put `.blur`, `.opacity`, or a solid `.background` directly on a `.glassEffect` view; it breaks the material.

### Glass-on-glass goes muddy
Nesting glass inside glass compounds blur and kills contrast. Group sibling glass elements in a single `GlassEffectContainer` instead of giving each its own independent glass background.

### System chrome restyles itself on recompile
Building against the iOS 26 SDK restyles toolbars, tab bars, and sheets as Liquid Glass automatically. If you previously forced a custom toolbar background or tint, it may now conflict with the material. Audit custom navigation/toolbar styling after bumping the SDK rather than assuming it looks the same.

### Sheet glass on partial detents
Partial-height sheets get an inset glass background that morphs as the sheet expands. Custom sheet backgrounds set with `.presentationBackground` can fight this; prefer the system background unless you have a specific reason.

## iOS 17+

### @Observable with SwiftData
Don't mix `@Model` (SwiftData) with `@Observable` on the same class - `@Model` already provides observation. Use `@Model` for persistence, `@Observable` for non-persisted ViewModels.

### navigationDestination inside List
`navigationDestination(for:)` must be attached to the `NavigationStack`, not the `List` or individual rows. Placing it inside `List` causes it to silently not register.

### .task modifier re-fires
`.task {}` re-fires whenever its `id:` parameter changes or the view re-appears after sheet dismissal. Guard with a flag or use `.task(id: someStableID)`.

## iOS 16 (legacy, below the iOS 18 floor)

These only matter if a project's deployment target still reaches back to iOS 16. New work defaults to iOS 18+ where these are non-issues.

### NavigationSplitView sidebar flickering
On iPad, `NavigationSplitView` with `columnVisibility` bound to state can flicker on first appearance. Set `.navigationSplitViewStyle(.balanced)` to reduce this.

### LazyVGrid with pinned headers
`pinnedViews: [.sectionHeaders]` inside `ScrollView` + `LazyVGrid` doesn't work on iOS 16 - headers scroll away. Use `LazyVStack` with sections instead if sticky headers are needed.

## General Gotchas

### Sheet + NavigationStack
A `NavigationStack` inside a `.sheet` starts with its own fresh navigation history. Don't rely on the parent stack's path inside a sheet.

### Button inside List row
A `Button` inside a `List` row with `.listRowBackground` set captures taps for the entire row only if `contentShape(Rectangle())` is applied to the button explicitly.

### @State vs @Binding mutation timing
Mutations to `@Binding` wrapped values trigger parent view re-renders. Avoid binding to computed properties - use a local `@State` intermediate if you need to batch changes.

### ForEach with Identifiable
If your model conforms to `Identifiable` using a non-stable ID (like a UUID generated at runtime), SwiftUI will animate deletions correctly but may cause visual glitches on large lists. Use stable, persisted IDs.

## SwiftUI Patterns (General)

### No side effects in `body`
Never trigger network calls, writes, or other side effects directly inside `body` - it runs on every re-render. Use `.task {}`, `.onAppear`, or `.onChange` instead.

```swift
// ❌ Runs on every render
var body: some View {
    let _ = viewModel.load() // don't do this
    ...
}

// ✅ Runs once (or when id changes)
.task { await viewModel.load() }
```

### `.task` vs `Task {}`
Use `.task {}` for work tied to a view's lifetime - it's automatically cancelled when the view disappears. Use `Task {}` inside button actions or event handlers where you manage cancellation yourself.

### Lazy stacks and ID stability
`LazyVStack`/`LazyHStack` recycle views by identity. If your model's `id` changes on update (e.g., a server-assigned ID arriving after optimistic insert), the row will be destroyed and recreated instead of animated. Always use stable, persistent IDs - never row index or transient UUIDs.

### View decomposition
Large `body` implementations cause slow compile times and poor re-render granularity. Extract sub-views into separate `struct` types (not `@ViewBuilder` functions) so SwiftUI can diff them independently. A view with a 50-line `body` is almost always a sign it should be broken up.

### Debugging re-renders
Add `let _ = Self._printChanges()` at the top of `body` during debugging to see exactly what property triggered a re-render. Remove before committing.

### `@MainActor.run` vs `await MainActor.run`
Use `await MainActor.run { }` to hop to the main actor from a background context for a single update. Don't wrap entire functions in it; isolate only the UI mutation. (Under Swift 6.2 main-actor-by-default you'll need this far less often, since most code is already on main.)

### Swift 6.2: enabling Approachable Concurrency changes where code runs
Turning on "Approachable Concurrency" (specifically `NonisolatedNonsendingByDefault`) silently changes the behavior of existing `nonisolated async` functions: they now run on the *caller's* actor instead of the global executor. Code that previously ran off-main (and that you relied on for not blocking the UI) may now run on the main actor. When migrating an existing target, expect this and add `@concurrent` to the functions that genuinely need to stay off-main, rather than flipping the flag and assuming behavior is unchanged. Migrate incrementally, target by target.
