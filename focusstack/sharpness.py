"""Local Tenengrad, with finite-support optional coarse-scale evidence."""

import cv2
import numpy as np


def smooth(array, radius):
    if radius == 0:
        return array.copy()
    return cv2.GaussianBlur(array, (2*radius+1, 2*radius+1), max(radius/3, 0.5), borderType=cv2.BORDER_REFLECT_101)


def luminance(rgb):
    # RGB throughout. OpenCV is only a math layer; no BGR conversion is involved.
    return cv2.cvtColor(rgb.astype(np.float32, copy=False), cv2.COLOR_RGB2GRAY)


def tenengrad(gray, radius):
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3, borderType=cv2.BORDER_REFLECT_101)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3, borderType=cv2.BORDER_REFLECT_101)
    np.square(gx, out=gx)
    np.square(gy, out=gy)
    gx += gy
    return smooth(gx, radius)


def focus_score(rgb, radius, multiscale=False):
    gray = luminance(rgb)
    score = tenengrad(gray, radius)
    if multiscale:
        coarse = smooth(gray, 3)
        score += 0.5 * tenengrad(coarse, 2*radius)
    return score


def _gradient_noise_gain(radius, sigma):
    g = cv2.getGaussianKernel(2*radius+1, sigma).ravel()
    derivative = np.convolve(g, [-1, 0, 1])
    smoothing = np.convolve(g, [1, 2, 1])
    return np.float32(2*np.sum(derivative**2)*np.sum(smoothing**2))


def photographic_score(rgb, radius, quality):
    """Local multi-scale evidence with a white-noise floor and contrast balancing.

    All statistics have finite support: no tile-wide noise/exposure estimates.
    Mixed second differences estimate noise, while coherent edges cancel in that
    estimator. The scale-filter derivative gain predicts noise energy to subtract.
    """
    gray = luminance(rgb)
    mixed = cv2.filter2D(gray, cv2.CV_32F, np.array([[1, -1], [-1, 1]], np.float32),
                        anchor=(0, 0), borderType=cv2.BORDER_REFLECT_101)
    np.square(mixed, out=mixed)
    noise = smooth(mixed, radius)*np.float32(0.25)
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1)
    xx, yy, xy = smooth(gx*gx, radius), smooth(gy*gy, radius), smooth(gx*gy, radius)
    coherence = np.sqrt((xx-yy)**2+4*xy*xy)/np.maximum(xx+yy, 1)
    # Directed edges/hair are signal, even when mixed differences are large.
    noise *= np.maximum(1-coherence*coherence, 0)
    mean = smooth(gray, radius)
    variance = np.maximum(smooth(gray*gray, radius)-mean*mean, 0)
    contrast = variance/(variance+2*noise+1024)
    result = np.zeros(gray.shape, np.float32)
    scales = [(1, 0.7, 1.0), (3, 1.0, 0.7)]
    if quality == "max":
        scales.append((6, 2.0, 0.4))
    for support, sigma, weight in scales:
        filtered = cv2.GaussianBlur(gray, (2*support+1, 2*support+1), sigma,
                                    borderType=cv2.BORDER_REFLECT_101)
        aggregation = radius if support == 1 else 2*radius
        energy = tenengrad(filtered, aggregation)
        floor = smooth(noise, aggregation)*_gradient_noise_gain(support, sigma)*1.5
        np.subtract(energy, floor, out=energy)
        np.maximum(energy, 0, out=energy)
        lap = cv2.Laplacian(filtered, cv2.CV_32F, ksize=1, borderType=cv2.BORDER_REFLECT_101)
        # Robust local high-frequency contribution. Mixed residual suppresses
        # unstructured fine noise, rather than blindly selecting its Laplacian.
        lap = smooth(lap*lap, aggregation)
        np.maximum(lap-noise*0.5, 0, out=lap)
        result += np.float32(weight)*(energy + np.float32(0.2)*lap)
    result *= contrast
    return result, gray
