# V3 product architecture

The unchanged Python V1.1 remains the golden reference. Annotated `native-v2.2` freezes `caa8c698f86d568a29bf1246ed3777c3487b5e60`; product work continues on `native-v3`. V2 measurements and photographic quality limits remain applicable.

The local Swift package now exposes four products:

- `FocusStackCore`: compatibility engine, bounded TIFF tiles, registration, focus, Metal/ML/Vision and existing fusion. Existing `NativeStackEngine.run` callers retain their API; `runProduct` adds optional evidence/constraints.
- `FusionCore`: source-faithful contract, provenance, source abstractions, uncertainty, coverage interpretation, quality findings and dependency-halo planning.
- `FusionAI`: model provenance and feature status registry. Motion is the existing model; artifact/coverage AI are extension boundaries, not shipped trained detectors.
- `FusionProject`: actor-owned project persistence, compressed maps, source identity/relink, processing history, audit and product workflow. It depends on the core, not the host.

Low-level product capture stays next to existing Metal buffers to avoid a circular package dependency or destructive engine rename. Registration/Focus/Motion/Ownership/Color/Export are logical boundaries inside the compatibility engine today, not falsely advertised as completely migrated frameworks. AppleHost/macOS consists of AppState and SwiftUI/AppKit file picking/display; the shared products import no AppKit/UIKit/SwiftUI. iPadOS/iOS retain smaller tiles/one-flight budgets. A visionOS target and mobile editor are not implemented.

The optional product path adds spatially bounded evidence/manual resources, one tile at a time. Tile admission includes the extra40 bytes per expanded pixel. No source-count-sized RGB, mask, pyramid or queue is introduced. The collector compresses a core block, updates integer counts and retains at most512 review findings. Source records and tile indexes are compact metadata; the package does not duplicate originals.

Source-Faithful mode is explicit in the manifest/export. Generative photographic processing is unavailable. AI scores/masks/ownership never supply RGB. Static automatic V2.2 fusion remains intact; manual hard overrides select valid registered captured pixels, and missing registered source pixels reject the edit. Excluding a source invalidates its local focus evidence; excluding the reference prevents the AI reference projection. The original temporal statistics still include excluded inputs; future model-aware exclusion features are a documented extension.

Manual edits rasterize sparse ordered rectangular constraints over existing tiles plus dependency halo. Use Auto/Best/Reference/Source/Exclude/Lock/Clear are available in the first macOS workspace. Rectangles are a minimal host tool; a pressure-aware brush/Pencil path can generate bounded constraint spans later. Replacement pixels are recomputed from sources and stored as optional tile cache; originals and the initial output are preserved. Clearing uses an ordered Auto layer, preserving logical history. Export merges the base TIFF with current replacements in bounded tiles and performs a full encode/validation. Local recomputation does not imply local TIFF encoding.

Processing history stores parameters, hashes, sparse constraints and invalidated regions rather than full-frame images per node. The workflow rejects overlapping operations in one session. Manifest optimistic checks and audit locking detect conflicting writers; cross-process transactional collaboration, crash recovery and cache compaction are not finished.

The first workspace has Sources / bounded ROI viewer / Inspector, STACK/REVIEW/EDIT/EXPORT modes, maps, review actions and source split/blink/scrubbing. Viewing is an explicitly reduced8-bit display operation using source ICC when present; photographic TIFF remains RGB16. QA proposals are heuristic, not confirmed defects. Source comparison uses the stored registration transform. Whole-image zoom/pan and advanced brush ergonomics remain future host work.

HDR, noise/burst/astro stacking, panorama, super resolution and video fusion remain extension points. Six capture/refocusing features are explicitly `IP_REVIEW_REQUIRED`; no production implementation is exposed. Generic FrameSource admits still, sequence and video identity/timestamps; only TIFF pixel decoding is implemented here. RAW processing remains future work.

See [provenance](PROVENANCE.md), [project format](FUSIONPROJECT_FORMAT.md), [coverage](FOCUS_COVERAGE.md), [sentinel](ARTIFACT_SENTINEL.md), [IP process](IP_ENGINEERING_HYGIENE.md) and [measured results](V3_RESULTS.md).

Source exclusion is an exact final-pixel constraint: focus ranking removes the excluded source, and the edited region projects to the best remaining valid captured source. This prevents coarse multiband levels leaking the excluded source back into the region. If no valid remaining source exists, the edit rejects.

Local edits reuse the workflow’s editor pipeline/model and merge per-block provenance/coverage counters. Untouched maps do not require a100MP scan after a brush edit. Starting a new full render releases the cached editor resources.
