"""TIFF storage: direct mappings or sequential segment decoding into disk caches."""

from dataclasses import dataclass
import math
import errno
import os
from pathlib import Path
import tempfile
import time
import cv2
import imagecodecs
import numpy as np
import psutil
import tifffile
from .config import FocusStackError
from .memory import close_mapping, evict, flush_rows, effective_budget, decoder_requirement
from .downsample import AreaReducer
from .metadata import read_metadata

@dataclass(frozen=True)
class ImageInfo:
    path: Path
    raw_shape: tuple
    shape: tuple
    dtype: np.dtype
    orientation: int
    mappable: bool
    max_segment_bytes: int
    metadata: dict
    encoded_segment_bytes: int = 0
    decoded_segment_bytes: int = 0

    @property
    def raw_bytes(self):
        return int(np.prod(self.raw_shape)) * self.dtype.itemsize


def discover(inputs):
    paths = []
    for item in inputs:
        path = Path(item).expanduser().resolve()
        if path.is_dir():
            paths.extend(sorted(p for p in path.iterdir() if p.suffix.lower() in {".tif", ".tiff"} and p.is_file()))
        elif path.is_file() and path.suffix.lower() in {".tif", ".tiff"}:
            paths.append(path)
        else:
            raise FocusStackError(f"Missing input or unsupported TIFF path: {path}")
    paths = list(dict.fromkeys(paths))
    if not paths:
        raise FocusStackError("No .tif or .tiff input files found")
    if len(paths) > 65535:
        raise FocusStackError("At most 65535 frames are supported")
    return paths


def inspect_image(path):
    try:
        with tifffile.TiffFile(path) as tif:
            if len(tif.pages) != 1:
                raise FocusStackError(f"{path}: expected a single-page RGB TIFF")
            page = tif.pages[0]
            if page.subifds:
                raise FocusStackError(f"{path}: subIFD/pyramidal TIFF layouts are unsupported")
            dtype = np.dtype(page.dtype)
            if page.photometric != 2 or page.planarconfig != 1 or len(page.shape) != 3 or page.shape[-1] != 3:
                raise FocusStackError(f"{path}: expected contiguous RGB, three channels; got shape {page.shape}")
            if dtype.kind != "u" or dtype.itemsize not in {1, 2}:
                raise FocusStackError(f"{path}: expected uint8 or uint16; got {dtype}")
            if page.bitspersample not in {8, 16}:
                raise FocusStackError(f"{path}: packed sample depths are unsupported")
            orientation = int(page.tags["Orientation"].value) if "Orientation" in page.tags else 1
            if orientation not in range(1, 9):
                raise FocusStackError(f"{path}: invalid orientation {orientation}")
            shape = tuple(page.shape)
            if orientation >= 5:
                shape = (shape[1], shape[0], 3)
            # Check strip/tile references before choosing mmap (mmap itself does not decode).
            size = Path(path).stat().st_size
            if any(n <= 0 or off <= 0 or off + n > size for off, n in zip(page.dataoffsets, page.databytecounts)):
                raise FocusStackError(f"{path}: corrupt/truncated or sparse TIFF segments")
            sh = page.tilelength if page.is_tiled else min(page.rowsperstrip, page.imagelength)
            sw = page.tilewidth if page.is_tiled else page.imagewidth
            expected_segments = math.ceil(page.imagelength/sh) * math.ceil(page.imagewidth/sw)
            if len(page.dataoffsets) != expected_segments or len(page.databytecounts) != expected_segments:
                raise FocusStackError(f"{path}: incorrect TIFF segment table")
            segment_bytes = int(sh * sw * 3 * dtype.itemsize)
            encoded_bytes = max(page.databytecounts)
            mappable = bool(page.is_memmappable)
            metadata = read_metadata(page)
            if orientation >= 5 and "resolution" in metadata:
                metadata["resolution"] = metadata["resolution"][::-1]
            return ImageInfo(Path(path), tuple(page.shape), shape, dtype, orientation, mappable, max(segment_bytes, encoded_bytes), metadata, encoded_bytes, segment_bytes)
    except FocusStackError:
        raise
    except Exception as exc:
        raise FocusStackError(f"Cannot inspect TIFF {path}: {exc}") from exc


