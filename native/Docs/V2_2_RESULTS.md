# Native V2.2 measured results — 2026-10-02

Physical MacBookPro18,2, Apple M1 Max, 32 GiB unified memory; macOS27.0 (26A428), Xcode27.0 (27A266a), Swift6.4, macOS/iOS SDK27.0. The actual M1 supports and executed Metal tensors/Metal4 ML. CPU/GPU/16-core ANE enumeration is retained. These are local measurements, not a physical iOS validation or a definitive per-operation hardware trace.

## Preserved baseline

Started clean on native-v2 at 7b93e2895865aea59ce5d7703ffd3f838f719d34; annotated native-v2.1 points there. Python work/python-v1.1 remain a0680d224c3c91a82bef13f318d77d2b60e7ffc3. Before edits, 62 native and 87 Python tests passed and the real three-frame Maximum/AI Off stack completed in 54.085s (alignment12.850, decode5.746, GPU focus3.277/fusion1.307, encode21.019, validation2.238; peak RSS140.234MiB/Metal673.625MiB). Historical V2.1 documentation and numbers remain intact.

## Registration

The known 100MP periodic source pair is explicitly rejected as ambiguous (confidence .151), rather than returning the false approximately485px offset. Real-stack confidence .9365/.9343, local agreement1.0 and pyramid disagreements .0694/.1071 reduced pixels accept the unchanged V2.1 transforms. Periodic grids/windows/bricks/checkerboards and weak texture reject; random texture, grass, translation, rotation/scale and focus blur pass. See [independent evidence and limitations](REGISTRATION_ROBUSTNESS.md).

## Synthetic model-only validation

560 independent held-out 128² examples (40/category), seed2207001, probability threshold .5. FPR here counts only entirely static focus-only examples, not static pixels adjacent to labelled motion. Targets are goals; misses remain visible. Pure-static IoU/precision/recall are undefined.

| Category | IoU | Precision | Recall | Focus-only FPR % |
|---|---:|---:|---:|---:|
| grass | 0.819 | 0.906 | 0.895 | 1.816 |
| leaves | 0.831 | 0.843 | 0.984 | 0.125 |
| branches | 0.915 | 0.933 | 0.978 | 0.014 |
| hair | 0.829 | 0.883 | 0.931 | 1.127 |
| flowers | 0.734 | 0.801 | 0.898 | 0.788 |
| cloud | 0.782 | 0.936 | 0.826 | 0.004 |
| water | 0.899 | 0.943 | 0.950 | 0.000 |
| waves | 0.900 | 0.939 | 0.956 | 0.100 |
| cloth | 0.842 | 0.945 | 0.886 | 0.195 |
| occlusion | 0.808 | 0.826 | 0.974 | 0.105 |
| silhouette | 0.798 | 0.841 | 0.940 | 0.221 |
| static_defocus | — | — | — | 0.242 |
| bokeh | — | — | — | 0.992 |
| noise | — | — | — | 0.066 |

## Actual native policy/fusion validation

168 new held-out 192² hard cases (12/category), seed2211001, four RGB16 captured candidates. Native Metal photographic focus, fixed candidate features, final Core ML model, gating/components and Maximum fusion all execute. Auto/High are fixed .90/.65 probability gates plus safety/ownership-confidence conditions. Different size, difficulty and operating threshold make this a separate benchmark from model-only validation. FPR below counts all labelled static pixels, including motion boundaries. Entirely static-case FPR is reported separately in the diagnostic table.

