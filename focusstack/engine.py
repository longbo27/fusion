"""Pipeline orchestration independent of the command-line interface."""

from dataclasses import dataclass, replace
import math
from pathlib import Path
import shutil
import tempfile
import time
import cv2
import numpy as np
from tqdm import tqdm
from .alignment import align_sources
from .config import Config, FocusStackError
from .fusion import fuse_tile, tile_bounds
from .io import Source, atomic_write, discover, inspect_image, validate_stack
from .memory import close_mapping, flush_rows, peak_rss_bytes, plan_resources, ensure_fd_capacity
from .timing import Timings


@dataclass(frozen=True)
class StackResult:
    output: Path
    shape: tuple
    frames: int
    elapsed_seconds: float
    peak_rss_bytes: int
    scratch_bytes: int
    output_bytes: int
    transforms: tuple
    scratch_path: Path | None
    timings: dict
    tile_size: int
    budget_bytes: int
    input_bytes: int
    alignment_diagnostics: tuple


def stack(inputs, output, config=None, *, log=None, progress=False, verbose=False):
    config = config or Config.from_environment()
    config.validate()
    started = time.perf_counter()
    stage = log or (lambda message: None)
    sources, pixels, scratch = [], None, None
    timings = Timings()
    cv2.setNumThreads(config.max_workers)  # no process pools or per-frame concurrency
    try:
        stage("Scan")
        paths = discover(inputs)
        output = Path(output).expanduser().resolve()
        if output in paths:
            raise FocusStackError("Output must differ from every input TIFF")
        stage("Validate")
        infos = [inspect_image(path) for path in paths]  # headers only
        validate_stack(infos)
        ref = len(infos)//2 if config.reference is None else config.reference
        if ref < 0 or ref >= len(infos):
            raise FocusStackError(f"Reference index must be between 0 and {len(infos)-1}")
        output.parent.mkdir(parents=True, exist_ok=True)
        scratch_parent = Path(config.temp_dir or tempfile.gettempdir()).expanduser().resolve()
        scratch_parent.mkdir(parents=True, exist_ok=True)
        plan = plan_resources(infos, config, scratch_parent, output.parent)
        ensure_fd_capacity(len(infos))
        config = replace(config, tile_size=plan.tile_size)
        h, w, _ = infos[0].shape
        tiles = math.ceil(h/config.tile_size)*math.ceil(w/config.tile_size)
        stage(f"{len(infos)} frames | {w}×{h} RGB {infos[0].dtype} | tile {config.tile_size}, halo {config.halo}, {tiles} tiles")
        stage(f"Estimated RAM {plan.ram_bytes/2**30:.2f} GiB / available {plan.available_ram/2**30:.2f} GiB | scratch {plan.scratch_bytes/2**30:.2f} GiB + output reserve {plan.output_bytes/2**30:.2f} GiB")
        scratch = Path(tempfile.mkdtemp(prefix="focusstack-", dir=scratch_parent))
        stage(f"Working memory budget {plan.budget_bytes/2**30:.2f} GiB")
        stage("Prepare/cache")
        with timings.measure("preparation_cache"):
            for index, info in enumerate(infos):
                sources.append(Source(info, scratch, index,
                    config.analysis_bound if config.alignment != "none" and len(infos) > 1 else None,
                    timings, plan.budget_bytes))
        # Integrated analysis is measured separately, exclude it from preparation.
        timings.seconds["preparation_cache"] -= timings.seconds["alignment_images"]
        stage("Align")
        def alignment_progress(index, result):
            if verbose:
                stage(f"Frame {index}: {result.method}, {result.diagnostics}, transform {result.matrix.tolist()}")
        alignment = align_sources(sources, ref, config, alignment_progress, timings)
        stage(f"Alignment: {config.alignment}, reference {ref}, minimum score {min(r.score for r in alignment):.3f}")
        transforms = [result.matrix for result in alignment]
        pixels = np.memmap(scratch / "output.raw", mode="w+", dtype=np.uint16, shape=infos[0].shape)
        stage("Stack tiles")
        iterator = tile_bounds(infos[0].shape, config.tile_size, config.halo, config.grid)
        for core, expanded in tqdm(iterator, total=tiles, desc="Tiles", disable=not progress, unit="tile"):
            tile = fuse_tile(sources, transforms, expanded, config, ref, timings)
            y, ey, x, ex = core
            hy, _, hx, _ = expanded
            pixels[y:ey, x:ex] = tile[y-hy:ey-hy, x-hx:ex-hx]
            del tile
            flush_rows(pixels, y, ey)
        for source in sources:
            source.close()
        sources.clear()
        scratch_bytes = sum(p.stat().st_size for p in scratch.iterdir())
        stage("Write")
        atomic_write(output, pixels, infos[ref].metadata, config.compression, stage, timings)
        elapsed = time.perf_counter()-started
        peak = peak_rss_bytes()
        stage(f"Complete | {elapsed:.2f}s | peak RSS {peak/2**20:.1f} MiB | output {output.stat().st_size/2**20:.1f} MiB")
        return StackResult(output, infos[0].shape, len(infos), elapsed, peak, scratch_bytes,
                           output.stat().st_size, tuple(transforms), scratch if config.keep_temp else None,
                           {**timings.seconds, "total": elapsed}, config.tile_size, plan.budget_bytes,
                           sum(i.path.stat().st_size for i in infos), tuple(r.diagnostics for r in alignment))
    except FocusStackError:
        raise
    except MemoryError as exc:
        raise FocusStackError("Working allocation failed; reduce tile size/alignment max dimension") from exc
    except Exception as exc:
        raise FocusStackError(f"Processing failed: {exc}") from exc
    finally:
        for source in sources:
            source.close()
        if pixels is not None:
            close_mapping(pixels)
        if scratch is not None:
            if config.keep_temp:
                stage(f"Temporary files kept at {scratch}")
            else:
                shutil.rmtree(scratch)
