# V1.1 measured validation

Codex Cloud, Linux x86_64, Python 3.12, NumPy 2.3.5, OpenCV 4.14.0,
tifffile 2026.9.20, imagecodecs 2026.8.16. Host reports 17.59 GiB, but the
**enforced cgroup RAM limit was 16 GiB** (`memory.max=17179869184`).
`memory.events` reported `oom=0`, `oom_kill=0`, `oom_group_kill=0`.
File-backed filesystem cache also charges to the cgroup and is reclaimed by the
kernel; it is not the process RSS below. Native workers: 2. Auto budget: 4 GiB.
Auto tiles: 2048, max halo: 84 plus dyadic grid alignment. All sources are real
**12000×8300 (99.6 MP) RGB uint16 TIFFs**, not thumbnails or repeated file links.
All frames/pixels are evaluated. Each final TIFF was fully reopened/decoded
before atomic replacement, with RGB uint16 shape and ICC/resolution verified.
Generation, tests and other small jobs sometimes overlapped; these are observed
cloud wall times, not isolated throughput guarantees. Engine RSS comes from fresh
processes and excludes generator memory. No raw TIFFs or result JSON are committed.

## Full-size results

| Run | Frames / source layout / alignment | Quality | Runtime s | Peak RSS MiB | Raw scratch MiB | Peak temporary storage MiB | Input MiB | Output MiB | Source-MP/s |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 20 / mappable / none | max | 241.428 | 636.92 | 569.92 | 1124.85 | 11398.35 | 554.93 | 8.251 |
| B | 20 / mappable / affine | max | 376.421 | 736.48 | 569.92 | 1123.68 | 11398.35 | 553.76 | 5.292 |
| C | 3 / compressed tiles / affine | max | 90.958 | 736.55 | 2287.97 | 2803.52 | 1518.04 | 515.55 | 3.285 |
| D | 1 / compressed single strip / reference | max | 53.057 | 1187.26 | 1139.83 | 1648.22 | 508.36 | 508.39 | 1.877 |

**20×100MP status: A and B passed end-to-end under the 16 GiB cap.**
C transcodes A frames 0, 9 and 19, validating three full-size compressed frames and integrated cache/alignment
generation. D validates a 597,600,000-byte decoded single strip; the encoded
segment is about 508 MiB. Its peak is higher because the codec must retain one
encoded/decoded segment during preparation, not because of source count.
D has one frame, so alignment is the identity reference and analysis is skipped.
Raw scratch includes decoded caches, cached grayscale and uint16 output scratch.
Peak temporary storage adds the encoded sibling TIFF before atomic replacement;
input datasets and pre-existing final outputs are listed separately and excluded.
A peak temporary storage is derived from measured raw scratch + output size.

## Stage timings (seconds)

| Run | Prep/cache | Analysis generation | Features/refinement | Focus | Depth cleanup | Fusion | Encoding | Full validation | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 0.006 | 0.000 | 0.000 | 185.630 | 1.339 | 33.475 | 14.749 | 1.596 | 241.428 |
| B | 0.006 | 34.307 | 13.538 | 219.569 | 1.269 | 89.578 | 14.674 | 1.557 | 376.421 |
| C | 10.621 | 1.511 | 1.441 | 32.193 | 1.421 | 21.991 | 17.557 | 1.970 | 90.958 |
| D | 7.650 | 0.000 | 0.000 | 10.491 | 1.143 | 9.109 | 20.441 | 1.656 | 53.057 |

Stage totals exclude some scan/header work, core output paging/writes, fsync
and orchestration; total includes those. Cache-integrated analysis time is
subtracted from preparation and listed in analysis generation, not counted twice.

## Memory scaling

Same 3072×2048 RGB16 dataset, quality=max, alignment=none, tile=1024, fresh
process for each count. Source prefixes are reused; missing focus planes in a
prefix do not alter the fact that every supplied source pixel is processed.

| Frames | Input MiB | Runtime s | Peak RSS MiB |
| ---: | ---: | ---: | ---: |
| 3 | 108.00 | 6.220 | 227.48 |
| 10 | 360.01 | 9.491 | 227.52 |
| 20 | 720.02 | 15.923 | 222.96 |

RSS is flat while input storage grows 6.7×. Scratch may scale with count for
compressed inputs; this comparison uses mappable inputs.

