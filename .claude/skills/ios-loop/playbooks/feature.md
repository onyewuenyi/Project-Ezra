# Feature

You own the design. Name the data shape before writing logic, and name how you will prove it works before writing views.

1. **Read the neighbourhood.** The models, the view that hosts the feature, the design-system tokens, and the project's rules (CLAUDE.md, docs). Match its idioms: naming, comment density, concurrency style.
2. **Name the shape.** The state the feature owns, who writes it, where it persists, which actor it lives on. Prefer an enum or state machine over parallel booleans, a derived value over a stored one that can drift. Write this in the todo list.
3. **Name the proof.** Which seam, deep link or UI test will reach the new state, and what end state proves it. If none exists, the seam is part of the feature (DEBUG-fenced, added to `.claude/ios-screens.txt`).
4. **Build the smallest vertical slice** that a user could see, behind a flag if the rest is not ready. Build it clean with the project's own build command.
5. **Unit-test the pure logic** (ranking, parsing, state transitions) the way callers call it, asserting literal expected values.
6. **Verify on the surface** (every surface `python3 scripts/ai/blast-radius.py` names, not just the one you built) at the default size and at the extremes (`principles.md`, Extremes are the test): largest accessibility text, smallest device, iPad if shipped, dark and light. Motion gets a frame sheet (start recording BEFORE the launch that triggers it). VoiceOver: every gesture has a spoken equivalent, and anything hidden for the eyes is hidden from VoiceOver too.
7. **Check the Release side** if you touched Info.plist, entitlements, permissions, launch arguments or third-party SDKs: `scripts/ai/verify.sh --release` (the seams gate plus the Release audit).
8. **Commit in verifiable units**, and update `.claude/ios-screens.txt` (`/map refresh`) and any checklist docs in the same change that changes a flow.
9. If the design was contested, run `/interrogate` on the diff before calling it done.

**Reply:** what the person using the app can now do, the shape you chose and why (a table if there were real alternatives), the evidence at each size and device, and the open decisions.
