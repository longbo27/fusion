# Production TIFF backend

## Dependency and supported layouts

libtiff 4.7.2 is vendored as portable C source with its upstream BSD-style permissive license, provenance and archive SHA256. Swift Package targets CLibTIFF and CTIFFBridge compile natively arm64 for macOS and iOS; Apple's SDK libz supplies Deflate. No Rosetta, downloaded binary framework or runtime Python dependency is used. Rebuild source integration with `native/Developer/vendor_libtiff.py`. Upstream: [release](https://libtiff.gitlab.io/releases/v4.7.2.html), [license](https://libtiff.gitlab.io/misc.html), [source archive](https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz).

Accepted pixels are contiguous unsigned RGB8/RGB16, classic TIFF/BigTIFF, either byte order, orientation 1–8, strips/tiles, None/Deflate (both tag variants)/LZW. RGB8 expands exactly by 257. RGB16 remains exact; alpha is explicitly 65535 in internal RGBA. PackBits exists in the vendor configuration but is deliberately not admitted by this bridge. JPEG, ZSTD and other optional codecs are not shipped. Unsupported layouts fail explicitly.

## Bounded reads

TIFF opens with `rcm`: disable artificial strip chopping and whole-source mmap. Uncompressed strips use bounded `pread` row spans, including a single giant strip. Compressed strips and tiles decode only intersecting segments, sequentially, reusing one segment buffer. TIFF endian conversion is explicit for direct raw rows and handled by libtiff codecs otherwise. Orientation maps the requested oriented ROI to source coordinates before segment selection.

The plan includes ROI RGBA bytes, 3×largest required decoded segment, 2×largest encoded segment and 32 MiB codec margin. Per-handle libtiff allocations have current-budget single/cumulative limits. A giant compressed strip necessarily requires its whole codec segment: admission can allow that large allocation if safe or reject it. This is not spatially bounded to the small returned ROI. The real large source here was uncompressed, so no full-image codec allocation was necessary. Giant compressed 100MP segments have not been physically benchmarked; small whole-compressed-strip fixtures exercised the same path. Metadata tables/ICC/descriptive tags also consume bounded current-budget allocations, rather than arbitrary fixed codec caps.

## Physical 101.897952MP source measurement

Source: 11656×8742, RGB16, classic little-endian TIFF, orientation 1, uncompressed, one strip, RowsPerStrip=8742, StripOffset=4664, StripByteCount=611,380,512. Embedded ICC is 560 bytes (Adobe RGB 1998), resolution 300×300 dpi. Private filenames/photos are not committed.

Fresh-process 1024² origin ROI on M1 Max:

| Measure | libtiff production | ImageIO Foundation probe |
|---|---:|---:|
| Baseline RSS | 7,946,240 bytes | approximately 7.5 MiB |
| Peak RSS | 16,859,136 bytes (16.08 MiB) | 1,242,300,416 bytes (1184.75 MiB) |
| Incremental production RSS | 8,912,896 bytes (8.5 MiB) | approximately 1.15 GiB |
| ROI decode | 7.359 ms | full-image allocation observed |

Plan: 6,144-byte row span, zero codec-encoded buffer, one required strip, directRows=true, conservative 41,961,472-byte envelope. Exact RGBA16 equality with Python/tifffile crop; SHA256 `d71a223f090ad0a9642c43e8f2e1bbdbdd62634f894ac5523065bec0d1e7dbdf`. ImageIO remains metadata/small-image reference only; NativeStackEngine never invokes its pixel provider.

## Output and interoperability

TIFFOutputWriter accepts exact-once row-major core coverage and stages raw RGB16 on disk. It encodes sibling temporary TIFF, default Deflate/horizontal predictor/32-row strips; LZW, None and tiled layouts are available. Conservative worst-case size chooses BigTIFF automatically; forced BigTIFF roundtrip is tested. The size-based automatic >4GB branch was reviewed, not exercised with a >4GB output.

Before publication, every encoded strip/tile is decoded sequentially and compared exactly against raw staging, including edge-tile padding and exact ICC bytes. File synchronization precedes atomic exclusive rename; an existing destination is never replaced. APFS directory fsync can return EINVAL; file integrity validation and atomic publication do not constitute an independently verified power-loss durability guarantee.

384 developer fixture combinations (depth, endian, classic/BigTIFF, three codecs, strip/tile and eight orientations) passed exact ROI comparison. Native tests verify strip/tile compression, BigTIFF, ICC and roundtrip. Strip None/LZW/Deflate output opens in ImageIO with exact RGB16 pixels. Tiled output opens in libtiff and tifffile; this installed ImageIO pixel provider rejected the tiled test fixture, so universal ImageIO tiled compatibility is not claimed. Full real output metadata is also readable through ImageIO.

Reproduce with artifacts outside Git:

```sh
.venv/bin/python native/Developer/generate_tiff_fixtures.py --artifacts /tmp/fs-tiff-fixtures
$BENCH --tiff-fixtures /tmp/fs-tiff-fixtures
$BENCH --libtiff-probe "$SOURCE" 0 0 1024
$BENCH --write-roundtrip /tmp/fs-roundtrip.tif
```

`BENCH` is the built Release FocusStackBenchmarks executable; destination must not exist.
