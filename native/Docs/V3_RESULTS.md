# V3 Product Foundation — measured results

## Revision and environment

Validated locally on 2026-10-02, Apple M1 Max MacBookPro18,2, arm64, 32GiB unified memory. Current OS: macOS27.0.1 build26A434; Xcode27.0 build27A266a, Swift6.4, macOS/iOS SDK27.0. Per-command DEVELOPER_DIR selected installed Xcode; global developer selection/privacy/security settings were not changed.

Annotated native-v2.2 points exactly to caa8c698f86d568a29bf1246ed3777c3487b5e60. Python work/python-v1.1 remains a0680d224c3c91a82bef13f318d77d2b60e7ffc3; native-v2.1 remains7b93e2895865aea59ce5d7703ffd3f838f719d34. Product changes belong to native-v3. The frozen V2.2 native tree was archived into ignored local artifacts and independently built on the current OS; no baseline branch was edited.

## Workloads and timing method

Real inputs: three11656×8742 =101,896,752px RGB16 TIFFs, classic big-endian, giant uncompressed strips, orientation1, exact560-byte AdobeRGB(1998) ICC,300dpi. Originals were read only. Real runs used Maximum quality and automatic registration; no transform was invented to bypass registration.

Synthetic inputs: twenty real disk TIFFs, each10000×10000 =100,000,000px, RGB16 uncompressed,32-row strips,600MB pixel data/source (12GB for20). Existing generate_100mp.py generated source-dependent continuous detail in two focus regions in bounded128-row spans. All20 sources were generated once;3/10/20 runs use prefixes of this same set. Identity geometry was explicitly supplied; these are memory/performance tests, not photographic/registration/AI-quality validation. AI was Off for scaling; real Auto was separately executed.

Release builds,1024px cores, Maximum quality, one tile/command buffer at a time. Trials ran sequentially without concurrent build/test/GPU jobs. V3 import hashes warm source files; an additional V2.2 baseline was therefore preceded by bounded1MiB source reads outside its engine timing. Initial colder baselines were also retained locally but are not used to suggest a V3 speedup. These are single observations with OS/cache variability, not statistical speed claims.

Product seconds measure evidence kernel/readback, per-block LZFSE/raw storage, summary counters and Artifact Sentinel inside the engine. They exclude source identity hashing and final project/audit output hashes. Finalize includes source re-verification, metadata/audit and output hashing. GPU stages use command-buffer GPU start/end timing; upload/readback are CPU wall intervals. Stage sums omit initialization/submission/other host work and are not an exact partition of total wall time.

| Workload | Warm V2.2 engine s | V3 engine s | Product bookkeeping s | Import hashes s | Finalize s | V3 full workflow s | Engine increase |
|---|---:|---:|---:|---:|---:|---:|---:|
| Real 3 × 101.897MP, Off | 36.622 | 58.563 | 18.161 | 1.026 | 2.001 | 61.635 | 59.9% |
| Synthetic 3 × 100MP, Off | 30.377 | 40.120 | 9.283 | 1.017 | 1.573 | 42.764 | 32.1% |
| Synthetic 10 × 100MP, Off | 54.533 | 62.062 | 8.745 | 3.478 | 4.214 | 69.815 | 13.8% |
| Synthetic 20 × 100MP, Off | 126.941 | 132.897 | 8.733 | 7.285 | 7.761 | 148.024 | 4.7% |

Real3 Auto: engine 75.685s, product 22.176s, full workflow 78.907s. Local calibration chose cpuANE configuration, median 1.653ms on the calibration fixture. This is a compute-unit/configuration diagnostic, not a physical ANE dispatch trace. Model/photographic quality limits from V2.2 remain.

The real3 bookkeeping cost is substantial:18.161s and59.9% engine increase against the warmed baseline. The modest-overhead target is **not established across photographic inputs**; compression/QA profiling and optimization remain necessary. At20 synthetic frames the measured engine increase is4.7%; full workflow increase is16.6% including hashes/audit. Input-dependent compression and extra identity reads should not be concealed behind unrelated cold-cache timings.

## V3 stage timings

