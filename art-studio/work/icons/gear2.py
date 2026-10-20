#!/usr/bin/env python3
"""Gear icons, second round: more carefully made. Three designs; all turn by one step on a tap and end exactly where they began."""
import sys, os, math
import numpy as np
from gear_icons import *
from gear_icons import gear_mask, bevel, pearl_grad, glyph_glow, compose, ease_io
from icons_render import X, Y, PPT, cov, capsule, gblur, to_png, smoothstep

N_TURN = 24


def hub_shade(lum, m, r_hole, lit):
    """Dark inner edge of the hub hole: the hole is cut deep."""
    r = np.hypot(X, Y)
    inner = np.clip(1 - (r - r_hole) / 2.2, 0, 1) * (r > r_hole - 0.3)
    return lum * (1 - 0.42 * inner * m)


def classic2(rot=0.0, lit=1.0):
    m = gear_mask(rot, base=15.5, tip=21.2, tooth=0.31, edge=0.13, hole=5.8)
    r = np.hypot(X, Y)
    lum = bevel(m, lit, depth=1.3)
    groove = np.clip(1 - np.abs(r - 10.4) / 0.55, 0, 1)                 # an engraved ring
    lum = lum * (1 - 0.34 * groove * m)
    lum = lum + np.clip(1 - np.abs(r - 11.4) / 0.5, 0, 1) * 0.10 * m * (0.3 + 0.7 * lit)      # its lit lip
    return hub_shade(lum, m, 5.8, lit), m


def pair(rot=0.0, lit=1.0):
    """rot: how far the big gear has turned (radians); the small one turns the other way, 8/6 as far, so the teeth keep meshing."""
    ax, ay, bx, by = -6.8, -6.2, 11.0, 10.2
    phi = math.atan2(by - ay, bx - ax)
    a0 = phi % (2 * math.pi / 8)
    b0 = (phi + math.pi + math.pi / 6) % (2 * math.pi / 6)
    def at(cx, cy, **kw):                                               # a gear centred at (cx, cy): shift the coordinate grids
        global X, Y
        return None
    # draw the two gears on shifted grids
    import icons_render as IR
    X0, Y0 = IR.X, IR.Y
    def mask(cx, cy, rotation, base, tip, teeth, hole, tooth=0.32):
        r = np.hypot(X0 - cx, Y0 - cy); th = np.arctan2(Y0 - cy, X0 - cx) - rotation
        t = (th * teeth / (2 * math.pi) + 0.5) % 1 - 0.5
        s = np.clip((tooth - np.abs(t)) / 0.14 + 0.5, 0, 1); s = s * s * (3 - 2 * s)
        m = cov(base + (tip - base) * s - r, 1.1) * (1 - cov(hole - r, 1.1))
        return m.astype(np.float32)
    mA = mask(ax, ay, a0 + rot, 13.0, 18.0, 8, 4.4)
    mB = mask(bx, by, b0 - rot * 8 / 6, 8.4, 12.2, 6, 3.0, 0.34)
    m = np.clip(np.maximum(mA, mB), 0, 1)
    lum = bevel(m, lit, depth=1.1)
    # a thin dark seam where the teeth meet, so that the two gears read as two
    seam = np.clip(mA * mB * 2.0, 0, 1)
    lum = lum * (1 - 0.30 * gblur(seam, 0.5 * PPT) * m)
    return lum, m


def dial(rot=0.0, lit=1.0):
    r = np.hypot(X, Y)
    m = gear_mask(rot, base=11.6, tip=16.2, tooth=0.32, edge=0.14, hole=3.8)
    ring = cov(24.6 - r, 1.1) * (1 - cov(23.0 - r, 1.1))
    ticks = np.zeros_like(m)
    for i in range(12):
        th = i * math.pi / 6 + math.pi / 12
        ticks = np.maximum(ticks, cov(capsule(math.cos(th) * 19.0, math.sin(th) * 19.0, math.cos(th) * 20.8, math.sin(th) * 20.8, 0.62), 1.1))
    allm = np.clip(np.maximum(np.maximum(m, ring), ticks), 0, 1)
    lum = bevel(allm, lit, depth=1.0)
    return hub_shade(lum, m, 3.8, lit), allm


DESIGNS = {'classic2': classic2, 'pair': pair, 'dial': dial}


def render(name, rot=0.0, lit=1.0):
    pre, a = DESIGNS[name](rot, lit)
    return compose([(pre, a)], lit=lit, glow=glyph_glow(a, 0.20))


def render_all(root):
    for name in DESIGNS:
        d = os.path.join(root, name); os.makedirs(d, exist_ok=True)
        to_png(*render(name), os.path.join(d, 'gear.png'), 1)
        to_png(*render(name, lit=0.0), os.path.join(d, 'gear-off.png'), 2)
        step = (math.pi / 4) if name != 'dial' else (math.pi / 4)
        for i in range(N_TURN):
            u = i / (N_TURN - 1)
            rot = step * ease_io(u)
            pre, a = render(name) if i in (0, N_TURN - 1) else render(name, rot)
            to_png(pre, a, os.path.join(d, 't%02d.png' % i), 10 + i)
        print(name, 'ok', flush=True)


if __name__ == '__main__':
    os.makedirs(sys.argv[1], exist_ok=True)
    render_all(sys.argv[1])
