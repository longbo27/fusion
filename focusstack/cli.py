"""Concise CLI for the reusable stacking pipeline."""

import argparse
from pathlib import Path
import sys
from . import __version__
from .config import Config, FocusStackError
from .engine import stack


def parser():
    result = argparse.ArgumentParser(description="FocusStack: bounded-memory RGB TIFF focus stacking")
    result.add_argument("inputs", nargs="+", help="TIFF files or directories (directory order is lexical)")
    result.add_argument("-o", "--output", required=True, type=Path)
    result.add_argument("--version", action="version", version=f"FocusStack {__version__}")
    result.add_argument("--tile-size", type=int)
    result.add_argument("--tile-overlap", type=int, help="halo pixels; defaults to required finite filter support")
    result.add_argument("--alignment", choices=["affine", "translation", "none"], default="affine")
    result.add_argument("--alignment-max-dim", type=int)
    result.add_argument("--reference", type=int, help="zero-based reference index (default: middle)")
    result.add_argument("--focus-radius", type=int, default=3)
    result.add_argument("--blend-radius", type=int, default=8)
    result.add_argument("--multiscale", action="store_true")
    result.add_argument("--compression", choices=["none", "zlib", "lzw", "zstd"], default="zlib")
    result.add_argument("--temp-dir", type=Path)
    result.add_argument("--max-workers", type=int, help="maximum OpenCV threads; TIFF codecs remain sequential")
    result.add_argument("--keep-temp", action="store_true")
    result.add_argument("--verbose", action="store_true")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    options = vars(args).copy()
    inputs, output = options.pop("inputs"), options.pop("output")
    verbose = options.pop("verbose")
    try:
        config = Config.from_environment(**options)
        stack(inputs, output, config, log=lambda message: print(message, file=sys.stderr),
              progress=sys.stderr.isatty(), verbose=verbose)
    except KeyboardInterrupt:
        print("Interrupted; incomplete output removed.", file=sys.stderr)
        return 130
    except FocusStackError as exc:
        print(f"focusstack: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
