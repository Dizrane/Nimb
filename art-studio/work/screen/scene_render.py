#!/usr/bin/env python3
"""The YouTube and Discord scene: a black screen with a play button and a Discord-style mark, in the same clean black-and-white
style as the dog. Shapes follow the current app drawing (ScreenArt.swift); only the finish changes."""
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'halo'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'dog'))
from halo_render import smoothstep, downsample, png_bytes   # noqa: E402
from icon_render import gblur                                # noqa: E402

SS = 4
PPT = 2 * SS                                   # hi-res pixels per point
SC = 0.8                                       # the app draws the scene at 0.8
BOX = (152.0, 118.0)                           # the old drawing box, points
OUT_PT = (160, 132)                            # canvas in points
W, H = int(OUT_PT[0] * PPT), int(OUT_PT[1] * PPT)
OX = (OUT_PT[0] - BOX[0] * SC) / 2             # where the box starts on the canvas, points
OY = (OUT_PT[1] - BOX[1] * SC) / 2


def P(x, y):
    """Point of the old drawing box -> hi-res pixel."""
    return ((OX + x * SC) * PPT, (OY + y * SC) * PPT)


yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)


def bez(p0, p1, p2, p3, n=24):
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    p0, p1, p2, p3 = map(np.array, (p0, p1, p2, p3))
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def poly_mask(pts):
    """Even-odd fill of a polygon (hi-res pixel coordinates), anti-aliased by the supersampling."""
    px, py = pts[:, 0], pts[:, 1]
    x0, x1 = int(max(px.min() - 2, 0)), int(min(px.max() + 3, W)); y0, y1 = int(max(py.min() - 2, 0)), int(min(py.max() + 3, H))
    X = xx[y0:y1, x0:x1] + 0.5; Y = yy[y0:y1, x0:x1] + 0.5
    inside = np.zeros(X.shape, bool)
    n = len(px)
    for i in range(n):
        ax, ay, bx, by = px[i], py[i], px[(i + 1) % n], py[(i + 1) % n]
        if ay == by: continue
        cond = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / (by - ay) + ax)
        inside ^= cond
    out = np.zeros((H, W), np.float32); out[y0:y1, x0:x1] = inside
    return out


def rrect_sdf(x0, y0, x1, y1, r):
    """Signed distance (pixels, positive inside) of a rounded rectangle given in box points."""
    (a, b), (c, d) = P(x0, y0), P(x1, y1); r = r * SC * PPT
    cx, cy, hx, hy = (a + c) / 2, (b + d) / 2, (c - a) / 2, (d - b) / 2
    qx = np.abs(xx + 0.5 - cx) - (hx - r); qy = np.abs(yy + 0.5 - cy) - (hy - r)
    out = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    return -out


def tri_sdf(pts, rad):
    """Signed distance (positive inside) of a triangle inflated by rad pixels (rounded corners)."""
    pts = [np.array(p, np.float32) for p in pts]
    d = np.full((H, W), 1e9, np.float32); sgn = np.ones((H, W), np.float32)
    X = xx + 0.5; Y = yy + 0.5
    for i in range(3):
        a, b = pts[i], pts[(i + 1) % 3]
        e = b - a; w = np.stack([X - a[0], Y - a[1]])
        t = np.clip((w[0] * e[0] + w[1] * e[1]) / (e @ e), 0, 1)
        dist = np.hypot(X - (a[0] + t * e[0]), Y - (a[1] + t * e[1]))
        d = np.minimum(d, dist)
    # inside test by the signs of the cross products
    def cross(a, b): return (b[0] - a[0]) * (Y - a[1]) - (b[1] - a[1]) * (X - a[0])
    s = np.sign(cross(pts[0], pts[1])) + np.sign(cross(pts[1], pts[2])) + np.sign(cross(pts[2], pts[0]))
    inside = np.abs(s) == 3
    sd = np.where(inside, d, -d)
    return sd + rad


def aa(sd, soft=1.2):
    return np.clip(0.5 + sd / soft, 0, 1).astype(np.float32)