def validate_stack(infos):
    first = infos[0]
    for info in infos[1:]:
        if info.shape != first.shape:
            raise FocusStackError(f"Dimension/channel mismatch: {info.path} has {info.shape}, expected {first.shape}")
        if info.dtype.kind != first.dtype.kind or info.dtype.itemsize != first.dtype.itemsize:
            raise FocusStackError(f"Bit-depth mismatch: {info.path} has {info.dtype}, expected {first.dtype}")
        if info.metadata.get("iccprofile") != first.metadata.get("iccprofile"):
            raise FocusStackError(f"ICC profile mismatch: {info.path}; convert all frames to a common profile before stacking")


def oriented(array, orientation):
    # All operations are views into the underlying mapping, including rotations.
    if orientation == 1:
        return array
    if orientation == 2:
        return array[:, ::-1]
    if orientation == 3:
        return array[::-1, ::-1]
    if orientation == 4:
        return array[::-1]
    transposed = array.transpose(1, 0, 2)
    if orientation == 5:
        return transposed
    if orientation == 6:
        return transposed[:, ::-1]
    if orientation == 7:
        return transposed[::-1, ::-1]
    return transposed[::-1]


class Source:
    """One disk-backed image; regions are copied only at tile/reduced resolution."""

    def __init__(self, info, scratch, index, analysis_bound=None, timings=None, decoder_budget=None):
        self.info = info
        self.raw = None
        self.analysis_path = None
        try:
            if info.mappable:
                self.raw = tifffile.memmap(info.path, mode="r")
            else:
                budget = effective_budget("auto") if decoder_budget is None else decoder_budget
                current = psutil.Process().memory_info().rss
                analysis_bytes = (min(analysis_bound, max(info.shape[:2]))**2*8) if analysis_bound else 0
                if decoder_requirement(info) + max(current, 160*1024**2) + analysis_bytes > budget:
                    raise FocusStackError("TIFF segment exceeds safe dynamic decoder budget; increase memory budget or retile")
                cache_path = Path(scratch) / f"source-{index:05d}.raw"
                self.raw = np.memmap(cache_path, mode="w+", dtype=info.dtype, shape=info.raw_shape)
                reducer = AreaReducer(info.shape, analysis_bound) if analysis_bound and info.orientation == 1 else None
                analysis_seconds = 0.0
                dirty_start, dirty_end, dirty_bytes = info.raw_shape[0], 0, 0
                def consume(decoded):
                    nonlocal dirty_start, dirty_end, dirty_bytes, analysis_seconds
                    data, position, _ = decoded
                    if data is None:
                        raise FocusStackError(f"{info.path}: missing TIFF segment")
                    _, _, y, x, _ = position
                    h = min(data.shape[1], info.raw_shape[0]-y)
                    w = min(data.shape[2], info.raw_shape[1]-x)
                    # Large segments are decoded once, but copies/cache pages are batched.
                    rows = max(1, min(512, (16*1024**2)//(w*info.dtype.itemsize*3)))
                    for by in range(0, h, rows):
                        ey = min(by+rows, h)
                        block = data[0, by:ey, :w, :3]
                        self.raw[y+by:y+ey, x:x+w] = block
                        if reducer is not None:
                            started = time.perf_counter()
                            for bx in range(0, w, 512):
                                reducer.add(block[:, bx:bx+512], y+by, x+bx)
                            analysis_seconds += time.perf_counter()-started
                        dirty_start = min(dirty_start, y+by)
                        dirty_end = max(dirty_end, y+ey)
                        dirty_bytes += block.nbytes
                        if dirty_bytes >= 32*1024**2:
                            flush_rows(self.raw, dirty_start, dirty_end)
                            dirty_start, dirty_end, dirty_bytes = info.raw_shape[0], 0, 0
                    # Callback returns no decoded array: previous segment is released
                    # before the iterator reads/decodes the next one.
                    return None
                with tifffile.TiffFile(info.path) as tif:
                    for _ in tif.pages[0].segments(maxworkers=1, buffersize=1, func=consume):
                        pass
                if dirty_bytes:
                    flush_rows(self.raw, dirty_start, dirty_end)
                if reducer is not None:
                    self.analysis_path = Path(scratch) / f"alignment-{index:05d}.npy"
                    np.save(self.analysis_path, reducer.finish())
                    if timings:
                        timings.seconds["alignment_images"] += analysis_seconds
            self.array = oriented(self.raw, info.orientation)
        except BaseException as exc:
            if self.raw is not None:
                close_mapping(self.raw)
            if not isinstance(exc, Exception):
                raise
            raise FocusStackError(f"Cannot prepare/cache {info.path}: {exc}") from exc

    def release_pages(self):
        evict(self.raw)

    def close(self):
        self.array = None
        close_mapping(self.raw)

    def reduced_gray(self, max_dim):
        """Streaming separable area sums; cached decode analysis avoids a rescan."""
        path = getattr(self, "analysis_path", None)
        if path is not None:
            result = np.load(path)
            if max(result.shape) > max_dim:
                from .alignment import resize_gray
                result = resize_gray(result, max_dim)
            return result
        reducer = AreaReducer(self.array.shape, max_dim)
        try:
            h, w = self.array.shape[:2]
            for y in range(0, h, 512):
                for x in range(0, w, 512):
                    reducer.add(self.array[y:min(y+512, h), x:min(x+512, w)], y, x)
                    self.release_pages()
            return reducer.finish()
        except Exception as exc:
            raise FocusStackError(f"Cannot downsample {self.info.path}: {exc}") from exc

    def warp_tile(self, transform, bounds):
        """Transform maps source to reference; inverse mapping reads a source ROI."""
        y0, y1, x0, x1 = bounds
        h, w = y1-y0, x1-x0
        if np.array_equal(transform, np.eye(2, 3)):
            native = np.uint16 if self.info.dtype.itemsize == 2 else np.uint8
            rgb = np.array(self.array[y0:y1, x0:x1], dtype=native, copy=True)
            self.release_pages()
            if rgb.dtype.itemsize == 1:
                rgb = rgb.astype(np.uint16)*257
            return rgb, np.ones((h, w), bool)
        inverse = cv2.invertAffineTransform(transform)
        corners = np.array([[x0, y0, 1], [x1-1, y0, 1], [x0, y1-1, 1], [x1-1, y1-1, 1]], np.float64)
        mapped = corners @ inverse.T
        ih, iw = self.array.shape[:2]
        sx = max(0, int(np.floor(mapped[:, 0].min())) - 2)
        ex = min(iw, int(np.ceil(mapped[:, 0].max())) + 3)
        sy = max(0, int(np.floor(mapped[:, 1].min())) - 2)
        ey = min(ih, int(np.ceil(mapped[:, 1].max())) + 3)
        if sx >= ex or sy >= ey:
            return np.zeros((h, w, 3), np.uint16), np.zeros((h, w), bool)
        native_dtype = np.uint16 if self.info.dtype.itemsize == 2 else np.uint8
        if max(h, w, ey-sy, ex-sx) >= 32767:
            raise FocusStackError("Required tile/ROI exceeds OpenCV's 32767 dimension limit; reduce tile size")
        roi = np.ascontiguousarray(self.array[sy:ey, sx:ex], dtype=native_dtype)
        # Geometry is local processing too: preserve fractional interpolation
        # values until the final fused uint16 conversion, while storage stays
        # uint8/uint16. This never converts a whole production frame to float.
        roi = roi.astype(np.float32)
        if self.info.dtype.itemsize == 1:
            roi *= 257
        # Compute maps in global coordinates. warpAffine's local fixed-point
        # increment rounding otherwise depends on tile origin and can change
        # focus winners at close scores, producing subtle affine tile seams.
        xx = np.arange(x0, x1, dtype=np.float32)[None, :]
        yy = np.arange(y0, y1, dtype=np.float32)[:, None]
        coeff = inverse.astype(np.float32)
        mx = coeff[0, 0] * xx + coeff[0, 1] * yy + coeff[0, 2]
        my = coeff[1, 0] * xx + coeff[1, 1] * yy + coeff[1, 2]
        valid = (mx >= -1e-4) & (mx <= iw-1+1e-4) & (my >= -1e-4) & (my <= ih-1+1e-4)
        mx -= sx
        my -= sy
        rgb = cv2.remap(roi, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        del roi
        self.release_pages()
        return rgb, valid


def validate_output(path, shape, expected_metadata):
    try:
        with tifffile.TiffFile(path) as tif:
            page = tif.pages[0]
            if len(tif.pages) != 1 or page.shape != shape or page.dtype != np.dtype("uint16") or page.photometric != 2:
                raise FocusStackError("Written TIFF has incorrect dimensions, dtype or channels")
            if "iccprofile" in expected_metadata:
                if "InterColorProfile" not in page.tags or bytes(page.tags["InterColorProfile"].value) != expected_metadata["iccprofile"]:
                    raise FocusStackError("Written TIFF lost the ICC profile")
            # Decode every segment, bounded and sequential, to detect truncated/corrupt output.
            for data, _, _ in page.segments(maxworkers=1, buffersize=1):
                if data is None or data.dtype != np.dtype("uint16"):
                    raise FocusStackError("Written TIFF has an invalid segment")
    except FocusStackError:
        raise
    except Exception as exc:
        raise FocusStackError(f"Output validation failed: {exc}") from exc


def atomic_write(output, pixels, metadata, compression, stage, timings=None):
    """Encode bounded strips; validate before replacing an existing destination."""
    output = Path(output)
    fd, name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp", dir=output.parent)
    os.close(fd)
    try:
        h, w, _ = pixels.shape
        rows = max(1, min(64, 1024**2 // (w * 6)))
        encoder = {"zlib": imagecodecs.zlib_encode, "lzw": imagecodecs.lzw_encode,
                   "zstd": imagecodecs.zstd_encode}.get(compression)
        def strips():
            for y in range(0, h, rows):
                block = np.array(pixels[y:y+rows], copy=True)
                evict(pixels)
                # TIFF's ndarray iterator represents whole pages for strip output.
                # Bytes iterators represent already encoded strips, so explicitly
                # encode one bounded strip without handing it a full page array.
                yield encoder(block) if encoder else block.tobytes()
        encoding_started = time.perf_counter()
        tifffile.imwrite(name, data=strips(), shape=pixels.shape, dtype=np.uint16,
                         photometric="rgb", rowsperstrip=rows, metadata=None,
                         bigtiff=h*w*6*(1.6 if compression == "lzw" else 1.1) + 4*1024**2 >= 2**32 - 2**25,
                         compression=None if compression == "none" else compression,
                         maxworkers=1, buffersize=1024**2, software="FocusStack 0.2.0", **metadata)
        if timings:
            timings.seconds["output_encoding"] += time.perf_counter()-encoding_started
        stage("Validate output")
        validation_started = time.perf_counter()
        validate_output(name, pixels.shape, metadata)
        if timings:
            timings.seconds["output_validation"] += time.perf_counter()-validation_started
        with open(name, "rb") as file:
            os.fsync(file.fileno())
        os.replace(name, output)
        directory_fd = os.open(output.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            try:
                os.fsync(directory_fd)
            except OSError as exc:
                if exc.errno not in {errno.EINVAL, errno.ENOTSUP}:
                    raise
        finally:
            os.close(directory_fd)
    finally:
        Path(name).unlink(missing_ok=True)
