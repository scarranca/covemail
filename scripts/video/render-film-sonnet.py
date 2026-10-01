import math, os, subprocess, sys, random
from multiprocessing import Pool
import numpy as np
from PIL import Image, ImageDraw, ImageFont

R = "/Users/scarranca/orca/workspaces/covemail/plaice/Sources/Cove/Resources/"
FONT = R + "Inter.ttf"
LOGO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cove-mark.png")
W, H, SS, FPS = 1920, 1080, 2, 30
SEG = 6.0
FRAMES = 720
INK = (244, 245, 248); MUTED = (157, 161, 171); WARM = (238, 138, 116); VIOLET = (201, 194, 224)
TIDE = [(120, 217, 201), (138, 186, 240), (186, 161, 237), (230, 168, 201), (242, 189, 140)]
LIGHT = (248, 249, 250); LINK = (36, 38, 44); LMUTED = (107, 111, 122)
CARD = (26, 29, 37)

def clamp(x): return min(1.0, max(0.0, x))
def sm(x): x = clamp(x); return x*x*(3-2*x)
def eo(x): x = clamp(x); return 1 - 2**(-10*x) if x < 1 else 1.0
def ei(x): x = clamp(x); return x**3
def pr(t, a, b): return clamp((t-a)/(b-a))
def lerp(a, b, t): return a+(b-a)*t
def tide(x):
    x = min(0.999, max(0.0, x))*(len(TIDE)-1); i = int(x); f = x-i
    a, b = TIDE[i], TIDE[i+1]
    return tuple(int(a[k]+(b[k]-a[k])*f) for k in range(3))

FONTS = {}
def F(size, w):
    k = (size, w)
    if k not in FONTS:
        f = ImageFont.truetype(FONT, int(round(size*SS)))
        try: f.set_variation_by_name(w)
        except Exception: pass
        FONTS[k] = f
    return FONTS[k]
MASKS = {}
def tmask(s, size, w):
    k = (s, size, w)
    if k not in MASKS:
        f = F(size, w); pad = int(size*SS*0.3)+4
        tw = int(math.ceil(f.getlength(s)))
        base = int(size*SS*1.15)
        m = Image.new("L", (tw+2*pad, int(size*SS*1.6)), 0)
        ImageDraw.Draw(m).text((pad, base), s, font=f, fill=255, anchor="ls")
        MASKS[k] = (m, tw, pad, base)
    return MASKS[k]
def tw1(s, size, w="Medium"): return F(size, w).getlength(s)/SS
GRADS = {}
def gradimg(wid, hei, pad, tw):
    k = (wid, hei, pad, tw)
    if k not in GRADS:
        xs = np.clip((np.arange(wid)-pad)/max(1, tw), 0, 1)
        arr = np.zeros((hei, wid, 3), np.uint8)
        cols = np.array([tide(x) for x in xs], np.uint8)
        arr[:] = cols[None, :, :]
        GRADS[k] = Image.fromarray(arr)
    return GRADS[k]
LOGOIMG = Image.open(LOGO).convert("RGBA")
LOGOCACHE = {}
_bg = None
def bg():
    global _bg
    if _bg is None:
        w, h = W*SS//2, H*SS//2
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        t = (xx/w*0.45 + yy/h*0.75)/1.2
        a = np.array([16, 17, 20], np.float32); b = np.array([29, 32, 41], np.float32)
        arr = a + (b-a)*t[..., None]
        _bg = Image.fromarray(arr.astype(np.uint8)).resize((W*SS, H*SS), Image.BILINEAR)
    return _bg

