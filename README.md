# FocusStack V1.1 production core (0.2.0)

Disk-backed RGB TIFF focus stacking for Linux and native macOS Apple Silicon.
Production validation uses `--quality max`. No GUI, RAW, ML, Metal, database,
network service, or hidden color conversion is included.

## Install / CLI

```sh
python -m pip install -e '.[test]'
focusstack ./input -o stacked.tif --quality max --alignment affine \
  --tile-size auto --memory-budget auto --compression zstd \
  --temp-dir /fast/scratch --benchmark-stages --report-json run.json
python -m pytest -q
```

Use native arm64 Python on Apple Silicon, rather than an x86_64/Rosetta environment:

```sh
arch -arm64 /opt/homebrew/bin/python3.12 -m venv .venv
source .venv/bin/activate
python -c 'import platform; print(platform.machine())'  # must print arm64
python -m pip install -e '.[test]'
python -m pytest -q
```

Dependencies: NumPy, headless OpenCV, tifffile, imagecodecs, psutil, tqdm; pytest
for tests. pip selects compatible native wheels. Linux Python 3.10/3.12 runs in
GitHub Actions; native macOS execution has not been measured in this cloud
session. RSS unit conversion and unsupported-advice behavior have unit tests.

Directory input is lexical order; explicit file order is retained. Use numbered
filenames and keep output outside the input directory. Frames must have equal
oriented shape, bit depth, and ICC profile bytes/presence. Output cannot overwrite
an input. Supported TIFFs: single-page contiguous three-channel RGB uint8/uint16,
strip/tiled, compressed/uncompressed, BigTIFF, either byte order, orientations 1–8.
Unsupported planar, RGBA, grayscale, packed depths, pyramidal/multipage TIFF and
RAW layouts are rejected clearly.

| Option | Default / behavior |
| --- | --- |
| `-o`, `--output` | Required TIFF destination |
| `--quality standard\|high\|max` | `standard` retains V1-compatible scoring/blending; high/max use multiband |
| `--tile-size auto\|INTEGER` | 1024; auto chooses 2048/1536/1024/512 within budget |
| `--memory-budget auto\|SIZE` | Auto: <=4 GiB and <=60% of available RAM; explicit example `8G`, `512MiB` |
| `--tile-overlap` | Complete finite filter/pyramid support; unsafe smaller values rejected |
| `--alignment affine\|translation\|none` | `affine` similarity (translation, rotation, uniform scale) |
| `--alignment-max-dim` | 4096 ceiling; only actually consumed resolution <=2048 is generated |
| `--reference INDEX` | Zero-based; default `frame_count // 2` |
| `--focus-radius` / `--blend-radius` | 3 / 8 pixels |
| `--multiscale` | Optional V1 standard-mode coarse evidence; high/max already combine scales |
| `--compression none\|zlib\|zstd\|lzw` | Lossless zlib output |
| `--temp-dir` / `--keep-temp` | System temp / retain caches and report path, including on failure |
| `--max-workers` | 2 OpenCV threads; no process pool or per-source workers |
| `--verbose` | Feature/inlier/geometry/overlap/score diagnostics per frame |
| `--benchmark-stages` | Print separate stage seconds |
| `--report-json FILE` | Machine-readable result, transforms, diagnostics, RAM/RSS, stage timings |
| `--version` | Print version |

`FOCUSSTACK_TILE_SIZE`, `FOCUSSTACK_ALIGNMENT_MAX_DIM`, and
`FOCUSSTACK_MAX_WORKERS` override integer defaults; explicit flags take precedence.
Set `OMP_NUM_THREADS=2` and `OPENBLAS_NUM_THREADS=2` before Python for controlled
native threading. Normal output reports stages, size/count, RAM budget/reservation,
chosen tile/halo, alignment summary, runtime and peak RSS.

## Processing / quality

TIFF headers, segment tables, RAM and both scratch/output filesystems are checked
before decoding. Mappable inputs have one mapping each; compressed/non-mappable
inputs are decoded once, sequentially, into uint8/uint16 raw disk caches. Codec
allocation is budgeted from encoded size, decoded size, current RSS, alignment
workspace and a safety margin. A ~600 MB compressed single strip is accepted when
safe: there is no fixed 64 MiB cap. The decoder releases its previous segment
before decoding another. Large-segment copies and dirty cache pages are bounded
and range-flushed in batches. No full-resolution float image or full-stack array
is constructed.

