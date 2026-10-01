# Current V2.1 baseline

Full-image native TIFF/focus/depth/fusion and real Core ML/Metal ML measurements are in [V2.1 results](V2_1_RESULTS.md). The following Foundation measurements are historical and use a simpler kernel pipeline; do not compare them directly with full production fusion.

# Native foundation baseline

Measured 2026-10-01 on the physical Apple M1 Max MacBook Pro, 32 GiB unified
memory, macOS 27.0/Xcode 27.0/Swift 6.4. All numbers below are executed measurements,
not predictions of full native stacking or other devices. Engine: shared
FocusStackCore package, Swift 6 mode, Release `-O`, safe shader math, exact RGBA16Uint
source/copy and Float32 luminance/gradients. See LOCAL_HARDWARE.md for SDK details.

## GPU tile measurements

Synthetic input is deterministic RGB16 with all-channel variation. Each size has
one warmup followed by three measured runs in a single fresh benchmark process;
table entries are medians per metric (not one selected run). The real row is one
cold run after a separate ImageIO memory probe, with a 1024² crop of the actual
101.897952 MP TIFF. GPU timings exclude file decoding, shader compilation, initial
pipeline creation and resource allocation. Benchmarking runs serially, outside
native tests; the host desktop remained active (no power/thermal controls changed).

| RGB16 tile | Upload ms | Luminance ms | Sobel/energy ms | Readback ms | GPU total ms | Pipeline wall ms | CPU reference ms | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Synthetic 1024² | 1.463 | 0.116 | 0.112 | 1.656 | 0.310 | 4.527 | 7.873 | 107.19 |
| Synthetic 2048² | 4.316 | 0.432 | 0.387 | 6.138 | 1.075 | 12.596 | 27.781 | 407.38 |
| Real source 1024² crop | 1.642 | 0.117 | 0.110 | 4.407 | 0.303 | 11.721 | 8.132 | 1184.75 |

Stage times use a persistent `MTLCounterSampleBuffer` with two samples at compute
encoder boundaries, calibrated with paired CPU/GPU clock samples. This M1 Max
exposes timestamp counters and stage sampling; dispatch sampling is unavailable.
The engine falls back to command-buffer GPU timestamps if counter creation or
resolution fails. All reported runs used the counter path.

GPU total sums exact copy + luminance + Sobel/energy. Upload and readback are CPU
wall times on shared memory, including result copies; pipeline wall includes
three serial command submissions/completions and readback. CPU reference computes
luminance+Sobel/energy only; its equivalent GPU work is luminance+Sobel columns,
not upload/copy/readback. The CPU implementation is a scalar correctness baseline,
not Accelerate/vImage or an optimized competitor. No speedup ratio is asserted.

Metal allocation at the end of the 1024² and 2048² runs was
36.391 / 144.391 MiB,
respectively. Conservative full tile working estimates are 128/512 MiB. Process
peaks include input, readback, CPU reference, validation and allocator residency;
the 2048² peak is cumulative after the smaller benchmark. There is no native
scratch cache or image output (scratch peak 0 bytes for these tile runs).

Maximum synthetic errors over all pixels/runs: luminance
1.1920929e-07, derivative 4.7683716e-07, energy 3.33786e-06.
Absolute tolerances: 2e-6 / 2e-5 / 2e-4 on normalized Float32 values. Exact uint16
copy validation passed, including the exhaustive 65,536-code test. The small
Python V1.1 golden fixture passed in native tests. The real crop's RGBA16 bytes
matched an independently mapped Python/tifffile source region byte-for-byte
(including channel order, with explicit alpha=65535). Only the developer check
uses Python; the native app and engine do not.

## Real 100 MP TIFF metadata and ImageIO decode memory

The read-only source is a real Hasselblad-derived TIFF already on the local disk:
11656×8742 = 101,897,952 pixels (101.897952 MP), RGB, uint16, orientation 1,
compression 1 (uncompressed strips), 300×300 dpi. An embedded ICC tag contains
560 original bytes; ImageIO/ColorSync describe Adobe RGB (1998). That profile name
is detected metadata, not an assumed color space or applied conversion.

The bounded first-IFD metadata reader retains exact ICC bytes. ImageIO metadata
inspection in a fresh process increased RSS from
7.47 to 12.02 MiB.
No pixel provider data was requested for that metadata measurement.

