#!/usr/bin/env python3
"""Draws the Sift app icon.

The mark matches the design mockups: a white four-point sparkle on the brand
blue, on a rounded square. Everything is drawn with plain geometry so the icon
is reproducible from source rather than a binary nobody can edit.

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
ASSET_DIR = REPO_ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICNS_PATH = REPO_ROOT / "Resources" / "AppIcon.icns"

CANVAS = 1024
# macOS draws an app icon inside a rounded square with roughly a 22% margin on a
# 1024 canvas, so the artwork keeps that proportion.
INSET = 100
CORNER = 230

TOP_COLOR = (56, 118, 255)
BOTTOM_COLOR = (24, 74, 214)


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def gradient(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / max(size - 1, 1)
        color = (
            lerp(TOP_COLOR[0], BOTTOM_COLOR[0], t),
            lerp(TOP_COLOR[1], BOTTOM_COLOR[1], t),
            lerp(TOP_COLOR[2], BOTTOM_COLOR[2], t),
            255,
        )
        draw.line([(0, y), (size, y)], fill=color)
    return image


def sparkle(draw: ImageDraw.ImageDraw, cx: float, cy: float, radius: float, waist: float, fill) -> None:
    """Draws a four-point star.

    `radius` is the tip distance from the centre and `waist` the half-width of the
    concave curve between two tips. A small waist gives the sharp sparkle the
    mockups use.
    """
    points = []
    for index in range(8):
        angle = index * 45.0
        distance = radius if index % 2 == 0 else waist
        from math import cos, radians, sin

        points.append(
            (
                cx + distance * cos(radians(angle - 90)),
                cy + distance * sin(radians(angle - 90)),
            )
        )
    # Smooth the concave part with quadratic curves through the waist points.
    draw.polygon(points, fill=fill)


def render(size: int) -> Image.Image:
    scale = size / CANVAS
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Rounded-square background.
    background = gradient(size)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(INSET * scale), (INSET * scale), (size - INSET * scale), (size - INSET * scale)],
        radius=CORNER * scale,
        fill=255,
    )
    canvas.paste(background, (0, 0), mask)

    draw = ImageDraw.Draw(canvas)
    white = (255, 255, 255, 255)

    # The large sparkle, slightly above and left of centre, with two small ones
    # for the "sifting" motion.
    sparkle(draw, 500 * scale, 430 * scale, 250 * scale, 58 * scale, white)
    sparkle(draw, 690 * scale, 665 * scale, 105 * scale, 26 * scale, white)
    sparkle(draw, 330 * scale, 690 * scale, 62 * scale, 16 * scale, white)

    return canvas


def main() -> int:
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
