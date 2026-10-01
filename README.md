# FocusStack V1

A Linux Python CLI for large RGB TIFF focus stacks. Source storage and output are
file-backed; alignment is reduced-resolution and fusion is tiled. There is no GUI,
RAW reader, ML model, or platform-specific acceleration.

## Install and run

Python 3.10+ on Linux, with NumPy, headless OpenCV, tifffile, imagecodecs, psutil and
tqdm. Codecs must have wheels compatible with your Python version.

```sh
python -m pip install -e '.[test]'
focusstack --version
focusstack ./input -o stacked.tif
focusstack a.tif b.tif c.tif -o stacked.tif \
  --tile-size 1024 --alignment affine --compression zlib
python -m pytest -q
```

Files from directories are sorted lexically; number filenames with zero padding
when frame order matters. Explicit file arguments retain their order. Inputs must
have the same oriented dimensions, bit depth, and ICC profile bytes (including
consistent profile presence). The output must differ from all
inputs; move any previous output out of an input directory before rerunning.

| Option | Default / behavior |
| --- | --- |
| `-o`, `--output` | Required destination TIFF |
| `--tile-size` | 1024-pixel core tiles |
| `--tile-overlap` | Automatically calculated finite filter support (13 at default radii); smaller unsafe halos rejected |
| `--alignment` | `affine` (translation, rotation, uniform scale); also `translation`, `none` |
| `--alignment-max-dim` | 4096-pixel ceiling for reduced analysis |
| `--reference` | Zero-based index; default `frame_count // 2` |
| `--focus-radius` | 3-pixel Tenengrad aggregation radius |
| `--blend-radius` | 8-pixel mask Gaussian radius; 0 disables spatial mask blur |
| `--multiscale` | Add coarse focus evidence; increases required halo |
| `--compression` | `zlib`; lossless `lzw`, `zstd`, or `none` |
| `--temp-dir` | System temp; choose a fast disk with adequate free space |
| `--max-workers` | 2 OpenCV threads; TIFF decoding/encoding remains sequential |
| `--keep-temp` | Retain raw caches/output scratch and report the location, including on failure |
| `--verbose` | Per-frame transform, alignment method, and score |
| `--version` | Print version |

`FOCUSSTACK_TILE_SIZE`, `FOCUSSTACK_ALIGNMENT_MAX_DIM`, and
`FOCUSSTACK_MAX_WORKERS` override their defaults; explicit CLI options take
precedence. For reproducible performance, also set `OMP_NUM_THREADS=2` and
`OPENBLAS_NUM_THREADS=2` before starting Python. Progress reports frame count,
shape, dtype, RAM/disk estimates, tile count, alignment summary, stage, elapsed
time and process lifetime peak RSS. Interactive terminals also show a tile bar.

## Algorithm

1. Inspect TIFF headers and segment tables, normalize orientation using mapping
   views, validate the stack, and check available RAM and scratch/output disk.
2. Use direct mmap for compatible TIFF layouts. Otherwise decode one strip/tile
   at a time into a raw disk-backed cache; no full-frame decoder call is used.
3. Read fixed 512×512 source blocks and area-average into reduced uint8
   grayscale analysis images.
   SIFT descriptors (at most 2048 pixels on the longest side) and RANSAC estimate
   source-to-reference partial affine transforms. ECC at at most 1024 pixels may
   refine them. Phase correlation provides a translation fallback. Validation
   requires correlation >=0.2, scale 0.8–1.25, rotation <=15 degrees, and overlap
   >=60%; failure identifies the frame and stops rather than silently misaligning.
4. For each expanded destination tile, inverse-transform its bounds and warp a
   source ROI. Pixel math uses float32 luminance and local Sobel energy followed
   by finite-support Gaussian aggregation. Optional multiscale combines fine and
   prefiltered coarse evidence. Invalid warp neighborhoods cannot win focus.
5. The first pass retains best/second scores and compact labels, derives relative
   score separation, and median-cleans low-confidence labels. The second pass
   reads selected sources sequentially, smooths their masks, keeps firm choices
   where scores separate, and accumulates weighted RGB and total weights. It
   never retains all RGB tiles, masks or score maps. Pixels without blend coverage
   use the reference. Crop the halo and write the uint16 core to output scratch.
6. Encode bounded strips to a sibling temporary TIFF, reopen and decode every
   strip to validate shape/dtype/RGB and ICC passthrough, fsync, and atomically
   replace the destination. Normal failures and Ctrl-C remove caches and partial
   TIFFs; existing destination contents survive failures before replacement.

Full-resolution warps and full-frame floating-point images are never created.
Transform matrices use float64 for coordinate accuracy; processing images/maps
use float32. Equal scores resolve to the earliest frame for deterministic output.
Tile seams are checked against a single-tile result, including affine warps and
multiscale filters. Blend code is separate so multiband fusion can replace it.

## Memory and storage

