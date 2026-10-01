#!/usr/bin/env python3
"""Cove brand film: a calm 48-second motion piece in four 12-second movements, made only from Cove's own
elements (the dark card, Inter, the dot tide, the dot portrait, the wave mark). Renders one continuous
film, then cuts it into four clips at exact keyframes, so the four play back-to-back as the full film.

Usage: python3 scripts/video/render-brand-film.py LOGO_PNG OUT_DIR
"""
import math
import os
import subprocess
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONT = os.path.join(ROOT, "Sources/Cove/Resources/Inter.ttf")
PORTRAIT = os.path.join(ROOT, "Sources/Cove/Resources/agent-portrait.jpg")
W, H, SS, FPS, SEG = 1920, 1080, 2, 30, 12.0
TOTAL = 4 * SEG
FRAMES = int(TOTAL * FPS)

INK = (244, 245, 248)
MUTED = (157, 161, 171)
WARM = (238, 138, 116)
VIOLET = (201, 194, 224)
TIDE = [(120, 217, 201), (138, 186, 240), (186, 161, 237), (230, 168, 201), (242, 189, 140)]


def smooth(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def window(t, start, end, fade=0.9):
    """1 inside [start, end], easing in and out over `fade` seconds."""
    return smooth((t - start) / fade) * (1 - smooth((t - (end - fade)) / fade))


def tide_color(x):
    """The Home tide gradient, left to right (x in 0–1)."""
    x = min(0.999, max(0.0, x)) * (len(TIDE) - 1)
    i = int(x)
    f = x - i
    a, b = TIDE[i], TIDE[i + 1]
    return tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3))


def font(size, weight="Medium"):
    f = ImageFont.truetype(FONT, size * SS)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


FONTS = {}


def F(size, weight="Medium"):
    key = (size, weight)
    if key not in FONTS:
        FONTS[key] = font(size, weight)
    return FONTS[key]


def background():
    top, bottom = np.array([16, 17, 20], float), np.array([29, 32, 41], float)
    ramp = np.linspace(0, 1, H * SS)[:, None, None]
    image = (top + (bottom - top) * ramp).repeat(W * SS, axis=1).astype(np.uint8)
    return Image.fromarray(image, "RGB").convert("RGBA")


def tide_points(counts, left, top, width, height, time, layers=14, spacing=6.2):
    """The Home tide (MailTideGeometry): a ridge shaped by counts, with a slow travelling ripple."""
    maximum = max(max(counts), 1)
    columns = max(2, int(width / spacing))
    x = np.linspace(0, 1, columns)
    position = np.clip(x * len(counts) - 0.5, 0, len(counts) - 1)
    index = np.floor(position).astype(int)
    nxt = np.minimum(index + 1, len(counts) - 1)
    frac = position - index
    eased = frac * frac * (3 - 2 * frac)
    c = np.array(counts, float)
    volume = (c[index] * (1 - eased) + c[nxt] * eased) / maximum
    points = []
    for layer in range(layers):
        depth = layer / (layers - 1)
        ripple = np.sin(x * math.pi * 5 - time * math.pi / 7 + depth * 2.4) * 1.6 * (height / 128)
        ridge = height * (0.82 - volume * 0.63)
        y = ridge + depth * (height * 0.90 - ridge) * 0.64 + ripple
        radius = 1.75 if layer == 0 else 1.35
        opacity = 0.95 if layer == 0 else max(0.1, 0.66 * (1 - depth) ** 1.3)
        points.append((left + 2 + x * (width - 4), top + y, radius, opacity))
    return points, x


