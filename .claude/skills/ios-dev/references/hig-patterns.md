# HIG Quick Reference

## Controls

| Need | Correct Control | Notes |
|------|----------------|-------|
| Primary action | Filled button `.buttonStyle(.borderedProminent)` | One per screen max |
| Secondary action | `.bordered` button or plain text | |
| Destructive | `.tint(.red)` + confirmation | Always confirm destructive actions |
| Toggle setting | `Toggle` | Never use a button to toggle state |
| Selection from list | `Picker` with `.pickerStyle(.menu)` | Use `.segmented` only for 2-4 equally-weighted options |

## Lists and Collections

- Use `List` for vertical, variable-height, scrollable data - it handles insets, separators, and swipe actions natively
- Use `LazyVGrid` for grid layouts; `LazyVStack` for performance in long custom lists
- Swipe actions: leading = non-destructive (complete, pin), trailing = destructive (delete)
- Always provide `.swipeActions` for primary list actions; don't hide them only in context menus

## Navigation Patterns

| Pattern | Use When |
|---------|----------|
| `NavigationStack` push | Drilling into detail |
| `.sheet` | Quick actions, forms, pickers |
| `.fullScreenCover` | Camera, onboarding, auth |
| `NavigationSplitView` | iPad sidebar layouts |

## Typography Scale (Dynamic Type)

```swift
.font(.largeTitle)   // 34pt - screen titles only
.font(.title)        // 28pt - section headers
.font(.title2)       // 22pt
.font(.title3)       // 20pt
.font(.headline)     // 17pt bold - list row titles
.font(.body)         // 17pt - default body
.font(.callout)      // 16pt
.font(.subheadline)  // 15pt - secondary labels
.font(.footnote)     // 13pt - timestamps, metadata
.font(.caption)      // 12pt - fine print
.font(.caption2)     // 11pt - labels at limits
```

Never use `.font(.system(size: 17))` for body text - it breaks Dynamic Type scaling.

## Spacing and Layout

Standard HIG margins: 16pt from edges (use `.padding(.horizontal)` which defaults to 16).
Standard cell height: 44pt minimum touch target.
Standard corner radius: 10pt (small cards), 16pt (large cards/sheets), 20pt (bottom sheets).

## SF Symbols

- Match symbol weight to surrounding text weight
- Use `.symbolRenderingMode(.hierarchical)` for colored symbols in context
- Use `.symbolVariant(.fill)` for selected/active states, outline for inactive
- Animate with `.contentTransition(.symbolEffect(.replace))`
