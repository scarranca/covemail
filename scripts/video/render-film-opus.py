#!/usr/bin/env python3
"""Cove — "Signal" (Opus cut). 24 s, four 6 s movements:
1 noise   : a storm of email rows, kinetic words, everything collapses into one point of light, which floods the frame.
2 sort    : light canvas. Mail drops in and sorts itself into Important and Other; a promo is unsubscribed in one click.
3 agents  : a halftone face ripples out from its centre; an agent is described in one sentence and gets to work.
4 settle  : rapid feature words over a rising tide; the tide gathers into the wave mark, wordmark, tagline.
"""
import math
import os
import subprocess
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/scarranca/orca/workspaces/covemail/plaice"
FONT = os.path.join(REPO, "Sources/Cove/Resources/Inter.ttf")
PORTRAIT = os.path.join(REPO, "Sources/Cove/Resources/agent-portrait.jpg")
LOGO_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cove-mark.png")
W, H, SS, FPS, SEG = 1920, 1080, 2, 30, 6.0
FRAMES = int(4 * SEG * FPS)

BG0, BG1 = (16, 17, 20), (29, 32, 41)
INK = (244, 245, 248)
MUTED = (157, 161, 171)
WARM = (238, 138, 116)
VIOLET = (201, 194, 224)
TIDE = [(120, 217, 201), (138, 186, 240), (186, 161, 237), (230, 168, 201), (242, 189, 140)]
LIGHT = (248, 249, 250)
LINK = (36, 38, 44)  # ink on light


def clamp(x):
    return min(1.0, max(0.0, x))


def smooth(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)


def eo(x):  # expo-ish ease out
    x = clamp(x)
    return 1 - (1 - x) ** 4


def ei(x):
    x = clamp(x)
    return x ** 3


def eio(x):
    x = clamp(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def back(x, s=1.4):  # ease out with a small overshoot
    x = clamp(x)
    return 1 + (s + 1) * (x - 1) ** 3 + s * (x - 1) ** 2


def tide_color(x):
    x = clamp(x) * 0.999 * (len(TIDE) - 1)
    i = int(x)
    f = x - i
    a, b = TIDE[i], TIDE[i + 1]
    return tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3))


def mix(a, b, f):
    return tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3))


FONTS = {}


def F(size, weight="Medium"):
    key = (size, weight)
    if key not in FONTS:
        f = ImageFont.truetype(FONT, int(size * SS))
        f.set_variation_by_name(weight)
        FONTS[key] = f
    return FONTS[key]


def A(a):
    return int(255 * clamp(a))


# ---------- primitives (coordinates in 1x units) ----------

def dot(d, x, y, r, c, a):
    if a <= 0.01 or r <= 0:
        return
    r *= SS
    d.ellipse((x * SS - r, y * SS - r, x * SS + r, y * SS + r), fill=c + (A(a),))


def text(d, x, y, s, size, c, a, weight="Medium", anchor="la"):
    if a <= 0.01:
        return
    d.text((x * SS, y * SS), s, font=F(size, weight), fill=c + (A(a),), anchor=anchor)


def tw(s, size, weight="Medium"):
    return F(size, weight).getlength(s) / SS


def sparkle(d, cx, cy, r, c, a, rot=0.0):
    if a <= 0.01:
        return
    pts = []
    for i in range(16):
        ang = i * math.pi / 8 - math.pi / 2 + rot
        reach = r if i % 4 == 0 else r * (0.30 if i % 2 else 0.40)
        pts.append(((cx + math.cos(ang) * reach) * SS, (cy + math.sin(ang) * reach) * SS))
    d.polygon(pts, fill=c + (A(a),))


def rrect(d, x0, y0, x1, y1, r, fill=None, outline=None, width=1):
    d.rounded_rectangle((x0 * SS, y0 * SS, x1 * SS, y1 * SS), radius=r * SS, fill=fill, outline=outline,
                        width=int(width * SS))


