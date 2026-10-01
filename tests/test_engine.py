from dataclasses import replace
from pathlib import Path
import subprocess
import sys
import cv2
import numpy as np
import pytest
import tifffile
from focusstack import Config, FocusStackError, stack
from focusstack import engine, io
from focusstack.alignment import estimate, validate_transform
from focusstack.io import oriented


def config(tmp_path, **kwargs):
    defaults = dict(tile_size=64, alignment="none", temp_dir=tmp_path / "scratch", compression="zlib")
    defaults.update(kwargs)
    return Config(**defaults)


@pytest.mark.parametrize("compression,tiled", [(None, False), ("zlib", False), ("zlib", True), ("lzw", True)])
def test_uint16_storage_and_output(scene, write_frames, tmp_path, compression, tiled):
    options = dict(compression=compression)
    options.update(dict(tile=(64, 64)) if tiled else dict(rowsperstrip=16))
    files = write_frames([scene], **options)
    result = stack(files, tmp_path / "result.tif", config(tmp_path))
    with tifffile.TiffFile(result.output) as tif:
        assert tif.pages[0].dtype == np.dtype("uint16")
        assert tif.pages[0].shape == scene.shape
        assert tif.pages[0].compression == 8  # Adobe deflate
        assert np.array_equal(tif.asarray(), scene)
    assert not list((tmp_path / "scratch").iterdir())


def test_uint8_expands_full_range(scene, write_frames, tmp_path):
    frame = (scene >> 8).astype(np.uint8)
    result = stack(write_frames([frame]), tmp_path / "result.tif", config(tmp_path))
    assert np.array_equal(tifffile.imread(result.output), frame.astype(np.uint16)*257)


@pytest.mark.parametrize("multiscale", [False, True])
def test_two_focus_planes_and_tile_boundaries(scene, planes, write_frames, tmp_path, multiscale):
    paths = write_frames(planes, compression="zlib", rowsperstrip=16)
    cfg = config(tmp_path, multiscale=multiscale)
    small = stack(paths, tmp_path / "tiles.tif", cfg)
    large = stack(paths, tmp_path / "single.tif", replace(cfg, tile_size=512))
    a, b = tifffile.imread(small.output), tifffile.imread(large.output)
    assert np.max(np.abs(a.astype(np.int32)-b.astype(np.int32))) <= 1
    middle = scene.shape[1]//2
    region = np.ones(scene.shape[:2], bool)
    region[:, middle-20:middle+20] = False
    error = np.mean((a[region].astype(np.float32)-scene[region])**2)
    input_error = np.mean((planes[0][region].astype(np.float32)-scene[region])**2)
    assert error < input_error * 0.01
    assert np.max(a) > 255


@pytest.mark.parametrize("count", [1, 3, 7])
def test_deterministic_multiple_sources(scene, write_frames, tmp_path, count):
    files = write_frames([scene for _ in range(count)])
    a = stack(files, tmp_path / "a.tif", config(tmp_path))
    b = stack(files, tmp_path / "b.tif", config(tmp_path))
    assert np.array_equal(tifffile.imread(a.output), tifffile.imread(b.output))
    assert np.array_equal(tifffile.imread(a.output), scene)


@pytest.mark.parametrize("mode", ["translation", "affine"])
def test_alignment_translation_rotation_scale(scene, mode):
    ref = cv2.cvtColor((scene >> 8).astype(np.uint8), cv2.COLOR_RGB2GRAY)
    if mode == "translation":
        forward = np.array([[1, 0, 7], [0, 1, -5]], np.float64)
    else:
        forward = cv2.getRotationMatrix2D((ref.shape[1]/2, ref.shape[0]/2), 2.8, 1.035)
        forward[:, 2] += [3, -4]
    src = cv2.warpAffine(ref, forward, ref.shape[::-1], borderMode=cv2.BORDER_REFLECT_101)
    found, score, _ = estimate(ref, src, mode)
    points = np.array([[[30, 30], [270, 30], [30, 220], [270, 220]]], np.float32)
    expected = cv2.transform(points, cv2.invertAffineTransform(forward))
    actual = cv2.transform(points, found)
    assert np.max(np.linalg.norm(actual-expected, axis=2)) < 0.7
    assert score > 0.8


