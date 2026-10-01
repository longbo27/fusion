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
    tile_size: int = 1024
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
    def required_halo(self):
        # Sobel + focus aggregation (+ multiscale prefilter), median, mask blur.
        focus_support = 2 * self.focus_radius + 4 if self.multiscale else self.focus_radius + 1
        return focus_support + 1 + self.blend_radius

    @property
    def halo(self):
        return self.required_halo if self.tile_overlap is None else self.tile_overlap

    def validate(self):
        if self.tile_size < 16 or self.alignment_max_dim < 32:
            raise FocusStackError("tile size must be >=16 and alignment max dimension >=32")
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
