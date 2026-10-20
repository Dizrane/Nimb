#!/usr/bin/env python3
"""The click animation of the "Нейросети" icon: the flower becomes the planet and, after a moment, the planet becomes the flower.
Three ways of doing the change. Frames are rendered here (numpy); the reverse change is the same frames played backwards."""
import sys, os, math
import numpy as np
from icons_render import *
from icons_render import _noise3                                # noqa: F401
from halo_render import bilinear                                # noqa: E402

FRAMES = 24          # frames of one change (flower -> planet); 24 fps = one second
HOLD = 12            # frames of the planet resting (a slow rock of the globe)
SPIN0 = -0.3         # the orientation of the planet at rest (the same as the still icon)


def flower_layers(lit=1.0):
    """Disc, flower glyph and the whole icon as separate premultiplied layers."""
    lum_d, a = base_disc(lit)
    k = 0.30 + 0.70 * lit
    glyph = np.zeros_like(lum_d)
    for i in range(6):
        th = math.radians(-90 + 60 * i)
        glyph = np.maximum(glyph, cov(vesica(th, 3.2, 18.5, 7.4)))
    for i in range(6):
        th = math.radians(-60 + 60 * i); ux, uy = math.cos(th), math.sin(th)
        glyph = np.maximum(glyph, cov(capsule(ux * 17.0, uy * 17.0, ux * 24.0, uy * 24.0, 0.8)))
        glyph = np.maximum(glyph, cov(disc(ux * 25.0, uy * 25.0, 1.3)))
    core = cov(disc(0, 0, 2.0))
    shade = pearl() * (0.35 + 0.65 * k)
    glow = gblur(glyph, 2.2 * PPT) * 0.30 * lit
    pre_glyph = (shade * glyph + glow * a) * 1.0
    a_glyph = np.clip(glyph + glow * a * 0.0, 0, 1)
    pre_disc = np.clip(lum_d, 0, 1) * a
    # the whole icon, as in ai_flower
    pre_icon, a_icon = ai_flower(lit)
    return dict(disc=(pre_disc.astype(np.float32), a.astype(np.float32)), glyph=(pre_glyph.astype(np.float32), a_glyph.astype(np.float32)), icon=(pre_icon, a_icon))


def xform(layer, scale=1.0, rot=0.0, sx=1.0, dx=0.0, dy=0.0):
    """Scale (and squash across, sx), rotate (radians) and move a layer about the middle of the picture."""
    pre, a = layer
    if scale <= 1e-3 or sx <= 1e-3:
        z = np.zeros_like(pre); return z, z
    u = (X - dx) / (scale * sx); v = (Y - dy) / scale
    c, s = math.cos(rot), math.sin(rot)
    xs = u * c + v * s; ys = -u * s + v * c
    px = C + xs * PPT - 0.5; py = C + ys * PPT - 0.5
    return bilinear(pre, px, py), bilinear(a, px, py)


def over(top, bottom):
    pt, at = top; pb, ab = bottom
    return pt + pb * (1 - at), at + ab * (1 - at)


def add_glow(layer, g):
    pre, a = layer
    g = np.clip(g, 0, 1)
    return pre + g * (1 - a), a + g * (1 - a)


def ease_in(u): return u * u
def ease_out(u): return 1 - (1 - u) ** 3
def ease_io(u): return u * u * (3 - 2 * u)
def ease_out_back(u, k=1.9): u = u - 1; return 1 + (k + 1) * u ** 3 + k * u ** 2


_planet_cache = {}
def planet_layer(spin, lit=1.0):
    key = round(spin, 3)
    if key not in _planet_cache:
        _planet_cache[key] = planet(lit, False, spin=spin)
    return _planet_cache[key]


