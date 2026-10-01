"""Inclusive wall timers for bounded pipeline operations."""
from contextlib import contextmanager
from time import perf_counter

STAGES = ("preparation_cache", "alignment_images", "feature_alignment", "focus_pass",
          "depth_regularization", "fusion", "output_encoding", "output_validation")


class Timings:
    def __init__(self):
        self.seconds = dict.fromkeys(STAGES, 0.0)

    @contextmanager
    def measure(self, name):
        start = perf_counter()
        try:
            yield
        finally:
            self.seconds[name] = self.seconds.get(name, 0.0) + perf_counter()-start
