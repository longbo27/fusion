"""Reduced-resolution feature/RANSAC alignment with optional ECC refinement."""

from dataclasses import dataclass, field
import math
import cv2
import numpy as np
from .config import FocusStackError


@dataclass(frozen=True)
class AlignmentResult:
    matrix: np.ndarray  # source -> reference, full-resolution pixel coordinates
    score: float
    method: str
    diagnostics: dict = field(default_factory=dict)


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


def similarity_ecc(reference, source, matrix, mode, iterations=15):
    """Normalized-correlation refinement with only similarity DOFs at every step.

    Jacobians and residuals are float32 reduced images. Only the 2/4 parameter
    normal equation is solved in float64. Damped steps must improve correlation.
    No affine shear/perspective is introduced, even temporarily.
    """
    h, w = reference.shape
    inverse = cv2.invertAffineTransform(matrix).astype(np.float32)
    target = reference.astype(np.float32)
    target -= target.mean()
    target /= max(float(target.std()), 1e-4)
    xx = (np.arange(w, dtype=np.float32)[None, :]-(w-1)/2)/w
    yy = (np.arange(h, dtype=np.float32)[:, None]-(h-1)/2)/w
    score = correlation(reference, source, matrix)
    for _ in range(iterations):
        warped = cv2.warpAffine(source.astype(np.float32), inverse, (w, h), flags=cv2.INTER_LINEAR|cv2.WARP_INVERSE_MAP)
        valid = cv2.warpAffine(np.ones(source.shape, np.uint8), inverse, (w, h), flags=cv2.INTER_NEAREST|cv2.WARP_INVERSE_MAP).astype(bool)
        warped -= warped[valid].mean()
        warped /= max(float(warped[valid].std()), 1e-4)
        gx = cv2.Sobel(warped, cv2.CV_32F, 1, 0)/8
        gy = cv2.Sobel(warped, cv2.CV_32F, 0, 1)/8
        columns = [gx, gy] if mode == "translation" else [gx*xx+gy*yy, -gx*yy+gy*xx, gx, gy]
        # Subsample Jacobian fitting only; acceptance uses all verification pixels.
        keep = valid[::2, ::2]
        jac = np.stack([c[::2, ::2][keep] for c in columns], axis=1)
        values = warped[::2, ::2][keep]
        jac -= jac.mean(axis=0)
        jac -= values[:, None]*(values @ jac)[None, :]/max(float(values @ values), 1e-6)
        error = (target-warped)[::2, ::2][keep]
        normal = (jac.T @ jac).astype(np.float64)
        rhs = (jac.T @ error).astype(np.float64)
        try:
            delta = np.linalg.solve(normal+np.eye(len(columns))*1e-3, rhs)
        except np.linalg.LinAlgError:
            break
        accepted = False
        for damping in (1.0, 0.5, 0.25):
            candidate = inverse.astype(np.float64)
            step = delta*damping
            if mode == "translation":
                candidate[:, 2] += step
            else:
                da, db, dx, dy = step
                da, db = da/w, db/w
                candidate[:, :2] += [[da, -db], [db, da]]
                candidate[:, 2] += [dx-da*(w-1)/2+db*(h-1)/2, dy-db*(w-1)/2-da*(h-1)/2]
            forward = cv2.invertAffineTransform(candidate)
            try:
                validate_transform(forward, reference.shape)
            except FocusStackError:
                continue
            new_score = correlation(reference, source, forward)
            if new_score > score+1e-6:
                inverse, score, accepted = candidate.astype(np.float32), new_score, True
                break
        if not accepted:
            break
    return cv2.invertAffineTransform(inverse).astype(np.float64), score


