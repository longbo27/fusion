"""Concise CLI for the reusable stacking pipeline."""

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys
from . import __version__
from .config import Config, FocusStackError
from .engine import stack
from .io import discover


def parser():
    result = argparse.ArgumentParser(description="FocusStack: bounded-memory RGB TIFF focus stacking")
    result.add_argument("inputs", nargs="+", help="TIFF files or directories (directory order is lexical)")
    result.add_argument("-o", "--output", required=True, type=Path)
    result.add_argument("--version", action="version", version=f"FocusStack {__version__}")
    result.add_argument("--tile-size", type=lambda v: v if v == "auto" else int(v))
    result.add_argument("--memory-budget", default="auto")
    result.add_argument("--quality", choices=["standard", "high", "max"], default="standard")
    result.add_argument("--benchmark-stages", action="store_true")
    result.add_argument("--report-json", type=Path)
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
    benchmark_stages = options.pop("benchmark_stages")
    report = options.pop("report_json")
    try:
        if report and (report.resolve() == output.resolve() or report.resolve() in discover(inputs)):
            raise FocusStackError("Report path must differ from output and input paths")
        config = Config.from_environment(**options)
        result = stack(inputs, output, config, log=lambda message: print(message, file=sys.stderr),
              progress=sys.stderr.isatty(), verbose=verbose)
        if benchmark_stages:
            print(json.dumps(result.timings, indent=2), file=sys.stderr)
        if report:
            report.parent.mkdir(parents=True, exist_ok=True)
            data = asdict(result)
            data["transforms"] = [m.tolist() for m in result.transforms]
            report.write_text(json.dumps(data, default=str, indent=2))
    except KeyboardInterrupt:
        print("Interrupted; incomplete output removed.", file=sys.stderr)
        return 130
    except (FocusStackError, OSError) as exc:
        print(f"focusstack: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
