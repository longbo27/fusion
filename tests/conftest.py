import cv2
import numpy as np
import pytest
import tifffile


@pytest.fixture
def scene():
    rng = np.random.default_rng(14)
    base = rng.integers(5000, 59000, (257, 321, 3), dtype=np.uint16)
    base = cv2.GaussianBlur(base, (3, 3), 0.65)
    for x, y in [(36, 48), (200, 60), (50, 200), (265, 210)]:
        cv2.circle(base, (x, y), 14, (60000, 8000, 42000), 3)
    return base


@pytest.fixture
def planes(scene):
    blurred = cv2.GaussianBlur(scene, (17, 17), 3)
    a, b = blurred.copy(), blurred.copy()
    middle = scene.shape[1]//2
    a[:, :middle] = scene[:, :middle]
    b[:, middle:] = scene[:, middle:]
    return [a, b]


@pytest.fixture
def write_frames(tmp_path):
    def write(frames, **kwargs):
        files = []
        for index, frame in enumerate(frames):
            path = tmp_path / f"frame-{index:02d}.tif"
            tifffile.imwrite(path, frame, photometric="rgb", metadata=None, **kwargs)
            files.append(path)
        return files
    return write
