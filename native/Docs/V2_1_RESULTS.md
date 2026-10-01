# Native V2.1 measured results — 2026-10-01

## Hardware and validation

Physical MacBookPro18,2 / Apple M1 Max / 32 GiB unified memory; macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4, macOS/iOS SDK 27.0. Apple M1 Max Metal device reports 26,800,603,136-byte recommended working set, unified memory, Apple7/Mac2/Common3/Metal3/Metal4 families. Tensor allocation, Metal 4 ML encoder and real model dispatch succeeded. CPU/GPU/16-core ANE enumeration executed.

- 62 native XCTest tests passed (35 Foundation + 27 V2.1), zero failures.
- 87 immutable Python tests passed; Python code/tests/config remain identical to python-v1.1.
- 384 independent TIFF ROI fixtures and 24 three-quality Python/Metal comparisons passed.
- macOS Debug/tests and Release xcodebuild succeeded; shared arm64 iOS Release compilation succeeded. No physical iOS execution claimed.
- Updated final Release macOS app launched; NSWorkspace reported finishedLaunching=true and the public window list showed a visible “FocusStack Native” window, 900×692. System Events interaction was blocked by existing Accessibility settings; no settings were changed. Processing paths executed through tests/CLI; picker/button automation was not performed.
- No Swift/C/Metal source warnings in final builds; Xcode's AppIntents extractor reports no dependency and skips extraction.

## Full native real photographic stack

3 × 11656×8742 = **101,897,952 pixels/source**, RGB16, real Hasselblad-derived TIFFs; Maximum, AI Off, native similarity registration, 1024² cores, 84-pixel globally aligned halo, 108 tiles, one in flight. Each source has one giant uncompressed strip. Decode uses production bounded rows. Native pipeline performs focus, top-three, depth cleanup, protected multiband fusion, RGB16 Deflate output and complete decode-again validation.

| Stage | Seconds |
|---|---:|
| Alignment, including bounded reductions/I/O | 15.422 |
| Tile ROI decode, focus/fusion passes | 5.366 |
| GPU focus, including warp/top-K | 2.953 |
| GPU depth | .088 |
| GPU pyramids/fusion/reconstruction | 1.144 |
| CPU upload copies | .204 |
| CPU final readback/crop | .041 |
| Encode | 20.996 |
| Complete output validation | 1.917 |
| Total wall time | **54.562** |

Stage scopes differ and omit setup/CPU scheduling/raw writes, so their sum is not total wall time. Peak RSS **151,584,768 bytes / 144.56 MiB**; final RSS 123.73 MiB; peak Metal **706,347,008 bytes / 673.625 MiB**. Output 483,261,718 bytes, raw staging 611,380,512 bytes; simultaneous raw+TIFF scratch 1,094,642,230 bytes (~1.02 GiB), removed staging after success. Exact ICC560 bytes/Adobe RGB1998, RGB16, orientation1 and 300dpi are preserved. Every output segment equals native staging exactly; this checks output integrity, not equivalence to all Python photographic pixels.

Native transforms a,b,tx,ty: source2 [1.0006482021,.00003292694,-3.38647,-3.74169], source3 [1.0011786980,.00002558141,-6.63011,-6.75555]. Native correlations .999752/.999619. Python 1024-reduced SIFT/RANSAC+similarity-ECC: source2 [1.0005489588,.000040987998,-2.67962,-3.18366], source3 [1.0011190180,.00001782319,-6.25901,-6.35295], correlations .999751/.999614. Subpixel/full-resolution transform differences depend on reduction/optimizer; no assertion of identical registration. Synthetic native translation/rotation/scale tests recover known transforms within .5px at tested points.

Seven sampled real cores versus Python with the same native transforms had p99=0 and mean .000081–.000590 uint16 codes. Six cores max1; one edge core had ten channel values above1, maximum365. See [parity limits](METAL_PARITY.md). Native remains a prototype quality replacement.

## Full 3/10/20 × 100MP architecture scaling

20 actual on-disk synthetic inputs, each 10000×10000 RGB16 (600,000,000 raw pixel bytes, 12GB total pixel data). Known identity geometry was supplied for this architecture test. Maximum quality, AI Off, 1024² cores/84halo, one active tile; actual libtiff reads, Metal focus/depth/fusion, final TIFF encoding and full validation executed in fresh processes. These are full images, not repeated small logical tiles.

