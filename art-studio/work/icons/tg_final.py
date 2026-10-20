#!/usr/bin/env python3
"""Telegram step icon, second round: a flat-ish paper plane in the pose of the well-known icon (nose to the upper right at about 20 degrees,
a long wing to the left, the other half hanging down, a slit between them), drawn here with our own light; and a calmer, stricter tap animation
in which the plane and the muzzle never meet."""
import sys, os, math
import numpy as np
from tg_morph import *
from tg_morph import face_layer, disc_layer, compose, finish_plain
from morph_render import xform, over, add_glow, ease_in, ease_out, ease_io, clip01

OUT_N, IN_N, REST_N = 30, 30, 10
NAMES = ('thru', 'arc', 'level')
UNITS = 0.46                                                    # points per drawing unit (the size of the plane)
FACE_CY = 1.0                                                   # where the muzzle sits, points below the middle of the disc
CEN = (50.0, 53.0)                                              # the middle of the drawing (units)
POLY = {                                                        # the plane, in drawing units (x right, y down)
    'wing': [(94, 14), (6, 50), (10, 56), (30, 58), (66, 37)],       # the long upper wing
    'body': [(94, 14), (66, 37), (44, 66), (80, 92), (92, 80)],      # the big lower half
    'fold': [(66, 37), (30, 58), (44, 66)],                          # the dark inside of the slit
}


def face_at(mz, flash=0.0):
    f = face_layer(cy=FACE_CY)
    return xform(f, mz.get('scale', 1.0), rot=mz.get('rot', 0.0), dx=mz.get('dx', 0.0), dy=mz.get('dy', 0.0))


def set_look(units, face_cy):
    global UNITS, FACE_CY
    UNITS, FACE_CY = units, face_cy
    _plane.clear()


def U(p):
    return ((p[0] - CEN[0]) * UNITS, (p[1] - CEN[1]) * UNITS)


def poly_mask(pts):
    px = np.array([U(p)[0] for p in pts], np.float32); py = np.array([U(p)[1] for p in pts], np.float32)
    x0, x1 = px.min() - 3, px.max() + 3; y0, y1 = py.min() - 3, py.max() + 3
    sel = (X >= x0) & (X <= x1) & (Y >= y0) & (Y <= y1)
    inside = np.zeros(X.shape, bool)
    n = len(px)
    for i in range(n):
        ax, ay, bx, by = px[i], py[i], px[(i + 1) % n], py[(i + 1) % n]
        if ay == by: continue
        cond = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / (by - ay) + ax)
        inside ^= (cond & sel)
    return inside.astype(np.float32)


def soft(m, r=0.9):
    """Round the corners a little (like paper that is folded, not cut) and anti-alias the edge."""
    g = gblur(m, r * PPT)
    G = np.clip((g - 0.5) * 3.2 + 0.5, 0, 1)
    gy, gx = np.gradient(gblur(m, r * PPT))
    dist = (g - 0.5) / (np.hypot(gx, gy) + 1e-6)
    return np.clip(0.5 + dist / 1.1, 0, 1).astype(np.float32)


_plane = {}
PLANE_SHIFT = (-2.9, 1.0)                                       # points: placed the way the plane stands in the Telegram icon (its box a little left of and below the middle), not by its box alone


def segment_dist(a, b):
    ax, ay = U(a); bx, by = U(b)
    px, py = X - ax, Y - ay; ex, ey = bx - ax, by - ay
    t = np.clip((px * ex + py * ey) / (ex * ex + ey * ey), 0, 1)
    return np.hypot(px - t * ex, py - t * ey)


