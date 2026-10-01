"""Sequential tiled TIFF generation plus isolated-process engine measurement."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import cv2
import numpy as np
import tifffile
from focusstack import Config, stack

PROFILES = {"small": (640, 480, 3), "medium": (3072, 2048, 6), "100mp": (12000, 8300, 10)}
ICC = b"FocusStack benchmark ICC passthrough marker (not a display profile)"


def texture(y0, y1, x0, x1):
    yy = np.arange(y0, y1, dtype=np.uint32)[:, None]
    xx = np.arange(x0, x1, dtype=np.uint32)[None, :]
    hashed = xx * np.uint32(374761393) + yy * np.uint32(668265263)
    hashed = (hashed ^ (hashed >> 13)) * np.uint32(1274126177)
    hashed ^= hashed >> 16
    image = np.empty((y1-y0, x1-x0, 3), np.uint16)
    for channel in range(3):
        image[..., channel] = (5000 + ((hashed >> (channel*5)) % 55000)).astype(np.uint16)
    return cv2.GaussianBlur(image, (3, 3), 0.65)


def frame_tiles(width, height, index, frames, tile=256):
    # Independent tiles use global-coordinate texture and a halo for blur support.
    for y in range(0, height, tile):
        for x in range(0, width, tile):
            ey, ex = min(y+tile, height), min(x+tile, width)
            sy, sx = max(0, y-10), max(0, x-10)
            by, bx = min(height, ey+10), min(width, ex+10)
            sharp = texture(sy, by, sx, bx)
            blurred = cv2.GaussianBlur(sharp, (17, 17), 3)
            focused = (np.arange(sx, bx)*frames//width == index)[None, :, None]
            source = np.where(focused, sharp, blurred)
            padded = np.zeros((tile, tile, 3), np.uint16)
            padded[:ey-y, :ex-x] = source[y-sy:ey-sy, x-sx:ex-sx]
            yield padded


def worker(args):
    root = args.worker
    config = Config(tile_size=args.tile_size, alignment=args.alignment,
                    alignment_max_dim=args.alignment_max_dim, temp_dir=root / "scratch",
                    max_workers=args.max_workers)
    result = stack([root / "input"], root / "output.tif", config, log=lambda s: print(s, file=sys.stderr))
    with tifffile.TiffFile(result.output) as tif:
        page = tif.pages[0]
        assert page.dtype == np.dtype("uint16") and page.shape == result.shape
        assert page.tags["InterColorProfile"].value == ICC
        assert page.tags["XResolution"].value == (300, 1)
    metrics = dict(width=result.shape[1], height=result.shape[0], images=result.frames,
                   tile_size=args.tile_size, alignment=args.alignment,
                   runtime_seconds=round(result.elapsed_seconds, 3),
                   peak_rss_mib=round(result.peak_rss_bytes/2**20, 2),
                   scratch_mib=round(result.scratch_bytes/2**20, 2),
                   output_mib=round(result.output_bytes/2**20, 2),
                   output_validated=True)
    (root / "metrics.json").write_text(json.dumps(metrics))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, default="small")
    parser.add_argument("--frames", type=int)
    parser.add_argument("--tile-size", type=int, default=1024)
    parser.add_argument("--alignment", choices=["none", "translation", "affine"], default="none")
    parser.add_argument("--alignment-max-dim", type=int, default=4096)
    parser.add_argument("--max-workers", type=int, default=2)
    parser.add_argument("--compression", choices=["none", "zlib"], default="zlib", help="source compression")
    parser.add_argument("--work-dir", type=Path, help="parent for generated data (defaults to system temp)")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        worker(args)
        return
    width, height, frames = PROFILES[args.profile]
    frames = frames if args.frames is None else args.frames
    if frames < 1 or frames > 65535:
        parser.error("frames must be between 1 and 65535")
    Config(tile_size=args.tile_size, alignment=args.alignment, alignment_max_dim=args.alignment_max_dim,
           max_workers=args.max_workers).validate()
    parent = args.work_dir or Path(tempfile.gettempdir())
    parent.mkdir(parents=True, exist_ok=True)
    reserve = width*height*6*(frames*2+3)
    if shutil.disk_usage(parent).free < reserve:
        parser.error(f"benchmark needs a conservative {reserve/2**30:.2f} GiB free disk")
    root = Path(tempfile.mkdtemp(prefix=f"focusstack-benchmark-{args.profile}-", dir=parent))
    try:
        (root / "input").mkdir()
        start = time.perf_counter()
        cv2.setNumThreads(args.max_workers)
        for index in range(frames):
            print(f"Generate {index+1}/{frames}: {width}×{height}", file=sys.stderr)
            tifffile.imwrite(root / "input" / f"frame-{index:03d}.tif",
                             data=frame_tiles(width, height, index, frames), shape=(height, width, 3),
                             dtype=np.uint16, photometric="rgb", metadata=None, tile=(256, 256),
                             compression=None if args.compression == "none" else args.compression,
                             bigtiff=width*height*6 >= 2**32-2**25, maxworkers=1, buffersize=1024**2,
                             iccprofile=ICC, resolution=(300, 300), resolutionunit="INCH")
        generation = time.perf_counter()-start
        subprocess.run([sys.executable, "-m", "benchmarks.run", "--worker", str(root),
                        "--tile-size", str(args.tile_size), "--alignment", args.alignment,
                        "--alignment-max-dim", str(args.alignment_max_dim), "--max-workers", str(args.max_workers)], check=True)
        metrics = json.loads((root / "metrics.json").read_text())
        metrics.update(profile=args.profile, source_compression=args.compression,
                       generation_seconds=round(generation, 3))
        print(json.dumps(metrics, indent=2))
        if args.keep:
            print(f"Artifacts retained: {root}", file=sys.stderr)
    finally:
        if not args.keep:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