| Workload | Alignment s | Decode s | Upload s | Focus GPU s | Depth GPU s | Fusion GPU s | RGB readback s | Encode s | Validation s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| real3 | 4.761 | 6.092 | 0.214 | 4.045 | 0.146 | 1.764 | 0.041 | 12.561 | 2.256 |
| synthetic3 | 0.000 | 6.204 | 0.213 | 3.647 | 0.071 | 1.248 | 0.050 | 9.011 | 1.477 |
| synthetic10 | 0.000 | 20.382 | 0.629 | 9.770 | 0.076 | 4.157 | 0.048 | 9.296 | 1.528 |
| synthetic20 | 0.000 | 68.868 | 1.255 | 25.008 | 0.089 | 11.771 | 0.051 | 8.527 | 1.605 |
| real3-auto | 4.880 | 6.443 | 0.213 | 4.031 | 0.130 | 2.354 | 0.045 | 12.739 | 2.264 |

## Memory, disk and project overhead

| Workload | V2.2 peak RSS MiB | V3 peak RSS MiB | V3 Metal allocated MiB | Compressed provenance MiB | Total initial project MiB | Temporary-file peak MiB |
|---|---:|---:|---:|---:|---:|---:|
| real3 | 145.3 | 188.0 | 851.5 | 383.9 | 384.1 | 1043.9 |
| synthetic3 | 78.6 | 145.0 | 851.5 | 76.6 | 76.8 | 793.8 |
| synthetic10 | 73.5 | 145.4 | 851.5 | 59.6 | 59.8 | 797.0 |
| synthetic20 | 70.1 | 142.7 | 851.5 | 55.1 | 55.3 | 800.4 |
| real3-auto | — | 281.2 | 851.5 | 484.1 | 484.4 | 1043.5 |

Raw RGB16 staging:611,380,512 bytes real;600,000,000 synthetic. Temporary-file peak samples every0.1s sum the writer’s hidden raw stage and partial encoded TIFF; they exclude source inputs, completed outputs and persistent project maps. Real peak1,094,642,230 bytes; synthetic20 peak839,300,176. Project bytes measure regular-file lengths after initial render, before manual cache growth; filesystem allocation differs. Companions/final TIFF are separate. Benchmark inputs/results live only in ignored local Artifacts, not Git.

Provenance uses16 raw bytes/core pixel, independent compressed blocks (LZFSE, raw fallback), UInt16 source IDs and UInt8 confidence/flags, plus sparse overrides. Only a bounded tile is resident; no100MP array of Swift per-pixel structs or per-source pyramids. Tile admission includes40 extra bytes/expanded pixel. Old engine allocates795.1MiB Metal; product path851.5MiB, independent of3/10/20 source count. Process RSS excludes some Metal/driver memory and OS cache; these measures should not be added as if disjoint physical allocations.

The first hash implementation read bounded chunks but Darwin autorelease lifetimes retained them, causing roughly1.9GiB on real3. It was rejected before scaling acceptance. Per-read autorelease pools fixed the lifetime; all accepted numbers above are reruns with this fix. Current synthetic3/10/20 peak RSS145.0/145.4/142.7MiB supports source-count-independent resident pixel memory for this workload.

## Source fidelity, coverage and QA

| Workload | Hard ownership % | Blend path % | AI ownership % | Fallback % | Low confidence % | Coverage evidence ≥ threshold % | Retained QA proposals |
|---|---:|---:|---:|---:|---:|---:|---:|
| real3 | 76.2859 | 23.7141 | 0.0000 | 0.0000 | 11.8396 | 99.6918 | 512 |
| synthetic3 | 66.3216 | 33.6784 | 0.0000 | 0.0000 | 50.0203 | 100.0000 | 512 |
| synthetic10 | 24.2476 | 75.7524 | 0.0000 | 0.0000 | 50.0188 | 100.0000 | 512 |
| synthetic20 | 37.4948 | 62.5052 | 0.0000 | 0.0000 | 99.9974 | 100.0000 | 512 |
| real3-auto | 73.9062 | 23.2180 | 2.8758 | 0.0000 | 11.8396 | 99.6918 | 512 |

Every accepted run reports explicit capturedSourcesOnly state, complete disjoint mode counts and **zero generative photographic pixels**. This constrains this engine; it does not authenticate a supplied input’s camera/editing history. Blend labels are processing paths, not a claimed exhaustive contributor set. Scalar multiband contribution weights were not retained and the inspector does not invent them. Manual/low-confidence annotations overlap disjoint modes.

Coverage is an uncalibrated absolute focus-evidence index, not objective sharpness probability. Real3 has4,291 low-evidence pixels; synthetic20 has100% threshold coverage but99.9974% low ownership confidence. This illustrates that relative ownership and absolute evidence are different; it is not evidence that all synthetic detail is photographically adequate. Current QA retains at most512 ranked cell proposals, with heuristic confidence0.5. All runs reach that cap;512 is not an exhaustive number of actual defects. No precision/recall or photographer-confirmed artifact claim is made. QA does not modify RGB.