def v_shrink(t, L):
    """The icon folds into a point with a flash, and the planet grows out of the point (with a little overshoot)."""
    if t < 0.44:
        u = t / 0.44; e = ease_in(u)
        s = max(1 - e, 0.0)
        flower = over(xform(L['glyph'], s, rot=math.radians(120) * e), xform(L['disc'], s))
        out = flower
        f = math.exp(-((t - 0.44) / 0.10) ** 2)
        g = np.exp(-(np.hypot(X, Y) / (2.5 + 5 * e)) ** 2) * 0.9 * (0.25 + 0.75 * e)
        return add_glow(out, g)
    u = (t - 0.44) / 0.56
    s = ease_out_back(u)
    spin = SPIN0 - 1.3 * (1 - ease_out(u))
    pl = xform(planet_layer(spin), max(s, 0.0))
    g = np.exp(-(np.hypot(X, Y) / (3 + 7 * u)) ** 2) * 0.8 * math.exp(-u * 5)
    return add_glow(pl, g)


def v_iris(t, L):
    """The flower turns and shrinks to the middle while the planet opens from the middle like an iris, with a thin bright ring at its edge."""
    e = ease_io(clip01(t / 0.7))
    flower = over(xform(L['glyph'], max(1 - 0.98 * e, 0.0), rot=math.radians(150) * e), L['disc'])
    ri = R * 1.03 * ease_out(clip01((t - 0.18) / 0.82))
    dist = np.hypot(X, Y)
    mask = np.clip((ri - dist) * PPT / 1.4 + 0.5, 0, 1)
    spin = SPIN0 - 0.9 * (1 - ease_out(t))
    pp, pa = planet_layer(spin)
    inner = (pp * mask, pa * mask)
    out = over(inner, flower)
    ring = np.exp(-((dist - ri) / 0.9) ** 2) * 0.85 * math.sin(math.pi * clip01(t)) ** 0.7 * (ri > 0.5)
    return add_glow(out, ring * (dist < R))


def v_coin(t, L):
    """The disc turns over like a coin: the flower on one side, the planet on the other; it dips a little in size at the turn."""
    phi = math.pi * t
    cx = abs(math.cos(phi))
    s = 1 - 0.20 * math.sin(phi)
    if t < 0.5:
        layer = L['icon']
    else:
        spin = SPIN0 - 0.8 * (1 - ease_out((t - 0.5) / 0.5))
        layer = planet_layer(spin)
    pre, a = xform(layer, s, sx=max(cx, 0.0))
    dim = 0.55 + 0.45 * cx
    out = (pre * dim, a)
    edge = np.exp(-(X / 0.9) ** 2) * (np.abs(Y) < 24 * s) * math.sin(phi) ** 6 * 0.9
    return add_glow(out, edge)


def clip01(x): return min(max(x, 0.0), 1.0)


VARIANTS = {'shrink': v_shrink, 'iris': v_iris, 'coin': v_coin}


def render_all(root):
    L = flower_layers(1.0)
    planet_rest = planet_layer(SPIN0)
    for name, fn in VARIANTS.items():
        out = os.path.join(root, name); os.makedirs(out, exist_ok=True)
        for i in range(FRAMES):
            t = i / (FRAMES - 1)
            pre, a = fn(t, L)
            if i == 0: pre, a = L['icon']                       # the first frame is exactly the still flower
            if i == FRAMES - 1: pre, a = planet_rest            # the last one exactly the still planet
            to_png(pre, a, os.path.join(out, 'f%02d.png' % i), i)
        print(name, 'ok', flush=True)
    hold = os.path.join(root, 'hold'); os.makedirs(hold, exist_ok=True)
    for k in range(HOLD):
        spin = SPIN0 + 0.22 * math.sin(math.pi * k / (HOLD - 1))
        pre, a = planet_layer(spin) if k not in (0, HOLD - 1) else planet_rest
        to_png(pre, a, os.path.join(hold, 'h%02d.png' % k), 50 + k)
    pre, a = L['icon']; to_png(pre, a, os.path.join(root, 'flower.png'), 1)
    pre, a = planet_rest; to_png(pre, a, os.path.join(root, 'planet.png'), 2)
    print('hold ok')


if __name__ == '__main__':
    render_all(sys.argv[1])
