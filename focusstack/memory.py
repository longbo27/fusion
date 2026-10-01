"""Working budgets, decoder preflight, mapped-range flushing, portable RSS."""
from dataclasses import dataclass
import mmap
from pathlib import Path
import re
import resource
import shutil
import sys
import psutil
from .config import FocusStackError

MIB = 1024**2


def parse_budget(value):
    if value == "auto":
        return None
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMGT]?)(?:I?B)?\s*", str(value).upper())
    if not match:
        raise FocusStackError("memory budget must be auto or a size such as 8G or 512M")
    size = int(float(match[1]) * 1024**("KMGT".find(match[2])+1 if match[2] else 0))
    if size < 64*MIB:
        raise FocusStackError("memory budget must be at least 64 MiB")
    return size


def available_memory():
    ram = psutil.virtual_memory()
    total, available = ram.total, ram.available
    # psutil can expose host RAM rather than a container's enforced limit.
    if sys.platform.startswith("linux"):
        try:
            root = Path("/sys/fs/cgroup")
            limit_text = (root/"memory.max").read_text().strip()
            if limit_text != "max":
                limit = int(limit_text)
                current = int((root/"memory.current").read_text())
                stats = dict(line.split() for line in (root/"memory.stat").read_text().splitlines())
                # Clean active file cache is reclaimable too; excluding it
                # would reject large decodes simply because earlier benchmarks
                # warmed source TIFFs. Dirty/writeback pages stay reserved.
                reclaimable = max(0, int(stats.get("inactive_file", 0)) + int(stats.get("active_file", 0))
                                  - int(stats.get("file_dirty", 0)) - int(stats.get("file_writeback", 0)))
                total = min(total, limit)
                available = min(available, max(0, limit-current+reclaimable))
        except (OSError, ValueError):
            pass
    return total, available


def effective_budget(value, available=None):
    total, observed = available_memory()
    available = observed if available is None else min(observed, available)
    # Keep >=40% of available memory for OS/other jobs; cap auto working set at 4G.
    safe = min(int(available*0.6), max(0, int(total*0.75)))
    requested = parse_budget(value)
    return min(safe, 4*1024**3) if requested is None else min(safe, requested)


@dataclass(frozen=True)
class ResourcePlan:
    ram_bytes: int
    available_ram: int
    scratch_bytes: int
    output_bytes: int
    budget_bytes: int
    tile_size: int
    decoder_bytes: int


def decoder_requirement(info):
    # One decoded segment, touched cache pages, codec scratch, and a conservative
    # encoded-byte iterator hand-off allowance. The old decoded array is released
    # by the callback before the next segment is decoded.
    decoded = getattr(info, "decoded_segment_bytes", info.max_segment_bytes)
    encoded = getattr(info, "encoded_segment_bytes", info.max_segment_bytes)
    return 2*encoded + 2*decoded + 64*MIB


def working_estimate(config, tile_size, shape):
    side = tile_size + 2*(config.halo+config.grid)
    analysis = min(config.analysis_bound, max(shape[:2]))**2 * 40 if config.alignment != "none" else 0
    # top-K, noise/edge metric, current ROI, source pyramid and accumulator pyramid.
    per_pixel = 160 if config.quality == "standard" else 240
    return side*side*per_pixel + analysis + 160*MIB


