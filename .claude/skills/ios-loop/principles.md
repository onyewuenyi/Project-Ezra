# Principles

Read the one whose trigger applies, and name it in the reply when it changed a decision.

**Prove it on the surface** (before saying done). A change is done when its effect was observed where the user meets it: the running app, the built bundle, the device. Not when it compiles, and not when unit tests pass. Drive the real path (a seam, a deep link, a UI test), capture the action, the resulting state and any side effect, and keep the evidence in a path you name. If you cannot reach it, say so in those words, with the reason. "Should work" is a guess.

**Environment before code** (a crash, hang, missing change or number you are about to believe). On iOS the environment fails like an app bug: a simulator runtime that can no longer spawn processes (every launch "crashes"), another session's build installed over yours ("my change did nothing"), a destination by name picking another runtime, `simctl spawn … defaults write` writing the simulator's shared preferences (a "fresh install" is not fresh), a half-signed bundle from a failed signing step. Run `scripts/ai/doctor.sh` first and `scripts/ai/sim.sh guard` (a plain launch must stay alive) around any crash measurement.

**Reproduce, then root-cause** (any defect). No fix before a reproduction with a rate (4/6), and no fix at the symptom. Read the crash report's faulting thread before forming a theory. Separate the trigger, the masking condition (why "sometimes") and the symptom. A nil-check, a retry or a delay that makes the symptom stop is a new bug with a later date.

**Attack the premise** (the same gate fails twice for the same reason). Stop patching. Write down the assumption every attempt shared, test it directly, and redesign from what is true. Three fixes at one symptom mean the model of the problem is wrong.

**Smallest change, subtract first** (before writing code). The best diff deletes something. Prefer removing the cause to adding a guard, a derived value to a stored one that can drift, an enum to parallel booleans. Match the codebase's idioms; a new pattern needs a reason.

**Extremes are the test** (any UI change). Judge at the edges: the largest accessibility text size, the smallest iPhone, iPad in both orientations if the app ships there, dark and light, Reduce Motion, VoiceOver, empty/one/many/error/offline. Most layout defects live only there: primary text truncated, controls off-screen or under the keyboard, a scaled glyph drawn outside its fixed frame, a 1300pt-wide button on iPad.

**Release is another app** (build settings, Info.plist, entitlements, seams, third-party SDKs, submission). Verify the artifact you ship: `scripts/ai/verify.sh --release`. Launch-argument seams fenced out (`strings` cannot check it; Swift hides literals of 15 bytes or fewer), the privacy manifest in the built bundle, export compliance answered, every usage string present, no in-process photo picker without a permission string, production entitlements and environments.

**Explain the number** (a new metric, eval, benchmark or probe). Instruments lie more often than code. Show it reads a known-good case as good and a known-bad case as bad before trusting it; report median and worst over N ≥ 5 runs with a stamp (build, OS version and build, device or `sim:`); a model eval proves it answered (under ~90% served is DEGRADED); argue thresholds from per-case values, never a summary.

**Additive data** (model, persistence, sync, or a destructive path). The person's data is never the experiment. A schema change is a new version that is a superset of the last. Destructive paths back up first, touch only what they name and report what they did. User content leaves the device only through a path the app states, in words that are true.

**Guard the context window, never block on the human** (long or wide work). Route bulk reading and long logs to subagents (`build-verify`, `Explore`) and keep only conclusions. When a genuine product decision blocks one branch of work, park it with options and a recommendation, and continue everything that does not depend on it.

**Encode lessons in structure** (you are about to write the same warning twice). Strongest rung first: a type that makes the wrong state unrepresentable · a failing test (including a grep test for an absence) · a hook that blocks · a script a playbook runs · a line in `.claude/ios-screens.txt` or a playbook · a line in CLAUDE.md. Delete the prose a structural fix replaces. `/reflect` does this.

## Decisions

Most forks are not the owner's: if running something would settle it (a layout, a timing, whether an eval separates), run it (`playbooks/prototype.md`). Bring only genuine product or preference calls, one per question, with your recommendation first and the evidence attached (a comparison image, a preview). Keep working on everything that does not depend on the answer.

## Autonomy

Proceed without asking on reversible work: edits, builds, simulator runs, local commits, opening a PR with `scripts/ai/pr.sh`. Ask before: merging, pushing anywhere but your own branch, deleting user data or simulators you did not create, uploading to App Store Connect, deploying a CloudKit schema to Production, launching a cloud session, and anything that sends user content off the device. When the owner asks "should we", answer with a judgment; "no, this does not earn its place" is a valid answer.
