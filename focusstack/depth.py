"""Bounded top-three selection and confidence/structure-aware depth cleanup."""
import cv2
import numpy as np
from .sharpness import smooth


class Candidates:
    def __init__(self, shape, frames, k=3):
        self.scores = np.full((k, *shape), -1, np.float32)
        self.indices = np.zeros((k, *shape), np.uint8 if frames <= 256 else np.uint16)

    def update(self, score, index):
        # Strict comparison means tied evidence retains source order.
        candidate = score.copy()
        label = np.full(score.shape, index, self.indices.dtype)
        winner = score > self.scores[0]
        for level in range(len(self.scores)):
            better = candidate > self.scores[level]
            old_score = self.scores[level].copy()
            old_index = self.indices[level].copy()
            np.copyto(self.scores[level], candidate, where=better)
            np.copyto(self.indices[level], label, where=better)
            np.copyto(candidate, old_score, where=better)
            np.copyto(label, old_index, where=better)
        return winner

    def confidence(self):
        best = np.maximum(self.scores[0], 0)
        return np.clip((best-np.maximum(self.scores[1], 0))/np.maximum(best, 1e-8), 0, 1)


def structure_strength(guide):
    gx = cv2.Sobel(guide, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(guide, cv2.CV_32F, 0, 1, ksize=3)
    strength = cv2.magnitude(gx, gy)
    # Absolute scale is explicitly uint16 luminance, with local contrast support.
    return np.clip(strength/16000, 0, 1)


def regularize(candidates, confidence, guide):
    labels = candidates.indices[0].copy()
    median = cv2.medianBlur(labels, 3)
    edge = structure_strength(guide)
    # Never average ordered depths across an edge. A median replacement must be
    # one of the local top-three candidates; strong/thin detail keeps ownership.
    admissible = np.any((candidates.indices == median[None]) & (candidates.scores >= 0), axis=0)
    change = (confidence < 0.2) & (edge < 0.35) & admissible
    labels[change] = median[change]
    return labels, edge