def plan_resources(infos, config, scratch_parent, output_parent):
    height, width, _ = infos[0].shape
    rgb_bytes = height*width*6
    scratch_bytes = sum(i.raw_bytes for i in infos if not i.mappable)+rgb_bytes
    if config.alignment != "none":
        scratch_bytes += sum(min(config.analysis_bound, max(i.shape[:2]))**2+128 for i in infos if not i.mappable)
    output_bytes = int(rgb_bytes*(1.6 if config.compression == "lzw" else 1.1))+4*MIB
    _, available = available_memory()
    budget = effective_budget(config.memory_budget, available)
    bookkeeping = sum(2048 + len(i.metadata.get("iccprofile", b"")) for i in infos if hasattr(i, "metadata"))
    decoder = max((decoder_requirement(i) for i in infos if not i.mappable), default=0)
    writer = width*6*6+128*MIB  # input/output codec buffers and iterator hand-off
    if writer+bookkeeping > budget:
        raise FocusStackError("Output strip row exceeds safe working RAM budget; increase --memory-budget")
    # TIFF preparation and fusion occur sequentially; do not sum independent peaks.
    candidates = [2048, 1536, 1024, 512] if config.tile_size == "auto" else [config.tile_size]
    tile_size = next((n for n in candidates if working_estimate(config, n, infos[0].shape)+bookkeeping <= budget), None)
    if tile_size is None:
        raise FocusStackError(f"Estimated working RAM exceeds memory budget {budget/2**30:.2f} GiB; reduce tile size/analysis dimension")
    if decoder + 160*MIB + bookkeeping + config.analysis_bound**2*8 > budget:
        raise FocusStackError(f"TIFF segment exceeds safe dynamic decoder budget: need {(decoder+160*MIB)/2**30:.2f} GiB, budget {budget/2**30:.2f} GiB; increase --memory-budget or retile")
    ram = max(working_estimate(config, tile_size, infos[0].shape), decoder+160*MIB, writer)+bookkeeping
    scratch_parent, output_parent = Path(scratch_parent), Path(output_parent)
    if scratch_parent.stat().st_dev == output_parent.stat().st_dev:
        if shutil.disk_usage(scratch_parent).free < scratch_bytes+output_bytes:
            raise FocusStackError(f"Insufficient disk space: need {(scratch_bytes+output_bytes)/2**30:.2f} GiB for scratch and atomic output")
    else:
        for directory, need in [(scratch_parent, scratch_bytes), (output_parent, output_bytes)]:
            if shutil.disk_usage(directory).free < need:
                raise FocusStackError(f"Insufficient disk space in {directory}: need {need/2**30:.2f} GiB")
    return ResourcePlan(ram, available, scratch_bytes, output_bytes, budget, tile_size, decoder)


def ensure_fd_capacity(frames):
    """macOS often starts with a 256-descriptor soft limit; one map per source."""
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    needed = frames+64
    if soft == resource.RLIM_INFINITY:
        return
    if soft < needed:
        if hard != resource.RLIM_INFINITY and hard < needed:
            raise FocusStackError(f"File descriptor limit {hard} is too low for {frames} frames; increase ulimit -n")
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (needed, hard))
        except (OSError, ValueError) as exc:
            raise FocusStackError("Cannot raise file descriptor limit; increase ulimit -n before stacking") from exc


def advise(mapping, start=0, length=0):
    flag = getattr(mmap, "MADV_DONTNEED", None)
    if mapping is not None and flag is not None and hasattr(mapping, "madvise"):
        try:
            if length:
                mapping.madvise(flag, start, length)
            else:
                mapping.madvise(flag)
        except (OSError, ValueError):
            pass  # macOS/other mapping implementations may not support this advice.


def evict(array, *, dirty=False):
    if dirty:
        array.flush()
    advise(getattr(array, "_mmap", None))


def flush_rows(array, y0, y1):
    """Flush and evict a bounded contiguous byte range, aligned to OS pages."""
    mapping = array._mmap
    rowbytes = array.shape[1]*array.shape[2]*array.dtype.itemsize
    offset = getattr(array, "offset", 0)
    start = (offset+y0*rowbytes)//mmap.PAGESIZE*mmap.PAGESIZE
    end = min(len(mapping), offset+y1*rowbytes)
    if end > start:
        mapping.flush(start, end-start)
        advise(mapping, start, end-start)


def close_mapping(array):
    mapping = getattr(array, "_mmap", None)
    if mapping is not None:
        mapping.close()


def rss_to_bytes(value, platform=None):
    return int(value) if (platform or sys.platform) == "darwin" else int(value)*1024


def peak_rss_bytes():
    return rss_to_bytes(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