Alignment uses deterministic separable area sums over <=512×512 source blocks;
global integer bins combine partial sums exactly across block boundaries.
Orientation-1 compressed decoding produces alignment data in the same pass and
stores it on disk, avoiding a full cache rescan. Other orientations currently
use a separate streaming pass. Only the reference and current reduced images
are resident. Phase at <=512 and SIFT/RANSAC at <=2048 provide coarse hypotheses;
normalized-correlation ECC-style refinement at <=1024 updates only similarity
DOFs at every iteration. Higher-resolution verification and geometry validation
reject low correlation (<0.2), scale outside 0.8–1.25, rotation >15 degrees, or
<60% overlap. Reference features are reused. Diagnostics include features,
inliers/ratio, scale, rotation, translation, overlap and final score.

Each expanded tile evaluates frames sequentially. High/max scoring combines
prefiltered multi-scale Sobel and Laplacian energy, a local noise-floor estimate,
structure-tensor coherence that protects directed fine edges, and local contrast
balancing. Statistics have finite support, with no tile-global noise estimates.
Only top-three float32 scores and compact uint8/uint16 indices are retained.
Low-confidence median cleanup must select a local candidate and avoids strong
edges; focus ordering is not assumed to describe a planar depth surface.

Fusion processes selected sources sequentially. Confidence, structure and label
boundaries control transition width. Strong focused edges and thin detail retain
hard RGB ownership. High/max accumulate weighted Laplacian RGB and Gaussian mask
weights at 3/4 reductions, respectively. Only the current source pyramid and
accumulator pyramids exist, regardless of frame count. Coarse ownership guards
and final confident-edge reconstruction suppress defocused silhouette colors.
Negative Laplacian values are retained; RGB is rounded/clipped once at final
uint16 conversion. Reference fallback is read only when pixels lack coverage.

Pyramids share a global dyadic grid and complete analysis/synthesis halos. ROI
warps use global-coordinate float32 remaps, avoiding tile-dependent OpenCV affine
increment rounding. Tests compare small tiles to a single tile, including odd
sizes, max quality and affine transforms. Matrices and small optimization normal
systems use float64; local pixel processing remains float32.

## Memory / output / metadata

The auto planner respects Linux cgroup limits as well as host RAM, reserves dirty
pages, and counts clean active/inactive file cache as reclaimable. Process
file-descriptor soft limits are raised within the hard limit for 255+ sources.

RAM depends on tile area, pyramid levels, reduced analysis, codec segment size and
small per-frame bookkeeping. Scratch grows with source count. For 20×12000×8300
RGB16, raw source bytes total 11.952 GB; mappable TIFFs do not need decoded copies.
Compressed caches require 597.6 MB/frame, plus 597.6 MB raw output, small cached
analysis images and a conservative atomic final-TIFF reservation. Disk checks sum
requirements on one filesystem or check each separately. RSS measurements are
process lifetime peaks; Linux KiB and macOS byte units are normalized.

Mapped writes are flushed over bounded ranges; supported memory advice releases
clean pages after bounded work. Missing/unsupported advice degrades without a
crash; OS reclaim of clean file-backed pages is platform dependent. The planner
is conservative, but cannot guarantee resources against competing processes.

Output encodes one bounded strip at a time to a sibling temporary TIFF, selects
classic TIFF/BigTIFF from a conservative size bound, reopens and decodes **every
strip**, verifies RGB shape/uint16/ICC, fsyncs, then atomically replaces the final
filename. Errors/Ctrl-C remove scratch and partial output, preserving the old
output before replacement. SIGKILL/power loss can leave orphan scratch or sibling
`.tmp` files; they do not publish a partially written final TIFF.

RGB order is preserved; uint8 expands by 257 to uint16. Reference ICC bytes,
resolution/unit, Artist, Copyright, DocumentName, DateTime and plain description
are copied safely. Orientation is normalized to 1, swapping X/Y resolution for
transposed input. Structural tags, shape JSON, OME XML, EXIF/GPS, maker notes,
XMP and arbitrary private tags are not copied. ICC passthrough is not profile
validation or color conversion. Fusion uses source encoded RGB; no gamma or
transfer function is guessed. Inputs should have consistent exposure/color space.

## Reproducible benchmarks

All benchmarks are opt-in. TIFFs are generated sequentially from bounded texture
blocks, never a resident source stack. Uncompressed profiles use directly
mappable strips. Engine RSS is measured in a fresh child process when generating
new data; `--reuse` is a fresh engine process too. Stage timings include caching,
alignment-image generation, feature alignment, focus, regularization, fusion,
encoding, full validation and total. JSON reports input/output bytes, raw scratch,
peak scratch including the final encoded temporary TIFF, and source-MP/s.

