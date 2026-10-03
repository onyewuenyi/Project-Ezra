---
paths:
  - "**/*.swift"
---

# Swift on the iOS 27 SDK

- Apple's exported skills (`~/.claude/skills/swiftui-specialist`, `swiftui-whats-new-27`, `app-intents-*`, `modernize-tests`) are authoritative and win over memory on any API or signature question. Re-export after every Xcode update (`scripts/ai/bootstrap.sh`).
- `@State` is a macro in SDK 27. "Variable used before being initialized", "invalid redeclaration of synthesized property" or "extraneous argument label" on a view with `@State`: read `swiftui-whats-new-27/references/state-macro.md` first. Apple's note: the fix is NOT to reorder the init's assignments.
- Result builders are unified under `@ContentBuilder`: a `ShapeStyle` with modifiers passed to `overlay`/`background` can become ambiguous (use the trailing-closure form), a module type shadowing a SwiftUI name can become ambiguous, and `TupleView` in explicit generic types becomes `TupleContent`. Details: `swiftui-whats-new-27/references/content-builder.md`.
