"""Top-K tile focus, edge-aware source ownership, sequential multiband fusion."""
from contextlib import nullcontext
import cv2
import numpy as np
from .blending import occlusion_weight
from .depth import Candidates, regularize
from .pyramid import Multiband
from .sharpness import photographic_score
from .fusion_v1 import fuse_tile as fuse_v1


def tile_bounds(shape, tile_size, halo, grid=1):
    h, w = shape[:2]
    for y in range(0, h, tile_size):
        for x in range(0, w, tile_size):
            ey, ex = min(y+tile_size, h), min(x+tile_size, w)
            # All pyramids share the global dyadic sampling phase.
            expanded = (max(0, (y-halo)//grid*grid), min(h, ((ey+halo+grid-1)//grid)*grid),
                        max(0, (x-halo)//grid*grid), min(w, ((ex+halo+grid-1)//grid)*grid))
            yield (y, ey, x, ex), expanded


def fuse_tile(sources, transforms, bounds, config, reference_index, timings=None):
    measure = timings.measure if timings else lambda _: nullcontext()
    if config.quality == "standard":
        return fuse_v1(sources, transforms, bounds, config, reference_index, timings)
    y0, y1, x0, x1 = bounds
    shape = (y1-y0, x1-x0)
    candidates = Candidates(shape, len(sources))
    guide = np.zeros(shape, np.float32)
    kernel = np.ones((2*config.focus_support+1, 2*config.focus_support+1), np.uint8)
    with measure("focus_pass"):
        for index, (source, transform) in enumerate(zip(sources, transforms)):
            rgb, valid = source.warp_tile(transform, bounds)
            score, gray = photographic_score(rgb, config.focus_radius, config.quality)
            eligible = cv2.erode(valid.astype(np.uint8), kernel, borderType=cv2.BORDER_CONSTANT, borderValue=1).astype(bool)
            score[~eligible] = -1
            better = candidates.update(score, index)
            np.copyto(guide, gray, where=better)
            del rgb, score, gray, valid, eligible, better
    with measure("depth_regularization"):
        confidence = candidates.confidence()
        labels, edge = regularize(candidates, confidence, guide)
        del guide, candidates
    with measure("fusion"):
        blender = Multiband(shape, config.pyramid_levels)
        owned = np.zeros((*shape, 3), np.float32)
        protection_map = np.maximum(np.clip(confidence*5, 0, 1), edge)
        for index in np.unique(labels):
            rgb, valid = sources[int(index)].warp_tile(transforms[int(index)], bounds)
            weight, protection, ownership = occlusion_weight(labels, index, confidence, edge, config.blend_radius, valid)
            blender.add(rgb, weight, (protection, ownership))
            owned += rgb*ownership[..., None]
            del rgb, valid, weight, protection, ownership
        image, covered = blender.finish()
        # Multiband transitions must not reconstruct a confident focused edge
        # using low-frequency colors from a defocused occluder.
        image *= (1-protection_map)[..., None]
        image += owned*protection_map[..., None]
        if not covered.all():
            fallback, _ = sources[reference_index].warp_tile(transforms[reference_index], bounds)
            image[~covered] = fallback[~covered]
        np.rint(image, out=image)
        np.clip(image, 0, 65535, out=image)
        return image.astype(np.uint16)