The independent `--imageio-probe` process explicitly allowed full decode to
measure cropping behavior. Before metadata RSS was
7.52 MiB; after metadata 11.95 MiB; after 1024² crop/read current RSS 26.64 MiB, lifetime peak **1184.75 MiB (1242300416 bytes)**.
The peak was about 1.16 GiB although the returned RGBA16 tile is only 8 MiB.
**This is not a production bounded ROI TIFF decode.** The large intermediate
allocation was released before the post-read current-RSS measurement; reporting
only current RSS would conceal it. The app never invokes this probe; ordinary
ImageIOTileProvider reads reject large sources before decoding.

This result concerns one real orientation-1 uncompressed strip TIFF on this SDK.
It does not prove compressed/tiled/BigTIFF decoding behavior. Classic/BigTIFF ICC
header parsing in both byte orders is unit tested, separately from pixel decoding.
No new TIFF binary dependency or streaming claim was introduced.

## Sequential-source memory scaling

Fresh Release processes, fixed 512² RGB16 tile, one reusable resource set,
sequential logical sources whose synthetic global origins differ. These are
3/10/20-source **tile prototype** checks, not full 20×100 MP native stacking.

| Logical sources | Final RSS MiB | Peak RSS MiB | Resource allocations | Max in-flight tiles |
| --- | ---: | ---: | ---: | ---: |
| 3 | 38.39 | 38.39 | 1 | 1 |
| 10 | 39.38 | 39.38 | 1 | 1 |
| 20 | 38.44 | 38.44 | 1 | 1 |

Source count did not increase a resident image/mask/pyramid collection. All
sources are generated and processed one at a time. Scratch peak was 0 bytes.

## Vision optical flow

128² synthetic image pair with a one-pixel shift, Vision low accuracy,
TwoComponent32Float (`2C0f`) output. Executed result:
128×128, 131072 bytes, 296.154 ms. RSS before/after 9.08/56.50 MiB; peak 59.77 MiB.
The first native test's cold Vision execution took about 18 seconds while system
Vision initialization occurred; the separate warm-system report above should not
be interpreted as cold startup performance. No deghost/source ownership logic uses
flow, and no photographic motion-quality acceptance is claimed.

## Build, tests and launch

- Python reference: 87/87 tests pass locally; engine/tests/benchmarks and `work`
  remain unchanged at a0680d224c3c91a82bef13f318d77d2b60e7ffc3.
- macOS: Debug test build and Release app/benchmark build pass through xcodebuild.
- Native XCTest: 35/35 pass on physical Apple Silicon, including GPU kernels,
  golden fixture, ICC/header bounds, resource reuse, pre-decode backpressure and
  mobile memory-envelope rejection. No hardware test was faked or skipped.
- Shared FocusStackCore: iOS 27 SDK arm64 compile, deployment iOS 17, succeeds with
  signing disabled. iOS/iPadOS UI and physical-device execution are not included.
- Release SwiftUI app: NSWorkspace finishedLaunching=true, visible
  `FocusStack Native` window 900×692. No privacy/security settings were changed.
- No production Core ML/Metal ML model was loaded or executed. CPU/GPU/16-core ANE
  enumeration, tensor allocation and ML encoder construction succeeded.

## Reproduce

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project native/FocusStack.xcodeproj -scheme FocusStack \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/FocusStackNativeDerived test
xcodebuild -project native/FocusStack.xcodeproj -scheme FocusStack \
  -configuration Release -derivedDataPath /tmp/FocusStackNativeDerived build
xcodebuild -project native/FocusStack.xcodeproj -scheme FocusStackCore \
  -destination 'generic/platform=iOS' -sdk iphoneos -configuration Release \
  -derivedDataPath /tmp/FocusStackNativeIOSDerived CODE_SIGNING_ALLOWED=NO build
BENCH=/tmp/FocusStackNativeDerived/Build/Products/Release/FocusStackBenchmarks
"$BENCH" > /tmp/focusstack-native-baseline.log
"$BENCH" --metadata /path/to/private/source.tif
# Developer-only experiment: full ImageIO decode may allocate >1 GiB.
"$BENCH" --imageio-probe /path/to/private/source.tif
"$BENCH" --vision
for count in 3 10 20; do "$BENCH" --scaling "$count"; done
PYTHONPATH="$PWD" .venv/bin/python native/Tools/generate_reference_fixtures.py
PATH="$PWD/.venv/bin:$PATH" .venv/bin/python -m pytest -q
```

Logs, Xcode products and real TIFFs stay outside Git. The only committed fixture
is ~4 KiB deterministic synthetic JSON. These summaries do not certify full
native stacking, additional TIFF codecs, model placement, or mobile hardware.
