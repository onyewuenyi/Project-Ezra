# UI pass

An audit of one or more surfaces for hierarchy, layout, motion and accessibility. Judge on evidence captured from the app, never on the code or a single still.

**Two passes, two prompts.** Pass 1 makes it work (states, navigation, interaction, tests). Pass 2, a separate prompt, makes it good: this playbook. One prompt asking for both does worse at each.

1. **Doctor, guard, and pin the environment.** 9:41 status bar (`scripts/ai/sim.sh statusbar`), a seeded store through a seam, on this checkout's own simulator (`scripts/ai/sim.sh udid`). Record the build's commit.
2. **Capture the matrix.** For each surface, through a seam:
   - text size: default (`large`) and `accessibility-extra-extra-extra-large` (at least `accessibility-extra-large`)
   - device: the smallest supported iPhone, the largest, and iPad if the app ships there (portrait and landscape)
   - appearance: dark and light, unless the app is locked to one
   - states: empty, one item, many, loading, error, offline
   Name every file `<surface>-<state>-<size>-<device>.png` in one evidence directory.
3. **Capture motion as frame sheets.** `record` runs for its whole duration, so start it in the background, then launch with the seam that triggers the transition (`scripts/ai/sim.sh record out.mov 8 & sleep 1; scripts/ai/sim.sh launch <seam>; wait`), then `scripts/ai/sim.sh frames out.mov sheet.png`. Read the sheet frame by frame for: a flash of wrong layout on the first frame, text drawn twice during a crossfade, content jumping, a transition that ignores Reduce Motion.
4. **Read each capture against a checklist:** one clear primary action; size follows importance; nothing truncated that names the thing the screen is about; tap targets at least 44pt; nothing under the keyboard, the home indicator or a floating button; content held to a readable width on iPad; no clipped Undo or confirmation.
5. **Accessibility pass.** Every control is labelled; gestures (swipes, long-press) have `.accessibilityActions`; `.opacity(0)` spacers are also `.accessibilityHidden`; transient messages stay long enough to be spoken; selected state is announced.
6. **Write findings as a table:** surface, condition, what is wrong, evidence path, severity. Severity is about the person using it, not the code.
7. **Fix in small units**, re-capture the same matrix cell after each plus every surface `python3 scripts/ai/blast-radius.py` names for the fix, and put the before/after paths side by side.
8. Pin the invariants that are the ABSENCE of something (no second accent, no implicit animation on first layout) with a test or grep, because no later screenshot will catch their return.

**Reply:** the findings table, what was fixed with before/after evidence, and what was judged and left alone.