RAM scales with expanded tile area, two small alignment representations, codec
segments and feature workspace. Source count increases scratch storage and
processing time, not the number of resident full-resolution arrays. Mmaps are
virtual mappings of files, **not retained decoded images in RAM**. Linux mmap
pages are explicitly evicted after bounded operations, with output/cache writes
flushed before eviction; otherwise repeated reads could accumulate process RSS.
The OS may retain reclaimable filesystem cache separately.

For `N` compressed 12000×8300 RGB uint16 frames, decoded cache storage is about
`N × 597.6 MB` (decimal), plus another 597.6 MB for raw output and a conservative
final TIFF reservation. Directly mappable inputs need no decoded copies. The
engine checks both filesystems when scratch/output live on different disks and
sums reservations when they share one. Estimates are conservative, not guarantees
against competing jobs or disk changes during processing. Reduce tile size and/or
analysis dimension if the RAM preflight rejects a job.

Non-mappable TIFF segments larger than **64 MiB encoded or decoded** are rejected
with instructions to retile or use shorter strips. A single giant compressed
strip cannot be decoded by the codec with a tile-sized memory bound. Normal
photographic tiled TIFFs and reasonable strip TIFFs use the cache fallback.
The engine rejects sparse/missing segments rather than treating corruption as
black pixels. The final TIFF automatically uses BigTIFF when its conservative
size reservation exceeds classic TIFF limits.

## Color and metadata

Source and output channel ordering is RGB. uint16 stays uint16; uint8 expands by
257 into the full uint16 range. TIFF orientations 1–8 are applied through views
and output Orientation is 1; X/Y resolution swaps for transposed orientations.
The reference supplies exact ICC bytes, resolution/unit, plain descriptive
ImageDescription, Artist, Copyright, DocumentName, and DateTime when present.
TIFF layout tags, shape JSON, OME XML, EXIF/GPS, maker notes, XMP and arbitrary
private tags are not copied. ICC passthrough is not color conversion or profile
validation: inconsistent profile bytes/presence are rejected, and inputs should
share one color space and exposure. No gamma
linearization, exposure matching, or ICC transform is performed. Fusion operates
in the supplied encoded RGB values.

## Tests and benchmarks

Tests generate small scenes at runtime: two focus planes, odd dimensions, tile
seams, deterministic fusion/alignment, translation/rotation/scale, source counts
including >255 labels, all TIFF orientations, endianness, compression, metadata,
CLI execution, and resource/corruption/interruption cleanup. No TIFF fixtures are
committed.

Benchmarks are opt-in and generate each source TIFF sequentially, one tile at a
time, using global-coordinate texture and known focus stripes. The engine runs
in a fresh child process so generator RSS does not contaminate its peak. Runtime
includes caching, fusion, TIFF encoding and complete output validation. Scratch
usage is logical raw-file size, not an RSS estimate. Outputs are deleted by
default; `--keep` retains them in the reported directory.

```sh
python -m benchmarks.run --profile small
python -m benchmarks.run --profile medium
python -m benchmarks.run --profile medium --alignment affine --alignment-max-dim 1024
# Explicit large workload: about 100 MP/frame, 10 frames by default.
python -m benchmarks.run --profile 100mp --frames 10 --work-dir /fast/scratch
```

Profiles: small 640×480/3 frames, medium 3072×2048/6 frames, 100mp
12000×8300/10 frames. Use `--frames`, `--tile-size`, `--compression` (source TIFFs),
`--max-workers`, and `--alignment` to compare workloads. The 100MP profile is
never part of normal tests.

Measured on Codex Cloud (Python 3.12, NumPy 2.3.5, OpenCV 4.14, tifffile
2026.9.20, imagecodecs 2026.8.16): the medium profile with compressed inputs,
1024-pixel tiles and alignment disabled processed six frames in **5.72 s**, with
**132.3 MiB peak RSS**, **252 MiB scratch**, and **35.1 MiB output**. Generation
was 4.45 s. Twelve frames used 144.5 MiB peak RSS and 468 MiB scratch, taking
9.94 s. The affine benchmark on six frames with 1024-pixel analysis completed in
10.47 s at 231.7 MiB peak RSS, with 252 MiB scratch and 35.0 MiB output.
These are synthetic measurements, not a measured 100MP throughput claim.

## V1 limitations

Only single-page contiguous RGB uint8/uint16 TIFFs are supported. Planar,
RGBA, grayscale, multi-page/pyramidal, RAW and packed depths require conversion.
The focus score favors contrast and can favor noise; flat or similarly blurred
areas cannot provide reliable depth. Mask fusion can retain halos around complex
occlusions and is not multiband reconstruction. Alignment is global and assumes
modest focus breathing; it cannot fix moving subjects, parallax, local distortion
or perspective. No source profiles/exposure are reconciled automatically. TIFF
input/cache and output encoding are sequential; there is no distributed or
multiprocess pipeline. SIGKILL/power loss can leave orphan scratch files or sibling
`.tmp` files, but never a partially renamed final TIFF. Performance on a full
10–30-frame 100MP photographic stack remains to be measured.