| Category | Auto IoU | P | R | Static-pixel FPR % | High IoU | P | R | Static-pixel FPR % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| grass | 0.653 | 0.933 | 0.685 | 3.539 | 0.682 | 0.872 | 0.758 | 7.963 |
| leaves | 0.845 | 0.913 | 0.919 | 0.882 | 0.821 | 0.846 | 0.966 | 1.779 |
| branches | 0.841 | 0.948 | 0.881 | 6.158 | 0.852 | 0.899 | 0.942 | 13.441 |
| hair | 0.749 | 0.928 | 0.795 | 7.592 | 0.764 | 0.869 | 0.864 | 16.138 |
| flowers | 0.800 | 0.935 | 0.847 | 0.643 | 0.806 | 0.860 | 0.928 | 1.656 |
| cloud | 0.486 | 0.976 | 0.492 | 2.415 | 0.594 | 0.965 | 0.607 | 4.452 |
| water | 0.840 | 0.990 | 0.847 | 0.769 | 0.891 | 0.980 | 0.908 | 1.746 |
| waves | 0.747 | 0.995 | 0.750 | 0.762 | 0.797 | 0.986 | 0.806 | 2.386 |
| cloth | 0.765 | 0.993 | 0.769 | 0.847 | 0.808 | 0.984 | 0.819 | 2.184 |
| occlusion | 0.717 | 0.933 | 0.755 | 0.535 | 0.743 | 0.829 | 0.878 | 1.801 |
| silhouette | 0.909 | 0.957 | 0.948 | 0.478 | 0.881 | 0.892 | 0.986 | 1.327 |
| static_defocus | — | 0.000 | — | 0.174 | — | 0.000 | — | 1.251 |
| bokeh | — | 0.000 | — | 0.006 | — | 0.000 | — | 0.242 |
| noise | — | 0.000 | — | 0.019 | — | 0.000 | — | 0.075 |


Aggregate native policy: Auto IoU 0.7297, precision 0.9633, recall 0.7506, background FPR 1.289%, fully-static-case FPR 0.173%; High IoU 0.7687, precision 0.9241, recall 0.8205, background FPR 3.034%, fully-static-case FPR 0.579%. All168 cases contribute and weak categories remain explicit.

Many production IoU/recall goals are **not met**, particularly grass, hair, cloud and occlusion. Background boundary false positives also exceed3% in some categories. Better raw-model validation must not be presented as production-policy success.

| Category (Auto) | Fully static-case FPR % | Ownership accuracy | Halo MSE | Double-edge MSE | Thin gradient ratio | Static reconstruction MSE | FN rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| grass | 0.011 | 0.884 | 0.000182 | 0.000168 | 1.376 | 1.88e-05 | 0.315 |
| leaves | 0.000 | 0.986 | 0.000726 | 2.66e-05 | — | 1.9e-05 | 0.081 |
| branches | 0.000 | 0.929 | 0.000185 | 1.57e-05 | 1.080 | 3.43e-05 | 0.119 |
| hair | 8.507 | 0.892 | 0.000373 | 8.92e-05 | 1.428 | 0.000204 | 0.205 |
| flowers | 0.000 | 0.982 | 0.000395 | 9.34e-05 | — | 1.02e-05 | 0.153 |
| cloud | 0.000 | 0.760 | 9.27e-05 | 6.56e-05 | — | 1.15e-05 | 0.508 |
| water | 0.000 | 0.929 | 8.13e-05 | 3.3e-05 | — | 2.67e-06 | 0.153 |
| waves | 0.000 | 0.857 | 9.49e-05 | 0.000126 | — | 7.42e-06 | 0.250 |
| cloth | 0.000 | 0.917 | 9.87e-05 | 2.32e-05 | — | 5.24e-06 | 0.231 |
| occlusion | 0.000 | 0.978 | 8.38e-05 | 4.41e-05 | — | 2.04e-06 | 0.245 |
| silhouette | 0.000 | 0.992 | 0.000382 | 3.56e-05 | — | 9.2e-06 | 0.052 |
| static_defocus | 0.174 | 0.999 | 0 | 0 | — | 1.6e-06 | 0.000 |
| bokeh | 0.006 | 1.000 | 0 | 0 | — | 3.03e-08 | 0.000 |
| noise | 0.019 | 1.000 | 0 | 0 | — | 2.48e-07 | 0.000 |

RGB MSE uses normalized [0,1] encoded channels. Halo is a two-pixel external truth band versus AI Off. Double-edge is gradient residual to coherent captured reference on labelled motion, a proxy rather than a perceptual ghost score. Thin ratio compares gradient norm to that reference; it does not prove recovery of the sharpest detail. Ownership target is reference in motion and original Off ownership elsewhere. Exactly **zero** RGB16 pixels changed outside detected masks across all168 cases in both modes. Static errors inside false-positive masks remain measurable.

The same-crop old pairwise prototype is evaluated with its original sampling, native confidence and PyTorch weights. Original Auto (.97) is very conservative: only7.45% aggregate motion recall and .0276% FPR across static_defocus/bokeh/noise. Original High (.85) reaches37.53% recall with6.349% static-focus FPR. V2.2 Auto’s three static-focus categories average .0665% FPR, substantially below old High while detecting much more motion. Original Auto still has a lower aggregate static-only FPR: a uniform improvement claim would be false. At a common raw .5 threshold the old prototype is poorly calibrated to the native focus-confidence contract (97.73% FPR); thresholds/protocols must always accompany these numbers.

