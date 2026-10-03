# Prototype arena

A design fork that a screenshot can settle: two or three layouts for a screen, a motion choice, an interaction model. Build the variants, look at them side by side, pick with evidence. Asking the human "which approach?" before this is asking them to imagine what you could have shown them.

1. **Name the fork and the judging criteria** before building: what must be true (fits at the largest text size, one primary action, readable on iPad, the transition under 350 ms).
2. **One variant per worktree:** `scripts/ai/worktree.sh new proto-a` (and `proto-b`, …). Each gets its own branch, DerivedData and simulator, so builds and installs never collide. Run a session in each (`cd ../<repo>-proto-a && claude`), or build them yourself in sequence. Each variant is the SMALLEST change that expresses the idea, behind the same seam.
3. **Capture every variant identically:** same seed, same seam, same sizes (`large` and the largest accessibility size), same device. Motion gets a frame sheet per variant.
4. **Compare side by side:** `scripts/ai/sim.sh compare out.png a.png b.png c.png` puts them in one labelled image. Look at it; judge against the criteria from step 1; record the verdict per criterion.
5. **Keep one, delete the rest:** merge the winner's minimal change onto a clean branch, then `scripts/ai/worktree.sh remove <path>` the others (it deletes their simulators too).
6. When the fork is a product call that no screenshot settles, bring the comparison image to the user as one decision (Decisions, in `principles.md`).

**Reply:** the fork, the criteria, the comparison image path, the verdict per criterion, and the variant kept.
