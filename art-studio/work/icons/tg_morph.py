#!/usr/bin/env python3
"""Telegram step icon: the paper plane (resting pose, like the well-known sideways plane), and on a tap it flies away into the distance,
the muzzle of the dog shows up for a couple of seconds, goes away, and the plane comes back and settles. Three ways of showing the muzzle."""
import sys, os, math
import numpy as np
from telegram_icons import *
from telegram_icons import mapped, finish_plain
from morph_render import xform, over, add_glow, ease_in, ease_out, ease_io, ease_out_back, clip01
from icons_render import _noise3                       # noqa: F401

OUT_N, IN_N, REST_N = 24, 24, 10
POSE = dict(roll=32.0, tilt=12.0, yaw=-40.0, length=36.0)
NOSE_DIR = (math.sin(math.radians(-POSE['yaw'])), -math.cos(math.radians(-POSE['yaw'])))        # the way the nose points, on the screen (y down)
_cache = {}


def disc_layer(lit=1.0):
    lum, a = base_disc(lit)
    return (np.clip(lum, 0, 1) * a).astype(np.float32), a.astype(np.float32)


def face_layer(lit=1.0, scale=0.215, cx=0.0, cy=1.0):
    """The pearl face with its glossy nose, on its own (premultiplied), placed as in the still icon."""
    key = ('face', lit, scale, cx, cy)
    if key in _cache: return _cache[key]
    k = 0.30 + 0.70 * lit
    face = mapped('face', 5.0, scale, cx, cy)
    nose = mapped('nose', 3.0, scale, cx, cy) * face
    ys, xs = np.nonzero(face > 0.5); fy0, fy1 = ys.min(), ys.max()
    u = np.clip((yy - fy0) / (fy1 - fy0), 0, 1)
    pearl_l = (0.97 - 0.22 * smoothstep(0.55, 1.0, u))
    pearl_l *= 0.58 + 0.42 * smoothstep(0.40, 0.97, gblur(face, 3.2 * PPT))
    pearl_l *= 1 - 0.5 * np.clip(gblur(np.roll(1 - face, int(1.8 * PPT), axis=0), 1.8 * PPT) * 1.3, 0, 1)
    pearl_l *= 0.34 + 0.66 * k
    nys, nxs = np.nonzero(nose > 0.5)
    ncx, ncy = (nxs.min() + nxs.max()) / 2, (nys.min() + nys.max()) / 2
    nrx, nry = (nxs.max() - nxs.min()) / 2, (nys.max() - nys.min()) / 2
    r2 = ((xx - ncx) / nrx) ** 2 + ((yy - ncy) / nry) ** 2
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    nxn, nyn = (xx - ncx) / nrx * 0.8, (yy - ncy) / nry * 0.8
    nl = np.sqrt(nxn ** 2 + nyn ** 2 + z ** 2 + 1e-6)
    h_ = np.array([-0.28, -0.62, 0.74]); h_ /= np.linalg.norm(h_)
    spec = np.clip((nxn * h_[0] + nyn * h_[1] + z * h_[2]) / nl, 0, 1) ** 38
    nose_l = 0.010 + 0.95 * spec * k + np.clip(-nyn / nl, 0, 1) ** 2 * 0.22 * k * 0.5
    lum = pearl_l * (1 - nose) + nose_l * nose
    out = ((lum * face).astype(np.float32), face.astype(np.float32))
    _cache[key] = out
    return out


def plane_layer(roll, tilt, yaw, length, lit=1.0):
    """The plane, on its own, centred on the middle of the disc."""
    k = 0.30 + 0.70 * lit
    PR.S = length * 2 * PR.SS / 2.0 * 1.02
    sh, al, P, mid = PR.render(PR.classic(), PR.LOOKS['paper'][1], roll_deg=roll, tilt_deg=tilt, yaw_deg=yaw)
    pre, alpha = PR.finish(sh, al)
    pad = (N - PR.N) // 2
    bp = np.zeros((N, N), np.float32); ba = np.zeros((N, N), np.float32)
    bp[pad:pad + PR.N, pad:pad + PR.N] = pre * (0.30 + 0.70 * k); ba[pad:pad + PR.N, pad:pad + PR.N] = alpha
    return bp, ba