class C:
    def __init__(s, base):
        s.img = base.copy(); s.d = ImageDraw.Draw(s.img, "RGBA"); s.ga = 1.0; s.ox = 0; s.oy = 0
    def grp(s, ox=0, oy=0, a=1.0):
        s.ox, s.oy, s.ga = ox, oy, a
    def X(s, x): return (x+s.ox)*SS
    def Y(s, y): return (y+s.oy)*SS
    def col(s, c, a=1.0):
        al = c[3]/255 if len(c) == 4 else 1.0
        return (c[0], c[1], c[2], int(255*clamp(al*a*s.ga)))
    def rr(s, x0, y0, x1, y1, r, fill=None, line=None, lw=1, a=1.0):
        box = [s.X(x0), s.Y(y0), s.X(x1), s.Y(y1)]
        if box[2] <= box[0] or box[3] <= box[1]: return
        r = min(r, (x1-x0)/2, (y1-y0)/2)
        s.d.rounded_rectangle(box, radius=r*SS, fill=s.col(fill, a) if fill else None,
                              outline=s.col(line, a) if line else None, width=int(lw*SS))
    def circ(s, cx, cy, r, fill=None, line=None, lw=1, a=1.0):
        s.d.ellipse([s.X(cx-r), s.Y(cy-r), s.X(cx+r), s.Y(cy+r)], fill=s.col(fill, a) if fill else None,
                    outline=s.col(line, a) if line else None, width=int(lw*SS))
    def shadow(s, x0, y0, x1, y1, r, a=1.0, strength=7):
        for i in range(8, 0, -1):
            e = i*3
            s.rr(x0-e, y0-e+10, x1+e, y1+e+10, r+e, fill=(30, 34, 50, strength), a=a)
    def star(s, cx, cy, r, fill, a=1.0, rot=0):
        pts = []
        for k in range(8):
            ang = k*math.pi/4 + rot
            rad = r if k % 2 == 0 else r*0.24
            pts.append((s.X(cx+math.cos(ang)*rad), s.Y(cy+math.sin(ang)*rad)))
        s.d.polygon(pts, fill=s.col(fill, a))
    def line(s, pts, fill, w, a=1.0):
        s.d.line([(s.X(x), s.Y(y)) for x, y in pts], fill=s.col(fill, a), width=int(w*SS), joint="curve")
    def text(s, t, x, y, size, w="Medium", color=INK, a=1.0, align="l", reveal=1.0, scale=1.0, grad=False):
        if not t: return
        m, tw, pad, base = tmask(t, size, w)
        al = clamp(a*s.ga*(color[3]/255 if len(color) == 4 else 1.0))
        if al <= 0.003 or reveal <= 0: return
        x2 = s.X(x); y2 = s.Y(y)+0.36*size*SS
        if align == "c": x2 -= tw/2
        elif align == "r": x2 -= tw
        ox, oy = x2-pad, y2-base
        if reveal < 1:
            dy = int((1-eo(reveal))*size*SS*0.9)
            m2 = Image.new("L", m.size, 0); m2.paste(m, (0, dy)); m = m2
            al *= clamp(reveal*3)
        if scale != 1.0:
            cx = ox+pad+tw/2; cy = y2-0.35*size*SS
            nw, nh = max(1, int(m.width*scale)), max(1, int(m.height*scale))
            m = m.resize((nw, nh), Image.BICUBIC)
            ox, oy = cx+(ox-cx)*scale, cy+(oy-cy)*scale
        if al < 0.999: m = m.point([int(i*al) for i in range(256)])
        if grad:
            g = gradimg(m.width, m.height, int(pad*scale), int(tw*scale))
            s.img.paste(g, (int(ox), int(oy)), m)
        else:
            s.img.paste(color[:3], (int(ox), int(oy)), m)
    def logo(s, cx, cy, size, a=1.0, color=(255, 255, 255)):
        k = size
        if k not in LOGOCACHE:
            im = LOGOIMG.resize((int(size*SS), int(size*SS)), Image.LANCZOS)
            LOGOCACHE[k] = im.getchannel("A")
        m = LOGOCACHE[k]
        al = clamp(a*s.ga)
        if al <= 0.003: return
        if al < 0.999: m = m.point([int(i*al) for i in range(256)])
        s.img.paste(color, (int(s.X(cx)-m.width/2), int(s.Y(cy)-m.height/2)), m)

def wave(c, t, base, amp, layers, x0=0, x1=W, a=1.0, step=16, spacing=26, rmin=2.6, rmax=5.2, seed=0):
    for l in range(layers):
        k = l/max(1, layers-1)
        for x in range(x0, x1+1, step):
            u = x/W
            y = (base + l*spacing*(0.7+0.5*k) + amp*(1-0.35*k)*math.sin(u*5.2 + t*0.9 + l*0.55)
                 + amp*0.45*math.sin(u*11.3 - t*1.3 + l*1.1))
            env = 0.5+0.5*math.sin(u*3.1 + t*0.6 + l*0.9)
            r = rmin + (rmax-rmin)*env*(1-0.45*k)
            al = (0.95-0.55*k)*(0.5+0.5*env)
            c.circ(x, y, r, fill=tide(u), a=al*a)

def fade_type(c, lines, t, t0, size, ys, gap=0.14, **kw):
    pass

# ------------------------------------------------ CLIP 1: noise -> calm
SUBJ = [("Acme", "Re: Q3 numbers"), ("Webinar", "50% off, today only"), ("Receipts", "Your order has shipped"),
        ("Calendar", "Invitation: weekly sync"), ("Acme", "Reminder: payment due"), ("Digest", "12 things you missed"),
        ("Security", "New sign-in to your account"), ("Jules", "Re: Re: Fwd: schedule"), ("Promo", "Last chance. Ends tonight"),
        ("Acme", "Action required: contract"), ("Maya", "Quick question"), ("News", "This week in tech"),
        ("Orders", "Shipping update"), ("Team", "Fwd: Fwd: notes"), ("Offers", "You're invited")]
