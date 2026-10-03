# Schema change

The person's data outlives every build. A schema change is proven by migrating a real store, not by the new build launching on an empty one.

1. **Find what has shipped.** The current model version, and whether any build carrying it reached TestFlight or the App Store. A shipped version is frozen.
2. **Add a new model version** (Editor ▸ Add Model Version, or a new `.xcdatamodel` directory) and set it current. Never edit a shipped version in place (the guard hook asks before you edit a committed version).
3. **Keep it a superset for lightweight migration:** nothing removed, no type changed, no optional → required, every new attribute optional or defaulted, every relationship with an inverse. A meaning change is a new field beside the old one. For CloudKit-mirrored stores this is not optional: CloudKit schemas are additive only once deployed.
4. **SwiftData:** add a new `VersionedSchema` and a `SchemaMigrationPlan` stage; the same superset rules apply.
5. **Prove the migration:** install the PREVIOUS build (from git, an isolated DerivedData), seed it through a seam, then install the new build over it without deleting the app, launch, and verify the seeded data reads back. A unit test that opens a fixture store of the old version with the new model is the durable form.
6. **Destructive paths** (reset, clear, dedupe) back up the store files (`.sqlite`, `-wal`, `-shm`) first, and are measured with a plain-launch guard between runs.
7. **CloudKit:** the Development schema is created by use; Production is not. Note the deploy to Production as an owner step for release, and never deploy it without asking.

**Reply:** the version added, the superset check, the upgrade-over-old-store evidence, and any owner step left (schema deploy).