_plane_off = None
def plane(roll=None, tilt=None, yaw=None, length=None, scale=1.0, dx=0.0, dy=0.0, alpha=1.0):
    """A plane in the given pose, recentred like the resting one, scaled and moved (points) and faded."""
    global _plane_off
    if _plane_off is None:
        pre, a = plane_layer(**POSE)
        ys, xs = np.nonzero(a > 0.3)
        _plane_off = (((xs.min() + xs.max()) / 2 - N / 2) / PPT + 0.6, ((ys.min() + ys.max()) / 2 - N / 2) / PPT - 0.6)      # a little up and to the right: the nose carries the eye
    p = dict(POSE)
    if roll is not None: p['roll'] = roll
    if tilt is not None: p['tilt'] = tilt
    if yaw is not None: p['yaw'] = yaw
    if length is not None: p['length'] = length
    pre, a = plane_layer(**p)
    pre, a = xform((pre, a), scale, dx=dx * 1.0 - _plane_off[0] * scale, dy=dy - _plane_off[1] * scale)
    return pre * alpha, a * alpha


def compose(objects, lit=1.0, glow=None):
    """objects: layers (premultiplied) drawn bottom to top over the disc, clipped to the disc."""
    dp, da = disc_layer(lit)
    out = (dp, da)
    for pre, a in objects:
        c = (pre * da, a * da)                                   # clipped to the disc
        out = over(c, out)
    pre, a = out
    if glow is not None:
        pre, a = add_glow((pre, a), glow * da)
    return finish_plain(pre, da)


def streak(p, back, length, strength):
    """A soft streak behind a flying plane: from p back along -direction."""
    x0, y0 = p; x1, y1 = p[0] - back[0] * length, p[1] - back[1] * length
    return np.clip(cov(capsule(x0, y0, x1, y1, 0.8)) * strength, 0, 1)


def leave(u):
    """The plane flies away to the upper right and into the distance: position along the nose direction, size, fade."""
    e = ease_in(u)
    dist = 27.0 * e
    s = 1.0 / (1.0 + 6.5 * e)
    a = 1.0 - smooth_step(0.72, 1.0, u)
    return dict(dx=NOSE_DIR[0] * dist, dy=NOSE_DIR[1] * dist, scale=s, alpha=a, roll=POSE['roll'] - 14 * e), e


def arrive(u):
    """It comes back from the lower left, near, and settles in the resting pose."""
    e = ease_out(u)
    dist = 40.0 * (1 - e)
    a = smooth_step(0.0, 0.25, u)
    return dict(dx=-NOSE_DIR[0] * dist, dy=-NOSE_DIR[1] * dist, scale=1.0 + 0.16 * (1 - e), alpha=a, roll=POSE['roll'] - 10 * (1 - e)), e


def smooth_step(a, b, x):
    t = clip01((x - a) / (b - a)); return t * t * (3 - 2 * t)


# --- three ways of showing the muzzle: (appear(u) -> transform of the face, vanish(u) -> transform)
def mz_peek(u, out=True):
    e = ease_out_back(u, 1.3) if out else ease_in(u)
    return dict(scale=1.0, dx=0.0, dy=38.0 * ((1 - e) if out else e))


def mz_grow(u, out=True):
    e = ease_out_back(u, 2.2) if out else 1 - ease_in(u)
    return dict(scale=max(e, 0.0), dx=0.0, dy=0.0, rot=math.radians(-90 * (1 - e)) if out else math.radians(90 * (1 - e)))


def mz_side(u, out=True):
    e = ease_out_back(u, 1.3) if out else ease_in(u)
    return dict(scale=1.0, dx=44.0 * ((1 - e) if out else e), dy=0.0, rot=math.radians(14 * ((1 - e) if out else e)))


VARIANTS = {'peek': mz_peek, 'grow': mz_grow, 'side': mz_side}