## V1 speed / profile comparison

Baseline is the unmodified commit `5b46f805283194dd49bdfa150b374100460decf6`.
Same six-frame compressed 3072×2048 dataset, affine analysis ceiling 1024,
core tile 1024. V1 completed in **11.01 s**, 236.6 MiB RSS (profiled run).
Its profile attributed 3.69 s to `np.add.at`, 3.90 s to reduced-gray generation
and 1.40 s to mmap flushes. V1 without alignment completed in 5.237 s.
Final V1.1 standard completed in **4.938 s**, 235.34 MiB RSS: **2.23×** faster.
Final V1.1 max completed in **9.389 s**, 250.53 MiB RSS, including its extra
focus scales/top-K/multiband work. This is a specific workload comparison, not
a universal max-quality speed claim. Full-size V1 timings were not measured.

## Objective quality comparison

`python -m benchmarks.quality` generates deterministic textured backgrounds,
bright/dark foreground objects, one/two-pixel crossing branches, known sharp
ground truth, sharp foreground in one frame and a blurred silhouette over sharp
background in another. Boundary bands are fixed from ground-truth geometry.
Actual unmodified V1 was run from the baseline checkout: its MSE values match
the retained standard mode exactly. Errors below are in uint16-value squared units.

| Scene / metric | V1 | V1.1 max | Change |
| --- | ---: | ---: | ---: |
| dark / mse | 2246939.500 | 1910628.375 | 14.97% lower |
| dark / halo_mse | 8273938.500 | 6739182.500 | 18.55% lower |
| dark / thin_mse | 0.000 | 0.000 | exact in both |
| bright / mse | 3027531.250 | 2444993.750 | 19.24% lower |
| bright / halo_mse | 10503519.000 | 8035004.000 | 23.50% lower |
| bright / thin_mse | 0.000 | 0.000 | exact in both |

Max seam difference is **0** for both difficult scenes; V1 differences are
1 (dark) and 0 (bright). Fine foreground structure error remains zero. Tests
also cover noisy-source rejection, ambiguous/crossing planes, high/max multiband
reconstruction, odd-size and affine seam equivalence, 20-source and >255-index
paths, compressed caches, adaptive segment budgeting, portable RSS/advice, and
interruption cleanup. The final suite passes **87 tests**. All original test cases remain; assertions for the changed
version/dynamic segment contract were updated.

## Reproduction

```sh
python -m benchmarks.dataset /fast/scratch/full/input --frames 20
python -m benchmarks.run --reuse /fast/scratch/full --frames 20 --alignment none --quality max --tile-size auto --report-json A.json
python -m benchmarks.run --reuse /fast/scratch/full --frames 20 --alignment affine --quality max --tile-size auto --report-json B.json
python -m benchmarks.compress /fast/scratch/full/input/frame-000.tif /fast/scratch/compressed/input/frame-000.tif
python -m benchmarks.compress /fast/scratch/full/input/frame-009.tif /fast/scratch/compressed/input/frame-001.tif
python -m benchmarks.compress /fast/scratch/full/input/frame-019.tif /fast/scratch/compressed/input/frame-002.tif
python -m benchmarks.run --reuse /fast/scratch/compressed --frames 3 --alignment affine --quality max --tile-size auto --report-json C.json
python -m benchmarks.compress /fast/scratch/full/input/frame-000.tif /fast/scratch/single/input/frame-000.tif --single-strip
python -m benchmarks.run --reuse /fast/scratch/single --frames 1 --alignment affine --quality max --tile-size auto --report-json D.json
python -m benchmarks.quality --report-json quality.json
```

For scaling: generate a 3072×2048/20-frame dataset with `benchmarks.dataset`,
reuse it with `--frames 3`, `10`, `20`, `--quality max --alignment none
`--tile-size 1024`, in separate processes. The single-strip generator spools
compression to disk; the optional TIFF writer still needs one encoded segment
as bytes, isolated from engine RSS measurement.

## Limits

Synthetic improvement does not establish quality on all photographic occlusions.
No unseen-background reconstruction/deconvolution, exposure/profile conversion,
local geometric alignment or native acceleration is provided. Fusion uses
encoded RGB. Native macOS execution/throughput remains unmeasured; portability
unit tests and an arm64 install path are provided. No 100MP task was blocked by
disk or time in this session.