def portrait_dots(box, spacing=6.0):
    """Halftone of the generated portrait: dot size follows the light, like the app and the landing."""
    left, top, size = box
    image = Image.open(PORTRAIT).convert("L")
    scale = size / image.height
    image = image.resize((int(image.width * scale), size), Image.LANCZOS)
    canvas = Image.new("L", (size, size), 0)
    canvas.paste(image, ((size - image.width) // 2, 0))
    pixels = np.asarray(canvas, float) / 255
    dots = []
    row = 0
    y = spacing / 2
    while y < size:
        x = spacing / 2 + (spacing / 2 if row % 2 else 0)
        while x < size:
            y0, y1 = int(max(0, y - spacing / 2)), int(min(size, y + spacing / 2))
            x0, x1 = int(max(0, x - spacing / 2)), int(min(size, x + spacing / 2))
            lum = pixels[y0:y1, x0:x1].mean()
            ink = min(1, max(0, (lum - 0.16) / 0.72)) ** 1.9
            if ink > 0.07:
                dots.append((left + x, top + y, ink))
            x += spacing
        y += spacing * 0.9
        row += 1
    return dots


RNG = np.random.default_rng(7)
PORTRAIT_BOX = (1060, 150, 780)
PORTRAIT_DOTS = None
LOGO = None


def text(draw, xy, value, size, color, alpha, weight="Medium", anchor="la"):
    if alpha <= 0.01:
        return
    draw.text((xy[0] * SS, xy[1] * SS), value, font=F(size, weight), fill=color + (int(255 * alpha),), anchor=anchor)


def dot(draw, x, y, r, color, alpha):
    if alpha <= 0.01:
        return
    r *= SS
    draw.ellipse((x * SS - r, y * SS - r, x * SS + r, y * SS + r), fill=color + (int(255 * min(1, alpha)),))


def sparkle(draw, cx, cy, r, color, alpha):
    """Cove's ✦ as a shape (Inter has no glyph for it): four soft points."""
    points = []
    for i in range(16):
        angle = i * math.pi / 8 - math.pi / 2
        reach = r if i % 4 == 0 else r * (0.32 if i % 2 else 0.42)
        points.append(((cx + math.cos(angle) * reach) * SS, (cy + math.sin(angle) * reach) * SS))
    draw.polygon(points, fill=color + (int(255 * alpha),))


def pill(draw, x, y, label, alpha, icon=None):
    if alpha <= 0.01:
        return
    f = F(22)
    width = draw.textlength(label, font=f) / SS + (34 if icon else 0) + 40
    draw.rounded_rectangle((x * SS, y * SS, (x + width) * SS, (y + 52) * SS), radius=10 * SS,
                           fill=(255, 255, 255, int(20 * alpha)))
    cursor = x + 20
    if icon:
        sparkle(draw, cursor + 9, y + 26, 10, WARM, alpha)
        cursor += 34
    text(draw, (cursor, y + 26), label, 22, (226, 228, 234), alpha, anchor="lm")
    return width


def frame(n):
    global PORTRAIT_DOTS, LOGO
    if PORTRAIT_DOTS is None:
        PORTRAIT_DOTS = portrait_dots(PORTRAIT_BOX)
        LOGO = Image.open(sys.argv[1]).convert("RGBA")
    t = n / FPS
    image = BASE.copy()
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    segment, local = int(t // SEG), t % SEG

    if segment == 0:  # Settle: scattered dots drift into the tide.
        counts = [3, 5, 4, 7, 6, 9, 8, 6, 7, 10, 8, 6, 7, 5]
        points, xs = tide_points(counts, 120, 610, 1680, 360, t)
        settle = smooth((local - 0.4) / 6.5)
        alpha = window(local, 0, SEG, 1.1)
        rng = np.random.default_rng(11)
        for (px, py, r, op) in points:
            sx = rng.uniform(0, W, len(px))
            sy = rng.uniform(0, H, len(px))
            drift = (1 - settle) * 18
            jx = np.sin(t * 0.6 + sy * 0.01) * drift
            jy = np.cos(t * 0.5 + sx * 0.01) * drift
            gx = sx + (px - sx) * settle + jx
            gy = sy + (py - sy) * settle + jy
            for i in range(0, len(gx)):
                dot(draw, gx[i], gy[i], r, tide_color(xs[i]), op * alpha * (0.35 + 0.65 * settle))
        text(draw, (160, 300), "Find your focus.", 92, INK, window(local, 4.2, SEG, 1.2))
        text(draw, (160, 410), "Let the rest settle.", 92, MUTED, window(local, 6.0, SEG, 1.2))

    elif segment == 1:  # One calm place: the tide as a horizon, the work above it.
        counts = [6, 7, 5, 8, 9, 7, 6, 8, 10, 9, 7, 8, 6, 7]
        points, xs = tide_points(counts, 120, 700, 1680, 300, t)
        alpha = window(local, 0, SEG, 1.1)
        for (px, py, r, op) in points:
            for i in range(len(px)):
                dot(draw, px[i], py[i], r, tide_color(xs[i]), op * alpha)
        text(draw, (160, 230), "Your email and calendar.", 76, INK, window(local, 0.8, SEG, 1.2))
        text(draw, (160, 325), "One calm workspace.", 76, MUTED, window(local, 2.2, SEG, 1.2))
        x = 160
        for i, (label, icon) in enumerate([("Ask Cove, right in your email", "✦"), ("Important and Other", None),
                                           ("Tasks from your email", None), ("Calendar you can drag", None)]):
            a = window(local, 4.0 + i * 0.9, SEG, 1.0)
            rise = (1 - smooth((local - 4.0 - i * 0.9) / 1.0)) * 14
            width = pill(draw, x, 470 + rise, label, a, icon)
            x += (width or 0) + 16

    elif segment == 2:  # Agents: the portrait gathers from loose dots; a soft light reads down the face.
        alpha = window(local, 0, SEG, 1.1)
        gather = smooth((local - 0.3) / 4.0)
        scan_y = PORTRAIT_BOX[1] + ((local % 6) / 6) * PORTRAIT_BOX[2] * 1.3 - PORTRAIT_BOX[2] * 0.15
        rng = np.random.default_rng(23)
        cx, cy = PORTRAIT_BOX[0] + PORTRAIT_BOX[2] / 2, PORTRAIT_BOX[1] + PORTRAIT_BOX[2] / 2
        for (x, y, ink) in PORTRAIT_DOTS:
            angle = rng.uniform(0, math.tau)
            spread = rng.uniform(120, 520)
            sx, sy = cx + math.cos(angle) * spread, cy + math.sin(angle) * spread
            gx, gy = sx + (x - sx) * gather, sy + (y - sy) * gather
            near = math.exp(-((y - scan_y) / 28) ** 2) * gather
            lit = min(1, ink + near * 0.22)
            shade = int(255 * (0.72 + 0.24 * lit))
            dot(draw, gx, gy, 0.7 + 1.9 * lit, (shade, shade, min(255, shade + 4)), (0.2 + 0.75 * lit) * alpha)
        text(draw, (160, 300), "Agents", 26, VIOLET, window(local, 1.2, SEG, 1.0))
        text(draw, (160, 350), "Work your inbox", 84, INK, window(local, 1.6, SEG, 1.2))
        text(draw, (160, 450), "for you.", 84, INK, window(local, 2.2, SEG, 1.2))
        captions = ["Invoice #2048 from Acme  →  Finance / Invoices", "Client asks about delivery  →  reply drafted",
                    "Flight confirmation  →  Travel"]
        for i, line in enumerate(captions):
            start = 4.6 + i * 2.2
            a = window(local, start, start + 2.4 if i < 2 else SEG, 0.6)
            text(draw, (160, 620 + (1 - smooth((local - start) / 0.6)) * 10), line, 30, WARM, a)
        text(draw, (160, 690), "Nothing is ever sent for you.", 26, MUTED, window(local, 6.0, SEG, 1.2), weight="Regular")

    else:  # Momentum, then the mark.
        counts = [1, 0, 2, 1, 3, 0, 2, 4, 1, 3, 2, 5, 3, 4]
        rise = smooth((local - 0.6) / 3.5)
        points, xs = tide_points([c * rise for c in counts], 120, 520, 1680, 420, t)
        part = window(local, 0, 7.2, 1.1)
        for (px, py, r, op) in points:
            for i in range(len(px)):
                dot(draw, px[i], py[i], r, tide_color(xs[i]), op * part)
        text(draw, (160, 230), "Keep the promises", 76, INK, window(local, 1.4, 7.2, 1.2))
        text(draw, (160, 325), "in your email.", 76, MUTED, window(local, 2.4, 7.2, 1.2))
        close = window(local, 7.6, SEG, 1.2)
        if close > 0.01:
            size = 96 * SS
            logo = LOGO.resize((size, size), Image.LANCZOS)
            logo.putalpha(logo.getchannel("A").point(lambda v: int(v * close)))
            word = F(96)
            word_w = draw.textlength("cove", font=word)
            total = size + 26 * SS + word_w
            lx = int(W * SS / 2 - total / 2)
            layer.alpha_composite(logo, (lx, int(430 * SS)))
            draw.text((lx + size + 26 * SS, 478 * SS), "cove", font=word, fill=INK + (int(255 * close),), anchor="lm")
            text(draw, (W / 2, 610), "Find your focus. Let the rest settle.", 34, MUTED, window(local, 8.4, SEG, 1.2),
                 weight="Regular", anchor="mm")
            text(draw, (W / 2, 690), "covemail.xyz", 26, (210, 212, 220), window(local, 9.2, SEG, 1.2), anchor="mm")

    image.alpha_composite(layer)
    return np.asarray(image.convert("RGB").resize((W, H), Image.LANCZOS), dtype=np.uint8).tobytes()


BASE = background()


def main():
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    full = os.path.join(out, "cove-brand-film.mp4")
    keyframes = ",".join(str(i * SEG) for i in range(1, 4))
    encoder = subprocess.Popen([
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
        "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-force_key_frames", keyframes, "-g", str(FPS * 2), full], stdin=subprocess.PIPE)
    with Pool(max(1, os.cpu_count() - 1)) as pool:
        for i, data in enumerate(pool.imap(frame, range(FRAMES), chunksize=4)):
            encoder.stdin.write(data)
            if i % 120 == 0:
                print(f"frame {i}/{FRAMES}", flush=True)
    encoder.stdin.close()
    encoder.wait()
    # Split at the forced keyframes without re-encoding: the four clips are exactly the full film.
    names = ["1-settle", "2-one-calm-place", "3-agents", "4-momentum"]
    pattern = os.path.join(out, "part-%d.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", full, "-map", "0", "-c", "copy", "-f", "segment",
                    "-segment_frames", ",".join(str(i * int(SEG * FPS)) for i in range(1, 4)), "-reset_timestamps", "1", pattern], check=True)
    for i, name in enumerate(names):
        os.replace(pattern % i, os.path.join(out, f"cove-brand-film-{name}.mp4"))
    print("done", full)


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[3] == "--cut":
        FULL = os.path.join(sys.argv[2], "cove-brand-film.mp4")
        keyframes = ",".join(str(i * SEG) for i in range(1, 4))
        names = ["1-settle", "2-one-calm-place", "3-agents", "4-momentum"]
        pattern = os.path.join(sys.argv[2], "part-%d.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", FULL, "-map", "0", "-c", "copy", "-f", "segment",
                        "-segment_frames", ",".join(str(i * int(SEG * FPS)) for i in range(1, 4)), "-reset_timestamps", "1", pattern], check=True)
        for i, name in enumerate(names):
            os.replace(pattern % i, os.path.join(sys.argv[2], f"cove-brand-film-{name}.mp4"))
    elif len(sys.argv) > 3 and sys.argv[3] == "--still":
        for t in map(float, sys.argv[4:]):
            data = frame(int(t * FPS))
            Image.frombytes("RGB", (W, H), data).save(os.path.join(sys.argv[2], f"still-{t:05.1f}.png"))
    else:
        main()
