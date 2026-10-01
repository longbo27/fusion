"""Two-pass bounded tile selection and confidence-aware RGB fusion."""

import cv2
import numpy as np
from .blending import normalize, source_weight
from .sharpness import focus_score


def tile_bounds(shape, tile_size, halo):
    h, w = shape[:2]
    for y in range(0, h, tile_size):
        for x in range(0, w, tile_size):
            ey, ex = min(y+tile_size, h), min(x+tile_size, w)
            expanded = (max(0, y-halo), min(h, ey+halo), max(0, x-halo), min(w, ex+halo))
            yield (y, ey, x, ex), expanded


def fuse_tile(sources, transforms, bounds, config, reference_index):
    y0, y1, x0, x1 = bounds
    shape = (y1-y0, x1-x0)
    best = np.full(shape, -1, np.float32)
    second = np.full(shape, -1, np.float32)
    labels = np.zeros(shape, np.uint8 if len(sources) <= 256 else np.uint16)
    focus_support = 2*config.focus_radius+4 if config.multiscale else config.focus_radius+1
    kernel = np.ones((2*focus_support+1, 2*focus_support+1), np.uint8)
    # PASS 1: only two score fields and one index field survive source iteration.
    for index, (source, transform) in enumerate(zip(sources, transforms)):
        rgb, valid = source.warp_tile(transform, bounds)
        score = focus_score(rgb, config.focus_radius, config.multiscale)
        valid = cv2.erode(valid.astype(np.uint8), kernel, borderType=cv2.BORDER_CONSTANT, borderValue=1).astype(bool)
        score[~valid] = -1
        better = score > best
        np.maximum(second, np.where(better, best, score), out=second)
        np.copyto(best, score, where=better)
        labels[better] = index
        del rgb, valid, score, better
    confidence = np.clip((best - np.maximum(second, 0)) / np.maximum(best, 1e-8), 0, 1)
    cleaned = cv2.medianBlur(labels, 3)
    # Preserve strong winners, regularize weak isolated labels.
    labels[confidence < 0.25] = cleaned[confidence < 0.25]
    del best, second, cleaned
    accumulator = np.zeros((*shape, 3), np.float32)
    total = np.zeros(shape, np.float32)
    # PASS 2: one source RGB tile and mask at a time, re-reading only selected frames.
    for index in np.unique(labels):
        rgb, valid = sources[int(index)].warp_tile(transforms[int(index)], bounds)
        weight = source_weight(labels, index, confidence, config.blend_radius, valid)
        accumulator += rgb * weight[..., None]
        total += weight
        del rgb, valid, weight
    fallback, _ = sources[reference_index].warp_tile(transforms[reference_index], bounds)
    return normalize(accumulator, total, fallback)