def plane_sprite(lit=1.0):
    if lit in _plane: return _plane[lit]
    k = 0.30 + 0.70 * lit
    wing_raw = poly_mask(POLY['wing']); body_raw = poly_mask(POLY['body']); fold = soft(poly_mask(POLY['fold']), 0.5)
    shape = soft(np.maximum(wing_raw, body_raw), 0.45)                  # ONE silhouette, so the nose stays sharp and whole
    wing_w = np.clip(soft(wing_raw, 0.35) * shape, 0, 1)
    ux, uy = U((6, 50)); nx, ny = U((94, 14))
    t = np.clip(((X - ux) * (nx - ux) + (Y - uy) * (ny - uy)) / ((nx - ux) ** 2 + (ny - uy) ** 2), 0, 1)
    wing_l = 0.93 + 0.07 * t - 0.10 * (1 - t) ** 3
    by0, by1 = U((80, 92))[1], U((94, 14))[1]
    v = np.clip((Y - by1) / (by0 - by1), 0, 1)
    body_l = 0.88 - 0.30 * v ** 1.2
    lum = wing_w * wing_l + (1 - wing_w) * shape * body_l
    # the fold is a soft crease along the edge between the two halves, not a gap
    crease = np.exp(-(segment_dist((66, 37), (94, 14)) / 0.45) ** 2)
    lum = lum * (1 - 0.16 * crease * shape)
    lum = lum * (1 - fold * (1 - shape)) + 0.10 * fold * (1 - shape)
    up = np.clip(shape - gblur(shape, 1.6 * PPT), 0, 1)
    lum = lum + up * 0.10
    lum = np.clip(lum, 0, 1) * (0.30 + 0.70 * k)
    out = ((lum * shape).astype(np.float32), shape.astype(np.float32))
    _plane[lit] = out
    return out


NOSE = (88.0, -36.0); _n = math.hypot(*NOSE); NOSE_DIR = (NOSE[0] / _n, NOSE[1] / _n)         # the way the nose points (screen, y down)


UPN = (NOSE_DIR[1], -NOSE_DIR[0])                               # the direction "up" for the plane, across its flight line (screen: up and to the left)


def plane_at(scale=1.0, dist=0.0, alpha=1.0, lat=0.0, rot=0.0):
    """The plane moved along its flight line by dist and across it by lat (points), scaled and turned (radians, clockwise on the screen)."""
    dx = NOSE_DIR[0] * dist + UPN[0] * lat + PLANE_SHIFT[0]; dy = NOSE_DIR[1] * dist + UPN[1] * lat + PLANE_SHIFT[1]
    pre, a = xform(plane_sprite(), scale, rot=rot, dx=dx, dy=dy)
    return pre * alpha, a * alpha


def ease(u): return ease_io(clip01(u))


# --- three ways of flying away and coming back. 't' runs 0..1 over the whole half; the plane flies in the first half of "out" and the second half of "in".
def ease_out3(u): return 1 - (1 - clip01(u)) ** 3
def ease_in3(u): return clip01(u) ** 3
MZ_OUT, MZ_IN = 0.50, 0.42                 # when the muzzle starts to come up / has gone


def muzzle_out(t):
    um = ease((t - MZ_OUT) / (1 - MZ_OUT)); return dict(dy=12 * (1 - um), alpha=um, present=um > 0)


def muzzle_in(t):
    um = ease(t / MZ_IN); return dict(dy=12 * um, alpha=1 - um, present=um < 1)


def out_pose(name, t):
    u = clip01(t / 0.46)
    if name == 'thru':           # straight along its flight line, through the edge of the disc
        e = ease_in3(u) * 0.85 + ease(u) * 0.15
        plane = dict(dist=64 * e, scale=1.0, alpha=1.0, lat=0.0, rot=0.0)
    elif name == 'arc':          # climbs: the path bends up and the nose lifts a little
        e = ease_in3(u) * 0.8 + ease(u) * 0.2
        plane = dict(dist=62 * e, scale=1.0 - 0.10 * e, alpha=1.0, lat=18 * e * e, rot=math.radians(-11) * e)
    else:                        # 'level': leaves level and straight, but a touch slower to start and with a hint of the nose rising
        e = ease(u)
        plane = dict(dist=64 * e, scale=1.0, alpha=1.0, lat=0.0, rot=math.radians(-4) * math.sin(math.pi * u) ** 2)
    return plane, muzzle_out(t)