rnd = random.Random(7)
PILLS = []
NP = 46
for i in range(NP):
    PILLS.append(dict(x=rnd.uniform(60, W-60-460), w=rnd.uniform(380, 520), v=rnd.uniform(380, 820), ph=rnd.uniform(0, 1400),
                      tb=rnd.uniform(0.0, 1.6), subj=SUBJ[i % len(SUBJ)], col=tide(rnd.random()), tx=0))
PILLS.sort(key=lambda p: p["x"])
for i, p in enumerate(PILLS): p["tx"] = 80 + i*(W-160)/(NP-1)

def clip1(c, t):
    GT = 2.7
    te = min(t, GT)
    for p in PILLS:
        if t < p["tb"]: continue
        s = te - p["tb"]
        dist = p["v"]*(s + 0.55*(te*te-p["tb"]**2))
        y = 1180 - (dist + p["ph"]) % 1500
        al = sm((t-p["tb"])/0.25)*0.5
        g = sm((t-GT-0.02*(p["x"]/W)*8)/0.95)
        wv = H*0.0
        ty = 640 + 40*math.sin(p["tx"]/W*5.2+t*0.9)
        w = lerp(p["w"], 10, sm(g*1.1)); h = lerp(60, 10, sm(g*1.1))
        x = lerp(p["x"], p["tx"]-5, g) + 0; yy = lerp(y, ty, g)
        col = INK if g < 1 else p["col"]
        if g < 0.99:
            c.rr(x, yy-h/2, x+w, yy+h/2, h/2 if g > 0.3 else 18, fill=(255, 255, 255, int(lerp(16, 0, g))), line=(255, 255, 255, int(lerp(34, 0, g))), a=al*(1-g*0.0))
        if g < 0.5:
            fa = 1-g*2
            c.circ(x+30, yy, 9, fill=p["col"], a=al*fa*1.2)
            c.text(p["subj"][0], x+54, yy-9, 15, "Medium", INK, a=al*fa*1.3)
            c.text(p["subj"][1], x+54, yy+13, 15, "Regular", MUTED, a=al*fa*1.4)
        else:
            c.circ(x+w/2, yy, lerp(7, 3.4, g), fill=p["col"], a=0.5+0.5*g)
    # counter + headline
    out = 1-sm((t-2.45)/0.4)
    n = int(12 + (2431-12)*eo(pr(t, 0.2, 2.3)))
    if out > 0:
        c.rr(1500, 70, 1860, 150, 40, fill=(238, 138, 116, 36), line=(238, 138, 116, 120), a=sm(t/0.3)*out)
        c.circ(1546, 110, 8, fill=WARM, a=sm(t/0.3)*out)
        c.text(f"{n:,}", 1580, 110, 36, "SemiBold", INK, a=sm(t/0.3)*out)
        c.text("unread", 1580+tw1(f"{n:,}", 36, "SemiBold")+14, 112, 24, "Regular", MUTED, a=sm(t/0.3)*out)
        words = [("Mail", 0.30), ("never", 0.62), ("stops.", 0.94)]
        xs = 960 - (sum(tw1(w, 168, "Medium") for w, _ in words) + 2*46)/2
        for w, tt in words:
            c.rr(0, 0, 0, 0, 0)
            c.text(w, xs, 520, 168, "Medium", INK, a=out, reveal=pr(t, tt, tt+0.45), scale=1.0)
            xs += tw1(w, 168, "Medium") + 46
    # settle
    if t > 3.0:
        wave(c, t, 700, 34, 6, a=sm((t-3.0)/0.9), rmin=2.8, rmax=5.0)
        c.logo(960-118, 150, 56, a=sm((t-3.2)/0.5))
        c.text("cove", 960-84, 152, 54, "Medium", INK, a=sm((t-3.2)/0.5))
        c.text("Email and calendar,", 960, 380, 108, "Medium", INK, align="c", reveal=pr(t, 3.35, 3.85))
        c.text("made calm.", 960, 510, 124, "Medium", INK, align="c", reveal=pr(t, 3.7, 4.2), grad=True)
        for i, (sx, sy, sr, st) in enumerate([(1290, 330, 15, 4.1), (360, 560, 11, 4.4), (1560, 520, 9, 4.7)]):
            tw_ = sm((t-st)/0.4)*(0.6+0.4*math.sin(t*3+i))
            c.star(sx, sy, sr, VIOLET if i != 1 else WARM, a=tw_)

