"""Local Tenengrad, with finite-support optional coarse-scale evidence."""

import cv2
import numpy as np


def smooth(array, radius):
    if radius == 0:
        return array.copy()
    return cv2.GaussianBlur(array, (2*radius+1, 2*radius+1), max(radius/3, 0.5), borderType=cv2.BORDER_REFLECT_101)


def luminance(rgb):
    # RGB throughout. OpenCV is only a math layer; no BGR conversion is involved.
    return cv2.cvtColor(rgb.astype(np.float32), cv2.COLOR_RGB2GRAY)


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