## Photographic regression evidence

Full TIFF SHA-256 equality against frozen V2.2 holds for all five completed comparisons: real3 Off, real3 Auto, synthetic3/10/20 Off. This checks every encoded photographic output byte, including metadata, on this machine. Existing V2.2 image-quality behavior was preserved; it was not improved or declared production-ready.

384 TIFF ROI fixtures pass, including strip/tile, codecs, byte order and BigTIFF variants.24 strict and24 stable Python golden cases pass unchanged tolerances: focus-score relative error≤2e-6, candidates≤1% mismatch, labels≤0.5%, confidence≤1e-4, final≤128 uint16 codes. Current maximum final error is93 codes on both frozen V2.2 and V3. This is near-parity, not exact native/Python equality. Prior V2.2 seven-real-sample ownership outliers (maximum365 codes) remain an inherited limitation; that sample experiment was not rerun as a new V3 improvement claim.

## Real100MP manual edit and export

On the real3 project, a32×32 Use Source0 constraint at(200,200) recomputed exactly one1024² core of108, with116px dependency/read halo:0.499s cold CLI operation.107 provenance block hashes stayed unchanged. All1,024 overridden pixels equal captured reference RGB exactly;803 output pixels changed because some already matched reference. A bounded full-output segment comparison found **zero changes outside the constraint**. The initial output/originals remained intact.

Reopen/inspect succeeded. Full edited export re-encoded/validated the image in bounded strips:47.010s including baseline/output hashes and audit; encode13.185s, RGB16/ICC validation2.505s, peak process RSS46.1MiB. Exact ICC bytes were preserved. Eight logical audit records verify as a SHA-256 chain; the companion output hash matches and source filenames/URLs are omitted. Fast local fusion does not imply local TIFF encoding.

## Build, tests and launch

Final110 native tests (all86 V2.2 plus24 V3), zero failures,25.844s; unchanged Python87 tests,7.24s. macOS Debug/test and Release xcodebuild succeed. FusionProject generic arm64 iOS Release build succeeds transitively for FusionAI/FusionCore/FocusStackCore; shared code imports no AppKit/UIKit/SwiftUI. Physical iPhone/iPad execution was not performed. Benign Xcode AppIntents metadata extraction warnings report no AppIntents dependency; no substantive source/build warning remains.

Release3.0.0 app launches and creates a native810×624 window, verified using public process/window metadata. The current desktop/Space reports its onscreen flag false; an onscreen appearance is not claimed. Interactive UI gestures were not comprehensively automated. No security/privacy preferences changed.

## Product boundaries and remaining work

Source-Faithful workflow, compact provenance, separate uncertainty causes, coverage/QA proposals, project save/open/relink, ordered manual constraints, incremental recompute, bounded export and companion audit are implemented. Sources remain external references; no original20-source stack is copied into a project. Unknown same-version fields survive; format0 migration is a documented pre-release fixture, not arbitrary legacy support. Future formats are preserved without mutation. Counter/geometry limits reject malformed summaries.

Limits: real-photo bookkeeping overhead; uncalibrated coverage/QA and capped/duplicate proposals; incomplete multiband contributor accounting; rectangular/ROI editor rather than full zoom/Pencil tooling; no automatic crash-journal repair, cache compaction or collaborative transactions; no audit signing/authenticity or universal bit identity; fast edit source admission uses size/time rather than adversarial identity proof; sandboxed mobile source access remains future. V2.2 deghost IoU/recall, cloud missed-motion, thin-detail/reference-focus and nonrigid/parallax limits remain. No model was trained/changed for V3.

No native dependency was added/upgraded. Vendored LibTIFF4.7.2 terms/notices remain, with full notices added to root documentation and app resources. The developer CycloneDX1.6 inventory executed successfully (17 installed/reference/vendor/system components), outside Git. Existing training-environment versions are historical V2.2 records, not a newly installed V3 training environment.

Six future capture/refocusing features remain IP_REVIEW_REQUIRED; HDR/noise/burst/astro/panorama/super-resolution/video are extension points, not finished features. Only public-safe engineering process is committed; local research templates are ignored. No patentability, non-infringement, validity or FTO conclusion follows from this milestone.
