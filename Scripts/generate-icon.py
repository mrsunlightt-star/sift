#!/usr/bin/env python3
"""Builds the Sift app icon from the owner's drawing.

`Resources/IconSource/app-icon.png` is the master: the gold star on the brand
green, drawn by the owner of this repository. It is a full-bleed square, so this
script only applies the geometry macOS expects — a rounded square inset on a
1024 canvas — and then re-samples that single master into every size the asset
catalog and the `.icns` need. Nothing is redrawn here: changing the picture means
replacing the master, not editing this file.

Outputs:
  Resources/Assets.xcassets/AppIcon.appiconset/*.png   (Xcode asset catalog)
  Resources/AppIcon.icns                              (SwiftPM bundle + DMG)
"""

from __future__ import annotations

import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_PATH = REPO_ROOT / "Resources" / "IconSource" / "app-icon.png"
ASSET_DIR = REPO_ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICNS_PATH = REPO_ROOT / "Resources" / "AppIcon.icns"

CANVAS = 1024
# macOS draws an app icon inside a rounded square with roughly a 22% margin on a
# 1024 canvas, so the artwork keeps that proportion. The source is square and
# full-bleed, which is what makes the margin this script's job rather than the
# drawing's.
INSET = 100
CORNER = 230


def render(size: int) -> Image.Image:
    """Returns one icon at `size` pixels, scaled from the master."""
    scale = size / CANVAS

    # The master is 500 px, so the largest slot always needs upsampling: Lanczos
    # keeps the star's straight edges straight, and the hatching inside it is the
    # reason nearest or bilinear would look wrong. Converted to RGBA first,
    # because `paste` with a mask needs an alpha channel to weigh against.
    master = Image.open(SOURCE_PATH).convert("RGBA")

    inset = int(round(INSET * scale))
    tile = size - inset * 2
    art = master.resize((tile, tile), Image.LANCZOS)

    # The radius is a canvas measurement, like the inset: the tile is always the
    # same picture at a different scale, so the corners of a 16 pt icon and a
    # 1024 pt one describe the same curve.
    mask = Image.new("L", (tile, tile), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (tile - 1, tile - 1)],
        radius=CORNER * scale,
        fill=255,
    )

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(art, (inset, inset), mask)
    return canvas


def main() -> int:
    if not SOURCE_PATH.exists():
        print(f"missing master: {SOURCE_PATH.relative_to(REPO_ROOT)}")
        return 1

    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)

    # The asset catalog asks for one file per slot; Retina slots reuse the same
    # pixel size as their point size.
    slots = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    cache: dict[int, Image.Image] = {}
    for name, pixels in slots:
        if pixels not in cache:
            cache[pixels] = render(pixels)
        cache[pixels].save(ASSET_DIR / name)

    # `iconutil` wants an `.iconset` directory and produces the `.icns`.
    with tempfile.TemporaryDirectory() as temporary:
        iconset = pathlib.Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for name, pixels in slots:
            cache[pixels].save(iconset / name)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS_PATH)],
            check=True,
        )

    print(f"wrote {len(slots)} icon sizes to {ASSET_DIR.relative_to(REPO_ROOT)}")
    print(f"wrote {ICNS_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
