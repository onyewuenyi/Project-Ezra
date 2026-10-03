# Device run

For what the simulator cannot prove: real performance, on-device model behaviour on phone hardware, push, CloudKit between two accounts, camera, background execution, thermal and memory limits.

1. **Find the device:** `xcrun devicectl list devices`. Unlocked, trusted, Developer Mode on. For anything longer than a minute, Auto-Lock set to Never: a locked screen backgrounds the app, and a suspended run freezes mid-report.
2. **Build into an isolated DerivedData** with `-destination id=<device udid> -allowProvisioningUpdates`. If signing fails, stop and report the missing capability or profile. Do not retry into the shared DerivedData.
3. **Install and launch with arguments:**
   `xcrun devicectl device install app --device <id> <App.app>`
   `xcrun devicectl device process launch --device <id> --terminate-existing <bundle id> -- -Flag value`
4. **Get evidence back:** have the app write its report into Documents, then
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/<file> --destination <local>`.
   Console: `xcrun devicectl device process launch --console …` or Console.app filtered by the process.
5. **Heartbeat long runs** (a line per case) so a stalled run can be told from a slow one.
6. **Stamp the result** with the device model and OS build, and never compare it with a simulator number.

**Reply:** the device and OS build, what ran, the pulled evidence paths, and anything that differed from the simulator.
