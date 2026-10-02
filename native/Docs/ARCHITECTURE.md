# FocusStack Native V2.1 architecture

## Reference and platform boundary

Python V1.1 (`python-v1.1`, a0680d224c3c91a82bef13f318d77d2b60e7ffc3) remains the golden reference. Foundation checkpoint is a775ab42bc54bdfbb73999418adaebc5f2357a0a. The macOS app never invokes Python. Native processing is a Swift 6 package targeting macOS 14 and iOS/iPadOS 17. It contains no AppKit/UIKit/SwiftUI, file pickers or app lifecycle code. Host apps own access permissions, UI, cancellation and mobile lifecycle/memory-pressure responses.

The package shares source-built libtiff, imaging/color metadata, similarity registration, tile planning, Metal shaders, focus/depth/multiband fusion, Core ML model resources and diagnostics. macOS Debug/Release and generic arm64 iOS compilation have executed. Mobile device execution and mobile UI remain future work.

## Production data path

`NativeStackEngine` is an actor. One core tile, one source ROI and one GPU command buffer are active at a time. Each tile has a globally aligned expanded halo. The focus pass reads every source sequentially, maintaining only three scores/indices, guide, confidence and cleaned labels. The fusion pass reads one source again, builds its temporary pyramid, accumulates into persistent per-level sums and reconstructs the tile. Completed uint16 cores go to disk-backed RGB staging. Final TIFF encoding and full segment/pixel/ICC validation precede exclusive atomic publication.

Only small file/provider/transform/report arrays grow with source count. Source count never sizes persistent image, mask or pyramid collections. Source count is limited to 65,535 by label representation. Pyramid array lengths depend on quality levels (Standard 0, High 3, Maximum 4). Metal resources are reused until region dimensions/level count change. Per-command and per-tile autorelease pools prevent completed Metal objects from retaining resources across the whole stack.

Command buffers batch compatible kernels within a focus pass, depth pass, fusion pass or reconstruction. Synchronous completion currently establishes resource ownership and timing; there is no speculative prefetch or overlapping tile pipeline. This imposes synchronization overhead but makes correctness and bounds explicit. Foundation's actor `GPUTilePipeline`/`BufferPool` remain available for hardware checks; production uses `ProductionMetalPipeline` with exclusive ownership by the stack actor.

## Spatial and memory planning

Core defaults are 1024 on desktop, 512 on mobile; smaller 512/256/128 candidates are selected if the conservative expanded-region estimate does not fit. Production maximum is 1024 desktop/512 mobile; Foundation standalone kernel benchmarks still allow 2048. Standard/High/Maximum halos are 13/52/84 pixels, with global grids 1/8/16. Inverse similarity ROI bounds include interpolation support. True image edges use REFLECT_101; internal tile boundaries sit outside the cropped core's filter support. Identity and affine small-tile versus full-region tests allow at most two uint16 codes difference.

Admission includes current RSS, desktop OS reserve max(4 GiB,25% RAM) or mobile max(512 MiB,40%), capability-based working-set caps (75% desktop/25% mobile), spatial GPU resources, fixed 2048² RGB16 upload capacity, two bounded ML feature/output buffers and temporary margins. TIFF decode separately budgets output + 3×decoded segment + 2×encoded segment + 32 MiB codec margin using current headroom, including already resident resources where reflected in RSS. libtiff has per-handle single/cumulative allocation limits. Encoding/validation budgets segment buffers too. Estimates cannot reserve RAM against competing applications; memory pressure integration remains host work.

Current/peak RSS and Metal allocated bytes are separate diagnostics. Shared-memory Metal allocations and OS file-cache residency are not completely represented by process RSS. Do not interpret 70 MiB RSS as total unified-memory consumption: the 20×100MP run also reported 673.6 MiB peak Metal allocation. Scratch needs raw RGB16 plus encoded TIFF simultaneously; a conservative disk preflight covers both and codec margin.

## Photographic math and color

RGB16 enters a UInt16 shared buffer, with alpha 65535. Explicit normalization is used where needed; all focus/depth/fusion fields and signed Laplacians are Float32. No photographic FP16 or hidden 8-bit path exists. Gaussian coefficient/noise-gain generation and registration's tiny normal equation use Double where required to match/reference numerical behavior. Encoded RGB uses Python/OpenCV coefficients 0.299/0.587/0.114; this is an algorithmic grayscale feature, not a claim of scene-linear luminance.

Safe Metal math disables implicit contraction; explicit FMAs reproduce relevant OpenCV Float32 paths. Global inverse remap coordinates and 1/32-pixel interpolation reproduce golden sampling. Negative Laplacian coefficients remain signed. Round-to-even and clipping occur once at final uint16 conversion. RGB/BGR order is explicit.

