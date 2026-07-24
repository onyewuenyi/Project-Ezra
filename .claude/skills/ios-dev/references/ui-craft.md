# iOS UI Craft

Detailed SwiftUI implementation patterns for building distinctive, memorable iOS UIs. Covers the four aesthetic axes: typography, color, motion, and surface/material.

The goal is to eliminate generic defaults and replace them with intentional choices that give an app a clear visual voice - without violating the platform contract.

---

## Typography

### SF Pro has more range than most apps use

```swift
// ❌ Generic - what Claude defaults to
Text("Hello")
    .font(.body)

// ✅ Considered - weight contrast creates visual hierarchy
Text("42 Tasks")
    .font(.system(size: 52, weight: .ultraLight, design: .rounded))

Text("DUE TODAY")
    .font(.system(size: 11, weight: .semibold))
    .kerning(1.5)   // tight tracking on small caps reads premium
    .foregroundStyle(.secondary)
```

### Size scale: use jumps, not steps

Boring: 13 → 15 → 17 → 20 (1.3× steps, undifferentiated)  
Distinctive: 11 → 17 → 34 → 52 (3×+ jumps, clear hierarchy)

```swift
// Hero number - large and light
Text("\(count)")
    .font(.system(size: 64, weight: .thin, design: .rounded))

// Supporting label - small and heavy
Text("COMPLETED")
    .font(.system(size: 10, weight: .heavy))
    .kerning(2)
```

### Custom fonts

Load a custom font when the brand genuinely needs it. SF Pro Rounded is often a better choice than a third-party font for warmth:

```swift
// SF Pro Rounded (no import needed)
Text("Good morning")
    .font(.system(.largeTitle, design: .rounded, weight: .semibold))

// Third-party font (registered via Info.plist UIAppFonts)
Text("Hello")
    .font(.custom("YourFont-Regular", size: 17))
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)  // still support Dynamic Type
```

Always pair custom fonts with Dynamic Type size scaling - `.font(.custom("Name", relativeTo: .body))` instead of fixed sizes.

---

## Color

### Commit to a palette, then execute it everywhere

```swift
// Define semantic tokens in an extension, not inline
extension ShapeStyle where Self == Color {
    static var brand: Color { Color("BrandPrimary") }  // from Assets
    static var brandSubtle: Color { Color("BrandPrimary").opacity(0.12) }
}

// Use everywhere
Text("Primary")
    .foregroundStyle(.brand)
Rectangle()
    .fill(.brandSubtle)
```

### Dark-first reads premium

Most consumer apps default to light mode. Going dark-first creates immediate differentiation:

```swift
// Explicit dark base that adapts correctly
Color(.systemBackground)  // adaptive - but starts light

// Force dark aesthetic while still supporting light mode correctly
// Use asset catalog with "Any" = near-black, "Dark" = darker-black
Color("SurfaceBase")
```

### Tinted materials for depth

```swift
// Card that floats above a blurred background
ZStack {
    // Background content (blurred image, gradient, etc.)
    backgroundContent
        .blur(radius: 40)
    
    // Card with tinted glass effect
    RoundedRectangle(cornerRadius: 20)
        .fill(.ultraThinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        }
}
```

### Accent color is a statement

Default `Color.accentColor` is blue. If you use it, you're saying your app is generic. Change it in Assets.xcassets → AccentColor - it propagates to all system controls automatically.

```swift
// Warm accent example
// In Assets: AccentColor = RGB(255, 92, 58) - coral
// No code needed - all buttons, toggles, links adopt it

// Or use a custom tint locally for one component
Toggle("Notifications", isOn: $enabled)
    .tint(Color("CoralAccent"))
```

---

## Motion

### Spring physics over linear animation

```swift
// ❌ Generic
withAnimation(.easeInOut(duration: 0.3)) { ... }

// ✅ Physical
withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { ... }

// For snappy, responsive UI (button taps, toggles) - target under ~200ms total
withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { ... }

// For dramatic reveals (sheets, onboarding) - target ~400-500ms for user to follow
withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) { ... }
```

**Response as semantic duration.** The `response` parameter is the approximate duration (in seconds) of the animation at critical damping. Use it to signal interaction weight, not just physics feel:

| Interaction type | Response range | Damping range | Why |
|---|---|---|---|
| Micro: toggle, button tap, icon badge | 0.15 – 0.28 | 0.75 – 0.9 | Immediate feedback; user should not wait |
| State change: card expand, row select | 0.3 – 0.4 | 0.68 – 0.8 | Noticeable but not sluggish |
| Navigation: push, sheet, full-page | 0.4 – 0.58 | 0.62 – 0.75 | User needs a beat to follow the spatial shift |
| Onboarding / hero reveal | 0.5 – 0.7 | 0.6 – 0.72 | Earned drama; use sparingly |

Sub-0.15 reads as a glitch with no transition. Above 0.65 for routine UI feels unresponsive. Dramatic / onboarding moments can exceed this intentionally.

### One orchestrated reveal > scattered micro-animations

**Only animate the elements that carry meaning.** Primary content leads; secondary items stagger in after; decorative elements skip animation entirely. Animating everything at once creates visual noise that makes the transition harder to follow, not easier.

```swift
// Staggered list appearance - primary content is instant, rows stagger in
struct ItemRow: View {
    let index: Int
    @State private var appeared = false

    var body: some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .onAppear {
                withAnimation(
                    .spring(response: 0.5, dampingFraction: 0.75)
                    .delay(Double(index) * 0.05)
                ) {
                    appeared = true
                }
            }
    }
}
```

Cap stagger delays at around 0.15s total spread across all items. If the last item's delay exceeds ~0.2s, the list reads as slow rather than choreographed. Keep `index * 0.04` to `0.06` as the multiplier; `0.08` and above starts feeling laboured.

### Modal background scale-down (reinforcing spatial layers)

When a custom modal or overlay appears, shrinking the background content reinforces the spatial model: the user is moving forward into a new layer, and the previous context is receding behind. The background should shrink slightly (to about 90-95%) and darken, making the new layer feel like it is floating above.

The system handles this automatically for `.sheet()` and `.fullScreenCover()` on iOS 26, so only implement it manually for custom ZStack-based overlays:

```swift
struct ContentView: View {
    @State private var isShowingOverlay = false

    var body: some View {
        ZStack {
            // Background content recedes when overlay is active
            MainContent()
                .scaleEffect(isShowingOverlay ? 0.94 : 1.0)
                .brightness(isShowingOverlay ? -0.04 : 0)
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.75),
                    value: isShowingOverlay
                )

            if isShowingOverlay {
                CustomOverlay(isPresented: $isShowingOverlay)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
```

Keep the scale at 0.92 – 0.96 (scale below 0.88 is aggressive and disorienting). Mirror the same spring on the overlay's entrance and the background's recession so they feel like one physical motion.

### SF Symbol animations for completion moments

```swift
// Checkmark that bounces on completion
Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
    .foregroundStyle(isComplete ? .green : .secondary)
    .symbolEffect(.bounce, value: isComplete)
    .contentTransition(.symbolEffect(.replace.downUp))
    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isComplete)
```

### Matched geometry for continuity

```swift
@Namespace private var heroNamespace

// In list row
Image(item.thumbnail)
    .matchedGeometryEffect(id: item.id, in: heroNamespace)

// In detail view (presented as overlay or fullScreenCover)
Image(item.thumbnail)
    .matchedGeometryEffect(id: item.id, in: heroNamespace)
```

### Always respect reduced motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

var animation: Animation {
    reduceMotion
        ? .none  // or .linear(duration: 0.01) for instant
        : .spring(response: 0.4, dampingFraction: 0.72)
}
```

---

## Surface and Material

### Shadows: precise and subtle beats heavy

```swift
// ❌ Generic - default shadow is a foggy blob
.shadow(radius: 10)

// ✅ Crafted - precise, directional, layered
.shadow(color: .black.opacity(0.04), radius: 2, y: 1)   // tight contact shadow
.shadow(color: .black.opacity(0.08), radius: 16, y: 8)  // soft ambient shadow

// For dark mode: use opacity only, not color tinting
.shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
```

### Corner radius is a design decision

```swift
// System standard (matches iOS 26 controls)
RoundedRectangle(cornerRadius: 12, style: .continuous)