def discord_polygon():
    mx, my, mw, mh = 82.0, 64.0, 66.0, 50.0
    def M(x, y): return (mx + x / 100 * mw, my + y / 76 * mh)
    segs = [(M(21, 7), M(29, 3), M(36, 5), M(41, 9)), (M(41, 9), M(47, 8), M(53, 8), M(59, 9)), (M(59, 9), M(64, 5), M(71, 3), M(79, 7)),
            (M(79, 7), M(90, 15), M(97, 36), M(98, 58)), (M(98, 58), M(91, 63), M(83, 67), M(75, 70)), (M(75, 70), M(73, 67), M(71, 64), M(70, 62)),
            (M(70, 62), M(57, 66), M(43, 66), M(30, 62)), (M(30, 62), M(29, 64), M(27, 67), M(25, 70)), (M(25, 70), M(17, 67), M(9, 63), M(2, 58)),
            (M(2, 58), M(3, 36), M(10, 15), M(21, 7))]
    pts = np.concatenate([bez(*s, n=30) for s in segs])
    return np.array([P(x, y) for x, y in pts], np.float32), M


def build():
    sc = {}
    # --- the screen
    bez_sd = rrect_sdf(13, 6, 139, 94, 24)
    disp_sd = rrect_sdf(20, 13, 132, 87, 17)
    sc['bezel'] = aa(bez_sd); sc['display'] = aa(disp_sd)
    # --- the play button
    cx, cy = 73, 49
    tri = tri_sdf([P(cx - 11, cy - 17), P(cx + 17, cy), P(cx - 11, cy + 17)], 3.0 * SC * PPT)
    sc['play'] = aa(tri)
    # --- the mark
    poly, M = discord_polygon()
    mark = poly_mask(poly)
    sc['mark'] = mark
    sc['mark_outline'] = (gblur(mark, 22) > 0.2).astype(np.float32)
    eyes = np.zeros((H, W), np.float32)
    for ex in (35.0, 65.0):
        ecx, ecy = P(*M(ex, 36.25)); rx, ry = 4.6 * SC * PPT, 6.25 * SC * PPT
        eyes = np.maximum(eyes, aa(1 - np.sqrt(((xx + 0.5 - ecx) / rx) ** 2 + ((yy + 0.5 - ecy) / ry) ** 2)) * 0 + aa((1 - np.sqrt(((xx + 0.5 - ecx) / rx) ** 2 + ((yy + 0.5 - ecy) / ry) ** 2)) * rx))
    sc['eyes'] = eyes
    return sc


