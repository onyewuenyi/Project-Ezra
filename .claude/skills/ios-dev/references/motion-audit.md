# Auditing Motion and Animation

You cannot watch an animation play. A SwiftUI spring, a transition, a gesture-driven interaction: none of it renders into this session as motion. So the rule is: build the audit from artifacts you can actually inspect, run the objective measurements that exist, and honestly flag the rest for on-device review. Do not invent critiques of motion you cannot see ("the bounce feels heavy"); that is guessing dressed up as judgment.

This is also how real iOS teams test motion. There are three layers, and a thorough audit uses all three.

---

## Layer 1: Read the literals (always, free)

Most motion problems are visible in the code before anything runs. Extract every animation parameter and judge it against known-good ranges (see `ui-craft.md` for the ranges).

What to pull and check:
- **Spring parameters.** `response` and `dampingFraction` on every `.spring(...)`. Snappy UI controls live around `response: 0.25, dampingFraction: 0.8`; reveals around `0.4, 0.7`; dramatic entrances around `0.55, 0.65`. Flag anything outside sensible bounds (e.g. `dampingFraction` below ~0.5 will overshoot and wobble; above ~0.95 is effectively no spring).
- **Linear easing on physical motion.** `.easeInOut`/`.linear` on something that should feel physical (cards, sheets, list insertions) is a smell. Physical motion wants springs.
- **Durations.** Sub-`0.15s` reads as a glitch, not a transition; over `~0.6s` for routine UI feels sluggish. Hero/onboarding moments can run longer deliberately.
- **Reduce Motion fallback.** Every spring/large movement must check `@Environment(\.accessibilityReduceMotion)` and provide an instant or short cross-fade alternative. Missing this is a real accessibility defect, and you can catch it statically.
- **Directionality consistency.** Transition direction should match the navigation axis. A horizontally-navigated app (tab bar, paging scroll) should have menus and overlays that slide in from a consistent horizontal origin, not a random `.bottom` default. Check that every `.move(edge:)` / `.asymmetric` / `offset(x:y:)` transition aligns with the app's primary navigation direction. Inconsistent directionality breaks the spatial model users are building.
- **Stagger overload.** If every element in a list or grid uses `.delay(index * n)` and `n` is large enough that the last item appears more than ~0.2 seconds after the first, flag it. Also flag screens where unrelated elements all stagger simultaneously - this reads as coordinated chaos rather than choreography. Only key primary elements should lead; secondary and decorative elements should either skip animation or use a tight uniform delay (0.04 – 0.06s per step).
- **Everything animates at once.** A transition where every element on screen moves/fades simultaneously with the same timing is a smell. Look for a single `withAnimation { ... }` block that changes many state variables at once and evaluate whether the elements have distinct roles (primary vs. secondary) that would benefit from sequencing.
- **Implicit vs explicit conflicts.** Multiple `.animation(...)` modifiers or an `.animation(value:)` plus a `withAnimation` on the same state can double-animate or fight. Animating state that drives layout (not just appearance) can cause jumps.
- **`matchedGeometryEffect` pairing.** A source without a matching destination id (or mismatched namespaces) silently fails the shared-element transition.

Output: concrete, code-level findings with severity. These are defensible because they reference exact values in the source, not a perceived feel.

---

## Layer 2: Measure smoothness objectively (numbers, not eyeballing)

A **hitch** is any frame that appears on screen later than expected. The metric is **hitch time ratio**: hitch milliseconds per second of animation. **Aim for <= 5 ms/s.** A 60Hz screen budgets 16.67ms per frame; a 120Hz ProMotion screen budgets 8.33ms, so ProMotion is less forgiving. This is objective and fully inspectable from a terminal.

**In development, XCTest signpost metrics.** Wrap the animated work in an `os_signpost` interval and measure it; with an animation interval you get hitch count, total hitch duration, hitch time ratio, frame rate, and frame count. Standard metrics cover the common cases without manual signposts:

```swift
import XCTest

final class MotionPerfTests: XCTestCase {
    func testScrollSmoothness() {
        let app = XCUIApplication(); app.launch()
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric]) {
            app.collectionViews.firstMatch.swipeUp(velocity: .fast)
        }
    }

    func testNavigationTransition() {
        let app = XCUIApplication(); app.launch()
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric]) {
            app.buttons["FirstRow"].tap()
            app.navigationBars.buttons.firstMatch.tap() // back
        }
    }
}
```

Other standard metrics: `scrollDraggingMetric`, `applicationLaunchMetric`, and `customSignpostMetric(...)` for your own `os_signpost` intervals (use this for bespoke animations like a custom card expand). Set a baseline on the first green run so regressions fail the test. Note: simulator timing is noisy; record baselines and run perf tests on a fixed real device model, not the simulator.

**In Instruments, the Animation Hitches template** shows where hitches occur in the render loop (commit vs render phase). Use Time Profiler and the Hangs instrument to find the root cause once a hitch is located. Practical gotcha: if the Animation Hitches template fails to start on a physical device, switch its recording mode from Deferred to "Capture Last N Seconds."