// Card - more generous
RoundedRectangle(cornerRadius: 20, style: .continuous)  // .continuous = squircle

// Large sheet or modal
RoundedRectangle(cornerRadius: 32, style: .continuous)

// Never mix radii randomly - pick 2–3 values and stick to them
```

### Background variety defeats flat-color boredom

```swift
// Gradient base (subtle, not garish)
LinearGradient(
    colors: [Color("BackgroundTop"), Color("BackgroundBottom")],
    startPoint: .top,
    endPoint: .bottom
)

// Mesh gradient (iOS 18+) - organic and modern
MeshGradient(
    width: 3, height: 3,
    points: [ /* 9 control points */ ],
    colors: [/* 9 colors in brand palette */]
)

// Blurred content background
ZStack {
    AsyncImage(url: heroImageURL) { image in
        image.resizable().aspectRatio(contentMode: .fill)
    } placeholder: { Color("BrandSurface") }
    .blur(radius: 60)
    .ignoresSafeArea()
    .overlay(Color.black.opacity(0.3))

    // Foreground content
}
```

### Liquid Glass: use the native API on iOS 26

On iOS 26 the system material for chrome is Liquid Glass. For floating controls and overlays, prefer the native API over hand-rolled translucency: it gets the lensing, specular highlights, and motion response for free, and it adapts to light/dark and the content behind it automatically.

```swift
// Single glass control
Button { save() } label: {
    Label("Save", systemImage: "tray.and.arrow.down").padding()
}
.glassEffect(.regular.tint(.accentColor).interactive())

// Group related glass elements so they blend and morph as one
@Namespace private var glassNS
GlassEffectContainer(spacing: 16) {
    ForEach(actions) { action in
        ActionButton(action)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID(action.id, in: glassNS) // animates across state changes
    }
}
```

Variants: `.regular` (standard), `.clear` (minimal blur), `.identity`. Modifiers: `.tint(_:)` for semantic color, `.interactive()` for tap scale/shimmer.

Rules that keep glass legible (these are the usual mistakes):
- Glass is for **chrome, not content**. Never put long-form or dense text on glass; give it a solid surface.
- **Don't stack glass on glass** (it goes muddy) and don't put `.blur`, `.opacity`, or a solid `.background` (e.g. `Color.white`) directly on a glass view; it fights the material.
- Group nearby glass elements in a `GlassEffectContainer` so they share rendering and morph coherently, instead of many independent glass views.
- Test with **Reduce Transparency** and **Increase Contrast** enabled; ensure text stays readable.
- System controls (toolbars, tab bars, sheets) adopt glass automatically when you build against the iOS 26 SDK, so often you do nothing. Don't override them with custom backgrounds.

### The glass card pattern (iOS 18 fallback)

When the deployment target is below iOS 26 (no `.glassEffect()`), or for a content card where you deliberately want a lighter custom look, hand-roll it with `.ultraThinMaterial`:

```swift
struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    }
            }
            .shadow(color: .black.opacity(0.06), radius: 20, y: 8)
    }
}
```

---

## Empty States and Loading States

These are often the first screens new users see - design them, don't placeholder them.

```swift
// Empty state - purposeful, not apologetic
struct EmptyStateView: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.headline, weight: .semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: action) {
                Label("Get Started", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

// Skeleton loading - never show a spinner where layout is known
struct SkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).frame(height: 14).frame(maxWidth: 160)
                RoundedRectangle(cornerRadius: 4).frame(height: 11).frame(maxWidth: 100)
            }
        }
        .foregroundStyle(.quaternary)
        .opacity(shimmer ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: shimmer)
        .onAppear { shimmer = true }
    }
}
```

---

## Haptics as a Design Layer

Haptics are part of the UI - treat them as intentional sound design.

```swift
// Completion - satisfying, final
.sensoryFeedback(.success, trigger: isCompleted)

// Selection changed - light, responsive
.sensoryFeedback(.selection, trigger: selectedTab)

// Destructive action - warning weight
.sensoryFeedback(.warning, trigger: didDelete)

// Custom pattern for custom interaction
let engine = try CHHapticEngine()
// ... define CHHapticPattern for truly custom experiences
```

Never add haptics to every tap - that's noise, not design. Reserve them for meaningful state changes.
