"""Deliberate whitelist: TIFF structural tags are never copied."""


def read_metadata(page):
    tags = page.tags
    result = {"extratags": [(274, "H", 1, 1, False)]}  # pixels normalized to top-left
    if "InterColorProfile" in tags:
        profile = bytes(tags["InterColorProfile"].value)
        result["iccprofile"] = profile
    if "XResolution" in tags and "YResolution" in tags:
        def rational(name):
            value = tags[name].value
            return value[0] / value[1] if isinstance(value, tuple) else float(value)
        result["resolution"] = (rational("XResolution"), rational("YResolution"))
        result["resolutionunit"] = int(tags["ResolutionUnit"].value) if "ResolutionUnit" in tags else 1
    for name, code in [("Artist", 315), ("Copyright", 33432), ("DocumentName", 269), ("DateTime", 306)]:
        if name in tags:
            result["extratags"].append((code, "s", 0, str(tags[name].value), False))
    if "ImageDescription" in tags:
        description = str(tags["ImageDescription"].value)
        # Do not propagate tifffile shape JSON, OME XML or other structural descriptions.
        if description and not description.lstrip().startswith(("{", "<")):
            result["description"] = description
    return result