def test_end_to_end_affine_alignment(scene, write_frames, tmp_path):
    matrix = cv2.getRotationMatrix2D((160, 128), 2, 1.02)
    matrix[:, 2] += [4, -2]
    moved = cv2.warpAffine(scene, matrix, scene.shape[1::-1])
    files = write_frames([moved, scene], compression="zlib", rowsperstrip=16)
    cfg = config(tmp_path, alignment="affine", reference=1)
    result = stack(files, tmp_path / "aligned.tif", cfg)
    output = tifffile.imread(result.output)
    assert np.max(np.abs(result.transforms[0]-cv2.invertAffineTransform(matrix))) < 0.7
    error = np.mean((output[30:-30, 30:-30].astype(np.float32)-scene[30:-30, 30:-30])**2)
    assert error < 250000
    one_tile = stack(files, tmp_path / "aligned-one.tif", replace(cfg, tile_size=512))
    difference = np.abs(output.astype(np.int32)-tifffile.imread(one_tile.output).astype(np.int32))
    assert np.quantile(difference, 0.999) <= 1


def test_metadata_preservation(scene, write_frames, tmp_path):
    profile = b"Synthetic ICC payload for exact passthrough verification"
    files = write_frames([scene], iccprofile=profile, resolution=(300, 240), resolutionunit="INCH",
                         description="Macro specimen", extratags=[(315, "s", 0, "Photographer", False)])
    result = stack(files, tmp_path / "result.tif", config(tmp_path))
    with tifffile.TiffFile(result.output) as tif:
        tags = tif.pages[0].tags
        assert tags["InterColorProfile"].value == profile
        assert tags["XResolution"].value == (300, 1)
        assert tags["YResolution"].value == (240, 1)
        assert tags["ResolutionUnit"].value == 2
        assert tags["Orientation"].value == 1
        assert tags["ImageDescription"].value == "Macro specimen"
        assert tags["Artist"].value == "Photographer"


@pytest.mark.parametrize("orientation", range(1, 9))
def test_orientation_normalization(scene, write_frames, tmp_path, orientation):
    files = write_frames([scene], compression="zlib", rowsperstrip=16,
                         extratags=[(274, "H", 1, orientation, False)], resolution=(300, 240))
    result = stack(files, tmp_path / "result.tif", config(tmp_path))
    assert np.array_equal(tifffile.imread(result.output), oriented(scene, orientation))
    with tifffile.TiffFile(result.output) as tif:
        if orientation >= 5:
            assert tif.pages[0].tags["XResolution"].value == (240, 1)


@pytest.mark.parametrize("bad", ["corrupt", "truncated", "shape", "depth", "gray", "rgba", "float", "pages"])
def test_reject_incompatible(scene, write_frames, tmp_path, bad):
    good = write_frames([scene])[0]
    path = tmp_path / "bad.tif"
    if bad == "corrupt":
        path.write_bytes(b"not a TIFF")
    elif bad == "truncated":
        path.write_bytes(good.read_bytes()[:-1000])
    else:
        frames = {"shape": scene[:-1], "depth": (scene >> 8).astype(np.uint8),
                  "gray": scene[..., 0], "rgba": np.concatenate([scene, scene[..., :1]], axis=2),
                  "float": scene.astype(np.float32), "pages": np.stack([scene, scene])}
        tifffile.imwrite(path, frames[bad], photometric="minisblack" if bad == "gray" else "rgb")
    with pytest.raises(FocusStackError):
        stack([good, path], tmp_path / "output.tif", config(tmp_path))
    assert not (tmp_path / "output.tif").exists()


@pytest.mark.parametrize("exception", [OSError("disk write failed"), KeyboardInterrupt()])
def test_atomic_failure_cleanup(scene, write_frames, tmp_path, monkeypatch, exception):
    files = write_frames([scene])
    output = tmp_path / "output.tif"
    output.write_bytes(b"previous output must survive")
    def fail(name, **kwargs):
        Path(name).write_bytes(b"partial TIFF")
        raise exception
    monkeypatch.setattr(io.tifffile, "imwrite", fail)
    with pytest.raises((FocusStackError, KeyboardInterrupt)):
        stack(files, output, config(tmp_path))
    assert output.read_bytes() == b"previous output must survive"
    assert not list(tmp_path.glob(".output.tif.*.tmp"))
    assert not list((tmp_path / "scratch").iterdir())