**In the field, MetricKit.** `MXAnimationMetric` surfaces a scroll hitch time ratio aggregated from real customer devices, viewable in Xcode Organizer. This is how shipped apps monitor motion quality at scale, across the device and OS spread you can't test locally. Recommend wiring up an `MXMetricManager` subscriber if the app doesn't have one.

---

## Layer 3: Record the user story and inspect a frame strip

This is the closest you get to "watching" the motion: record the actual rendered flow, slice it into frames, and view the frames as images.

**1. Drive the flow.** For a repeatable capture, write a short XCUITest that performs the user story (open list, tap row, complete task, dismiss). For a one-off or exploratory pass, drive it manually in the booted simulator, or use `idb` (`brew install idb-companion`, then `pip install fb-idb`) to script taps and swipes without writing a full XCUITest.

**2. Record it.**
```bash
# Clean, consistent status bar first (optional, nice for review)
xcrun simctl status_bar booted override --time "9:41" --batteryLevel 100 --wifiBars 3

# Record (default codec is hevc; h264 is friendlier for downstream tools)
xcrun simctl io booted recordVideo --codec h264 flow.mp4
# ...perform or run the flow, then stop with Ctrl-C (SIGINT)
```

**3. Slice into a frame strip and inspect.** `ffmpeg` is the tool (install via `brew install ffmpeg` if absent):
```bash
mkdir -p frames
# Even sampling: ~12 frames per second of motion
ffmpeg -i flow.mp4 -vf fps=12 frames/f%03d.png
# Or capture only the moments where the screen changes (transition keyframes)
ffmpeg -i flow.mp4 -vf "select='gt(scene,0.1)',showinfo" -vsync vfr frames/scene%03d.png
```
Then view the frames. Now you can honestly assess choreography: does the element animate from the right anchor, is there a continuous path (matched geometry) between list and detail, does anything pop or clip mid-transition, are the start and end states correct, does the layout hold while the sheet expands. If `ffmpeg` isn't available, fall back to a burst of `xcrun simctl io booted screenshot` calls during the flow.

**Important limit:** the simulator's frame rate is inconsistent and not representative of device smoothness. Use the frame strip for *choreography and layout*, never to judge fps or hitchiness. Smoothness is Layer 2's job (metrics + real device).

---

## Layer 3b: Programmatic frame diffing (dedicated polish passes)

For a deep, pixel-perfect pass rather than a general audit, go beyond viewing a frame strip by hand. This is the workflow that catches popping, ghosting, and misaligned elements between adjacent frames, things a glance at a strip alone tends to miss.

Dump at a higher rate over the specific transition being polished, not the whole flow:
```bash
ffmpeg -i flow.mp4 -vf fps=30 frames/f%03d.png
```

Then diff adjacent frames with Python and Pillow:
```python
from PIL import Image, ImageChops

a = Image.open("frames/f001.png")
b = Image.open("frames/f002.png")
diff = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
diff.save("frames/diff_001_002.png")
# A tight diff region matching the animating element confirms clean motion.
# A diff scattered outside that region usually means a layout jump or a pop
# that a glance at the strip alone would likely miss.
```

Crop to the region of interest before diffing (`Image.crop(box)`); a full-frame diff is noisy and slow to interpret.

This is not a fixed script to run every time. It is a capability to build when the task specifically calls for frame-level or pixel-level verification: `idb` to drive the simulator, `ffmpeg` to capture, PIL to compare. Reach for it when asked to make a transition "flawless" or "pixel-perfect," not for routine motion checks (Layer 3 alone covers those).

---

## Layer 4: Verify Reduce Motion

Re-run the same recording with Reduce Motion enabled (Settings > Accessibility > Motion in the booted simulator). Confirm springs are replaced with instant changes or short cross-fades, no overshoot or parallax remains, and the flow still reads. A frame strip of the reduced version next to the standard one makes regressions obvious.

---

## Layer 5: Flag the rest for on-device review (do not fake it)

Some qualities are genuinely perceptual and cannot be settled from code, metrics, or a frame strip. Name them explicitly with what to check, rather than rendering a verdict:
- **ProMotion feel** at 120Hz (the simulator and metrics approximate it; the felt smoothness is a device thing).
- **Haptic synchronization**: does `.sensoryFeedback` land exactly on the visual state change.
- **Gesture tracking**: does the interactive transition follow the finger 1:1 with no rubber-banding or lag.
- **Perceived latency**: does the animation start immediately on touch-down or feel delayed.

---

## Audit output format

For each motion element, report what each layer found and its severity (reuse the P0/P1/P2/P3 scale if doing a formal design review):

```
Element: task-complete checkmark
- Literals (Layer 1): spring(response: 0.3, damping: 0.6) is fine; MISSING reduce-motion fallback. [P1]
- Metrics (Layer 2): not run / hitch ratio 1.2 ms/s, within budget. [ok]
- Frame strip (Layer 3): checkmark scales from center, reads clean across 8 frames. [ok]
- Verify on device (Layer 5): confirm .success haptic fires on the fill frame, not before.
```

The discipline: every claim is tied to a literal, a number, or a frame you actually looked at. Everything else is a labeled "verify on device," not a guess.
