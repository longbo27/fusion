"""Generate/reuse real TIFF datasets without retaining complete frames."""
import argparse
import json
from pathlib import Path
import shutil
import time
import cv2
import numpy as np
import tifffile
from .run import texture, ICC


def strips(width, height, index, frames, rows=64):
    for y in range(0, height, rows):
        ey = min(y+rows, height)
        sy, by = max(0, y-10), min(height, ey+10)
        sharp = texture(sy, by, 0, width)
        blur = cv2.GaussianBlur(sharp, (17, 17), 3)
        owned = (np.arange(width)*frames//width == index)[None, :, None]
        yield np.where(owned, sharp, blur)[y-sy:ey-sy].tobytes()


def generate(root, width, height, frames):
    root.mkdir(parents=True, exist_ok=True)
    required = width*height*6*frames + 16*1024**2
    if shutil.disk_usage(root).free < required:
        raise RuntimeError(f"Need {required} free bytes for generated sources")
    started = time.perf_counter()
    cv2.setNumThreads(2)
    for index in range(frames):
        print(f"Generate {index+1}/{frames}: {width}×{height}", flush=True)
        tifffile.imwrite(root / f"frame-{index:03d}.tif", data=strips(width, height, index, frames),
                         shape=(height, width, 3), dtype=np.uint16, photometric="rgb", metadata=None,
                         rowsperstrip=64, bigtiff=True, compression=None,
                         iccprofile=ICC, resolution=(300, 300), resolutionunit="INCH")
    report = dict(width=width, height=height, frames=frames,
                  generation_seconds=time.perf_counter()-started,
                  input_bytes=sum(p.stat().st_size for p in root.glob('*.tif')))
    (root / "dataset.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    p.add_argument('--width', type=int, default=12000)
    p.add_argument('--height', type=int, default=8300)
    p.add_argument('--frames', type=int, default=20)
    a=p.parse_args()
    generate(a.directory, a.width, a.height, a.frames)
