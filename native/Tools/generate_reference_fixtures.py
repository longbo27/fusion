"""Developer only: run from repository root with the golden Python environment.
No Python is linked to or invoked by the app. Small fixtures only.
"""
from pathlib import Path
import json
import numpy as np
import cv2
from focusstack.sharpness import luminance, tenengrad

width, height = 7, 5
x, y = np.meshgrid(np.arange(width), np.arange(height))
rgb = np.stack([(x*7919+y*1049+1)%65536, (x*17+y*3253+257)%65536,
                (x*4093+y*37+65534)%65536], axis=-1).astype(np.uint16)
gray = luminance(rgb) / np.float32(65535)
gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, borderType=cv2.BORDER_REFLECT_101)
gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, borderType=cv2.BORDER_REFLECT_101)
# radius=0 preserves the original unblurred V1.1 Tenengrad prototype.
energy = tenengrad(luminance(rgb), 0) / np.float32(65535**2)
fixture = dict(reference_commit="a0680d224c3c91a82bef13f318d77d2b60e7ffc3",
               width=width, height=height, rgb=rgb.reshape(-1).tolist(),
               luminance=gray.reshape(-1).tolist(), gx=gx.reshape(-1).tolist(),
               gy=gy.reshape(-1).tolist(), energy=energy.reshape(-1).tolist())
path = Path("native/FocusStackTests/Fixtures/golden.json")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(fixture, indent=2)+"\n")
print(f"Wrote {path} ({path.stat().st_size} bytes)")
