# FocusStack Native V2 Foundation

## Scope and reference boundary

Python FocusStack 0.2.0/V1.1 at `a0680d224c3c91a82bef13f318d77d2b60e7ffc3`
is immutable golden reference (`python-v1.1`, annotated). Native work lives on
`native-v2`. The app never launches Python. No full fusion, RAW decoding, trained
model, photographic pixel synthesis, cloud service, telemetry, or release update
system is implemented in this milestone.

## Shared Apple engine

`native/FocusStackCore/Package.swift` exports the Swift 6 `FocusStackCore` library
for macOS 14+ and iOS 17+ (including iPadOS). The package has no AppKit, SwiftUI,
UIKit, file picker, or application-lifecycle dependency. The macOS Xcode app,
benchmark tool, and native tests all link this same local package, rather than
compiling copies of engine source into separate products. The installed iOS SDK
has compiled the package successfully; no physical iPhone/iPad execution is claimed.

The shared package owns imaging/ICC abstractions, tile admission and scheduling,
Metal compute/shader resources, Core ML configuration/compute-plan inspection,
Vision motion experiments, diagnostics, and memory policy. Later focus/depth
ownership and multiband fusion belong here too; they are intentionally not ported
in Foundation. AppKit file picking, SwiftUI state/logs/views, application lifecycle,
and future mobile file/security-scoped URL handling belong to host targets.

Metal shaders are package resources, compiled through `MTLDevice.makeLibrary`
once per pipeline outside benchmark timings, with safe math and reusable pipeline
states. macOS/iOS/iPadOS use identical sources and bundle lookup. Future Core ML
assets belong to the package Models resource namespace, not individual host apps.
No model asset is packaged today; Models/Resources notes are excluded from builds.

## Tile and memory ownership

`TileProvider` reads one `TileDescriptor` with explicit global origin.
`TileScheduler` admits one descriptor before decode and rejects concurrent
producers with explicit backpressure. Clients await completion before requesting
the next source/tile; there is no resident stack, per-source resource set, or
unbounded producer queue of decoded pixels. The app also gates submissions with
MainActor state. `GPUTilePipeline` owns MetalContext, pipelines, counters, and
BufferPool in an actor, and never suspends while a GPU resource lease is held.

BufferPool retains one reusable set, replacing it when dimensions change. Shared
RGBA16Uint textures store source/copy; Float32 shared buffers store luminance and
Sobel X/Y/energy. One tile is currently in flight. The queue permits at most two
command buffers, but execution submits exactly one at a time. Three serial stages
are intentional for first-stage numerical/timing isolation. BufferPool and desktop
memory policy allow up to two leases for a future scheduler; overlapped two-tile
execution is not implemented or claimed. No heap is needed for this first reuse
scheme; model intermediates have an explicit bounded heap contract.

Descriptor dimensions are bounded to 2048. Desktop policy allows 2048/1024/512
(and smaller tiles when needed) and up to two future in-flight tiles. Mobile policy
caps the edge at 512, supports 256/128 under smaller budgets, and caps in-flight
work at one. Both policies depend on physical RAM, current RSS, and the device's
recommended working set, not chip names. Desktop OS reserve is max(4 GiB,25%
physical RAM); mobile reserve is max(512 MiB,40%). GPU budget caps are 75% and 25%
of the reported working set respectively. A zero headroom result rejects work.

The conservative working estimate is 128 bytes/pixel: GPU resources, source,
readback, CPU validation, allocation/padding and temporary margins. Native large
TIFF reads are separately rejected; bounded small ImageIO reads budget decoded
storage ×3 plus encoded file size and tile working space against available RAM.
These are conservative admission estimates, not guarantees against competing apps.
Darwin RSS/peak RSS use bytes; current Metal allocation is reported separately.
No TIFF/scratch caches are written by this prototype.

## Photographic precision and validation

A `rgba16Uint` texture is an exact 16-bit alternative to UNORM, avoiding any
implicit intermediate precision reduction. CPU packing preserves RGB order and
adds alpha=65535. The copy kernel preserves every uint16 code exactly. Luminance
explicitly normalizes integer RGB by 65535 into Float32. The coefficients
0.299/0.587/0.114 match Python V1.1 OpenCV RGB2GRAY, operating on encoded RGB;
this prototype does not assert physical scene luminance or apply a transfer curve.

Sobel uses 3×3 derivatives and REFLECT_101 image-edge extension; Tenengrad is
unblurred gx²+gy² (`radius=0` in the Python fixture). Absolute normalized tolerances
are 2e-6 luminance, 2e-5 derivatives, and 2e-4 energy. Scalar Swift CPU code is an
independent correctness/benchmark baseline, not an optimized production CPU path.
The developer-only fixture script imports the unchanged Python engine and writes
one small deterministic JSON fixture. Native tests compare all fixture pixels,
channel order, boundaries/odd sizes, and all 65,536 uint16 codes. No FP16 photo
processing or 8-bit photo path exists. Vision's explicitly separate synthetic
8-bit fixture only exercises its motion API.

