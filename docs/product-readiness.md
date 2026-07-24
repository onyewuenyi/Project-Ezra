# Product Readiness

## CloudKit sync (Phase 3 / CKShare cross-account): not yet — and why

**Short answer: no, don't do Phase 3 or turn on sync now.** You're mid-development with a
churning schema, and that's exactly the condition CloudKit punishes hardest. Here's the
reasoning and the actual right trigger.

### Why not now

**The killer reason — CloudKit locks your schema; your clean-break policy is the opposite of
that.** You're bumping `schemaGeneration` and wiping the store on every meaning-change
(gen 2→3→4→5, and your own comment says "wipes existing stores, TestFlight users included").
That works because it's a local store you can destroy. **CloudKit does not let you do that.**
Once a CloudKit schema is deployed to Production, changes must be **additive only** — you can
add fields, never remove/rename/retype, and you can't "wipe the server." Turning sync on now
would put you in a head-on collision with the redesign you're actively doing (you just retired
the whole attention/retro layer for the Today sequence — that's precisely the kind of
destructive schema change CloudKit forbids in production).

**The supporting reasons:**

- **No users yet.** Sync's value is exactly zero until two people/devices share a household.
  Building it now is speculative plumbing for a Household model whose surface is still being
  redesigned.
- **Phase 3 (CKShare) is the hard, device-only, most-bespoke part** — best built once, against
  a stable domain, not re-worked mid-redesign.
- **It buys you nothing today** and adds real friction (you'd have to manually reset the
  CloudKit Development environment on every schema change).

### The best time — a concrete trigger

Enable sync when **both** are true:

1. **The schema has stabilized** — Today + Household surfaces have settled and you expect
   future model changes to be additive (new fields), not destructive. That's when CloudKit's
   additive-only constraint stops being a straitjacket.
2. **You're actually staging the multi-user beta** — i.e., about to put Charles + Maya on
   separate devices/Apple IDs. That's the moment sync earns its keep.

Practically, that's usually right before the first real multi-household beta, not during solo
dev. Do it as one focused effort: entitlement → private-DB sync (Phase 2a, ~1 line) → then
Phase 3 CKShare, tested on two real Apple IDs.

### What to do in the meantime

**Nothing — and that's the point.** The Phase 2 foundation already keeps you sync-ready
without paying any cost now: history tracking is on, the model is CloudKit-compatible (0
unique constraints, all inverses), and flipping sync on is still just setting
`PersistenceStack.cloudKitContainerID` + adding the entitlement. Keep developing on the local
store, keep using clean-break wipes freely, and let the schema settle. When you hit the
trigger above, come back and we'll do the entitlement + private sync + CKShare in one clean
pass.

One caveat to bank now, since it affects choices you make during dev: **before you deploy the
CloudKit schema for real, get the Household/FamilyMember/ownership fields to a shape you're
confident in** — those back the share root and the identity handshake, so they're the ones
most expensive to change after sync is live. The Today/Task churn matters less (additive), but
the sharing-critical models are worth freezing first.