def face_at(mz, flash=0.0):
    f = face_layer()
    pre, a = xform(f, mz.get('scale', 1.0), rot=mz.get('rot', 0.0), dx=mz.get('dx', 0.0), dy=mz.get('dy', 0.0))
    return pre, a


def frame_out(name, i):
    t = i / (OUT_N - 1)
    pl = leave(clip01(t / 0.62))[0]
    objs = []
    glow = None
    um = clip01((t - 0.30) / 0.70)
    if um > 0:
        objs.append(face_at(VARIANTS[name](um, True)))
    if t < 0.62:
        d, e = leave(clip01(t / 0.62))
        p = plane(roll=d['roll'], dx=d['dx'], dy=d['dy'], scale=d['scale'], alpha=d['alpha'])
        # the plane is behind the muzzle when it is in the distance
        objs.insert(0, p)
        sk = streak((d['dx'], d['dy']), NOSE_DIR, 4 + 14 * e * (1 - e) * 2, 0.5 * e * (1 - e) * 4 * d['alpha'])
        glow = sk
    if name == 'grow' and 0.26 < t < 0.5:
        g = np.exp(-(np.hypot(X, Y) / 3.5) ** 2) * math.sin(math.pi * clip01((t - 0.26) / 0.24)) * 0.9
        glow = g if glow is None else np.maximum(glow, g)
    return compose(objs, glow=glow)


def frame_in(name, i):
    t = i / (IN_N - 1)
    objs = []
    glow = None
    um = clip01(t / 0.55)
    if um < 1:
        objs.append(face_at(VARIANTS[name](um, False)))
    up = clip01((t - 0.40) / 0.60)
    if up > 0:
        d, e = arrive(up)
        objs.append(plane(roll=d['roll'], dx=d['dx'], dy=d['dy'], scale=d['scale'], alpha=d['alpha']))
        glow = streak((d['dx'], d['dy']), NOSE_DIR, 12 * (1 - e), 0.4 * (1 - e))
    if name == 'grow' and 0.45 < t < 0.65:
        g = np.exp(-(np.hypot(X, Y) / 3.0) ** 2) * math.sin(math.pi * clip01((t - 0.45) / 0.2)) * 0.8
        glow = g if glow is None else np.maximum(glow, g)
    return compose(objs, glow=glow)


def still_plane():
    return compose([plane()])


def still_face():
    return compose([face_at(dict(scale=1.0))])


def frame_rest(k):
    s = 1.0 + 0.03 * math.sin(math.pi * k / (REST_N - 1))
    dy = -0.7 * math.sin(math.pi * k / (REST_N - 1))
    return compose([face_at(dict(scale=s, dy=dy))])


def render_all(root):
    sp, sf = still_plane(), still_face()
    to_png(*sp, os.path.join(root, 'plane.png'), 1); to_png(*sf, os.path.join(root, 'face.png'), 2)
    pre, a = compose([plane()], lit=0.0); to_png(pre, a, os.path.join(root, 'plane-off.png'), 3)
    for name in VARIANTS:
        d = os.path.join(root, name); os.makedirs(d, exist_ok=True)
        for i in range(OUT_N):
            pre, a = sp if i == 0 else sf if i == OUT_N - 1 else frame_out(name, i)
            to_png(pre, a, os.path.join(d, 'out%02d.png' % i), 10 + i)
        for i in range(IN_N):
            pre, a = sf if i == 0 else sp if i == IN_N - 1 else frame_in(name, i)
            to_png(pre, a, os.path.join(d, 'in%02d.png' % i), 40 + i)
        print(name, 'ok', flush=True)
    d = os.path.join(root, 'rest'); os.makedirs(d, exist_ok=True)
    for k in range(REST_N):
        pre, a = sf if k in (0, REST_N - 1) else frame_rest(k)
        to_png(pre, a, os.path.join(d, 'r%02d.png' % k), 80 + k)
    print('rest ok')


if __name__ == '__main__':
    render_all(sys.argv[1])
