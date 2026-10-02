# Artifact Sentinel — initial evidence-based QA

V3 inspects completed RGB16 fusion and source-derived evidence in bounded64px cells. It creates ranked `ArtifactFinding` proposals with type, region, severity, confidence, evidence and related observed primary sources. It never changes pixels.

Initial signals:

- focus gap: low absolute focus evidence (not proof that no sharp source exists);
- low-confidence ownership: weak top-candidate separation;
- registration discontinuity: low global registration confidence, not dense local motion;
- motion leakage: high model motion probability outside selected ownership;
- bright/dark halo: reconstructed encoded luminance outside streamed captured-luminance range by.02;
- clipping/exposure: encoded channel at0/65535, which can also be legitimate scene content;
- suspicious source transition: neighboring source guides differ with weak focus;
- double edges/ghosting: adjacent strong red-channel gradients with motion-leakage evidence; these use the same proxy, not two independent validated detectors;
- possible tile seam: strong gradient near core border and weak focus; natural edges can trigger it.

A cell signal exceeding8% yields a proposal. Severity is fraction of triggering evidence; initial confidence is0.5, explicitly heuristic. Cell findings merge into at most512 highest-severity retained proposals. Related sources are observed primary guides capped at8, not exhaustive multiband contributors. Duplicate/nearby cell merging, exposure-normalized RGB halo analysis, true seam residual comparisons and calibrated detector precision/recall remain future work.

The macOS review queue supports next/previous, jump to ROI, accept auto, choose source via Edit, ignore and mark reviewed. Review actions enter the project audit/history. Acceptance means the photographer recorded a review choice, not that an automatic detector proved correctness. V2.2 cloud/motion false-negative limitations remain.

Tests cover serialization and prove QA does not modify RGB. Actual finding counts/coverage and bounded storage costs are in V3_RESULTS.md; no perceptual defect accuracy is claimed without reviewed labels.
