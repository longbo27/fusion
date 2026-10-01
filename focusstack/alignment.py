"""Reduced-resolution feature/RANSAC alignment with optional ECC refinement."""

from dataclasses import dataclass
import math
import cv2
import numpy as np
from .config import FocusStackError


@dataclass(frozen=True)
class AlignmentResult:
    matrix: np.ndarray  # source -> reference, full-resolution pixel coordinates
    score: float
    method: str


def resize_gray(gray, bound):
    h, w = gray.shape
    scale = min(1.0, bound / max(h, w))
    shape = (max(1, round(w * scale)), max(1, round(h * scale)))
    return cv2.resize(gray, shape, interpolation=cv2.INTER_AREA)


def rescale_transform(matrix, old_shape, new_shape):
    sy, sx = new_shape[0] / old_shape[0], new_shape[1] / old_shape[1]
    scale = np.diag([sx, sy, 1.0])
    extended = np.eye(3)
    extended[:2] = matrix
    return (scale @ extended @ np.linalg.inv(scale))[:2]


def similarity(matrix):
    """Project numerical/ECC affine shear onto rotation and uniform scale."""
    a = (matrix[0, 0] + matrix[1, 1]) * 0.5
    b = (matrix[1, 0] - matrix[0, 1]) * 0.5
    result = matrix.copy()
    result[:, :2] = [[a, -b], [b, a]]
    return result


def validate_transform(matrix, shape):
    if matrix.shape != (2, 3) or not np.isfinite(matrix).all():
        raise FocusStackError("Alignment produced a non-finite transform")
    linear = matrix[:, :2]
    scales = np.linalg.svd(linear, compute_uv=False)
    rotation = abs(math.degrees(math.atan2(linear[1, 0], linear[0, 0])))
    if np.linalg.det(linear) <= 0 or scales.min() < 0.8 or scales.max() > 1.25 or scales.max()/scales.min() > 1.03:
        raise FocusStackError(f"Unreasonable alignment scale/shear: {scales}")
    if rotation > 15:
        raise FocusStackError(f"Unreasonable alignment rotation: {rotation:.1f} degrees")
    h, w = shape
    corners = np.array([[0, 0], [w-1, 0], [w-1, h-1], [0, h-1]], np.float32)
    warped = cv2.transform(corners[None], matrix.astype(np.float32))[0]
    area, _ = cv2.intersectConvexConvex(corners, warped)
    overlap = area / max((w-1)*(h-1), 1)
    if overlap < 0.6:
        raise FocusStackError(f"Insufficient alignment overlap: {overlap:.1%}")


def correlation(reference, source, matrix):
    h, w = reference.shape
    warped = cv2.warpAffine(source, matrix, (w, h))
    valid = cv2.warpAffine(np.ones(source.shape, np.uint8), matrix, (w, h), flags=cv2.INTER_NEAREST).astype(bool)
    a, b = reference[valid].astype(np.float32), warped[valid].astype(np.float32)
    a -= a.mean()
    b -= b.mean()
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b) / denom) if denom > 1e-6 else 0.0


def estimate(reference, source, mode):
    # Limit feature workspace independently of the configured analysis ceiling.
    ref, src = resize_gray(reference, 2048), resize_gray(source, 2048)
    sift = cv2.SIFT_create(nfeatures=3000, contrastThreshold=0.02)
    kr, dr = sift.detectAndCompute(ref, None)
    ks, ds = sift.detectAndCompute(src, None)
    matrix, method = None, ""
    if dr is not None and ds is not None and len(dr) >= 6 and len(ds) >= 6:
        matches = cv2.BFMatcher().knnMatch(ds, dr, k=2)
        good = [pair[0] for pair in matches if len(pair) == 2 and pair[0].distance < 0.75*pair[1].distance]
        if len(good) >= 6:
            a = np.array([ks[m.queryIdx].pt for m in good], np.float32)
            b = np.array([kr[m.trainIdx].pt for m in good], np.float32)
            cv2.setRNGSeed(0)
            candidate, inliers = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC, ransacReprojThreshold=2.5, maxIters=3000, confidence=0.995)
            if candidate is not None and inliers.sum() >= 6 and inliers.mean() >= 0.25:
                matrix = candidate
                if mode == "translation":
                    matrix = np.eye(2, 3)
                    matrix[:, 2] = np.median((b-a)[inliers.ravel().astype(bool)], axis=0)
                method = "SIFT/RANSAC"
    if matrix is None:
        shift, response = cv2.phaseCorrelate(src.astype(np.float32), ref.astype(np.float32))
        if not np.isfinite(response) or response < 0.08:
            raise FocusStackError("Alignment has too little shared texture for features or phase correlation; try --alignment none for registered inputs")
        matrix = np.eye(2, 3)
        matrix[:, 2] = shift
        method = "phase correlation"
    validate_transform(matrix, ref.shape)
    # ECC on another reduced representation. It estimates reference -> source.
    er, es = resize_gray(ref, 1024), resize_gray(src, 1024)
    small = rescale_transform(matrix, ref.shape, er.shape)
    score = correlation(er, es, small)
    try:
        inverse = cv2.invertAffineTransform(small).astype(np.float32)
        _, inverse = cv2.findTransformECC(er.astype(np.float32)/255, es.astype(np.float32)/255, inverse,
            cv2.MOTION_TRANSLATION if mode == "translation" else cv2.MOTION_AFFINE,
            (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-5), None, 5)
        refined = cv2.invertAffineTransform(inverse).astype(np.float64)
        if mode == "affine":
            refined = similarity(refined)
        validate_transform(refined, er.shape)
        refined_score = correlation(er, es, refined)
        if refined_score >= score:
            small, score = refined, refined_score
            method += "+ECC"
    except (cv2.error, FocusStackError):
        pass  # Valid coarse alignment is a documented fallback.
    if not np.isfinite(score) or score < 0.2:
        raise FocusStackError(f"Alignment score too low ({score:.3f}); try --alignment none only for registered inputs")
    return rescale_transform(small, er.shape, reference.shape), score, method


def align_sources(sources, reference_index, config, progress):
    identity = np.eye(2, 3, dtype=np.float64)
    if config.alignment == "none":
        return [AlignmentResult(identity.copy(), 1.0, "disabled") for _ in sources]
    reference = sources[reference_index].reduced_gray(config.alignment_max_dim)
    full_shape = sources[0].info.shape[:2]
    results = []
    for index, source in enumerate(sources):
        if index == reference_index:
            results.append(AlignmentResult(identity.copy(), 1.0, "reference"))
        else:
            try:
                gray = source.reduced_gray(config.alignment_max_dim)
                matrix, score, method = estimate(reference, gray, config.alignment)
                matrix = rescale_transform(matrix, gray.shape, full_shape)
                validate_transform(matrix, full_shape)
                results.append(AlignmentResult(matrix, score, method))
                del gray
            except (cv2.error, FocusStackError) as exc:
                raise FocusStackError(f"Frame {index} ({source.info.path.name}) alignment failed: {exc}") from exc
        progress(index, results[-1])
    return results