ICC bytes are retained exactly. Stack input ICC and oriented dimensions must agree; mismatches are rejected pending explicit conversion. No assumed sRGB/AdobeRGB/P3, gamma or automatic Metal color conversion occurs. ImageIO/ColorSync remain metadata/reference tools; production pixels use libtiff. Output normalizes orientation to 1, preserves resolution/ICC and safe descriptive tags. RAW/3FR, CMYK, planar/separate RGB and alpha TIFF are outside this implementation.

Registration alone uses an explicitly documented RGB16 >> 8 gray analysis reduction, never photographic output. Reduced reference/current images are at most 1024 edge desktop/512 mobile. Accelerate FFT phase correlation followed by Huber similarity refinement provides translation/rotation/uniform-scale transforms. It is a prototype: periodic texture, parallax and large local motion need stronger registration validation/feature matching before broad production use.

## ML and motion

The compact shared `FocusMotionNetProto` ML Program predicts motion and blend safety from bounded aligned reference/candidate grayscale, absolute residual, confidence and edges. Its synthetic-only quality is limited. AI defaults Off. Auto/High use conservative thresholds .97/.85, aggregate one candidate at a time and select coherent reference-frame ownership for high motion. RGB is always read from actual source images; the model never synthesizes RGB. Blend-safety is exposed by the prototype but the current ownership path uses motion probability only. Local normalized difference and optional flow features remain future experiments, not implemented model inputs.

Ordinary Core ML wraps shared Metal input memory through MLMultiArray. It copies the bounded probability output into shared Metal storage. Core ML may make internal transfers; zero-copy physical execution is not promised. ComputePlanInspector records preferred/supported devices and relative cost. Actual tested CPU+ANE execution plus ANE-preferring convolution plans support ANE suitability; the APIs do not provide a definitive physical dispatch trace.

Metal 4 APIs are compile/runtime gated at OS 26. `MetalMLPrototype` executes Metal compute → buffer-backed MTLTensor → ML package dispatch → MTLTensor → Metal compute, sharing GPU events without intermediate CPU pixel readback. It retains the ordinary Core ML fallback. Its measured cold dispatch is slower on this M1 Max and is not the default app backend. No claim of newer hardware tensor-instruction acceleration follows merely from API support. Older supported systems use standard Metal and Core ML.

Vision flow remains optional: the measured 128² request was ~495 ms, much slower than this model. It is excluded from the default hot path and never determines ownership by itself.

## Evidence and limits

See [V2.1 results](V2_1_RESULTS.md), [TIFF backend](TIFF_BACKEND.md), [Metal parity](METAL_PARITY.md) and [ML prototype](ML_PROTOTYPE.md). These distinguish complete TIFF integrity validation from sampled photographic parity. Python is still the quality reference: sparse score ties cause source-label/output differences, including ten channel values above one code in the sampled real stack. No bit-exact replacement, production deghost quality, physical iOS validation or broad registration robustness is claimed.


## V2.2 candidate deghost and registration

Registration now reports independent ambiguity evidence and rejects questionable transforms before full-resolution fusion. FocusMotionNetV1 consumes a fixed top-candidate/temporal feature contract, with native 256/208 sliding patches. Core ML backend choice uses validated local warm measurements; an optional compatible external Metal ML package participates in the same decision. Portable model/shader resources remain shared and AppKit remains host-only.

Motion components currently retain captured reference ownership. The unchanged static pyramid is reconstructed, then strong-motion final projection removes every Laplacian contribution in the detected region. This preserves exact static output outside masks while preventing coarse-level reintroduction. Candidate logits do not yet prove a better component source. Debug previews are bounded and opt-in; mask-only readback and UI overlays are separate from photographic RGB16 output.

Deflate strip encoding can use two bounded workers on larger desktop workloads; mobile defaults to one. Worker buffers are admitted against the current OS/RSS/codec budget; the TIFF handle has one owner and serialized raw-strip publication. Full decoded-pixel and ICC validation precedes exclusive atomic publication. None/LZW/tiled encoding retains the serial path.

See [V2.2 results](V2_2_RESULTS.md), [model](DEGHOST_MODEL.md) and [registration](REGISTRATION_ROBUSTNESS.md). Historical V2.1 benchmarks remain intact. Actual quality target misses and reference-defocus/static-false-positive tradeoffs are recorded; neither synthetic masks nor the existence of ANE proves photographic production quality.

## V3 product foundation

The compatibility engine remains `FocusStackCore`; new shared `FusionCore`, `FusionAI` and `FusionProject` products organize provenance, uncertainty, QA, model governance, source identity, projects, audit and local constraints. Optional evidence capture leaves V2 automatic fusion intact. The macOS host gains a source-faithful workspace and bounded ROI inspector. See [V3 product architecture](V3_PRODUCT_ARCHITECTURE.md); previous benchmark history is retained. Heuristic coverage/QA and unverified photographic AI are not presented as calibrated product guarantees.
