# Focus coverage foundation

Selecting the sharpest frame does not establish adequate focus. V3 adds an independent absolute focus-evidence channel to the bounded product tile.

The initial implementation uses the existing maximum noise-adjusted photographic focus score, normalized by65535². `coverage_confidence = energy / (energy + 0.00002)`. The threshold is an explicitly uncalibrated engineering scale in encoded source luminance. No ICC transfer curve is assumed or applied. This is an evidence index, not an objectively calibrated probability of photographic focus.

Summary coverage counts pixels with quantized evidence≥128/255; low-evidence review counts use<51/255. The map and QA findings expose low evidence separately from relative winner confidence. Tests compare sharp texture with uniformly weak evidence even when candidate separation is identical. Actual100MP summaries are in V3_RESULTS.md.

Low texture, intentional smooth surfaces, noise and blur can be indistinguishable. The current index cannot conclusively prove a skipped focus step or that no adequate source exists. Accordingly the UI says insufficient source information/low evidence and marks the index uncalibrated. It does not state "No adequately focused source exists" as an established fact from this heuristic alone. A future calibrated source-coverage detector with reliable optical/test labels may authorize that stronger statement.

Registration uncertainty stays separate and generates review findings when measured confidence is low; supplied transforms remain unmeasured. Misalignment/parallax can still contaminate evidence. No missing detail is generated, and coverage analysis never changes photographic RGB. Review counts are capped retained proposals, not a guaranteed exhaustive component count.
