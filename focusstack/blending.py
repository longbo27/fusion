"""Replaceable sequential mask blender; no per-source mask pyramid is retained."""

import numpy as np
from .sharpness import smooth


def source_weight(labels, index, confidence, radius, valid):
    mask = (labels == index).astype(np.float32)
    soft = smooth(mask, radius)
    # Separated focus scores keep detail; ambiguity permits a smooth transition.
    hardness = np.clip(confidence * 4, 0, 1)
    weight = hardness * mask + (1-hardness) * soft
    weight *= valid
    return weight


def normalize(accumulator, total, fallback):
    covered = total > 1e-8
    np.divide(accumulator, np.maximum(total[..., None], 1e-8), out=accumulator)
    if fallback is not None:
        accumulator[~covered] = fallback[~covered]
    np.clip(accumulator, 0, 65535, out=accumulator)
    np.rint(accumulator, out=accumulator)
    return accumulator.astype(np.uint16)


def occlusion_weight(labels, index, confidence, edge, radius, valid):
    """Hard detail ownership; uncertainty blends only near label transitions."""
    mask = (labels == index).astype(np.float32)
    local = smooth(mask, radius)
    # Only mask boundaries need transitions. Strong edge detail remains hard,
    # even when neighboring focus candidates have similarly high scores.
    protection = np.maximum(np.clip(confidence*5, 0, 1), edge)
    transition = np.clip(4*local*(1-local), 0, 1)
    softness = (1-protection)*transition
    weight = mask*(1-softness)+local*softness
    weight *= valid
    return weight, protection, mask*valid