# ------------------------------------------------ CLIP 2: describe it (light)
TYPED = "File Acme invoices, draft replies for me to review."
def clip2_light(c, t):
    ink, mu = LINK, LMUTED
    words = [("Say", 0.85), ("it", 1.0), ("in", 1.12), ("one", 1.24), ("sentence.", 1.4)]
    xs = 960 - (sum(tw1(w, 84, "Medium") for w, _ in words) + 4*22)/2
    for w, tt in words:
        c.text(w, xs, 150, 84, "Medium", ink, reveal=pr(t, tt, tt+0.4)); xs += tw1(w, 84, "Medium")+22
    # prompt card
    ca = eo(pr(t, 1.2, 1.7)); cy = 400
    c.grp(0, (1-ca)*30, 1.0)
    c.shadow(330, cy-70, 1590, cy+70, 36, a=ca)
    c.rr(330, cy-70, 1590, cy+70, 36, fill=(255, 255, 255), line=(0, 0, 0, 22), a=ca)
    c.star(398, cy, 20, WARM, a=ca)
    c.text("New agent", 1500, cy-44, 18, "Medium", mu, a=ca, align="r")
    p = pr(t, 1.7, 3.5)
    n = int(len(TYPED)*(p**0.9))
    s = TYPED[:n]
    c.text(s, 450, cy, 38, "Medium", ink, a=ca)
    if t > 1.6 and t < 4.4:
        blink = 1 if (int(t*2.4) % 2 == 0 or p < 1) else 0.0
        c.rr(450+tw1(s, 38)+4, cy-24, 450+tw1(s, 38)+7, cy+24, 1.5, fill=WARM, a=blink*ca)
    c.grp()
    # results
    cards = [("Filed", "Acme · Invoices", "Label applied", TIDE[0], 3.55),
             ("Draft ready", "Re: Contract. Waiting for you", "Review, then send", TIDE[1], 3.8),
             ("Notify", "Acme · needs a reply today", "Notification on this Mac", TIDE[4], 4.05)]
    for i, (a, b, ch, col, ts) in enumerate(cards):
        q = eo(pr(t, ts, ts+0.55)); cx0 = 960 + (i-1)*440 - 200; y0 = 590
        off = (1-q)*-120
        c.grp((1-q)*(i-1)*-140, off, 1.0)
        c.shadow(cx0, y0, cx0+400, y0+200, 28, a=q)
        c.rr(cx0, y0, cx0+400, y0+200, 28, fill=(255, 255, 255), line=(0, 0, 0, 20), a=q)
        c.circ(cx0+44, y0+50, 16, fill=col, a=q)
        c.text(a, cx0+76, y0+50, 30, "SemiBold", ink, a=q)
        c.text(b, cx0+30, y0+104, 21, "Regular", mu, a=q)
        c.rr(cx0+30, y0+136, cx0+30+tw1(ch, 17)+34, y0+172, 18, fill=(0, 0, 0, 12), a=q)
        c.text(ch, cx0+47, y0+155, 17, "Medium", ink, a=q)
        c.grp()
    # promise
    pa = pr(t, 4.55, 5.0)
    if pa > 0:
        tx = "Nothing is ever sent for you."
        wd = tw1(tx, 56, "Medium")
        c.text(tx, 960+30, 900, 56, "Medium", ink, align="c", reveal=pa)
        cxk = 960+30-wd/2-44
        q = eo(pr(t, 4.7, 5.1))
        c.circ(cxk, 900, 24*q, fill=TIDE[0], a=1)
        c.line([(cxk-10, 900), (cxk-3, 907), (cxk+11, 892)], (16, 17, 20), 4, a=pr(t, 4.9, 5.1))

def clip2(c, t):
    tt = t
    r = 0.0
    r = 1500*sm(pr(tt, 0.15, 0.95)) * (1-sm(pr(tt, 5.15, 5.85)))
    c.star(960, 540, 22*(1-sm(pr(tt, 0.1, 0.4))), VIOLET, a=1)
    if r > 1:
        lc = C(bg())
        lc.d.rectangle([0, 0, W*SS, H*SS], fill=LIGHT+(255,))
        clip2_light(lc, tt)
        m = Image.new("L", (W*SS, H*SS), 0)
        ImageDraw.Draw(m).ellipse([(960-r)*SS, (540-r)*SS, (960+r)*SS, (540+r)*SS], fill=255)
        c.img.paste(lc.img, (0, 0), m)
        c.d = ImageDraw.Draw(c.img, "RGBA")

# ------------------------------------------------ CLIP 3: flow
def avatar(c, x, y, r, name, col):
    c.circ(x, y, r, fill=col+(60,))
    c.text(name[0], x, y, int(r*0.9), "SemiBold", col, align="c")

