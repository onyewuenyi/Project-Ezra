# Household Architecture

Durable notes on the household identity layer. Read this before touching identity,
ownership, or anything that will eventually sync.

## The mindset

The household is **not a profile page**. It's the **root aggregate** — the collaboration
boundary that every future shared feature hangs off of:

```
Household
    ↓
Members
    ↓
Shared Context (settings · AI context · memory)
    ↓
AI
    ↓
Tasks
```

The account isn't the product; it's the context that powers the product. The schema
reflects that long-term shape even while the V1 experience stays deliberately tiny:
**name, photo, done.**

## Model map

| Model | Role | V1 UI? |
|---|---|---|
| `Household` | Root aggregate: family name, family photo; owns members/settings/aiContext/memories/invitations | name + photo |
| `UserProfile` | The current user ("you"): `displayName`, photo | name + photo |
| `FamilyMember` | A person you delegate to: name, photo, `relationship`, `role`, soft-delete | name + photo + relationship |
| `HouseholdSettings` | Home *location* (coords, never an address), time zone, EventKit calendar **identifier**, `planningStyle` | none (reserved) |
| `HouseholdAIContext` | Consolidated AI personalization (automation level, notes) — never scattered `aiPreferences` | none (reserved) |
| `HouseholdMemory` | Durable household facts ("Trash Tuesday", "Ezra naps at one") — the biggest future lever on assistant quality | none (reserved) |
| `Invitation` | Pending/accepted/expired — modeled now so real sharing needs no migration | none (reserved) |

`AppSchema.models` (`Models/AppSchema.swift`) is the single source of truth for the
model set; the app container, every `#Preview`, and every test container reference it.

**Expose behavior, not knobs.** The only user-facing dial planned for settings is
`planningStyle` (Relaxed / Balanced / Proactive). The best settings screens are almost
empty — everything else is inferred.

**Local vs shared.** Device-local UI preferences (`hasOnboarded`, sort order, theme)
stay in `@AppStorage` and must **never** move onto the household models — they aren't
shared state.

## CloudKit: designed-for, not yet on

Sync is **off** today (`ModelConfiguration` is local), but every model is already
CloudKit-compatible, so enabling it is a one-line + entitlement change rather than a
migration:

- UUID keys everywhere; **no `@Attribute(.unique)`** (CloudKit can't express it)
- every stored property optional or defaulted
- every relationship optional
- `photoUpdatedAt` on each avatar-bearing model — versioning so a CloudKit cache can
  invalidate cleanly

Planned database split (mirrors the private/shared boundary):

```
Private database          Shared database
    UserProfile               Household
                              FamilyMember
                              Tasks
```

`UserProfile` is deliberately standalone with **no relationship to `Household`** —
CloudKit cannot express a cross-database relationship.

**To turn sync on:** add the iCloud + CloudKit capability and a container in Xcode
signing (needs a paid Apple Developer account), then set `cloudKitDatabase:` on the
`ModelConfiguration`. Do that through the Xcode GUI — never by hand-editing
`project.pbxproj` or entitlements.

## Ownership: every task is born owned

> **This section was reversed on 2026-08-11 and is now the opposite of what it once said.**
> The old model treated `ownerID == nil` as a sentinel meaning "mine", so an unowned task
> was the normal case. That is gone. The migration this section used to plan for has
> already happened, without a schema change.

**Every task is born owned**, and `OwnerProposer` (`AI/OwnerProposer.swift`) is the pure,
deterministic ladder that does it: spoken name → graph adjacency (`childOf`/`duplicateOf`
targets only — never blockers, which point the wrong way) → category affinity → **the
capturer**. Because the last rung always answers, the ladder is **total**: there is no
abstention, `applyOwnershipGate` and `ownerPending` are both retired, and the current user
*is* a `FamilyMember`.

`ownerID == nil` therefore no longer means "mine". It means **unowned**, and only a human
hand-back produces it. "Mine" is `isMine(currentUserID:)`.

Two rules keep the ladder honest:

- **Load never selects an owner, only adjusts one** — it demotes the overloaded and breaks
  ties; it cannot pick.
- **`.defaultSelf` carries no reason and no ✦.** Defaulting to you is not an inference, and
  dressing it as one would be worse than the abstention it replaced.

`ownerOrigin` (`.human` / `.inferred`) is stored because the affinity rung's denominator
counts **human-established ownership only** — otherwise rung 4's own output floods the
signal and rung 3 becomes unreachable. `creatorID` (authorship) is a separate field from
`ownerID` (who it is for), which is what lets the Tasks screen offer Assigned and Created
as two independent readings of the same store.

The gate that still matters is `HouseholdSync.isLive` (compile-time `false`): it gates the
proposer's **inferred non-self rungs** and the Brief's ownership filter, so a task can
never leave your briefing for someone with no device in the graph. `.spoken` is
deliberately not gated.

## Avatars: one pipeline

Every avatar renders through `AvatarView` / `AvatarSource`
(`Features/Components/AvatarView.swift`) — photo, initials, gradient, emoji, person, or
family. Never duplicate avatar logic; add a case to `AvatarSource` instead.
`OwnerAvatarBadge` is a thin compatibility shim over it. Picked photos are downscaled to
a 256px square (`AvatarPhoto.downscaled`) before they ever reach the store.

## Soft deletes

Removing a family member sets `deletedAt` rather than deleting the row, so a task they
once owned keeps its attribution. Use `Household.activeMembers` / filter `!isDeleted`
for any roster the user sees.
