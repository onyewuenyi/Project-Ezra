# Hillclimb

Scientific improvement of one metric over many runs: an eval score, a model's latency or accuracy, a false-accept rate, a segmentation rate. Used heavily for on-device AI (Foundation Models) and cloud-model features.

1. **Name the metric, the corpus and the gate.** Which cases, which critical error (e.g. a false accept) must never rise, which metric is the one being optimized.
2. **Stamp every run:** app build/commit, OS version AND build (the on-device model's only version fingerprint), device or `sim:` prefix, model id, configuration fingerprint, time. A number without its stamp cannot be compared with anything.
3. **Prove the harness answered.** If fewer than ~90% of cases were served by the arm under test, the run is DEGRADED: report the error, not the score.
4. **Bracket the metric** before optimizing it: a case the metric must score as right, a case it must score as wrong. Instruments lie more often than code.
5. **Baseline** on the unchanged code, the same corpus, the same device class.
6. **Loop:** one hypothesis, one change, one run (repeat for variance on a model), compare to baseline on BOTH the optimized metric and the gate. Keep a decision log: hypothesis, change, result, kept/reverted, stamp.
7. **A defect found by eye becomes a corpus case**, labelled, before it is fixed, so the number sees it.
8. **Commit one accepted win at a time**, with the before/after numbers in the message. Move floors only in the direction the observed numbers support.

**Reply:** the metric trajectory table, the gate's value at each step, what was reverted and why, and the stamp of the final run.