## Real photographic stack

Three existing 11656×8742 (101,896,752px each) RGB16 Hasselblad TIFFs with exact560-byte Adobe RGB1998 ICC and300dpi. A V2.2 audit corrected the historical byte-order description: originals are big-endian; native/golden decoding already handled it correctly. All final output pixels were decoded and compared with raw staging, and exact ICC was verified before exclusive publication. Five private512² regions (grass, thin stems, cloud, water, static rock) have reference/Off/Auto/High100% and nearest200% previews with source ICC, masks/probability maps and RGB16 TIFFs outside Git. Full stack debug maps are bounded1536px previews and can miss fine masks; native tile maps preserve100% detail.

| Mode | Alignment s | Decode s | AI s | Focus GPU s | Fusion GPU s | Encode s | Validate s | Total s | Peak RSS MiB | Metal MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 7.857 | 5.704 | 0.000 | 3.109 | 1.279 | 11.204 | 1.881 | 41.117 | 237.438 | 795.078 |
| auto | 3.900 | 5.456 | 10.849 | 3.047 | 1.344 | 10.816 | 1.891 | 47.080 | 353.406 | 801.078 |
| high | 3.958 | 5.883 | 12.511 | 3.213 | 1.394 | 11.399 | 2.070 | 49.137 | 353.609 | 801.078 |

These single local runs have different filesystem/cache/device conditions; stage timings do not establish a controlled speedup. Earlier reruns varied substantially. Auto/High selected locally measured Core ML configurations (recorded in the external reports). The real outputs use ordinary Core ML; optional Metal-backend crop execution is reported separately.

Crop review is mixed. Motion masks trigger in grass/stems/water and preserve captured single-source RGB; some visually static rock pixels are replaced. The reviewed cloud crop receives no mask in either mode. Reference ownership can retain reference defocus in moving foreground, sacrificing local focus. No manual photographic masks have been reviewed; real IoU/precision/recall cannot be claimed. The external annotation preparation is executed, stays unreviewed/ignore by default and is reserved for validation, not training. Moving photographic quality is **not solved** and photographer review is required before relying on AI output.

## Core ML and warm Metal ML

124,327-parameter portable source package; masks only. Twenty warmed iterations of the same final256² fixture/configuration, model load and first prediction separated. Memory is process RSS lifetime peak in this sequential multi-configuration process, not total unified-memory usage.

| Configuration | Load ms | First ms | Warm mean ms | Min ms | Tiles/s (warm mean) | Peak RSS MiB | PyTorch probability max error |
|---|---:|---:|---:|---:|---:|---:|---:|
| all | 221.947 | 8.089 | 2.826 | 2.474 | 353.875 | 43.250 | 0.005794 |
| cpu | 27.103 | 5.557 | 4.586 | 4.479 | 218.063 | 51.766 | 0.013389 |
| cpuGPU | 53.196 | 38.932 | 2.843 | 2.044 | 351.693 | 54.938 | 0.003587 |
| cpuANE | 170.121 | 7.320 | 1.805 | 1.355 | 553.996 | 58.750 | 0.005794 |

Metal ML: setup141.168ms, cold ML GPU20.999ms/cold bridge end-to-end24.593ms, **warm median GPU1.281ms / bridge end-to-end2.045ms**,20 iterations reusing pipeline/tensors/heap/events. PyTorch max probability error0.003587. Bridge includes GPU pre/post copies; Core ML table is prediction-only, so timings are not identical work scopes. The runtime selector measures its own comparable shared-buffer prediction scope, not these unrelated timings.

Actual optional-package crop calibration selected **metalML**, warm2.174ms, against its locally measured Core ML alternatives, and all five crop modes executed. Ordinary real-stack calibration preferred CPU+ANE instead. Device load/cache conditions can change the winner; M1 support is never conditional on Metal4. The app defaults to the portable Core ML source package; compatible compiled Metal packages are supplied explicitly by the host/developer.

Per-configuration MLComputePlan traversal executed. Major convolution/decoder operations expose ANE as supported and ordinarily preferred with .all/CPU+ANE; CPU casts/glue remain. Preferred/supported labels are plans, not definitive physical execution traces. Conversion warns that coremltools9’s validated PyTorch version is2.7.0 whereas this existing venv uses2.7.1; actual fixture/inference validations, not version assumptions, support the measured compatibility.