def row(c, x, y, w, name, subj, col, a=1.0, hl=False):
    avatar(c, x+44, y+38, 24, name, col)
    c.text(name, x+88, y+28, 22, "Medium", INK, a=a)
    c.text(subj, x+88, y+58, 20, "Regular", MUTED, a=a)
    c.rr(x+24, y+90, x+w-24, y+91, 0, fill=(255, 255, 255, 14), a=a)

def cursor(c, x, y, a=1.0):
    pts = [(x, y), (x, y+30), (x+8, y+23), (x+14, y+36), (x+20, y+33), (x+14, y+21), (x+25, y+21)]
    c.d.polygon([(c.X(px), c.Y(py)) for px, py in pts], fill=c.col((255, 255, 255), a), outline=c.col((16, 17, 20), a))

WX, WY, WW, WH = 1010, 250, 790, 580
def window(c):
    c.shadow(WX, WY, WX+WW, WY+WH, 30, strength=10)
    c.rr(WX, WY, WX+WW, WY+WH, 30, fill=CARD, line=(255, 255, 255, 22))
    for i, col in enumerate([(238, 138, 116), (242, 189, 140), (120, 217, 201)]):
        c.circ(WX+34+i*24, WY+30, 7, fill=col, a=0.9)

def beatA(c, b):
    window(c)
    ox, oy = WX, WY
    c.text("Important", ox+44, oy+88, 26, "SemiBold", INK)
    c.rr(ox+44, oy+110, ox+44+tw1("Important", 26, "SemiBold"), oy+114, 2, fill=WARM)
    c.text("Other", ox+WW-170, oy+88, 26, "Medium", MUTED)
    q = eo(pr(b, 0.9, 1.1))
    if q > 0:
        c.circ(ox+WW-60, oy+86, 17*q, fill=VIOLET)
        c.text("2", ox+WW-60, oy+87, 18*q if q > .6 else 1, "SemiBold", (16, 17, 20), align="c", a=pr(b, 1.0, 1.1))
    c.rr(ox+24, oy+124, ox+WW-24, oy+125, 0, fill=(255, 255, 255, 18))
    items = [("Acme", "Contract for review", TIDE[0]), ("Maya", "Lunch on Thursday?", TIDE[1]), ("Jules", "A question about the invoice", TIDE[2]),
             ("Acme Weekly", "50% off everything", TIDE[3]), ("Receipts", "Your order has shipped", TIDE[4])]
    for i, (n, s, col) in enumerate(items):
        y = oy+136+i*92
        if i < 3:
            c.grp(0, 0, eo(pr(b, 0.1+i*0.05, 0.4+i*0.05)))
            row(c, ox, y, WW, n, s, col); c.grp()
        else:
            q = sm(pr(b, 0.5+(i-3)*0.1, 0.95+(i-3)*0.1))
            if q <= 0:
                c.grp(0, 0, eo(pr(b, 0.1+i*0.05, 0.4+i*0.05)))
                row(c, ox, y, WW, n, s, col); c.grp()
            elif q < 1:
                w = lerp(WW-48, 150, q); x = lerp(ox+24, ox+WW-170-4, q); yy = lerp(y+10, oy+70, q)
                c.rr(x, yy, x+w, yy+68, 34, fill=col+(60,), line=col+(150,), a=1-q**3)
                c.text(n, x+34, yy+34, 20 if q > 0.4 else 22, "Medium", INK, a=(1-q)**0.5)
    # sorted hint
    c.text("Everything else waits quietly.", ox+44, oy+WH-34, 20, "Regular", MUTED, a=eo(pr(b, 1.0, 1.25)))

def beatB(c, b):
    window(c)
    ox, oy = WX, WY
    avatar(c, ox+70, oy+110, 26, "Acme", TIDE[0])
    c.text("Acme", ox+112, oy+98, 24, "SemiBold", INK)
    c.text("Contract for review", ox+112, oy+128, 20, "Regular", MUTED)
    l1 = "Hi, could you send the signed contract"
    c.text(l1, ox+44, oy+210, 27, "Regular", INK)
    pre = "by "
    x_f = ox+44+tw1(pre, 27, "Regular")
    c.text(pre+"Friday?", ox+44, oy+256, 27, "Regular", INK)
    fw = tw1("Friday", 27, "Regular")
    xs = ox+44+tw1(pre, 27)
    uh = eo(pr(b, 0.25, 0.5))
    c.rr(xs-4, oy+236, xs+fw+4, oy+276, 8, fill=WARM+(50,), a=uh)
    c.rr(xs, oy+274, xs+fw*uh, oy+277, 2, fill=WARM)
    q = eo(pr(b, 0.45, 0.8))
    c.grp(0, (1-q)*-40, 1.0)
    c.star(ox+58, oy+350, 12, WARM, a=q)
    c.text("Task from this email", ox+82, oy+350, 19, "Medium", WARM, a=q)
    c.rr(ox+34, oy+380, ox+WW-34, oy+480, 26, fill=(255, 255, 255, 16), line=(255, 255, 255, 36), a=q)
    k = eo(pr(b, 0.85, 1.05))
    c.circ(ox+88, oy+430, 18, line=MUTED, lw=2, a=q)
    c.circ(ox+88, oy+430, 18*k, fill=TIDE[0], a=q)
    c.line([(ox+79, oy+430), (ox+86, oy+437), (ox+98, oy+423)], (16, 17, 20), 4, a=pr(b, 0.95, 1.05)*q)
    c.text("Send Acme the signed contract", ox+130, oy+430, 25, "Medium", INK, a=q)
    c.rr(ox+WW-140, oy+410, ox+WW-60, oy+450, 20, fill=(255, 255, 255, 22), a=q)
    c.text("Fri", ox+WW-100, oy+431, 19, "Medium", INK, align="c", a=q)
    c.grp()
    c.text("Added to Google Tasks", ox+44, oy+WH-38, 20, "Regular", MUTED, a=eo(pr(b, 1.0, 1.2)))

