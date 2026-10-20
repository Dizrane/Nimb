#!/usr/bin/env python3
"""The gear of the last step ("Чтобы работало само"): a drawn gear in the same black glass disc, white, lit from above-left.
Eight teeth, so a turn of 45 degrees looks exactly like the start: the tap animation is one tooth, and it loops without a seam."""
import sys, os, math
import numpy as np
from icons_render import *
from tg_final import compose, soft
from tg_morph import disc_layer
from yd_icons import poly_mask_pts, glyph_glow

TEETH = 8
RADIUS = dict(base=15.0, tip=20.5)


def gear_mask(rot=0.0, base=15.0, tip=21.0, tooth=0.34, edge=0.14, hole=5.2, ring=None):
    """Coverage of a gear turned by rot radians. tooth: share of the pitch the tooth takes at its root; hole: radius of the hub hole."""
    r = np.hypot(X, Y); th = np.arctan2(Y, X) - rot
    t = (th * TEETH / (2 * math.pi) + 0.5) % 1 - 0.5                       # -0.5..0.5 across a tooth
    s = np.clip((tooth - np.abs(t)) / edge + 0.5, 0, 1)                    # 1 on the tooth, 0 between teeth, soft sides
    s = s * s * (3 - 2 * s)
    rg = base + (tip - base) * s
    m = cov(rg - r, 1.1)
    if hole > 0: m = m * (1 - cov(hole - r, 1.1))
    if ring is not None:                                                    # an inner ring: remove the body between ring[0] and ring[1]
        m = m * (1 - cov(np.minimum(r - ring[0], ring[1] - r), 1.1))
    return m.astype(np.float32)


def bevel(m, lit=1.0, depth=1.2):
    """Light on a flat shape as if it were embossed a little: bright on the edges that face the light (upper left), dark on the others."""
    k = 0.30 + 0.70 * lit
    g = gblur(m, depth * PPT)
    gy, gx = np.gradient(g)
    nx, ny = -gx * 18, -gy * 18
    L = np.array([-0.55, -0.70, 0.45]); L /= np.linalg.norm(L)
    lam = np.clip((nx * L[0] + ny * L[1] + 1.0 * L[2]) / np.sqrt(nx * nx + ny * ny + 1), 0, 1)
    base = 0.95 + 0.20 * (lam - L[2])
    top = pearl_grad(-22, 22, 1.0, 0.80)
    lum = np.clip(base * top, 0, 1) * (0.34 + 0.66 * k)
    return (lum * m).astype(np.float32)


def pearl_grad(y0, y1, hi=0.99, lo=0.68):
    return hi + (lo - hi) * np.clip((Y - y0) / (y1 - y0), 0, 1)


def check_mask(cx=0.0, cy=0.0, size=6.5):
    """A rounded check mark."""
    a = capsule(cx - size * 0.55, cy + size * 0.05, cx - size * 0.12, cy + size * 0.5, 0.95)
    b = capsule(cx - size * 0.12, cy + size * 0.5, cx + size * 0.62, cy - size * 0.42, 0.95)
    return np.maximum(cov(a, 1.1), cov(b, 1.1)).astype(np.float32)


def gear(variant, rot=0.0, lit=1.0):
    """Returns (premultiplied layer, glyph alpha) for one of the designs."""
    if variant == 'solid':            # classic: a solid gear with a hub hole
        m = gear_mask(rot, base=15.2, tip=21.0, hole=5.4)
        return bevel(m, lit), m
    if variant == 'ring':             # lighter: a ring-shaped gear, teeth outside and a thin hub ring inside, spokes between
        m = gear_mask(rot, base=15.4, tip=21.0, hole=0.0, ring=(7.6, 12.6))
        hub = cov(7.6 - np.hypot(X, Y), 1.1) * (1 - cov(3.8 - np.hypot(X, Y), 1.1))
        spokes = np.zeros_like(m)
        for i in range(4):
            th = rot + math.pi / 4 + i * math.pi / 2
            spokes = np.maximum(spokes, cov(capsule(math.cos(th) * 7, math.sin(th) * 7, math.cos(th) * 13, math.sin(th) * 13, 1.3), 1.1))
        m = np.clip(np.maximum(np.maximum(m, hub), spokes), 0, 1)
        return bevel(m, lit), m
    if variant == 'check':            # a solid gear with a check mark in the hub (it works on its own); the check does not turn
        m = gear_mask(rot, base=15.2, tip=21.0, hole=8.6)
        chk = check_mask(0.2, 0.2, 7.0)
        body = bevel(m, lit)
        mm = np.clip(np.maximum(m, chk), 0, 1)
        chk_lum = pearl_grad(-8, 8, 1.0, 0.82) * (0.34 + 0.66 * (0.30 + 0.70 * lit)) * chk
        return (body * (1 - chk) + chk_lum).astype(np.float32), mm
    raise ValueError(variant)


def render(variant, rot=0.0, lit=1.0):
    pre, a = gear(variant, rot, lit)
    return compose([(pre, a)], lit=lit, glow=glyph_glow(a, 0.20))


VARIANTS = ('solid', 'ring', 'check')
N_TURN = 24


def ease_io(u): return u * u * (3 - 2 * u)


def render_all(root):
    for v in VARIANTS:
        d = os.path.join(root, v); os.makedirs(d, exist_ok=True)
        to_png(*render(v), os.path.join(d, 'gear.png'), 1)
        to_png(*render(v, lit=0.0), os.path.join(d, 'gear-off.png'), 2)
        for i in range(N_TURN):
            u = i / (N_TURN - 1)
            rot = (math.pi / 4) * (ease_io(u) + 0.06 * math.sin(2 * math.pi * u) * (1 - u) * u * 4 * 0)   # one tooth, eased
            pre, a = render(v) if i in (0, N_TURN - 1) else render(v, rot)
            to_png(pre, a, os.path.join(d, 't%02d.png' % i), 10 + i)
        print(v, 'ok', flush=True)


if __name__ == '__main__':
    os.makedirs(sys.argv[1], exist_ok=True)
    render_all(sys.argv[1])