def track(d, x, y, s, size, c, t, start, end=None, weight="Medium", align="center", spread=0.35, stagger=0.022,
          dur=0.55, out=0.28, rise=26):
    """Kinetic title: letters track in from wide spacing and settle with kerning intact; leave by lifting and fading."""
    f = F(size, weight)
    total = f.getlength(s) / SS
    x0 = x - total / 2 if align == "center" else (x - total if align == "right" else x)
    n = len(s)
    leave = 0.0 if end is None else eo((t - end) / out)
    if leave >= 0.999:
        return
    span = dur + stagger * n
    g = eo((t - start) / span)
    if g <= 0.001:
        return
    for i, ch in enumerate(s):
        if ch == " ":
            continue
        e = smooth((t - start - i * stagger) / (dur * 0.7))
        if e <= 0.001:
            continue
        gx = x0 + f.getlength(s[:i]) / SS
        offset = (gx + f.getlength(ch) / SS / 2 - (x0 + total / 2)) * spread * 1.6 * (1 - g)
        a = e * (1 - leave)
        yy = y + (1 - g) * rise * 0.5 - leave * rise
        text(d, gx + offset, yy, ch, size, c, a, weight, anchor="ls")


def slot(layer, x, y, s, size, c, t, start, end=None, weight="Medium", align="center", dur=0.5, out=0.35):
    """Masked slot: the whole line rises out of its baseline mask and exits upward through the cap line."""
    f = F(size, weight)
    asc, desc = f.getmetrics()
    w = int(f.getlength(s)) + 8
    hgt = asc + desc + 8
    e = eo((t - start) / dur)
    lv = 0.0 if end is None else ei((t - end) / out)
    if e <= 0.001 or lv >= 0.999:
        return
    img = Image.new("RGBA", (w, hgt), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((2, 2), s, font=f, fill=c + (255,))
    shift = int((1 - e) * hgt) - int(lv * hgt)
    left = x * SS - (w / 2 if align == "center" else (w if align == "right" else 0))
    top = y * SS - asc
    if shift >= 0:
        part = img.crop((0, 0, w, hgt - shift))
        pos = (int(left), int(top + shift))
    else:
        part = img.crop((0, -shift, w, hgt))
        pos = (int(left), int(top))
    if part.height > 0:
        layer.paste(part, pos, part)


def gradient_bg():
    ramp = np.linspace(0, 1, H * SS)[:, None, None]
    top, bot = np.array(BG0, float), np.array(BG1, float)
    img = (top + (bot - top) * ramp).repeat(W * SS, axis=1).astype(np.uint8)
    return Image.fromarray(img, "RGB")


# ---------- scene data (lazily built per worker) ----------
CACHE = {}


def portrait_dots(cx, cy, size, spacing):
    img = Image.open(PORTRAIT).convert("L")
    sc = size / img.height
    img = img.resize((int(img.width * sc), size), Image.LANCZOS)
    canvas = Image.new("L", (size, size), 0)
    canvas.paste(img, ((size - img.width) // 2, 0))
    px = np.asarray(canvas, float) / 255
    out = []
    row, y = 0, spacing / 2
    while y < size:
        x = spacing / 2 + (spacing / 2 if row % 2 else 0)
        while x < size:
            y0, y1 = int(max(0, y - spacing / 2)), int(min(size, y + spacing / 2))
            x0, x1 = int(max(0, x - spacing / 2)), int(min(size, x + spacing / 2))
            ink = clamp((px[y0:y1, x0:x1].mean() - 0.14) / 0.72) ** 1.7
            if ink > 0.06:
                out.append((cx - size / 2 + x, cy - size / 2 + y, ink))
            x += spacing
        y += spacing * 0.88
        row += 1
    return out


def get(name):
    if name not in CACHE:
        if name == "bg":
            CACHE[name] = gradient_bg()
        elif name == "logo":
            CACHE[name] = Image.open(LOGO_PATH).convert("RGBA")
        elif name == "portrait":
            CACHE[name] = portrait_dots(520, 540, 820, 9.0)
        elif name == "storm":
            rng = np.random.default_rng(5)
            rows = []
            for i in range(110):
                depth = rng.uniform(0.35, 1.0)
                rows.append(dict(x=rng.uniform(-120, W - 120), y0=rng.uniform(0, H + 400), depth=depth,
                                 speed=rng.uniform(260, 520) * depth, w=rng.uniform(300, 440) * depth,
                                 unread=rng.uniform() < 0.45, hue=rng.uniform(), b1=rng.uniform(0.35, 0.7),
                                 b2=rng.uniform(0.5, 0.95)))
            CACHE[name] = sorted(rows, key=lambda r: r["depth"])
    return CACHE[name]


# ---------- 1 · noise ----------

def scene_noise(img, layer, d, t):
    rows = get("storm")
    cx, cy = W / 2, H / 2 - 10
    collapse = eio((t - 3.55) / 1.15)  # rows fly into the centre point
    fade_in = smooth(t / 0.35)
    for r in rows:
        dep = r["depth"]
        # accelerating upward stream
        y = (r["y0"] - (r["speed"] * t + 60 * t * t * dep)) % (H + 400) - 200
        x = r["x"]
        w, h = r["w"], 64 * dep
        if collapse > 0:
            x = x + (cx - w / 2 * (1 - collapse) - x) * collapse
            y = y + (cy - h / 2 * (1 - collapse) - y) * collapse
            w *= 1 - collapse
            h *= 1 - collapse
        a = (0.35 + 0.65 * dep) * fade_in * (1 - smooth((collapse - 0.85) / 0.15))
        if a <= 0.01:
            continue
        if w > 14:
            rrect(d, x, y, x + w, y + h, min(12 * dep, h / 2), fill=(44, 48, 60, A(a)))
            av = 26 * dep * (1 - collapse)
            dot(d, x + 18 * dep + av / 2, y + h / 2, av / 2, tide_color(r["hue"]), a * 0.9)
            bx = x + 30 * dep + av
            bw = max(0, w - (bx - x) - 26 * dep)
            rrect(d, bx, y + h * 0.30, bx + bw * r["b1"], y + h * 0.30 + 8 * dep, 4 * dep, fill=(120, 124, 134, A(a)))
            rrect(d, bx, y + h * 0.58, bx + bw * r["b2"], y + h * 0.58 + 6 * dep, 3 * dep, fill=(74, 78, 90, A(a)))
            if r["unread"]:
                dot(d, x + w - 14 * dep, y + h / 2, 4.5 * dep, WARM, a)
        else:
            dot(d, x + w / 2, y + h / 2, 3 + 2 * dep, tide_color(r["hue"]), a)
    # scrim behind words while the storm runs
    sc = smooth((t - 0.2) / 0.4) * (1 - smooth((t - 3.4) / 0.4))
    if sc > 0.01:
        d.rectangle((0, 0, W * SS, H * SS), fill=BG0 + (A(0.55 * sc),))
    words = [("Every email.", 0.25, 1.15), ("Every ping.", 1.25, 2.15), ("Every “urgent.”", 2.25, 3.35)]
    for s, a, b in words:
        track(d, W / 2, 590, s, 132, INK, t, a, b, weight="SemiBold", dur=0.45, stagger=0.016, out=0.22)
    # the point of light
    p = smooth((t - 4.2) / 0.5)
    if p > 0.01:
        pulse = 1 + 0.18 * math.sin((t - 4.2) * 7) * (1 - smooth((t - 4.9) / 0.3))
        for k, (rr, aa) in enumerate([(70, 0.06), (40, 0.12), (22, 0.25), (9, 1.0)]):
            dot(d, cx, cy, rr * p * pulse, INK, aa * p)
    track(d, W / 2, cy + 120, "What if it all settled?", 40, MUTED, t, 4.35, 5.15, weight="Regular", dur=0.5, out=0.2)
    # flood: the point opens into the light canvas
    fl = ei((t - 5.25) / 0.55)
    if fl > 0:
        rad = 9 + fl * 1150
        dot(d, cx, cy, rad, LIGHT, 1.0)
    return d


# ---------- 2 · sort (light) ----------
IMPORTANT = [("Acme", "Contract signed — next steps", TIDE[0]),
             ("Maya Chen", "Lunch on Thursday?", TIDE[2]),
             ("Acme", "Invoice #2048 due Friday", TIDE[4])]
OTHER = [("Newsletter", "This week in design", None),
         ("Receipts", "Your order has shipped", None),
         ("Promotions", "30% off this weekend", None),
         ("Notifications", "New sign-in on your account", None)]
COLW, CARDH = 720, 104
LX, RX = 150, 1050


def card(d, x, y, sender, subject, a, accent, dim=1.0, unsub=0.0, press=0.0):
    if a <= 0.01:
        return
    rrect(d, x + 2, y + 5, x + COLW + 2, y + CARDH + 5, 16, fill=(36, 38, 44, A(0.06 * a)))
    rrect(d, x, y, x + COLW, y + CARDH, 16, fill=(255, 255, 255, A(a)), outline=(226, 228, 233, A(a)), width=1.2)
    col = accent if accent else (190, 193, 200)
    dot(d, x + 50, y + CARDH / 2, 24, col, a)
    ini = sender[0]
    text(d, x + 50, y + CARDH / 2, ini, 22, (255, 255, 255), a, "SemiBold", anchor="mm")
    text(d, x + 94, y + 42, sender, 25, LINK, a * dim, "SemiBold", anchor="ls")
    text(d, x + 94, y + 78, subject, 24, LINK, a * (0.72 if dim == 1 else dim * 0.8), "Regular", anchor="ls")
    if accent:
        dot(d, x + COLW - 30, y + CARDH / 2, 6, WARM, a)
    if unsub > 0.01:
        label = "Unsubscribe"
        bw = tw(label, 20, "SemiBold") + 36
        bx, by = x + COLW - bw - 22, y + CARDH / 2 - 22
        s = 1 - 0.06 * math.sin(clamp(press) * math.pi)
        cxp, cyp = bx + bw / 2, by + 22
        rrect(d, cxp - bw / 2 * s, cyp - 22 * s, cxp + bw / 2 * s, cyp + 22 * s, 22,
              fill=mix((255, 255, 255), WARM, 0.14 + 0.5 * clamp(press)) + (A(unsub * a),),
              outline=WARM + (A(unsub * a),), width=1.4)
        text(d, cxp, cyp, label, 20, (176, 82, 60), unsub * a, "SemiBold", anchor="mm")


def scene_sort(img, layer, d, t):
    d.rectangle((0, 0, W * SS, H * SS), fill=LIGHT + (255,))
    # divider and tab labels
    ln = eo((t - 0.15) / 0.7)
    d.line(((W / 2) * SS, 170 * SS, (W / 2) * SS, (170 + 560 * ln) * SS), fill=(214, 216, 222, 255), width=2 * SS)
    track(d, LX, 140, "Important", 44, LINK, t, 0.1, 5.35, "SemiBold", align="left", spread=0.25)
    track(d, RX, 140, "Other", 44, LINK, t, 0.25, 5.35, "SemiBold", align="left", spread=0.25)
    text(d, LX + tw("Important", 44, "SemiBold") + 18, 140, "3", 26, WARM, smooth((t - 1.9) / 0.3) * (1 - smooth((t - 5.2) / 0.2)), "SemiBold", anchor="ls")
    # arrival order alternates sides; each card drops from top-centre and flies to its slot
    order = [("i", 0), ("o", 0), ("i", 1), ("o", 1), ("o", 2), ("i", 2), ("o", 3)]
    gone = 5.3
    for k, (side, idx) in enumerate(order):
        st = 0.55 + k * 0.24
        e = back((t - st) / 0.55, 1.1)
        a = smooth((t - st) / 0.18) * (1 - smooth((t - gone) / 0.25))
        if side == "i":
            sender, subject, acc = IMPORTANT[idx]
            tx, ty = LX, 210 + idx * (CARDH + 18)
            dim = 1.0
        else:
            sender, subject, acc = OTHER[idx]
            tx, ty = RX, 210 + idx * (CARDH + 18)
            dim = 0.62
        sx, sy = W / 2 - COLW / 2, H + 20
        x = sx + (tx - sx) * e
        y = sy + (ty - sy) * eo((t - st) / 0.5)
        if side == "o" and idx == 2:  # the promo: one click to unsubscribe, then it leaves
            un = smooth((t - 2.75) / 0.3)
            press = clamp((t - 3.25) / 0.3)
            out = eio((t - 3.6) / 0.45)
            x += out * 120
            a *= 1 - out
            card(d, x, y, sender, subject, a, acc, dim, unsub=un, press=press)
            continue
        if side == "o" and idx == 3:  # the next one slides up into the freed slot
            y -= eio((t - 3.85) / 0.45) * (CARDH + 18)
        card(d, x, y, sender, subject, a, acc, dim)
    # cursor for the click
    ca = smooth((t - 2.85) / 0.25) * (1 - smooth((t - 3.7) / 0.2))
    if ca > 0.01:
        px = RX + COLW - 80 + (1 - eo((t - 2.85) / 0.45)) * 120
        py = 210 + 2 * (CARDH + 18) + CARDH / 2 + 6 + (1 - eo((t - 2.85) / 0.45)) * 90
        pts = [(px, py), (px, py + 30), (px + 8, py + 23), (px + 14, py + 36), (px + 19, py + 34), (px + 13, py + 21), (px + 23, py + 21)]
        d.polygon([(a_ * SS, b_ * SS) for a_, b_ in pts], fill=LINK + (A(ca),), outline=(255, 255, 255, A(ca)))
    text(d, RX + COLW - 150, 210 + 2 * (CARDH + 18) + CARDH + 40, "One click. Gone for good.", 24, LINK,
         smooth((t - 3.35) / 0.25) * (1 - smooth((t - 4.3) / 0.3)) * 0.75, "Regular", anchor="mm")
    # headline
    track(d, W / 2, 880, "What matters, first.", 84, LINK, t, 3.9, 5.3, "SemiBold", spread=0.3)
    track(d, W / 2, 950, "Important and Other, sorted for you.", 30, LINK, t, 4.25, 5.3, "Regular", spread=0.2)
    # iris to dark
    ir = ei((t - 5.4) / 0.5)
    if ir > 0:
        rad = (6 + ir * 1150) * SS
        mask = Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).ellipse((W * SS / 2 - rad, H * SS / 2 - rad, W * SS / 2 + rad, H * SS / 2 + rad), fill=255)
        img.paste(get("bg"), (0, 0), mask)
    return d


# ---------- 3 · agents ----------

def scene_agents(img, layer, d, t):
    dots_ = get("portrait")
    cx, cy = 520, 540
    wave = (t - 0.1) * 560  # ripple radius
    leave = smooth((t - 5.3) / 0.6)
    for (x, y, ink) in dots_:
        dist = math.hypot(x - cx, y - cy)
        g = eo((wave - dist) / 260)
        if g <= 0.01:
            continue
        front = math.exp(-((wave - dist - 40) / 60) ** 2)
        r = (1.3 + 3.3 * ink) * g * (1 - leave * 0.9)
        shade = int(170 + 85 * ink)
        col = mix((shade, shade, min(255, shade + 6)), tide_color(clamp((x - 110) / 820)), front * 0.85)
        a = (0.25 + 0.75 * ink) * g * (1 - leave) + front * 0.4 * (1 - leave)
        dot(d, x, y, r + front * 1.2, col, a)
    X = 1040
    end = 5.35
    track(d, X, 230, "AGENTS", 22, VIOLET, t, 0.35, end, "SemiBold", align="left", spread=0.6)
    slot(layer, X, 320, "Describe it", 76, INK, t, 0.55, end, "SemiBold", align="left")
    slot(layer, X, 410, "in a sentence.", 76, MUTED, t, 0.75, end, "SemiBold", align="left")
    d = ImageDraw.Draw(layer, "RGBA")
    # prompt field
    pa = smooth((t - 1.25) / 0.3) * (1 - smooth((t - end) / 0.3))
    if pa > 0.01:
        rise = (1 - eo((t - 1.25) / 0.5)) * 30
        y0 = 470 + rise
        rrect(d, X, y0, X + 760, y0 + 76, 18, fill=(36, 39, 48, A(pa)), outline=(66, 70, 82, A(pa)), width=1.2)
        sparkle(d, X + 38, y0 + 38, 13, WARM, pa, rot=(t - 1.25) * 0.8 * (1 - smooth((t - 3) / 0.5)))
        s = "File Acme invoices under Finance."
        n = int(clamp((t - 1.6) / 1.1) * len(s))
        text(d, X + 68, y0 + 38, s[:n], 26, INK, pa, "Regular", anchor="lm")
        if t < 3.1 and int(t * 3) % 2 == 0 or n < len(s):
            cx_ = X + 70 + tw(s[:n], 26, "Regular")
            d.rectangle((cx_ * SS, (y0 + 22) * SS, (cx_ + 2) * SS, (y0 + 54) * SS), fill=WARM + (A(pa),))
    rows = [("Filed", "Acme invoice #2048  →  Finance / Invoices", TIDE[0]),
            ("Drafted", "Reply ready for your review", TIDE[2]),
            ("Notified", "New match from Acme", TIDE[4])]
    for i, (tag, line, c) in enumerate(rows):
        st = 2.85 + i * 0.32
        a = smooth((t - st) / 0.25) * (1 - smooth((t - end) / 0.3))
        if a <= 0.01:
            continue
        dx = (1 - eo((t - st) / 0.5)) * 60
        y = 600 + i * 62
        dot(d, X + 10 + dx, y, 7, c, a)
        text(d, X + 34 + dx, y, tag, 24, c, a, "SemiBold", anchor="lm")
        text(d, X + 150 + dx, y, line, 24, (214, 216, 222), a, "Regular", anchor="lm")
    track(d, X, 860, "Nothing is ever sent for you.", 40, WARM, t, 4.15, end, "Medium", align="left", spread=0.25)
    return d


# ---------- 4 · settle ----------

def tide(d, t, cx, base, width, amp, layers, alpha, gather=0.0, spacing=8.0):
    cols = int(width / spacing)
    xs = np.linspace(0, 1, cols)
    for L in range(layers):
        dep = L / max(1, layers - 1)
        ph = t * 2.2 - dep * 1.9
        y = (np.sin(xs * math.pi * 3.2 + ph) * 0.55 + np.sin(xs * math.pi * 7.1 - ph * 0.7) * 0.25) * amp * (1 - dep * 0.35)
        env = np.sin(xs * math.pi) ** 0.8
        yy = base + y * env + dep * amp * 0.9
        xx = cx - width / 2 + xs * width
        r = 2.6 if L == 0 else 2.0
        op = 0.95 if L == 0 else max(0.12, 0.7 * (1 - dep) ** 1.2)
        for i in range(cols):
            gx, gy = xx[i], yy[i]
            if gather > 0:
                ang = (xs[i] * 2 + dep * 0.2) * math.pi
                rad = 46 + dep * 20
                tx, ty = MARK[0] + math.cos(ang) * rad, MARK[1] + math.sin(ang) * rad
                g = eio(gather - xs[i] * 0.15 * 0)
                gx, gy = gx + (tx - gx) * g, gy + (ty - gy) * g
            dot(d, gx, gy, r, tide_color(xs[i]), op * alpha)


def scene_settle(img, layer, d, t):
    global MARK
    total = 112 + 30 + tw("cove", 112)
    MARK = (W / 2 - total / 2 + 56, 471)
    grow = eo((t - 0.05) / 1.6)
    gather = clamp((t - 2.4) / 0.6)
    ta = smooth(t / 0.3) * (1 - smooth((gather - 0.75) / 0.25))
    if ta > 0.01:
        tide(d, t, W / 2, 760, 1720 * (0.25 + 0.75 * grow) * (1 - 0.0 * gather), 90 * grow, 9, ta, gather)
    feats = ["Ask Cove, inside the email.", "Tasks, straight to Google Tasks.", "A calendar you can drag.",
             "Encrypted on your Mac."]
    for i, s in enumerate(feats):
        st = 0.15 + i * 0.6
        slot(layer, W / 2, 470, s, 92, INK, t, st, st + 0.52 if i < 3 else 2.45, "SemiBold", dur=0.32, out=0.2)
    d = ImageDraw.Draw(layer, "RGBA")
    sp = smooth((t - 0.1) / 0.2) * (1 - smooth((t - 0.75) / 0.12))
    sparkle(d, W / 2 - tw(feats[0], 92, "SemiBold") / 2 - 52, 438, 26, WARM, sp, rot=t * 2)
    # lock-up
    la = smooth((t - 2.8) / 0.5)
    if la > 0.01:
        logo = get("logo")
        size = int(112 * SS)
        lg = logo.resize((size, size), Image.LANCZOS)
        lg.putalpha(lg.getchannel("A").point(lambda v: int(v * la)))
        wf = F(112, "Medium")
        ww = wf.getlength("cove")
        total = size + 30 * SS + ww
        slide = (1 - eo((t - 2.8) / 0.9)) * 30
        lx = int(W * SS / 2 - total / 2)
        layer.paste(lg, (lx, int((415 + slide) * SS)), lg)
        d.text((lx + size + 30 * SS, (471 + slide) * SS), "cove", font=wf, fill=INK + (A(la),), anchor="lm")
    track(d, W / 2, 640, "Find your focus. Let the rest settle.", 40, MUTED, t, 3.55, None, "Regular", spread=0.18,
          stagger=0.012)
    track(d, W / 2, 712, "covemail.xyz  ·  macOS", 26, (210, 212, 220), t, 4.2, None, "Medium", spread=0.3)
    return d


MARK = (0, 0)
SCENES = [scene_noise, scene_sort, scene_agents, scene_settle]


def frame(n):
    t = n / FPS
    seg = min(3, int(t // SEG))
    local = t - seg * SEG
    img = get("bg").copy()
    d = ImageDraw.Draw(img, "RGBA")  # RGBA ink on an RGB canvas blends instead of replacing
    SCENES[seg](img, img, d, local)
    return np.asarray(img.resize((W, H), Image.LANCZOS), dtype=np.uint8).tobytes()


NAMES = ["1-noise", "2-sort", "3-agents", "4-settle"]


def main(out):
    os.makedirs(out, exist_ok=True)
    full = os.path.join(out, "cove-film-opus.mp4")
    enc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                            "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-force_key_frames", "6,12,18",
                            "-g", "60", full], stdin=subprocess.PIPE)
    with Pool(max(1, os.cpu_count() - 1)) as pool:
        for i, data in enumerate(pool.imap(frame, range(FRAMES), chunksize=4)):
            enc.stdin.write(data)
            if i % 120 == 0:
                print("frame", i, flush=True)
    enc.stdin.close()
    enc.wait()
    pattern = os.path.join(out, "part-%d.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", full, "-map", "0", "-c", "copy", "-f", "segment",
                    "-segment_frames", "180,360,540", "-reset_timestamps", "1", pattern], check=True)
    for i, nm in enumerate(NAMES):
        os.replace(pattern % i, os.path.join(out, f"cove-film-opus-{nm}.mp4"))


if __name__ == "__main__":
    if sys.argv[1] == "--still":
        out = sys.argv[2]
        os.makedirs(out, exist_ok=True)
        for s in sys.argv[3:]:
            tt = float(s)
            Image.frombytes("RGB", (W, H), frame(int(round(tt * FPS)))).save(os.path.join(out, f"s{tt:05.2f}.png"))
    else:
        main(sys.argv[1])
