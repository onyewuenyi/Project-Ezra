# iOS Product Design Principles

This reference covers product design thinking for iOS - not just "which component to use" (see hig-patterns.md) but *why* good iOS apps feel the way they do, and how to make intentional design decisions at every level.

---

## Apple's Three Core Principles (HIG)

Everything in Apple's design philosophy flows from three ideas:

**Clarity** - The interface communicates instantly. Typography is legible. Icons are unambiguous. The user never wonders what something does or where to tap next. Clarity is not minimalism for its own sake; it's precision. Every element earns its place.

**Deference** - The UI serves the content, never competing with it. Controls should recede. Chrome should disappear. The Photos app is the canonical example: the interface is almost invisible so photos can be the entire experience. Ask of every screen: "What is the user actually here for, and is the UI getting out of the way?"

**Depth** - Visual layers and motion communicate hierarchy and context. Sheets slide up from underneath. Modals dim the content behind them. These aren't decorations - they're spatial signals that tell users where they are and how to get back. Transitions should feel like physical navigation, not arbitrary animation.

---

## WWDC 2025: Design Foundations

Apple's own designers distill app design down to three structural questions every screen must answer:

1. **Where am I?** - The user always knows their location in the app
2. **What can I do here?** - Primary actions are visible; secondary actions are discoverable
3. **Where can I go from here?** - Navigation paths are clear and predictable

**Progressive disclosure** is the key technique: don't show everything at once. Group by time, progress, or patterns. Reveal complexity only when the user is ready for it. The most sophisticated apps feel *simple* on first use and *powerful* on tenth use.

**Cohesive visual style** matters more than individual polish. A screen with inconsistent spacing, mismatched type scales, or competing accent colors will feel amateur even if every individual element is well-made. Pick a visual direction and commit.

**Microcopy is design.** Apple's guidance: simplify, cut filler words, lead with the benefit ("Save to iCloud" not "iCloud backup is available"). Never apologize in error messages. Read every label out loud - if it sounds awkward, it will feel awkward.

---

## Liquid Glass (iOS 26 / 2025)

Apple's most significant visual redesign since iOS 7. The key principles:

- **Translucency + depth replace flat color.** UI elements now have the optical properties of glass - they refract, blur, and respond to what's behind them and to light.
- **Hierarchy through layering.** Content lives on a base layer; controls float above it. The glass material signals "this is interactive" without needing color or explicit labels.
- **Motion is physics, not decoration.** Elements respond to momentum. Snapping feels springy. This makes the interface feel *physical* - grounded in a world with weight.

**When to adopt Liquid Glass:** Buttons, controls, and toolbars are the primary candidates. Don't apply it to content or data surfaces - the glass is for the chrome, not the substance. If you're targeting iOS 26+, use `.glassEffect()` modifier and let the system handle adaptation to light/dark.

---

## What Separates Good iOS Apps from Great Ones

Patterns from Apple Design Award winners and respected indie designers:

### 1. The App Has a Clear Point of View
Great iOS apps know exactly what they are and what they're *not*. They make opinionated choices. The "Not Boring" app philosophy (Andy Allen's studio): "richness, texture, and fun" - not feature completeness, but a distinctive character. Apps that try to do everything for everyone end up feeling like they do nothing well.

**Design implication:** Before adding a feature, ask if it deepens the app's core identity or dilutes it.

### 2. Interactions Feel Physical
Loren Brichter's pull-to-refresh (Tweetie, 2009) became a platform standard because it had *physical intuition* - pulling a list like a rubber band and releasing it. Great iOS interactions borrow from the physical world: spring physics, momentum, resistance. The interface should feel like it has *weight*.

**Design implication:** Use `UISpringLoadedInteraction`, spring animations, and haptic feedback not as embellishments but as communication. Resistance tells the user they're at a boundary. A satisfying snap tells them an action completed.

### 3. Delight Is in the Details, Not the Splash Screen
Award-winning apps consistently have one thing in common: they sweat the details that most apps ignore. The empty state is designed, not placeholder text. The loading state is intentional, not a spinner. The success moment has a micro-animation. These moments are cheap to build and enormously impactful on perceived quality.

**Design implication:** Map every state - empty, loading, error, success, edge cases - and design each one. A well-designed empty state can be the best onboarding a new user gets.

### 4. Consistency Creates Trust
Users form mental models fast. If your tab bar changes between screens, or your button hierarchy is inconsistent, users feel anxious without knowing why. Consistency isn't sameness - it's predictability. The same action should always look and behave the same way.

**Design implication:** Define and enforce a small set of interaction patterns early. A "primary action" should always be a `.borderedProminent` button. "Destructive" always red + confirmation. Never reuse a visual pattern for a different semantic meaning.

### 5. Accessibility Is Good Design
1 in 7 people have a disability. But accessibility improvements - higher contrast, larger touch targets, clear labels - improve the experience for *everyone*. Dynamic Type is the best example: supporting it makes your app better for users with poor vision *and* for users who just happen to have their phone in bright sunlight.

**Design implication:** Test with VoiceOver before shipping every feature, not as an afterthought. Turn on Display Accessibility > Reduce Motion to verify your animations have appropriate fallbacks.

---

## The "Is This Native Enough?" Tension

A constant iOS design question: when should you follow platform conventions vs. forge your own path?

**Always follow conventions for:** Navigation structure, gesture vocabulary (swipe-back, pull-to-refresh), settings patterns, share sheet, system alerts. These are deeply ingrained in users' muscle memory. Breaking them creates friction that users feel but can't articulate.

**Express your identity through:** Color, typography, illustration, iconography, animation character, tone of voice, empty states, onboarding. These are the surfaces where your app can feel distinctive without confusing users about how to use it.

The mistake most apps make is doing it backwards - conforming where they should express (flat, generic visual design) and breaking conventions where they should conform (custom navigation gestures, non-standard tab bars).

---

## App Structure Checklist

Before building any screen, answer:

- [ ] What is the **single primary action** on this screen?
- [ ] What is the **content hierarchy**? (What's most important?)
- [ ] What are the **states**? (Empty, loading, error, populated, edge cases)
- [ ] What **context** does the user arrive with, and what do they leave with?
- [ ] How does this screen **connect** to the rest of the app? (Can the user always get back?)
- [ ] Is this screen doing **one job**, or has scope crept in?

---

## Writing for iOS

Apple's guidance: write like you're talking to a smart friend, not writing a legal document.

| Instead of | Use |
|------------|-----|
| "An error has occurred" | "Couldn't save - check your connection" |
| "Are you sure you want to delete?" | "Delete Task?" [Delete] [Cancel] |
| "This feature requires permission" | "To send reminders, allow notifications" |
| "Loading..." | Nothing (use skeleton views) or "Getting your tasks..." |

Rules:
- Title case for titles and buttons, sentence case for descriptions
- Lead with the action or benefit, not the mechanism  
- No exclamation points except for genuinely exciting moments (onboarding completion, first success)
- Keep button labels to 1-3 words
