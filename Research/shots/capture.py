#!/usr/bin/env python3
"""Capture the Sift window to Research/shots/<name>.png.

Screenshots are evidence for the UX review: they must show the shipping build,
at its real window size, with the app in the requested state. The helper reads
the window bounds from the accessibility tree (points), captures the screen at
its native pixel size, and crops by the 2x backing scale so the output is an
exact 1:1 copy of the window.
"""
import os
import subprocess
import sys
import time

from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)))


def bounds():
    script = """
tell application "System Events" to tell process "Sift"
  set frontmost to true
  perform action "AXRaise" of window 1
  delay 0.5
  set p to position of window 1
  set s to size of window 1
  return {item 1 of p, item 2 of p, item 1 of s, item 2 of s}
end tell
"""
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"could not read window bounds: {out.stderr.strip()}")
    x, y, w, h = [int(float(v.strip())) for v in out.stdout.strip().split(", ")]
    return x, y, w, h


def capture(name):
    x, y, w, h = bounds()
    time.sleep(0.35)
    full = "/tmp/sift-full.png"
    subprocess.run(["screencapture", "-x", "-o", full], check=True)
    im = Image.open(full)
    scale = 2  # this display is 3840x2160 over 1920x1080 points
    box = (x * scale, y * scale, (x + w) * scale, (y + h) * scale)
    box = (
        max(0, box[0]),
        max(0, box[1]),
        min(im.size[0], box[2]),
        min(im.size[1], box[3]),
    )
    im.crop(box).save(os.path.join(OUT, f"{name}.png"))
    print(f"{name}.png  window={w}x{h}pt  px={box[2]-box[0]}x{box[3]-box[1]}")


if __name__ == "__main__":
    capture(sys.argv[1] if len(sys.argv) > 1 else "shot")