def render(sc, lit=1.0, glow=True):
    k = 0.30 + 0.70 * lit
    a_bezel, a_disp, a_play, a_mark, a_out, a_eyes = sc['bezel'], sc['display'], sc['play'], sc['mark'], sc['mark_outline'], sc['eyes']
    (bx0, by0), (bx1, by1) = P(13, 6), P(139, 94)
    u = np.clip((yy - by0) / (by1 - by0), 0, 1); xn = (xx - (bx0 + bx1) / 2) / ((bx1 - bx0) / 2)
    # bezel: black with a soft light from the halo above and a velvet sheen along the edge
    inner = gblur(a_bezel, 0.12 * (bx1 - bx0) / 2)
    sheen = np.clip(1 - (inner - 0.5) * 2.4, 0, 1) ** 1.6
    top_glow = np.exp(-(((xn + 0.1) / 0.8) ** 2 + ((u - 0.05) / 0.35) ** 2))
    bez = (0.016 + 0.035 * (1 - u) + 0.10 * top_glow + 0.17 * sheen * (0.3 + 0.7 * (1 - u))) * (0.35 + 0.65 * k)
    # the glass: dark, a faint diagonal reflection
    gu = np.clip((yy - P(0, 13)[1]) / (P(0, 87)[1] - P(0, 13)[1]), 0, 1)
    glass = 0.115 * (1 - gu) + 0.02 * gu
    band = np.exp(-(((xx - bx0) - 0.55 * (by1 - yy) - 0.18 * (bx1 - bx0)) / (0.07 * (bx1 - bx0))) ** 2) * 0.05
    glass = (glass + band) * (0.4 + 0.6 * k)
    lum = bez * (1 - a_disp) + glass * a_disp
    # the edge of the glass: a thin light line
    gedge = np.clip(a_disp - gblur(a_disp, 1.4 * SS), 0, 1)
    lum += gedge * 0.10 * k
    # the play button: pearl with a soft glow
    (px0, py0), (px1, py1) = P(62, 32), P(90, 66)
    pu = np.clip((yy - py0) / (py1 - py0), 0, 1)
    pearl = (0.99 - 0.34 * pu) * (0.35 + 0.65 * k)
    play_glow = gblur(a_play, 9 * SC * PPT * 0.9) * 0.55 * lit + gblur(a_play, 3 * PPT) * 0.25 * lit
    lum = lum * (1 - a_play) + pearl * a_play + play_glow * (1 - a_play) * a_disp
    # the mark: pearl, a dark outline that separates it from the screen, two dark eyes
    (mx0, my0), (mx1, my1) = P(82, 64), P(148, 114)
    mu = np.clip((yy - my0) / (my1 - my0), 0, 1)
    mpearl = (0.99 - 0.33 * mu) * (0.35 + 0.65 * k)
    # a hint of shade where the mark meets the screen
    lum = lum * (1 - a_out * (1 - a_mark)) + 0.0 * a_out * (1 - a_mark)
    lum = lum * (1 - a_mark) + mpearl * a_mark
    ey = 0.30 * (1 - np.clip((yy - P(0, 74)[1]) / (P(0, 88)[1] - P(0, 74)[1]), 0, 1)) + 0.04
    lum = lum * (1 - a_eyes * a_mark) + ey * a_eyes * a_mark
    # thin rim light on the outline of the bezel
    edge = np.clip(a_bezel - gblur(a_bezel, 1.8 * SS), 0, 1)
    up = np.clip(-np.gradient(gblur(a_bezel, 3.0 * SS), axis=0), 0, 1); up /= up.max() + 1e-6
    left = np.clip(-np.gradient(gblur(a_bezel, 3.0 * SS), axis=1), 0, 1); left /= left.max() + 1e-6
    lum += edge * (0.12 + 0.55 * np.maximum(up, 0.7 * left)) * k * (1 - a_mark)
    lum = np.clip(lum, 0, 1)
    alpha = np.clip(np.maximum(a_bezel, a_mark), 0, 1)
    pre = lum * alpha
    if glow:
        g = gblur(alpha, 0.09 * (bx1 - bx0) / 2 * 1.3) * (0.05 + 0.09 * lit) * 0.9
        ga = np.clip(g, 0, 0.5) * (1 - alpha); pre = pre + ga; alpha = alpha + ga
    return pre.astype(np.float32), alpha.astype(np.float32)


def to_png(pre, alpha, path, seed=0):
    p = downsample(pre, SS); a = downsample(alpha, SS)
    straight = np.where(a > 1e-4, p / np.maximum(a, 1e-4), 0)
    rng = np.random.default_rng(seed)
    q = np.clip(np.round(straight * 255 + (rng.random(a.shape) - 0.5)), 0, 255).astype(np.uint8)
    qa = np.clip(np.round(a * 255 + (rng.random(a.shape) - 0.5) * (a > 0.002)), 0, 255).astype(np.uint8)
    rgba = np.empty(a.shape + (4,), np.uint8); rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = q; rgba[..., 3] = qa
    open(path, 'wb').write(png_bytes(rgba))


def on_black(pre, path):
    p = np.clip(downsample(pre, SS), 0, 1); g = np.clip(np.round(p * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    open(path, 'wb').write(png_bytes(rgba))


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    sc = build()
    pre, a = render(sc, 1.0); on_black(pre, os.path.join(out, 'scene_test.png'))