def beatC(c, b):
    window(c)
    ox, oy = WX, WY
    days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
    gx, gy, cw, rh = ox+60, oy+110, 135, 66
    for i, d in enumerate(days):
        c.text(d, gx+i*cw+cw/2, oy+84, 22, "Medium", MUTED, align="c")
    for j in range(7):
        c.rr(gx-20, gy+j*rh, gx+5*cw, gy+j*rh+1, 0, fill=(255, 255, 255, 20))
    for i in range(1, 5):
        c.rr(gx+i*cw, gy, gx+i*cw+1, gy+6*rh, 0, fill=(255, 255, 255, 10))
    def ev(col, day, row_, h, label, y_off=0, x_off=0, lift=0.0):
        x0 = gx+day*cw+6+x_off; y0 = gy+row_*rh+4+y_off
        if lift > 0:
            c.shadow(x0, y0, x0+cw-12, y0+h*rh-8, 12, strength=14)
        c.rr(x0, y0, x0+cw-12, y0+h*rh-8, 12, fill=col+(int(70+lift*60),), line=col+(200,), lw=1.5)
        c.rr(x0+2, y0+10, x0+6, y0+h*rh-18, 2, fill=col)
        c.text(label, x0+18, y0+28, 19, "Medium", INK)
    for ia, (dd, rr_, hh, lab, col) in enumerate([(0, 0, 1, "Standup", TIDE[0]), (2, 2.2, 1.5, "Design review", TIDE[2]), (4, 1, 1, "1:1", TIDE[1])]):
        c.grp(0, 0, eo(pr(b, 0.05+ia*0.06, 0.3+ia*0.06))); ev(col, dd, rr_, hh, lab); c.grp()
    d = sm(pr(b, 0.35, 0.95))
    sx, sy = 1, 1
    tx_, ty_ = 3, 3.9
    if d < 0.01:
        c.grp(0, 0, eo(pr(b, 0.1, 0.35))); ev(WARM, sx, sy, 1, "Acme sync"); c.grp()
    else:
        ox_ = gx+sx*cw+6; oy_ = gy+sy*rh+4
        c.rr(ox_, oy_, ox_+cw-12, oy_+rh-8, 12, line=WARM+(110,), lw=1.5)
        ev(WARM, sx, sy, 1, "Acme sync", y_off=(ty_-sy)*rh*d, x_off=(tx_-sx)*cw*d, lift=1.0 if d < 1 else 0)
    cx_ = gx+sx*cw+60+(tx_-sx)*cw*d; cy_ = gy+sy*rh+34+(ty_-sy)*rh*d
    if b < 1.1:
        cursor(c, cx_+(1-eo(pr(b, 0.0, 0.35)))*80, cy_+(1-eo(pr(b, 0.0, 0.35)))*60, a=eo(pr(b, 0.05, 0.25))*(1-pr(b, 1.0, 1.1)))
    q = eo(pr(b, 0.95, 1.2))
    c.grp(0, (1-q)*20, 1.0)
    c.rr(ox+WW-420, oy+WH-78, ox+WW-34, oy+WH-26, 26, fill=(255, 255, 255, 24), line=(255, 255, 255, 40), a=q)
    c.text("Moved to Thu 1:00 PM", ox+WW-400, oy+WH-52, 19, "Medium", INK, a=q)
    c.text("Undo", ox+WW-56, oy+WH-52, 19, "Medium", WARM, a=q, align="r")
    c.grp()

