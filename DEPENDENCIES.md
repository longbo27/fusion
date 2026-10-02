# Dependency inventory — 2026-10-02

No dependency was added or upgraded for V3. Product modules use the installed Apple SDK, Swift standard library and Foundation/Compression/CryptoKit. No payment/subscription SDK is included. License labels below identify recorded terms, not a commercial clearance conclusion.

| Component | Observed version | Upstream | Recorded license | Purpose / distribution boundary |
|---|---|---|---|---|
| LibTIFF | 4.7.2 | [official release](https://libtiff.gitlab.io/libtiff/releases/v4.7.2.html) | libtiff / Leffler-SGI terms, plus Berkeley-derived LZW notice | Vendored native strip/tile/BigTIFF decoding and export |
| zlib | Apple SDK/system libz; compile version recorded by SBOM | [zlib](https://zlib.net/zlib_license.html) | zlib | Platform-linked Deflate; no new vendored binary |
| Swift / Apple frameworks | Swift6.4, SDK27.0 / Xcode27.0 in local validation | [Apple developer](https://developer.apple.com/documentation/) | Apple SDK/platform agreements; Swift [Apache-2.0 with runtime exception](https://www.swift.org/LICENSE.txt) | Native platform runtime; not a license grant from this document |
| NumPy | reference2.5.3; training2.2.6 | [upstream license](https://numpy.org/doc/stable/license) | Installed reference metadata: BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0; retain exact wheel notices | Python reference / developer fixtures only |
| opencv-python-headless | 4.14.0.94 | [OpenCV Python](https://github.com/opencv/opencv-python) | Apache-2.0; bundled third-party notices separately | Python reference, not native app |
| tifffile | 2026.9.20 | [upstream](https://github.com/cgohlke/tifffile) | BSD-3-Clause | Python reference fixtures |
| imagecodecs | 2026.8.16 | [upstream](https://github.com/cgohlke/imagecodecs) | BSD-3-Clause wrapper; individual codec licenses in installed `imagecodecs/licenses` | Python reference only; wrapper license does not cover every codec |
| psutil | 7.2.2 | [upstream](https://github.com/giampaolo/psutil) | BSD-3-Clause | Reference memory diagnostics |
| tqdm | 4.70.1 | [upstream](https://github.com/tqdm/tqdm) | MPL-2.0 AND MIT in installed metadata | Reference progress |
| pytest | 9.1.1 | [upstream](https://github.com/pytest-dev/pytest) | MIT | Developer tests only |
| setuptools | 84.0.0 | [upstream](https://github.com/pypa/setuptools) | MIT; its vendored tools retain separate notices | Python packaging only |
| PyTorch | training2.7.1 | [upstream](https://github.com/pytorch/pytorch) | BSD-style with bundled component notices | Existing isolated training venv, never native runtime |
| coremltools | training9.0 | [upstream](https://github.com/apple/coremltools) | BSD-3-Clause / exact package notices | Developer model conversion |
| SciPy | training1.18.1 | [upstream](https://github.com/scipy/scipy) | BSD-3-Clause plus wheel notices | Developer synthetic fixtures |

`native/FocusStackCore/Vendor/libtiff/PROVENANCE.json` records upstream tarball SHA-256 `672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a`. Configured native codecs: uncompressed, LZW, Deflate and PackBits; JPEG/JBIG/LZMA/Zstd/WebP/LERC/libdeflate disabled. See the exact [vendored notice](native/FocusStackCore/Vendor/libtiff/LICENSE.md), reproduced in THIRD_PARTY_NOTICES.md and included in the macOS app resource. Inspect the actual compiled vendored source and exact distribution artifact before extending codecs or redistribution scope.

Generate an inventory (CycloneDX1.6 JSON, developer assist, not an exhaustive transitive compliance audit) outside Git:

```sh
.venv/bin/python native/Developer/generate_sbom.py --output /tmp/focusstack-reference-sbom.json
# Run the same script with the isolated training venv to record that environment.
```

The script records installed package metadata/license labels, vendored provenance/source-tree hash and current SDK compiler information. System framework versions and binary-embedded third-party notices require artifact-level release review. No FTO or redistribution clearance follows from an SBOM.

Training versions above are recorded V2.2 development-environment versions. V3 did not recreate that isolated environment, train a model or add its packages to the native runtime.
