"""Validated algorithm settings; no UI or platform dependencies."""

from dataclasses import dataclass
import os
from pathlib import Path


class FocusStackError(Exception):
    """Actionable input, resource, or processing failure."""


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError as exc:
        raise FocusStackError(f"{name} must be an integer") from exc


@dataclass(frozen=True)
class Config:
    tile_size: int | str = 1024
    memory_budget: str = "auto"
    quality: str = "standard"
    tile_overlap: int | None = None
    alignment: str = "affine"
    alignment_max_dim: int = 4096
    reference: int | None = None
    focus_radius: int = 3
    blend_radius: int = 8
    multiscale: bool = False
    compression: str = "zlib"
    temp_dir: Path | None = None
    max_workers: int = 2
    keep_temp: bool = False

    @classmethod
    def from_environment(cls, **kwargs):
        defaults = dict(
            tile_size=env_int("FOCUSSTACK_TILE_SIZE", 1024),
            alignment_max_dim=env_int("FOCUSSTACK_ALIGNMENT_MAX_DIM", 4096),
            max_workers=env_int("FOCUSSTACK_MAX_WORKERS", 2),
        )
        defaults.update({k: v for k, v in kwargs.items() if v is not None})
        return cls(**defaults)

    @property
    def pyramid_levels(self):
        return {"standard": 0, "high": 3, "max": 4}[self.quality]

    @property
    def grid(self):
        return 2**self.pyramid_levels

    @property
    def focus_support(self):
        if self.quality != "standard":
            return max(3*self.focus_radius+1, 2*self.focus_radius+8)
        return 2*self.focus_radius+4 if self.multiscale else self.focus_radius+1

    @property
    def analysis_bound(self):
        return min(self.alignment_max_dim, 2048)

    @property
    def required_halo(self):
        # Complete finite support: focus/cleanup/mask + analysis and synthesis
        # pyramid filters. Grid-aligned expansion makes tile phases identical.
        return self.focus_support + (1 if self.quality == "standard" else 2) + self.blend_radius + 4*(2**self.pyramid_levels-1)

    @property
    def halo(self):
        return self.required_halo if self.tile_overlap is None else self.tile_overlap

    def validate(self):
        if (self.tile_size != "auto" and (not isinstance(self.tile_size, int) or self.tile_size < 16)) or self.alignment_max_dim < 32:
            raise FocusStackError("tile size must be >=16 and alignment max dimension >=32")
        if self.quality not in {"standard", "high", "max"}:
            raise FocusStackError("quality must be standard, high, or max")
        from .memory import parse_budget
        parse_budget(self.memory_budget)
        if self.focus_radius < 1 or self.blend_radius < 0:
            raise FocusStackError("focus radius must be >=1 and blend radius >=0")
        if self.max_workers < 1 or self.max_workers > 32:
            raise FocusStackError("max workers must be between 1 and 32")
        if self.halo < self.required_halo:
            raise FocusStackError(f"tile overlap must be >= {self.required_halo} for these filters")
        if self.alignment not in {"none", "translation", "affine"}:
            raise FocusStackError("alignment must be affine, translation, or none")
        if self.compression not in {"none", "zlib", "lzw", "zstd"}:
            raise FocusStackError("compression must be none, zlib, lzw, or zstd")