def in_pose(name, t):
    u = clip01((t - 0.46) / 0.54); e = ease_out3(u)
    if name == 'thru':           # comes in along the same line from the lower left and slows down
        plane = dict(dist=-64 * (1 - e), scale=1.0, alpha=1.0, lat=0.0, rot=0.0)
    elif name == 'arc':          # swoops in from below, levels out and settles; the nose is a little down at first
        plane = dict(dist=-62 * (1 - e), scale=1.0 + 0.06 * (1 - e), alpha=1.0, lat=-16 * (1 - e) ** 2, rot=math.radians(10) * (1 - e))
    else:                        # comes in from the left at the height of its place, slows down and rocks once as it settles
        rock = math.radians(5) * (1 - e) * math.cos(2.6 * math.pi * e)
        plane = dict(dist=-64 * (1 - e), scale=1.0, alpha=1.0, lat=-6 * (1 - e), rot=rock)
    return plane, muzzle_in(t)


def smooth_step(a, b, x):
    t = clip01((x - a) / (b - a)); return t * t * (3 - 2 * t)


def layers_for(pose):
    plane, muzzle = pose
    p = plane_at(plane['scale'], plane['dist'], plane['alpha'], plane.get('lat', 0.0), plane.get('rot', 0.0)) if plane['alpha'] > 0.003 else None
    if muzzle.get('present', True) and muzzle['alpha'] > 0.003:
        pre, a = face_at(dict(scale=1.0, dy=muzzle['dy']))
        m = (pre * muzzle['alpha'], a * muzzle['alpha'])
    else:
        m = None
    return p, m


def build_frame(name, direction, i, n):
    t = i / (n - 1)
    plane_l, muz_l = layers_for((out_pose if direction == 'out' else in_pose)(name, t))
    objs = [l for l in (plane_l, muz_l) if l is not None]
    return compose(objs), plane_l, muz_l


def overlap(plane_l, muz_l, da):
    """How many pixels (of the 160 x 160 picture) are covered by both the plane and the muzzle, inside the disc; with a 1 pt margin."""
    if plane_l is None or muz_l is None: return 0.0
    pm = gblur((plane_l[1] * da > 0.04).astype(np.float32), 1.0 * PPT) > 0.15
    mm = (muz_l[1] * da > 0.04)
    return float((pm & mm).sum()) / (PPT * PPT / 4)           # in picture pixels (2 per point)


def render_all(root, check=True):
    _, da = disc_layer()
    sp = compose([plane_at()]); sf = compose([face_at(dict(scale=1.0))])
    to_png(*sp, os.path.join(root, 'plane.png'), 1); to_png(*sf, os.path.join(root, 'face.png'), 2)
    pre, a = compose([plane_at()], lit=0.0); to_png(pre, a, os.path.join(root, 'plane-off.png'), 3)
    report = {}
    for name in NAMES:
        d = os.path.join(root, name); os.makedirs(d, exist_ok=True)
        worst = 0.0
        for i in range(OUT_N):
            (pre, a), p, m = build_frame(name, 'out', i, OUT_N)
            if i == 0: pre, a = sp
            if i == OUT_N - 1: pre, a = sf
            worst = max(worst, overlap(p, m, da))
            to_png(pre, a, os.path.join(d, 'out%02d.png' % i), 10 + i)
        for i in range(IN_N):
            (pre, a), p, m = build_frame(name, 'in', i, IN_N)
            if i == 0: pre, a = sf
            if i == IN_N - 1: pre, a = sp
            worst = max(worst, overlap(p, m, da))
            to_png(pre, a, os.path.join(d, 'in%02d.png' % i), 50 + i)
        report[name] = worst
        print(name, 'worst overlap (px of 160x160): %.1f' % worst, flush=True)
    d = os.path.join(root, 'rest'); os.makedirs(d, exist_ok=True)
    for k in range(REST_N):
        pre, a = sf if k in (0, REST_N - 1) else compose([face_at(dict(scale=1.0 + 0.02 * math.sin(math.pi * k / (REST_N - 1)), dy=-0.6 * math.sin(math.pi * k / (REST_N - 1))))])
        to_png(pre, a, os.path.join(d, 'r%02d.png' % k), 90 + k)
    return report


if __name__ == '__main__':
    os.makedirs(sys.argv[1], exist_ok=True)
    print(render_all(sys.argv[1]))
