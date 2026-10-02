# `.fusionproject` package — format1

The package references originals and stores metadata/auxiliary maps. It does not copy the20×100MP source images by default.

```
manifest.json
sources/                  reserved source-reference/host-bookmark boundary
processing/               reserved external graph parameter records
maps/provenance/*.fsp      immutable compressed bounded blocks
manual/                   reserved sparse-layer externalization
qa/                       reserved finding externalization
history/audit.jsonl        append-only logical events
cache/replacements/*.rgba16 optional recomputed RGB16 core tiles
```

Format1 manifest contains source references, metadata fingerprints, SHA-256, exact size, modification timestamp, optional frame ID/timestamp/kind, engine/model/architecture versions, creation/modification dates, transforms, settings, explicit source-faithful state, block indexes, sparse ordered overrides, QA findings, processing nodes and output hashes. Empty subdirectories establish module boundaries; overrides/findings/nodes are presently inline bounded metadata, not falsely described as implemented independent databases.

Source URLs/filenames belong to the private local project, not the public companion audit. Future Apple hosts can add security-scoped bookmarks and photo-library identifiers; sandboxed mobile access/relink authorization is not physically validated. TIFF is the only implemented source decoder; generic still/sequence/video identities do not imply RAW/video support.

Source relink requires exact SHA-256/size/metadata identity and retains stable source ID. Missing sources remain readable project metadata, with explicit unavailable status; new rendering requires available sources. Import hashes and post-render identity verification stream1MiB reads. Edits use recorded size/high-resolution modification time for fast admission; explicit availability checks and relink perform full hashes. Matching size/time is a fast filesystem check, not cryptographic proof against adversarial timestamp manipulation. Baseline output and replacement hashes are checked during export.

Blocks have magic FSP3, UInt32 schema1, width, height, raw length and compression marker, followed by LZFSE or raw payload. Index records include SHA-256, geometry and lengths. Decoding is limited to1024² pixels; unsafe paths, symlink payloads, corrupt extents/hashes and symlink package components are rejected. Metadata max8MiB, audit max32MiB, history max10000 nodes, retained QA max512. These limits reject excessive projects instead of unbounded allocations.

Migration0→1 represents the documented pre-release schema with Source-Faithful mode added. Unknown same-version fields are recursively preserved, including stable-ID records. Future format versions reject opening for mutation and remain untouched. The first migration test does not imply support for arbitrary unpublished historical schemas.

Atomic manifest replacement and optimistic content-hash checks protect normal single-writer saves. Audit appends have an OS file lock and synchronized writes. Audit/manifest are not one cross-file transaction: interrupted saves may leave a head mismatch that is rejected; automatic crash-journal recovery and cross-process collaborative editing remain future work. Immutable map/replacement files can be orphaned after failed edits, and repeated edits grow optional cache/history; garbage collection/compaction is deferred.

Audit records have sequence, date, operation, previous-record SHA-256 and canonical sorted-key payload. This detects chain inconsistency, not authorship or authenticity: no signing is provided. Decisions/settings are recorded; universal cross-hardware bitwise reproducibility is not promised. Exported `image.fusion.json` omits source filenames/URLs and includes IDs, hashes, settings, transforms, model governance, source-faithful counts, coverage and output SHA-256.

Current local editing recomputes dependent core tiles with halo, preserving source masters and the base output. Final TIFF export traverses the output in bounded tiles, merges validated replacement cache and re-encodes/fully validates RGB16+ICC. Per-block summary counters update aggregates without decoding untouched maps; no untouched photographic tile is fused again.

Source exclusion is an exact final-pixel constraint: focus ranking removes the excluded source, and the edited region projects to the best remaining valid captured source. This prevents coarse multiband levels leaking the excluded source back into the region. If no valid remaining source exists, the edit rejects.

Local edits reuse the workflow’s editor pipeline/model and merge per-block provenance/coverage counters. Untouched maps do not require a100MP scan after a brush edit. Starting a new full render releases the cached editor resources.

Each block index retains bounded summary counters. Completed project opens validate disjoint counts and coverage extents against block/image geometry before aggregates are used. These are consistency checks, not signed authenticity evidence.
