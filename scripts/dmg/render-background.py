#!/usr/bin/env python3
"""The DMG window background: Cove's light canvas, a title, a trail of dots that grows from the Cove icon
to the Applications folder in the tide colors, and a faint tide along the bottom. Finder shows a still
image, so the trail implies the motion. Writes a 1x + 2x TIFF for Retina.

Usage: python3 scripts/dmg/render-background.py OUT.tiff
Layout (points, shared with scripts/dmg/settings.py): window 660x420, Cove icon at (170, 210),
Applications at (490, 210), 128-point icons.
"""
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONT = os.path.join(ROOT, "Sources/Cove/Resources/Inter.ttf")
MARK = os.path.join(ROOT, "scripts/video/cove-mark.png")
W, H = 660, 420
APP, APPS = (170, 210), (490, 210)
CANVAS = (248, 249, 250)
INK = (36, 38, 44)
BODY = (96, 101, 110)
TIDE = [(120, 217, 201), (138, 186, 240), (186, 161, 237), (230, 168, 201), (242, 189, 140)]


def tide(x):
    x = min(0.999, max(0.0, x)) * (len(TIDE) - 1)
    i, f = int(x), x - int(x)
    return tuple(int(TIDE[i][k] + (TIDE[i + 1][k] - TIDE[i][k]) * f) for k in range(3))


def font(size, scale, weight):
    f = ImageFont.truetype(FONT, int(size * scale))
    f.set_variation_by_name(weight)
    return f


def render(scale):
    S = scale * 2  # draw at twice the target, then reduce, for smooth dots and text
    image = Image.new("RGBA", (W * S, H * S), CANVAS + (255,))
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def dot(x, y, r, color, alpha):
        draw.ellipse(((x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S), fill=color + (int(255 * alpha),))

    draw.text((W / 2 * S, 58 * S), "Drag Cove into Applications", font=font(22, S, "Medium"), fill=INK + (255,), anchor="mm")
    draw.text((W / 2 * S, 86 * S), "Then open it from your Applications folder.", font=font(13, S, "Regular"),
              fill=BODY + (255,), anchor="mm")

    # The trail: from just right of the Cove icon to just left of Applications, a gentle arc of dots that
    # grow and brighten toward the folder, ending in a chevron, like the app being carried across.
    start, end = APP[0] + 78, APPS[0] - 82
    steps = 15
    for i in range(steps):
        p = i / (steps - 1)
        x = start + (end - start) * p
        y = APP[1] - 6 - math.sin(p * math.pi) * 16
        dot(x, y, 1.6 + 2.4 * p ** 1.2, tide(p), 0.35 + 0.6 * p)
    tip_x, tip_y = end + 10, APP[1] - 6
    for k in range(1, 4):
        for sign in (-1, 1):
            dot(tip_x - k * 6.2, tip_y + sign * k * 6.2, 3.2 - k * 0.35, tide(1), 0.95 - k * 0.12)
    dot(tip_x, tip_y, 3.6, tide(1), 1)

    # A faint tide along the bottom (the Home chart's point cloud), behind everything.
    counts = [3, 5, 4, 6, 5, 7, 6, 8, 7, 6, 7, 5]
    columns, layers = 110, 7
    for layer_index in range(layers):
        depth = layer_index / (layers - 1)
        for c in range(columns):
            x = c / (columns - 1)
            pos = min(len(counts) - 1.0, max(0.0, x * len(counts) - 0.5))
            i = int(pos)
            n = min(len(counts) - 1, i + 1)
            f = pos - i
            f = f * f * (3 - 2 * f)
            volume = (counts[i] * (1 - f) + counts[n] * f) / max(counts)
            ridge = 60 * (0.82 - volume * 0.63)
            yy = ridge + depth * (60 * 0.9 - ridge) * 0.64 + math.sin(x * math.pi * 5 + depth * 2.4) * 1.2
            dot(20 + x * (W - 40), H - 78 + yy, 0.9 if layer_index == 0 else 0.75, tide(x),
                (0.55 if layer_index == 0 else 0.35 * (1 - depth) ** 1.3))

    # The small wave mark and wordmark, bottom left, like the site footer.
    mark = Image.open(MARK).convert("RGBA").resize((14 * S, 14 * S), Image.LANCZOS)
    tinted = Image.new("RGBA", mark.size, INK + (0,))
    tinted.putalpha(mark.getchannel("A").point(lambda v: int(v * 0.8)))
    layer.alpha_composite(tinted, (22 * S, (H - 30) * S))
    draw.text((40 * S, (H - 23) * S), "cove", font=font(14, S, "Medium"), fill=INK + (205,), anchor="lm")

    image.alpha_composite(layer)
    return image.convert("RGB").resize((W * scale, H * scale), Image.LANCZOS)


def main(out):
    with tempfile.TemporaryDirectory() as tmp:
        one, two = os.path.join(tmp, "background.png"), os.path.join(tmp, "background@2x.png")
        render(1).save(one, dpi=(72, 72))
        render(2).save(two, dpi=(144, 144))
        # One TIFF with both resolutions, so Finder picks the sharp one on Retina displays.
        subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", out], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if len(sys.argv) > 2:
            render(2).save(sys.argv[2])


if __name__ == "__main__":
    main(sys.argv[1])