| Sources | Decode s | GPU focus s | Depth s | GPU fusion s | Encode s | Validate s | Total s | Peak RSS MiB | Peak Metal MiB |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 3 | 15.051 | 3.613 | .057 | 1.218 | 14.666 | 1.193 | **43.050** | 74.02 | 673.625 |
| 10 | 46.460 | 11.380 | .059 | 3.814 | 14.530 | 1.305 | **84.011** | 71.52 | 673.625 |
| 20 | 109.585 | 23.588 | .059 | 7.758 | 14.355 | 1.331 | **165.394** | 69.80 | 673.625 |

20-source CPU upload1.234s/readback.076s. Output239,300,176 bytes; raw staging600,000,000, scratch peak839,300,176 bytes (~.782 GiB). No OOM; persistent Metal allocation is independent of source count. Process RSS is not total unified memory or OS file cache. Disk cache/desktop activity affect timing; results are local observations, not controlled speedup claims.

An exploratory periodic synthetic run with automatic registration completed but chose erroneous repeated-pattern offsets (up to ~485px). That run is excluded from geometry validation. Known identities isolate memory/processing scaling; the real three-frame run independently tests the native registration path. A stronger ambiguous-pattern registration gate/feature path is required before production use.

```sh
.venv/bin/python native/Developer/generate_100mp.py --artifacts /tmp/fs-100mp --count 20
# zsh arrays: choose fresh output paths; files must not exist.
inputs=(/tmp/fs-100mp/synthetic-*.tif)
$BENCH --stack-identity /tmp/fs-3.tif ${inputs[1,3]}
$BENCH --stack-identity /tmp/fs-10.tif ${inputs[1,10]}
$BENCH --stack-identity /tmp/fs-20.tif $inputs
$BENCH --stack "$OUTPUT" "$SOURCE1" "$SOURCE2" "$SOURCE3"
```

## Detailed GPU microbenchmark

One 1024² Maximum region, three logical synthetic sources, opt-in fixed timestamp counter buffer. Times aggregate all matching kernels across both passes, include counter instrumentation/cold effects and are not full-stack values. Pipeline states persist and kernels are batched into command buffers.

| GPU operation group | ms |
|---|---:|
| Warp/upload representation | 1.991 |
| Gray/moments | .253 |
| Noise | .764 |
| Structure tensor | .839 |
| Evidence | 2.800 |
| Score accumulation | 3.245 |
| Gaussian aggregation across stages | 15.791 |
| Top-K | .735 |
| Depth | .259 |
| Cleanup | .211 |
| Pyramid downsampling | 5.115 |
| Fusion accumulation | 2.661 |
| Reconstruction | .826 |
| Final uint16 | .203 |

GPU command-buffer groups: focus26.925ms/depth.729ms/fusion12.666ms; CPU upload1.911ms/readback.892ms. Individual counter scopes and command-buffer totals may differ; they must not be summed into an unrelated end-to-end estimate. `$BENCH --production-timing` reproduces these scopes.

## I/O, ML and remaining limits

Production real1024² ROI incremental RSS8.5MiB versus Foundation ImageIO peak1184.75MiB, exact Python crop. [TIFF details](TIFF_BACKEND.md). Core ML final model14,631 bytes, CPU+ANE mean.553ms, .all.914ms; compute plan prefers ANE for conv/ReLU/sigmoid, CPU casts. No definitive physical device trace. Actual Metal4 compute/tensor/ML/tensor/compute dispatch GPU6.932ms, bridge8.186ms cold, no intermediate CPU pixel readback. [Model details](ML_PROTOTYPE.md).

Known limits: sparse score-tie output differences; prototype registration can be ambiguous; synthetic-only AI IoU.523 and false positives; AI Off default; no definitive ANE trace; Metal ML experiment slower/cold and outside app backend; mobile compile only; no RAW/alpha/planar/CMYK/JPEG/ZSTD; giant compressed100MP segment memory and >4GB automatic output switch not benchmarked; tiled ImageIO pixel interoperability is limited on this SDK; no broad photographic/user review or power-loss durability test. These limits prevent declaring a production-quality replacement for Python V1.1.