def test_validation_failure_preserves_destination(scene, write_frames, tmp_path, monkeypatch):
    files = write_frames([scene])
    output = tmp_path / "output.tif"
    output.write_bytes(b"existing")
    def fail(*args):
        raise FocusStackError("Injected validation failure")
    monkeypatch.setattr(io, "validate_output", fail)
    with pytest.raises(FocusStackError, match="validation failure"):
        stack(files, output, config(tmp_path))
    assert output.read_bytes() == b"existing"
    assert not list(tmp_path.glob(".output.tif.*.tmp"))


def test_keep_temp(scene, write_frames, tmp_path):
    result = stack(write_frames([scene], compression="zlib", rowsperstrip=16), tmp_path / "output.tif",
                   config(tmp_path, keep_temp=True))
    assert result.scratch_path.is_dir()
    assert (result.scratch_path / "source-00000.raw").exists()
    assert (result.scratch_path / "output.raw").exists()


def test_resource_and_decode_limits(scene, write_frames, tmp_path, monkeypatch):
    import focusstack.memory as memory
    files = write_frames([scene], compression="zlib", rowsperstrip=16)
    monkeypatch.setattr(memory.shutil, "disk_usage", lambda _: type("Disk", (), {"free": 1})())
    with pytest.raises(FocusStackError, match="Insufficient disk"):
        stack(files, tmp_path / "result.tif", config(tmp_path))
    info = io.inspect_image(files[0])
    with pytest.raises(FocusStackError, match="segment exceeds"):
        io.Source(info, tmp_path, 0, decoder_budget=1)


def test_resource_ram_limit(scene, write_frames, tmp_path, monkeypatch):
    import focusstack.memory as memory
    files = write_frames([scene])
    monkeypatch.setattr(memory.psutil, "virtual_memory", lambda: type("RAM", (), {"available": 1, "total": 1})())
    with pytest.raises(FocusStackError, match="working RAM"):
        stack(files, tmp_path / "result.tif", config(tmp_path))


def test_transform_and_config_validation(tmp_path):
    with pytest.raises(FocusStackError, match="scale"):
        validate_transform(np.array([[2, 0, 0], [0, 2, 0]], float), (100, 100))
    with pytest.raises(FocusStackError, match="overlap"):
        validate_transform(np.array([[1, 0, 90], [0, 1, 0]], float), (100, 100))
    with pytest.raises(FocusStackError, match="overlap"):
        config(tmp_path, tile_overlap=1).validate()
    with pytest.raises(FocusStackError, match="No .tif"):
        stack([tmp_path], tmp_path / "result.tif", config(tmp_path))


def test_cli_smoke(scene, planes, write_frames, tmp_path):
    paths = write_frames(planes, compression="zlib", rowsperstrip=16)
    output = tmp_path / "cli.tif"
    call = subprocess.run([sys.executable, "-m", "focusstack", *map(str, paths), "-o", str(output),
                           "--alignment", "none", "--tile-size", "64", "--temp-dir", str(tmp_path / "scratch")],
                          capture_output=True, text=True)
    assert call.returncode == 0, call.stderr
    assert "Validate output" in call.stderr and "peak RSS" in call.stderr
    image = tifffile.imread(output)
    assert image.dtype == np.uint16 and image.shape == scene.shape
    version = subprocess.run(["focusstack", "--version"], capture_output=True, text=True)
    assert version.returncode == 0 and "0.2.0" in version.stdout


@pytest.mark.parametrize("compression", [None, "zlib"])
def test_big_endian_pixels_and_analysis(scene, write_frames, tmp_path, compression):
    files = write_frames([scene], byteorder=">", compression=compression, rowsperstrip=16)
    info = io.inspect_image(files[0])
    scratch = tmp_path / "cache"
    scratch.mkdir()
    source = io.Source(info, scratch, 0)
    try:
        small = source.reduced_gray(4096)
        expected = cv2.cvtColor((scene >> 8).astype(np.uint8), cv2.COLOR_RGB2GRAY)
        assert np.array_equal(small, expected)
    finally:
        source.close()
    result = stack(files, tmp_path / "result.tif", config(tmp_path))
    assert np.array_equal(tifffile.imread(result.output), scene)