def beatD(c, b):
    window(c)
    ox, oy = WX, WY
    c.text("Inbox", ox+44, oy+90, 28, "SemiBold", INK)
    items = [("Maya", "Lunch on Thursday?", TIDE[1]), ("Acme Weekly", "50% off everything this week", TIDE[3]),
             ("Jules", "A question about the invoice", TIDE[2]), ("Acme", "Contract for review", TIDE[0])]
    col_q = sm(pr(b, 0.9, 1.15))
    for i, (n, s, col) in enumerate(items):
        y = oy+130+i*110
        a = eo(pr(b, 0.05+i*0.05, 0.3+i*0.05))
        if i == 1:
            a *= 1-col_q
        elif i > 1:
            y -= 110*col_q
        c.grp(0, 0, a)
        avatar(c, ox+44+0, y+40, 26, n, col)
        c.text(n, ox+90, y+30, 23, "Medium", INK)
        c.text(s, ox+90, y+64, 20, "Regular", MUTED)
        c.rr(ox+24, y+100, ox+WW-24, y+101, 0, fill=(255, 255, 255, 14))
        if i == 1:
            click = pr(b, 0.55, 0.72)
            bx0, bx1, by0, by1 = ox+WW-250, ox+WW-44, y+16, y+66
            if click < 0.4:
                c.rr(bx0, by0, bx1, by1, 25, line=(255, 255, 255, 120), lw=1.5)
                c.text("Unsubscribe", (bx0+bx1)/2, (by0+by1)/2, 21, "Medium", INK, align="c")
            else:
                c.rr(bx0, by0, bx1, by1, 25, fill=TIDE[0])
                c.text("Unsubscribed", (bx0+bx1)/2, (by0+by1)/2, 21, "Medium", (16, 17, 20), align="c")
            rp = pr(b, 0.5, 0.8)
            if 0 < rp < 1:
                c.circ((bx0+bx1)/2, (by0+by1)/2, 30+60*rp, line=TIDE[0]+(int(200*(1-rp)),), lw=3)
        c.grp()
    cp = eo(pr(b, 0.0, 0.45))
    cursor(c, lerp(ox+WW-30, ox+WW-150, cp), lerp(oy+470, oy+250, cp), a=eo(pr(b, 0.0, 0.2))*(1-pr(b, 0.95, 1.1)))

BEATS = [("Inbox", "Important", "comes first.", beatA), ("Tasks", "Tasks from", "your email.", beatB),
         ("Calendar", "Drag your", "day around.", beatC), ("Unsubscribe", "Unsubscribe", "in one click.", beatD)]
STEP = 1.32; B0 = 0.3
def clip3(c, t):
    wave(c, t+3, 940, 14, 3, a=0.22, step=24, spacing=22, rmin=2.2, rmax=3.6)
    for k, (kick, l1, l2, fn) in enumerate(BEATS):
        b = t - (B0 + k*STEP)
        if b < -0.001 or b > STEP+0.001: continue
        tin = eo(b/0.38); tout = ei((b-(STEP-0.22))/0.22)
        a = tin*(1-tout)
        c.grp(0, 0, a)
        c.text(f"0{k+1}", 140, 330, 22, "Medium", WARM)
        c.rr(180, 329, 180+40*tin, 331, 1, fill=WARM)
        c.text(kick.upper() if False else kick, 236, 330, 22, "Medium", MUTED)
        c.grp(-tout*60, 0, 1-tout)
        c.text(l1, 140, 470, 100, "Medium", INK, reveal=pr(b, 0.0, 0.42))
        c.text(l2, 140, 590, 100, "Medium", INK, reveal=pr(b, 0.08, 0.5), grad=(k % 2 == 0) or True)
        c.grp((1-tin)*240 - tout*200, 0, a)
        fn(c, b)
        c.grp()
    # progress rail
    for k in range(4):
        b = t - (B0 + k*STEP)
        act = sm(pr(b, -0.05, 0.1))*(1-sm(pr(b, STEP-0.1, STEP+0.05)))
        w = 26 + 50*act
        x = 140 + sum(26+0 for _ in range(k)) + 0
    xr = 140
    for k in range(4):
        b = t - (B0 + k*STEP)
        act = sm(pr(b, -0.05, 0.1))*(1-sm(pr(b, STEP-0.1, STEP+0.05)))
        w = 26 + 56*act
        c.rr(xr, 880, xr+w, 884, 2, fill=INK if act > 0.5 else (255, 255, 255, 50), a=0.9 if act > 0.5 else 1)
        xr += w + 12

# ------------------------------------------------ CLIP 4: settle
def lock(c, x, y, a=1.0):
    c.rr(x-9, y-6, x+9, y+10, 3, fill=INK, a=a)
    c.d.arc([c.X(x-6), c.Y(y-19), c.X(x+6), c.Y(y-3)], 180, 360, fill=c.col(INK, a), width=int(2.6*SS))
    c.line([(x-6, y-11), (x-6, y-6)], INK, 2.6, a=a); c.line([(x+6, y-11), (x+6, y-6)], INK, 2.6, a=a)