## TIFF output and bounded memory

Two fixed compression slots use independent horizontal predictors/zlib streams; only the owner writes TIFF raw strips, in order. There is no queued strip collection. Desktop images≥16MP can use two workers after memory admission; mobile/small images default to one. None/LZW/tiled compression remain serial. RGB16 strip round trips through both libtiff and ImageIO are exact, including an odd final strip. Final real AI Off encoding took11.204s vs pre-change21.019s; this is a local before/after observation, not a controlled multi-run speedup claim. Output remains Deflate/horizontal predictor; source ICC/resolution preserved. Raw staging611,380,512bytes, peak raw+published output about1.095GB, independent of input count.

## Full 3/10/20 ×100MP scaling

20 actual10000×10000 RGB16 on-disk sources (12GB raw pixels), known identity transforms, Maximum,1024² cores,84px halo, one active tile, AI Off. This validates the architecture and hot-path memory after new candidate/statistic buffers and encoder changes; it does not validate periodic registration or20-frame AI quality.

| Sources | Decode s | Focus GPU s | Fusion GPU s | Encode s | Total s | Peak RSS MiB | Metal MiB | Raw scratch bytes | Output bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 3 | 15.619 | 3.706 | 1.252 | 7.711 | 32.462 | 70.375 | 795.078 | 600000000 | 232335104 |
| 10 | 42.079 | 10.750 | 3.625 | 7.487 | 71.458 | 70.500 | 795.078 | 600000000 | 235753934 |
| 20 | 105.181 | 23.782 | 7.298 | 7.273 | 153.608 | 70.641 | 795.078 | 600000000 | 239300176 |

Persistent Metal resources are source-count independent. Process RSS excludes some GPU/driver allocations and OS file cache; Metal allocated size also does not expose every Core ML allocation. No whole source stack or full-frame float pyramid is resident. Mobile remains smaller tile/one-flight/resource-budget based and is compile-validated only.

## Numerical ownership stability

Positive score intervals use a local first-order Float32 γ32 error envelope, including noise-floor cancellation terms; candidate comparisons require overlapping intervals and effectively zero confidence (≤64 Float32 epsilon). Stable fallback chooses deterministic candidate/reference order only if the existing spatial median has no eligible candidate, the edge is unprotected and the path is High/Maximum. Exact zero evidence, valid median decisions, protected thin structures, Standard behavior and confidently different choices are preserved. This is a conservative heuristic around rounded local inputs, not a formal bound for the complete upstream pipeline.

The first broad rule increased sampled outliers to665 channels/max2706 codes and failed policy parity. It was rejected. The narrower rule passes all24 fixtures and restores the unchanged V2.1 sampled result: ten channel values above one code, maximum365; all other sampled pixels differ by at most one code. Seven native samples plus unchanged Python reference execute with identical transforms/global grids. The remaining large differences are **not reduced**; claiming the numerical goal achieved would be false. Candidate/median/edge preservation tests protect against shipping the rejected behavior.

## Validation and remaining limits

Final **86 native tests** (original62 +24 V2.2) and **87 Python tests** pass. macOS Debug/test and Release xcodebuild succeed. Shared generic arm64 iOS Release build succeeds. The Release2.2.0 app launches with a running process and an onscreen native window, verified through public window metadata; no privacy/security settings changed. All384 TIFF fixtures and24 strict/24 stable policy parity fixtures execute successfully. Python golden code is unchanged. No TIFFs, private images, training datasets/checkpoints, compiled ML packages, caches or raw benchmark outputs belong to Git.

Quality limits: Auto/High IoU and recall targets remain unmet in several categories; static false positives are nonzero and some thin-detail/background categories exceed3%; reference ownership can lose foreground focus; the cloud photographic crop is missed; real labels are unreviewed; component grouping is per bounded tile, with coherent reference choice across tiles; candidate logits do not yet choose better focused component sources; calibration is a short local fixture rather than broad backend equivalence; parallax/nonrigid registration and physical iOS execution remain unvalidated. These prevent a claim of production photographic readiness even though computational validation and the requested real workloads execute.


Production-readiness status: computational work and local validations are delivered, but photographic target goals and rare ownership-parity improvement are incomplete. This commit must not be described as a production-quality deghost release.