@pytest.mark.parametrize("compression", ["none", "lzw", "zstd"])
def test_output_compression(scene, write_frames, tmp_path, compression):
    result = stack(write_frames([scene]), tmp_path / "result.tif", config(tmp_path, compression=compression))
    assert np.array_equal(tifffile.imread(result.output), scene)


def test_alignment_failure_and_cache_cleanup(write_frames, tmp_path):
    blank = np.full((80, 96, 3), 30000, np.uint16)
    paths = write_frames([blank, blank], compression="zlib", rowsperstrip=16)
    with pytest.raises(FocusStackError, match="alignment failed"):
        stack(paths, tmp_path / "result.tif", config(tmp_path, alignment="affine"))
    assert not list((tmp_path / "scratch").iterdir())


def test_decoded_cache_failure_cleanup(scene, write_frames, tmp_path, monkeypatch):
    files = write_frames([scene], compression="zlib", rowsperstrip=16)
    def fail(*args, **kwargs):
        raise ValueError("Injected decode error")
    monkeypatch.setattr(tifffile.TiffPage, "segments", fail)
    with pytest.raises(FocusStackError, match="prepare/cache"):
        stack(files, tmp_path / "result.tif", config(tmp_path))
    assert not list((tmp_path / "scratch").iterdir())


def test_invalid_reference_and_input_overwrite(scene, write_frames, tmp_path):
    files = write_frames([scene])
    with pytest.raises(FocusStackError, match="Reference index"):
        stack(files, tmp_path / "result.tif", config(tmp_path, reference=2))
    with pytest.raises(FocusStackError, match="differ"):
        stack(files, files[0], config(tmp_path))


def test_source_index_above_255(scene, tmp_path):
    from focusstack.fusion import fuse_tile
    blurry = cv2.GaussianBlur(scene[:32, :32], (17, 17), 3)
    sharp = scene[:32, :32]
    class SyntheticSource:
        def __init__(self, rgb):
            self.rgb = rgb
        def warp_tile(self, transform, bounds):
            return self.rgb.copy(), np.ones((32, 32), bool)
    sources = [SyntheticSource(blurry)]*256 + [SyntheticSource(sharp)]
    transforms = [np.eye(2, 3)]*257
    image = fuse_tile(sources, transforms, (0, 32, 0, 32), config(tmp_path), 256)
    assert np.array_equal(image[6:-6, 6:-6], sharp[6:-6, 6:-6])


def test_affine_estimate_deterministic(scene):
    gray = cv2.cvtColor((scene >> 8).astype(np.uint8), cv2.COLOR_RGB2GRAY)
    matrix = cv2.getRotationMatrix2D((160, 128), -2.5, 0.97)
    moved = cv2.warpAffine(gray, matrix, gray.shape[::-1], borderMode=cv2.BORDER_REFLECT_101)
    a, _, _ = estimate(gray, moved, "affine")
    b, _, _ = estimate(gray, moved, "affine")
    assert np.array_equal(a, b)


def test_profile_mismatch_rejected(scene, write_frames, tmp_path):
    a = write_frames([scene], iccprofile=b"profile-A")[0]
    b = tmp_path / "different.tif"
    tifffile.imwrite(b, scene, photometric="rgb", iccprofile=b"profile-B")
    with pytest.raises(FocusStackError, match="ICC profile mismatch"):
        stack([a, b], tmp_path / "result.tif", config(tmp_path))


def test_reduced_analysis_uses_fixed_blocks(tmp_path):
    # Monitor source reads; dimensions larger than the analysis ceiling must
    # never turn into full-width or full-height working image copies.
    class CheckedArray:
        shape = (1100, 1700, 3)
        def __getitem__(self, slices):
            height = slices[0].stop - slices[0].start
            width = slices[1].stop - slices[1].start
            assert height <= 512 and width <= 512
            return np.full((height, width, 3), 32768, np.uint16)
    source = object.__new__(io.Source)
    source.array = CheckedArray()
    source.info = type("Info", (), {"dtype": np.dtype("uint16"), "path": "synthetic"})()
    source.release_pages = lambda: None
    image = source.reduced_gray(256)
    assert image.shape == (166, 256) and image.dtype == np.uint8
    assert np.all(image == 128)
