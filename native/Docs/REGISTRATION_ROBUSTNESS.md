# Native V2.2 registration robustness

The similarity optimizer remains the V2.1 bounded Accelerate phase/Huber implementation. Acceptance now requires independent evidence. Python V1.1 registration remains unchanged.

The report includes `registrationConfidence`, `registrationAmbiguous` and reasons, with six nonmax-suppressed phase hypotheses, peak ratio, raw-image competing correlation gap, high-pass periodic aliases, pyramid corner disagreement, nine local-region votes, texture variance and a weak previous-frame continuity prior. All inspection uses bounded 256/512/1024 reductions. Temporal ordering cannot authorize a transform on its own.

Distant high-pass aliases are checked against the actual candidate warp. A near-exact match can distinguish an alias through residual energy: best correlation >.98, alternative residual >1e-5 and best residual <20% of alternative residual. Exact repetition cannot pass that test. This preserves the existing rotation/scale fixture while rejecting truly ambiguous repeated structures. These are conservative engineering gates, not a calibrated probability or proof of correspondence.

Executed tests cover periodic grids, repeated windows, bricks, checkerboards, weak texture, random texture, nonperiodic grass, translation, rotation/scale and focus blur. Periodic and weak-texture cases raise structured `RegistrationRejected`; the UI exposes confidence and ambiguity rather than continuing silently.

The known full 10000×10000 periodic synthetic source-0/source-19 failure now exits before stacking with confidence .151 and reasons: repeated high-pass texture (.9903), competing phase hypotheses and a similarly plausible large-shift alternative. It does not return the false approximately 485px transform.

The real 11656×8742 three-frame stack is accepted at confidence .936485/.934290, phase ratios 188.26/120.99, local agreement 1.0 and pyramid disagreement .06936/.10710 reduced-image pixels. Its V2.1 transforms are preserved:

| Source | a | b | tx | ty |
|---|---:|---:|---:|---:|
| 2 | 1.0006482021 | .00003292694 | -3.38647 | -3.74169 |
| 3 | 1.0011786980 | .00002558141 | -6.63011 | -6.75555 |

Remaining limits include parallax, rolling/nonrigid geometry, large motion occupying most registration evidence and legitimate scenes with little distinct texture. Conservative rejection can require user review. This is a similarity registration improvement, not a general correspondence solution. Registration-confidence preview is the minimum accepted frame confidence, spatially constant; it is not a dense uncertainty map.
