# Perf

A slowness is a number before it is a fix.

1. **Define the number:** cold launch to first frame, a scroll's hitch ratio, a view body's cost at N items, a request's latency, peak memory. Say which device class. A simulator number is Mac silicon, never a phone number: label it `sim` and confirm the win on a device before claiming it.
2. **Baseline it, N ≥ 5 runs**, reporting median and worst. Tools, cheapest first:
   - `os_signpost` intervals + `xcrun xctrace record --template 'Time Profiler' --launch -- <app>` (or `--attach`) on a device
   - `XCTest` `measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTApplicationLaunchMetric()])`
   - a probe test that times the pure function at realistic scale (e.g. 240 items)
3. **Bracket the instrument** (`principles.md`, Bracket the instrument): make it read a known-slow and a known-fast case correctly before trusting it.
4. **Profile, then hypothesize.** Read the heaviest stack in the trace. Common iOS causes: work in `body` (formatters, sorting, fetches), O(n²) derivations per row, main-actor I/O, a `@Published` that invalidates the whole tree, images decoded on the main thread, Core Data faults fired in a loop.
5. **Change one thing, re-measure the same way**, and keep a table: hypothesis, change, before, after, kept or reverted.
6. **Pin the win** with a performance test or a probe that fails when it regresses beyond a stated budget.

**Reply:** the metric, baseline and result (median and worst, runs, device), the trace evidence for the cause, the table of tried changes, and the budget now pinned.
