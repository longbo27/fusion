"""Sequential-source multiband accumulators; source count never sizes pyramids."""
import cv2
import numpy as np


def gaussian_pyramid(image, levels):
    result = [image]
    for _ in range(levels):
        result.append(cv2.pyrDown(result[-1], borderType=cv2.BORDER_REFLECT_101))
    return result


def laplacian_pyramid(image, levels):
    gauss = gaussian_pyramid(image, levels)
    lap = []
    for index in range(levels):
        h, w = gauss[index].shape[:2]
        lap.append(gauss[index]-cv2.pyrUp(gauss[index+1], dstsize=(w, h)))
    lap.append(gauss[-1])
    return lap


def reconstruct(pyramid):
    image = pyramid[-1]
    for level in reversed(pyramid[:-1]):
        h, w = level.shape[:2]
        image = cv2.pyrUp(image, dstsize=(w, h))+level
    return image


class Multiband:
    def __init__(self, shape, levels):
        h, w = shape
        self.accumulators, self.weights = [], []
        for _ in range(levels+1):
            self.accumulators.append(np.zeros((h, w, 3), np.float32))
            self.weights.append(np.zeros((h, w), np.float32))
            h, w = (h+1)//2, (w+1)//2
        self.levels = levels

    def add(self, rgb, mask, hard=None):
        source = laplacian_pyramid(rgb.astype(np.float32, copy=False), self.levels)
        masks = gaussian_pyramid(mask, self.levels)
        # Strong edge ownership is propagated to coarse levels too, preventing
        # low-frequency color from a defocused occluder bleeding through detail.
        for level, (pixels, weight) in enumerate(zip(source, masks)):
            if hard is not None and level:
                protection, ownership = hard
                stride = 2**level
                protect = protection[::stride, ::stride]
                own = ownership[::stride, ::stride]
                weight = weight*(1-protect)+own*protect
            self.accumulators[level] += pixels*weight[..., None]
            self.weights[level] += weight
        # These pyramids die before the next source is read.

    def finish(self):
        for pixels, weights in zip(self.accumulators, self.weights):
            np.divide(pixels, np.maximum(weights[..., None], 1e-8), out=pixels)
        return reconstruct(self.accumulators), self.weights[0] > 1e-8
