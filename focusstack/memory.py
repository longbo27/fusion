"""Resource planning and explicit eviction of file-backed working sets."""

from dataclasses import dataclass
import mmap
from pathlib import Path
import resource
import shutil
import psutil
from .config import FocusStackError


@dataclass(frozen=True)
class ResourcePlan:
    ram_bytes: int
    available_ram: int
    scratch_bytes: int
    output_bytes: int


def plan_resources(infos, config, scratch_parent, output_parent):
    height, width, _ = infos[0].shape
    rgb_bytes = height * width * 6
    cache_bytes = sum(i.raw_bytes for i in infos if not i.mappable)
    scratch_bytes = cache_bytes + rgb_bytes
    # DEFLATE/ZSTD/LZW overhead, headers, strip tables, conservative LZW expansion.
    output_bytes = int(rgb_bytes * (1.6 if config.compression == "lzw" else 1.1)) + 4 * 1024**2
    side = config.tile_size + 2 * config.halo
    # Working pixels, remapping/source ROI, gradients, masks, accumulator, allocator margin.
    ram = side * side * 160 + min(config.alignment_max_dim, max(height, width))**2 * 32 + 128 * 1024**2
    # Generator hand-off may briefly retain old/new decoded segments plus bytes.
    ram += 3 * max(i.max_segment_bytes for i in infos if not i.mappable) if any(not i.mappable for i in infos) else 0
    available = psutil.virtual_memory().available
    if ram > available * 0.8:
        raise FocusStackError(f"Estimated working RAM {ram / 2**30:.2f} GiB exceeds safe available RAM {available / 2**30:.2f} GiB; reduce tile size/alignment max dimension")
    scratch_parent, output_parent = Path(scratch_parent), Path(output_parent)
    if scratch_parent.stat().st_dev == output_parent.stat().st_dev:
        if shutil.disk_usage(scratch_parent).free < scratch_bytes + output_bytes:
            raise FocusStackError(f"Insufficient disk space: need {(scratch_bytes + output_bytes) / 2**30:.2f} GiB for scratch and atomic output")
    else:
        for directory, need in [(scratch_parent, scratch_bytes), (output_parent, output_bytes)]:
            if shutil.disk_usage(directory).free < need:
                raise FocusStackError(f"Insufficient disk space in {directory}: need {need / 2**30:.2f} GiB")
    return ResourcePlan(ram, available, scratch_bytes, output_bytes)


def evict(array, *, dirty=False):
    """Linux RSS must not grow with touched mmap pages. Drop after bounded work."""
    if dirty:
        array.flush()
    mapping = getattr(array, "_mmap", None)
    if mapping is not None and hasattr(mapping, "madvise"):
        mapping.madvise(mmap.MADV_DONTNEED)


def close_mapping(array):
    mapping = getattr(array, "_mmap", None)
    if mapping is not None:
        mapping.close()


def peak_rss_bytes():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024  # Linux