Tile origins and synthetic generation are global. This milestone treats each
prototype tile as an isolated image; reflected tile boundaries are NOT a
production whole-image seam solution. Future focus/fusion must request adequate
halos, use global remap coordinates and a global dyadic pyramid grid, and pass
native affine/seam comparisons to the Python reference before use. No native
alignment or multiband fusion has been implemented.

## TIFF and color

ImageIO inspects first-image width/height, sample depth, channel count,
orientation, resolution, compression and color-space description without drawing.
A small independent bounded metadata reader extracts the original ICC tag bytes
from classic TIFF and BigTIFF in both byte orders. It only reads the first IFD
(up to 16,384 entries) and ICC payload (up to 16 MiB), validates offsets/lengths,
and rejects oversized metadata instead of silently losing a profile. These are
metadata safeguards, not TIFF segment codec caps. It is not a TIFF pixel decoder.

ColorProfile retains original ICC bytes separately from ImageIO/ColorSync's
representation and description. ImageIO may infer a named space even without an
embedded ICC; only the actual ICC tag determines presence. No transfer curve,
sRGB/AdobeRGB/P3 assumption, CGContext color conversion, or automatic texture color
conversion is applied. RGB16 ImageIO read rejects unsupported layout/alpha,
orientation and depth rather than converting. Original ICC preservation is ready
for a future writer; no native image output writer exists yet.

The real 101.897952 MP TIFF crop probe demonstrated a ~1.16 GiB peak allocation.
Therefore public ImageIO cropping is not accepted as a production bounded decoder.
The normal TileProvider only permits full decoded images <=64 MiB and obeys the
additional memory admission budget. The explicit benchmark `--imageio-probe`
raises that guard for one measured developer experiment in a fresh process; it is
never called by the app. No streaming claim is made from the small returned crop.

A future production backend should evaluate a maintained libtiff integration
(with license/build/security review), handling strips, tiles, compression,
BigTIFF, endian/layout/orientation, large segment allocations and ICC explicitly.
Budget encoded+decoded segments and margins dynamically; don't impose arbitrary
fixed segment caps. Very large compressed strips need measured decode bounds,
backpressure and scratch strategy. No TIFF binary dependency is added now. TIFF
codec support on iOS and BigTIFF ImageIO pixel decoding remain unvalidated.

## Acceleration and motion

Standard Metal compute is the always-supported baseline for supported Apple
Silicon. Every Metal 4 symbol is compiler and macOS 26/iOS 26 availability gated.
Capabilities use GPU family queries, a real small Float32 tensor allocation, and
construction of a real MTL4 ML encoder without dispatching a network. Both succeed
on this M1 Max. No inference, GPU tensor/neural instruction acceleration, or model
quality is inferred from these probes. New devices benefit through capability
queries/resources instead of chip-name branches; older OS versions retain standard
Metal. Older OS fallback is logic-tested, not physically executed on this Mac.

Core ML enumerates CPU/GPU/ANE using MLComputeDevice and defaults configuration to
`.all`. Detected ANE presence does not establish model placement. CoreMLRunner owns
an explicitly loaded compiled model; no model is shipped. ComputePlanInspector
walks program blocks, neural-network layers and pipeline submodels, reporting
preferred/supported devices and relative cost weights where provided. Compute
plans are predictions, not executed placement/performance measurements. Model
loading/plan inspection have compiled but cannot be execution-tested without a
model. MetalMLBridge accepts caller-owned tensor/argument/pipeline/heap resources
on the GPU timeline and contains no CPU readback; actual ML dispatch is untested.

MotionAnalyzer runs Vision optical flow only on equal tiles <=2048², requests
Float32 two-component vectors, and records time/size/format/bytes/RSS. The 128²
translated synthetic fixture executed successfully. Flow is an experimental future
AI feature input and never determines final source ownership. Request input color
handling is Vision's responsibility; no photographic fusion is based on it.

## Validation and limits

macOS Debug native tests, Debug/Release Xcode builds, physical app/window launch,
iOS package compilation, RGB16 hardware kernels, real TIFF metadata/crop probe,
and Vision execution are recorded in the local hardware and baseline documents.
The only Xcode build warning is AppIntents metadata extraction skipped because no
AppIntents dependency exists; there are no Swift/Metal source warnings.

3/10/20 scaling checks exercise sequential 512² synthetic sources in fresh
processes, not native 20×100 MP stacking. Full native photographic acceptance,
compressed/tiled 100 MP codec coverage, iPhone/iPad hardware tests, memory pressure
notifications/lifecycle integration, complete fusion and real AI models are future
milestones. Python V1.1 remains the production golden engine.

## Apple API references

Installed SDK headers/interfaces and physical tests take precedence over assumed
availability. Useful primary references:

- [Metal 4 introduction](https://developer.apple.com/videos/play/wwdc2025/205/)
- [Metal machine-learning passes](https://developer.apple.com/documentation/metal/machine-learning-passes)
- [GPU/CPU timestamp calibration](https://developer.apple.com/documentation/metal/converting-gpu-timestamps-into-cpu-time)
- [ImageIO image-at-index decoding](https://developer.apple.com/documentation/imageio/cgimagesourcecreateimageatindex(_:_:_:))
- [Core ML compute plan device usage](https://developer.apple.com/documentation/coreml/mlcomputeplandeviceusage)
