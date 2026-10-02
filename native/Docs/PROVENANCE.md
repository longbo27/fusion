# Source-faithful provenance

Captured source pixels may undergo registration resampling, mathematical multiband blending and explicit final quantization. These are real-source operations, not generative AI. A winning focus label does not prove a blended output pixel has one source.

`ProductEvidenceTile` is four UInt32 words per core pixel (16 raw bytes), only one tile resident:

| Word | Fields |
|---|---|
| x | UInt16 primary owner/guide; UInt16 secondary **candidate** |
| y | UInt16 best-focus candidate; UInt8 decision mode; UInt8 manual/availability flags |
| z | UInt8 focus separation, motion probability, registration confidence, absolute coverage evidence |
| w | UInt8 motion uncertainty, UInt16 third candidate, UInt8 QA evidence flags; ownership ambiguity derives from retained focus separation |

All supported Apple platforms are little-endian. Per-block schema/version/geometry and content hashes reject incompatible or corrupt payloads. LZFSE compresses each block independently; incompressible blocks store raw bytes. Random lookup decodes one bounded block. No100MP array of Swift provenance objects is allocated.

Decision modes are hard ownership, multiband blend, reference fallback, AI deghost ownership and manual override. The final projection and actual reconstruction denominator determine the mode. Manual hard source choices have precedence only when a valid registered captured pixel exists. Missing registered pixels reject editing rather than silently pretending the selected source was used. Quantized values carry up to1/255 resolution; unavailable motion/registration remain nil, not zero certainty.

For the multiband path, primary is an ownership guide, secondary is a focus candidate, and exhaustive contributor sets/scalar percentages are **not retained**. Neighbors/coarse pyramid levels may contribute other sources. The inspector explicitly says weights/contributors are unavailable. It never displays a fabricated94.2% source contribution. A multiband-capable path can include only one source locally; blend-area counts describe processing path, not a proven count of distinct contributors. Future level-aware sparse contributor accounting can refine this without changing the schema interpretation.

Hard ownership reports100% captured-source ownership after registration sampling. This does not claim the RGB tuple equals one unresampled camera pixel. Reference fallback and AI ownership are separately counted. Manual and low-confidence counts are overlapping annotations, not additional disjoint pixel classes. The disjoint hard/blend/fallback/AI counts sum to the image pixel count. `SourceFaithfulReport` records explicit mode and zero generative photographic pixels for this implementation; export requires a completed project.

Uncertainty retains focus ambiguity, motion uncertainty (1−|2p−1| when evaluated), registration uncertainty, ownership ambiguity and insufficient coverage separately. Focus/ownership ambiguity share current separation evidence and are correlated. Combined review risk is a conservative maximum, not a calibrated defect probability. CONFIDENT/AMBIGUOUS/INSUFFICIENT SOURCE INFORMATION/REVIEW RECOMMENDED are review labels, not certainty guarantees.

Storage/runtime overhead and the unchanged photographic parity limitation are reported in V3_RESULTS.md. Debug8-bit overlays do not alter RGB16 photographic output.

Source-Faithful mode constrains this engine's operations. It does not authenticate that every input was captured by a camera or that a supplied original contains no prior edits. Zero generative photographic pixels refers to processing performed by this engine, not a forensic assertion about input history.
