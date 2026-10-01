# Local Apple hardware and toolchain

Measured on the physical development Mac on 2026-10-01 (Europe/Oslo).

| Item | Detected value |
| --- | --- |
| Mac | MacBook Pro, MacBookPro18,2 |
| Architecture / chip | arm64 / Apple M1 Max |
| CPU cores | 10 (8 performance, 2 efficiency) |
| Physical unified memory | 32 GiB (34,359,738,368 bytes) |
| macOS | 27.0, build 26A428 |
| Xcode | 27.0, build 27A266a |
| Swift | Apple Swift 6.4, swiftlang-6.4.0.34.1, clang-2100.3.34.1; Swift 6 language mode |
| macOS SDK | 27.0 |
| iOS SDK | 27.0; shared core compiled for arm64 iOS 17 deployment |
| Metal device | Apple M1 Max, unified memory true |
| Recommended Metal working set | 26,800,603,136 bytes (24.960 GiB) |
| Maximum Metal buffer | 20,100,448,256 bytes (18.720 GiB) |
| Max threadgroup dimension tuple | 1024 × 1024 × 1024 (not their product) |
| Actual luminance pipeline thread width / total thread limit | 32 / 1024 |
| Max threadgroup memory | 32,768 bytes |
| Relevant supported families queried | Apple7, Mac2, Common3, Metal3, Metal4; Apple8/Apple9 false |
| Validated texture extent | 2048² RGBA16Uint; no public MTLDevice maximum 2D dimension query used |
| GPU counters | timestamp set; stage sampling true, dispatch sampling false |
| GPU timestamp frequency diagnostic | 24,000,000 ticks/s (SDK API; measured timings use paired clock calibration) |
| Core ML devices | Apple Neural Engine (16 cores), GPU: Apple M1 Max, CPU |
| Metal 4 probe | Family support true, real 16×16 Float32 ML/compute tensor allocated, ML encoder constructed |
| Model execution | No production model loaded; no ML network dispatched |
| Vision | VNGenerateOpticalFlowRequest exposed and executed on 128² fixture |

The system's active developer directory is `/Library/Developer/CommandLineTools`.
Plain `xcodebuild -version` initially failed because that directory is not full
Xcode. All native Xcode commands used a local environment override:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

No global xcode-select, privacy, security, or system-permission changes were made.
SDK path: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.
The CLT SDK also reports 27.0; full Xcode was used for validation.

Initially `xcrun -f metal` located Xcode's launcher, but `metal --version` reported
that the optional Metal Toolchain was missing; metallib and metal-package-builder
were unavailable. Apple's `xcodebuild -downloadComponent MetalToolchain` installed
Metal Toolchain 27A266a. All three now resolve under the Apple-mounted
`Metal.xctoolchain/usr/bin` path (the cryptex mount suffix is ephemeral).

## Installed API evidence

The installed macOS SDK contains:

- Metal.framework/Headers/MTLTensor.h: MTLTensor, descriptor/extents and ML/compute
  usage, available macOS 26/iOS 26; newer auxiliary planes are macOS/iOS 27.
- Metal.framework/Headers/MTL4MachineLearningCommandEncoder.h: ML pipeline,
  argument table and heap dispatch, macOS 26/iOS 26.
- Metal.framework/Headers/MTLDevice.h: Metal4 GPU family, tensor allocation,
  command allocator/buffer creation, queue/resource sizes, counters and timestamps.
- CoreML.framework headers + Swift module interface: MLComputeDevice enumeration
  (macOS 14/iOS 17) and MLComputePlan/deviceUsage/estimatedCost (macOS 14.4/iOS 17.4).
  The Swift model structure is an enum, traversed recursively for pipeline models.
- Vision.framework/Headers/VNGenerateOpticalFlowRequest.h: two-component optical
  flow, accuracy and output-format properties; macOS 11/iOS 14 and later.

The source uses explicit platform availability checks for these APIs. Physical
M1 Max resource probes establish tensor/encoder availability, while newer GPU
neural/tensor acceleration and actual model execution remain unmeasured.

## Build and launch evidence

`xcodebuild` Debug/Release builds and macOS native tests succeeded. The same
FocusStackCore package built for `generic/platform=iOS` with signing disabled;
this is a compile check only. The Release macOS app launched through `open`.
NSWorkspace reported finishedLaunching=true, and the system window list showed
an on-screen `FocusStack Native` window, 900×692. No screenshot or UI-interaction
permission was needed. Button automation was not exercised; their shared engine
paths were executed through tests and the benchmark tool.