def clip4(c, t):
    rise = eo(pr(t, 0.0, 1.8))
    wave(c, t+9, 770+(1-rise)*300, 40, 7, a=sm(t/0.7), spacing=30, rmin=2.8, rmax=5.6)
    # chips row
    chips = [("Encrypted on your Mac", True, 0.9), ("Nothing is ever sent for you", False, 1.1), ("Made for macOS", False, 1.3)]
    wsum = 0; wd = []
    for tx, _, _ in chips:
        w = tw1(tx, 22)+ 52 + (30 if tx.startswith("Enc") else 0); wd.append(w); wsum += w
    xs = 960 - (wsum + 24*2)/2
    out = 1-sm(pr(t, 4.0, 4.4))
    for (tx, lk, ts), w in zip(chips, wd):
        q = eo(pr(t, ts, ts+0.5))*out
        c.grp(0, (1-q)*16, 1.0)
        c.rr(xs, 640, xs+w, 692, 26, fill=(255, 255, 255, 16), line=(255, 255, 255, 40), a=q)
        if lk:
            lock(c, xs+32, 666, a=q); c.text(tx, xs+56, 668, 22, "Medium", INK, a=q)
        else:
            c.text(tx, xs+w/2, 668, 22, "Medium", INK, a=q, align="c")
        c.grp()
        xs += w+24
    # titles
    to = 1-sm(pr(t, 4.0, 4.45))
    if to > 0:
        c.grp(0, -ei(pr(t, 4.0, 4.45))*40, to)
        wds = [("Find", 1.5), ("your", 1.68), ("focus.", 1.86)]
        sx = 960 - (sum(tw1(w, 150) for w, _ in wds) + 2*38)/2
        for w, ts in wds:
            q = pr(t, ts, ts+0.5)
            c.text(w, sx, 330, 150, "Medium", INK, reveal=q, scale=1+0.08*(1-eo(q))); sx += tw1(w, 150)+38
        wds = [("Let", 2.55), ("the", 2.7), ("rest", 2.85), ("settle.", 3.0)]
        sx = 960 - (sum(tw1(w, 150) for w, _ in wds) + 3*38)/2
        for w, ts in wds:
            q = pr(t, ts, ts+0.5)
            c.text(w, sx, 500, 150, "Medium", INK if w != "settle." else INK, reveal=q, grad=True, scale=1+0.08*(1-eo(q))); sx += tw1(w, 150)+38
        c.grp()
        for i, (sx_, sy_, sr, st) in enumerate([(1500, 250, 22, 2.2), (410, 440, 14, 3.1), (1620, 560, 12, 3.4)]):
            q = sm((t-st)/0.4)*(0.55+0.45*math.sin(t*3+i))*to
            c.star(sx_, sy_, sr, [VIOLET, WARM, TIDE[0]][i], a=q)
    # final
    f = pr(t, 4.35, 4.95)
    if f > 0:
        q = eo(f)
        c.logo(960, 290-(1-q)*20, 150, a=q)
        c.text("cove", 960, 470-(1-q)*20, 150, "Medium", INK, align="c", reveal=pr(t, 4.5, 5.0))
        c.text("covemail.xyz", 960, 610, 34, "Medium", INK, align="c", a=eo(pr(t, 4.9, 5.3)))
        c.text("for macOS", 960, 656, 26, "Regular", MUTED, align="c", a=eo(pr(t, 5.0, 5.4)))

def frame(i):
    T = i/FPS
    ci = min(3, int(T // SEG)); lt = T - ci*SEG
    c = C(bg())
    [clip1, clip2, clip3, clip4][ci](c, lt)
    im = c.img
    env = sm(lt/0.2)*sm((SEG-lt-1/FPS*0.0)/0.2)
    if env < 0.999:
        im = Image.blend(bg(), im, env)
    return im.reduce(SS).convert("RGB").tobytes()

if __name__ == "__main__":
    if sys.argv[1] == "still":
        for s in sys.argv[2:]:
            i = int(float(s)*FPS)
            Image.frombytes("RGB", (W, H), frame(i)).save(f"/private/tmp/cove-film-sonnet/still_{s}.png")
    else:
        out = sys.argv[2]
        p = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "30", "-i", "-",
            "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p", "-r", "30", "-g", "30",
            "-force_key_frames", "0,6,12,18", "-sc_threshold", "0", "-movflags", "+faststart", out], stdin=subprocess.PIPE)
        with Pool(max(1, os.cpu_count()-1)) as pool:
            for b in pool.imap(frame, range(FRAMES), chunksize=4):
                p.stdin.write(b)
        p.stdin.close(); p.wait()
