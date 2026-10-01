"""FocusStack: CPU, disk-backed, tiled photographic fusion."""

__version__ = "0.2.0"

from .config import Config, FocusStackError
from .engine import stack

__all__ = ["Config", "FocusStackError", "stack", "__version__"]