def estimate_detailed(reference, source, mode, reference_features=None):
    ref, src = resize_gray(reference, 2048), resize_gray(source, 2048)
    coarse_ref, coarse_src = resize_gray(ref, 512), resize_gray(src, 512)
    choices = []
    shift, response = cv2.phaseCorrelate(coarse_src.astype(np.float32), coarse_ref.astype(np.float32))
    if np.isfinite(response) and response >= 0.08:
        coarse = np.eye(2, 3)
        coarse[:, 2] = shift
        candidate = rescale_transform(coarse, coarse_ref.shape, ref.shape)
        try:
            validate_transform(candidate, ref.shape)
            choices.append((candidate, "phase"))
        except FocusStackError:
            pass
    sift = cv2.SIFT_create(nfeatures=3000, contrastThreshold=0.02)
    kr, dr = reference_features if reference_features is not None else sift.detectAndCompute(ref, None)
    ks, ds = sift.detectAndCompute(src, None)
    inlier_count, inlier_ratio = 0, 0.0
    if dr is not None and ds is not None and len(dr) >= 6 and len(ds) >= 6:
        matches = cv2.BFMatcher().knnMatch(ds, dr, k=2)
        good = [pair[0] for pair in matches if len(pair) == 2 and pair[0].distance < 0.75*pair[1].distance]
        if len(good) >= 6:
            a = np.array([ks[m.queryIdx].pt for m in good], np.float32)
            b = np.array([kr[m.trainIdx].pt for m in good], np.float32)
            cv2.setRNGSeed(0)
            candidate, inliers = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC, ransacReprojThreshold=2.5, maxIters=3000, confidence=0.995)
            if candidate is not None:
                inlier_count, inlier_ratio = int(inliers.sum()), float(inliers.mean())
                if inlier_count >= 6 and inlier_ratio >= 0.25:
                    if mode == "translation":
                        candidate = np.eye(2, 3)
                        candidate[:, 2] = np.median((b-a)[inliers.ravel().astype(bool)], axis=0)
                    try:
                        validate_transform(candidate, ref.shape)
                        choices.append((candidate, "SIFT/RANSAC"))
                    except FocusStackError:
                        pass
    if not choices:
        raise FocusStackError("Alignment has too little shared texture or unreasonable geometry; inspect frame/registration")
    er, es = resize_gray(ref, 1024), resize_gray(src, 1024)
    scored = [(correlation(er, es, rescale_transform(m, ref.shape, er.shape)), m, method) for m, method in choices]
    _, matrix, method = max(scored, key=lambda item: item[0])
    small = rescale_transform(matrix, ref.shape, er.shape)
    refined, _ = similarity_ecc(er, es, small, mode)
    matrix = rescale_transform(refined, er.shape, ref.shape)
    # Verify at the actually generated high resolution, not only at ECC resolution.
    score = correlation(ref, src, matrix)
    if not np.isfinite(score) or score < 0.2:
        raise FocusStackError(f"Alignment score too low ({score:.3f})")
    validate_transform(matrix, ref.shape)
    scale = float(np.hypot(matrix[0, 0], matrix[1, 0]))
    corners = np.array([[0, 0], [ref.shape[1]-1, 0], [ref.shape[1]-1, ref.shape[0]-1], [0, ref.shape[0]-1]], np.float32)
    warped = cv2.transform(corners[None], matrix.astype(np.float32))[0]
    overlap, _ = cv2.intersectConvexConvex(corners, warped)
    diagnostics = dict(reference_features=len(kr), source_features=len(ks), inliers=inlier_count,
        inlier_ratio=inlier_ratio, scale=scale, rotation_degrees=math.degrees(math.atan2(matrix[1, 0], matrix[0, 0])),
        translation=matrix[:, 2].tolist(), overlap=float(overlap/max((ref.shape[0]-1)*(ref.shape[1]-1), 1)),
        score=score, generated_shape=list(reference.shape), verified_shape=list(ref.shape))
    return rescale_transform(matrix, ref.shape, reference.shape), score, method+"+similarity-ECC", diagnostics


def estimate(reference, source, mode):
    matrix, score, method, _ = estimate_detailed(reference, source, mode)
    return matrix, score, method


def align_sources(sources, reference_index, config, progress, timings=None):
    identity = np.eye(2, 3, dtype=np.float64)
    if config.alignment == "none":
        return [AlignmentResult(identity.copy(), 1.0, "disabled") for _ in sources]
    if len(sources) == 1:
        return [AlignmentResult(identity.copy(), 1.0, "reference")]
    from contextlib import nullcontext
    measure = timings.measure if timings else lambda _: nullcontext()
    with measure("alignment_images"):
        reference = sources[reference_index].reduced_gray(config.analysis_bound)
    with measure("feature_alignment"):
        features = cv2.SIFT_create(nfeatures=3000, contrastThreshold=0.02).detectAndCompute(reference, None)
    full_shape = sources[0].info.shape[:2]
    results = []
    for index, source in enumerate(sources):
        if index == reference_index:
            results.append(AlignmentResult(identity.copy(), 1.0, "reference"))
        else:
            try:
                with measure("alignment_images"):
                    gray = source.reduced_gray(config.analysis_bound)
                with measure("feature_alignment"):
                    matrix, score, method, diagnostics = estimate_detailed(reference, gray, config.alignment, features)
                matrix = rescale_transform(matrix, gray.shape, full_shape)
                validate_transform(matrix, full_shape)
                diagnostics["translation"] = matrix[:, 2].tolist()
                results.append(AlignmentResult(matrix, score, method, diagnostics))
                del gray
            except (cv2.error, FocusStackError) as exc:
                raise FocusStackError(f"Frame {index} ({source.info.path.name}) alignment failed: {exc}") from exc
        progress(index, results[-1])
    return results