```sh
python -m benchmarks.run --profile medium --quality max --compression none
python -m benchmarks.run --profile 100mp --frames 20 --compression none \
  --quality max --alignment none --tile-size auto --work-dir /fast/scratch --keep
# Reuse the root printed by the preceding command; no second 12 GB dataset:
python -m benchmarks.run --reuse /fast/scratch/ROOT --frames 20 \
  --quality max --alignment affine --tile-size auto --report-json B.json
python -m benchmarks.run --profile 100mp --frames 3 --compression zlib \
  --quality max --alignment affine --tile-size auto --work-dir /fast/scratch
python -m benchmarks.quality --report-json quality.json
```

`benchmarks.dataset` generates a reusable mappable dataset. `benchmarks.compress`
transcodes one mapped source to tiled compression or an opt-in single-strip
fixture. `--keep` retains generated artifacts; normal generated benchmarks remove
them. Reused datasets are not removed. Small/medium/100mp default to
640×480/3, 3072×2048/6, 12000×8300/20. No huge workload runs in pytest/CI.

For memory scaling, generate one 20-frame medium dataset, then reuse it in three
fresh processes with `--frames 3`, `10`, `20`, keeping quality/tile size fixed.
Measured RSS at max quality/1024 tiles was **227.48 / 227.52 / 222.96 MiB**;
input bytes grew from 108 to 720 MiB. Bookkeeping does not retain pixel stacks.

Measurements and detailed stage/quality comparisons are in
[benchmarks/RESULTS.md](benchmarks/RESULTS.md). Results are generated synthetic
photographs on Codex Cloud, not a claim about all real photographic scenes.

## Remaining limits

The global similarity model cannot repair moving subjects, parallax, local
lens distortion or perspective. Focus/noise estimation is heuristic; ambiguous
flat regions lack true depth evidence, and complex real occlusions can retain
halos. Max improves the tested synthetic boundaries but does not infer unseen
background or perform deconvolution. Multiband fusion uses encoded RGB and does
not reconcile exposure/ICC transforms. No I/O prefetch is added: measurements
favored reducing rescans, flushes and unnecessary reads without queue complexity.
Native Apple Silicon behavior is architecturally supported but needs validation
on physical macOS hardware. Full-size generated workloads and exact limitations
are reported individually in the measurement document.

## Native V2.1

Python 0.2.0 / V1.1 above remains the unchanged golden reference at
`a0680d224c3c91a82bef13f318d77d2b60e7ffc3` (`python-v1.1`). Native work is
isolated on `native-v2`; the app never invokes Python.

Open `native/FocusStack.xcodeproj`, shared `FocusStack` scheme. The Swift 6 SwiftUI
host targets Apple Silicon macOS 14+. `native/FocusStackCore` is a shared macOS /
iOS 17+ / iPadOS package without AppKit/UIKit. It now includes source-built
libtiff bounded ROI/output, native similarity registration, Float32 Metal
focus/depth/protected multiband fusion, and an optional compact synthetic motion
mask model. Metal 4 inference is capability-gated at OS 26; ordinary Core ML
remains the app fallback. AI defaults Off and never synthesizes RGB.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project native/FocusStack.xcodeproj -scheme FocusStack \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/FocusStackNativeDerived test
xcodebuild -project native/FocusStack.xcodeproj -scheme FocusStack \
  -configuration Release -derivedDataPath /tmp/FocusStackNativeDerived build
/tmp/FocusStackNativeDerived/Build/Products/Release/FocusStackBenchmarks
(cd native/FocusStackCore && xcodebuild -scheme FocusStackCore \
  -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO build)
```

A real 3×101.9MP stack and generated 20×100MP native pipeline completed on the
M1 Max. Python remains the photographic quality reference: rare score ties,
prototype alignment and synthetic-only AI remain limitations. See
[measured V2.1 results](native/Docs/V2_1_RESULTS.md),
[architecture](native/Docs/ARCHITECTURE.md),
[TIFF backend](native/Docs/TIFF_BACKEND.md),
[Metal parity](native/Docs/METAL_PARITY.md),
[ML prototype](native/Docs/ML_PROTOTYPE.md), and
[local hardware](native/Docs/LOCAL_HARDWARE.md).
ImageIO remains metadata/small-image reference, never the production large-TIFF
pixel decoder. Generated TIFFs, fixtures, training checkpoints, reports and build
products stay outside Git.
