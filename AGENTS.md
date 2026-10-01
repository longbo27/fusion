# FocusStack engineering rules

- Never load the whole image stack into memory.
- Never replace tiled processing with full-frame float arrays.
- Never silently convert 16-bit output to 8-bit.
- Never commit TIFF test/output files or generated caches/benchmark outputs.
- Preserve ICC and metadata where safely possible.
- Favor bounded memory over small speed improvements.
- Avoid Python pixel loops. Use float32, not float64, unless required.
- Measure memory after performance changes. Run tests before finishing.
- Keep algorithms independent of UI/platform code.
- Future macOS optimization will use native Apple technologies; do not add them to Linux V1.
