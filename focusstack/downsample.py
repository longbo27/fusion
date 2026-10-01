"""Separable streaming area reduction with global bins and fixed source blocks."""
import cv2
import numpy as np


def analysis_shape(shape, bound):
    h, w = shape[:2]
    scale = min(1.0, bound/max(h, w))
    return max(1, round(h*scale)), max(1, round(w*scale))


class AreaReducer:
    def __init__(self, shape, bound):
        self.h, self.w = shape[:2]
        self.rh, self.rw = analysis_shape(shape, bound)
        self.sums = np.zeros((self.rh, self.rw), np.float32)
        self.counts = np.zeros((self.rh, self.rw), np.uint32)

    def add(self, rgb, y, x):
        # Blocks are caller bounded, including large TIFF segments split into views.
        native = np.uint16 if rgb.dtype.itemsize == 2 else np.uint8
        block = np.ascontiguousarray(rgb, dtype=native)
        if block.dtype.itemsize == 2:
            block = (block >> 8).astype(np.uint8)
        gray = cv2.cvtColor(block, cv2.COLOR_RGB2GRAY).astype(np.float32)
        h, w = gray.shape
        yy = np.arange(y, y+h, dtype=np.int64)*self.rh//self.h
        xx = np.arange(x, x+w, dtype=np.int64)*self.rw//self.w
        ys = np.r_[0, np.flatnonzero(np.diff(yy))+1]
        xs = np.r_[0, np.flatnonzero(np.diff(xx))+1]
        reduced = np.add.reduceat(np.add.reduceat(gray, xs, axis=1), ys, axis=0)
        counts = np.diff(np.r_[ys, h]).astype(np.uint32)[:, None] * np.diff(np.r_[xs, w]).astype(np.uint32)[None, :]
        # Global bins repeat at chunk boundaries; add partial contributions exactly.
        section = np.s_[yy[0]:yy[-1]+1, xx[0]:xx[-1]+1]
        self.sums[section] += reduced
        self.counts[section] += counts

    def finish(self):
        np.divide(self.sums, np.maximum(self.counts, 1), out=self.sums)
        np.rint(self.sums, out=self.sums)
        return self.sums.astype(np.uint8)
