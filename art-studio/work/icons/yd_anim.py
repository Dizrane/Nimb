#!/usr/bin/env python3
"""YouTube and Discord icon: the white play button at rest; on a tap it goes away, the Discord mark shows for a couple of seconds (it blinks once),
goes away, and the play button comes back. Three ways to do it, and a variant where both stand together."""
import sys, os, math
import numpy as np
from yd_icons import *
from yd_icons import play_layer, mark_layer, glyph_glow
from tg_final import muzzle_out, muzzle_in
from tg_morph import disc_layer
from morph_render import ease_in, ease_out, ease_io
from tg_final import MZ_OUT, MZ_IN

OUT_N, IN_N, REST_N, LOOP_N = 30, 30, 10, 24
_c = {}


def L(name, **kw):
    key = (name, tuple(sorted(kw.items())))
    if key not in _c:
        _c[key] = play_layer(**kw) if name == 'play' else mark_layer(**kw)[:2]
    return _c[key]


def scene(objs, extra=None):
    """Compose the layers over the disc with a soft glow around the glyphs."""
    alpha = np.zeros_like(objs[0][1]) if objs else None
    for pre, a in objs: alpha = np.maximum(alpha, a)
    glow = glyph_glow(alpha) if objs else None
    if extra is not None: glow = glow + extra if glow is not None else extra
    return compose(objs, glow=glow)


def play_pose(name, direction, t):
    if direction == 'out':
        u = clip01(t / 0.46)
        if name == 'slide':
            e = ease_in3(u) * 0.85 + ease(u) * 0.15; return dict(dx=64 * e)
        if name == 'grow': return dict(scale=max(1 - ease_in(u), 0))
        return dict(sx=max(math.cos(math.pi / 2 * ease_in(u)), 0))
    u = clip01((t - 0.46) / 0.54)
    if name == 'slide': return dict(dx=-64 * (1 - ease_out3(u)))
    if name == 'grow': return dict(scale=max(ease_out(u), 0))
    return dict(sx=max(math.sin(math.pi / 2 * ease_out(u)), 0))


def mark_pose(name, direction, t):
    if direction == 'out':
        um = clip01((t - MZ_OUT) / (1 - MZ_OUT))
        if name == 'slide': m = muzzle_out(t); return dict(dy=m['dy']), m['alpha']
        if name == 'grow': return dict(scale=max(ease_out(um), 0)), 1.0
        return dict(sx=max(math.sin(math.pi / 2 * ease_out(um)), 0)), 1.0
    um = clip01(t / MZ_IN)
    if name == 'slide': m = muzzle_in(t); return dict(dy=m['dy']), m['alpha']
    if name == 'grow': return dict(scale=max(1 - ease_in(um), 0)), 1.0
    return dict(sx=max(math.cos(math.pi / 2 * ease_in(um)), 0)), 1.0


def put(layer, pose, alpha=1.0):
    pre, a = xform(layer, pose.get('scale', 1.0), sx=pose.get('sx', 1.0), dx=pose.get('dx', 0.0), dy=pose.get('dy', 0.0))
    return pre * alpha, a * alpha


def frame(name, direction, i, n):
    t = i / (n - 1)
    objs = []
    pp = play_pose(name, direction, t)
    if pp.get('scale', 1.0) > 0.003 and pp.get('sx', 1.0) > 0.003:
        objs.append(put(L('play'), pp))
    mp, ma = mark_pose(name, direction, t)
    show = (t >= MZ_OUT) if direction == 'out' else (t <= MZ_IN)
    if show and mp.get('scale', 1.0) > 0.003 and mp.get('sx', 1.0) > 0.003 and ma > 0.003:
        objs.append(put(L('mark'), mp, ma))
    return scene(objs), (objs[0] if objs else None), (objs[1] if len(objs) > 1 else None)


def overlap_px(a_l, b_l, da):
    if a_l is None or b_l is None: return 0.0
    pm = gblur((a_l[1] * da > 0.04).astype(np.float32), 1.0 * PPT) > 0.15
    mm = (b_l[1] * da > 0.04)
    return float((pm & mm).sum()) / (PPT * PPT / 4)


BLINK = [0, 0, 0, 0, 0, 0.65, 1.0, 0.5, 0, 0]


def rest_frame(k):
    b = BLINK[k]
    pre, a = mark_layer(blink=b)[:2]
    return scene([(pre, a)])


# --- the pair: play and the mark together, centred as a group
PAIR = dict(play=dict(height=19.0, cx=-7.8, cy=-6.2), mark=dict(width=24.0, cx=8.6, cy=7.6))


def pair_frame(k, n=LOOP_N):
    t = k / n
    b = 0.0
    for c0 in (0.18, 0.36):                                    # two quick blinks
        d = (t - c0) / 0.08
        if 0 <= d <= 1: b = max(b, math.sin(math.pi * d))
    pl = play_layer(**PAIR['play'])
    # a glint that crosses the play triangle
    g = 0.0
    q = (t - 0.52) / 0.34
    if 0 <= q <= 1:
        cxg = PAIR['play']['cx'] - 14 + 28 * ease(q)
        band = np.exp(-(((X - cxg) + (Y - PAIR['play']['cy']) * 0.55) / 3.2) ** 2)
        pl = (np.clip(pl[0] + band * 0.30 * pl[1], 0, 1.2), pl[1])
    mk, ma, ring = mark_layer(blink=b, outline=1.2, **PAIR['mark'])
    # the dark ring round the mark separates it from the triangle
    plc = (pl[0] * (1 - ring), pl[1] * (1 - ring))
    objs = [plc, (mk, ma)]
    shift = pair_shift()
    objs = [xform(o, 1.0, dx=shift[0], dy=shift[1]) for o in objs]
    return scene(objs)


_shift = None
def pair_shift():
    """Move the group so that its box is centred on the disc (optical centring: the play triangle weighs a little to the left)."""
    global _shift
    if _shift is None:
        pl = play_layer(**PAIR['play']); mk = mark_layer(**PAIR['mark'])[:2]
        a = np.maximum(pl[1], mk[1]); ys, xs = np.nonzero(a > 0.5); c = a.shape[0] / 2
        _shift = (-((xs.min() + xs.max()) / 2 - c) / PPT, -((ys.min() + ys.max()) / 2 - c) / PPT)
    return _shift


def render_all(root):
    _, da = disc_layer()
    sp = scene([L('play')]); sm = scene([L('mark')])
    to_png(*sp, os.path.join(root, 'play.png'), 1); to_png(*sm, os.path.join(root, 'mark.png'), 2)
    pre, a = compose([L('play')], lit=0.0); to_png(pre, a, os.path.join(root, 'play-off.png'), 3)
    report = {}
    for name in ('slide', 'grow', 'flip'):
        d = os.path.join(root, name); os.makedirs(d, exist_ok=True); worst = 0.0
        for i in range(OUT_N):
            (pre, a), p, m = frame(name, 'out', i, OUT_N)
            if i == 0: pre, a = sp
            if i == OUT_N - 1: pre, a = sm
            worst = max(worst, overlap_px(p, m, da)); to_png(pre, a, os.path.join(d, 'out%02d.png' % i), 10 + i)
        for i in range(IN_N):
            (pre, a), p, m = frame(name, 'in', i, IN_N)
            if i == 0: pre, a = sm
            if i == IN_N - 1: pre, a = sp
            worst = max(worst, overlap_px(p, m, da)); to_png(pre, a, os.path.join(d, 'in%02d.png' % i), 50 + i)
        report[name] = worst
        print(name, 'worst overlap %.1f px' % worst, flush=True)
    d = os.path.join(root, 'rest'); os.makedirs(d, exist_ok=True)
    for k in range(REST_N):
        pre, a = sm if BLINK[k] == 0 and k in (0, REST_N - 1) else rest_frame(k)
        to_png(pre, a, os.path.join(d, 'r%02d.png' % k), 90 + k)
    d = os.path.join(root, 'pair'); os.makedirs(d, exist_ok=True)
    for k in range(LOOP_N):
        pre, a = pair_frame(k); to_png(pre, a, os.path.join(d, 'p%02d.png' % k), 120 + k)
    to_png(*pair_frame(0), os.path.join(root, 'pair.png'), 5)
    print('rest and pair ok')
    return report


if __name__ == '__main__':
    os.makedirs(sys.argv[1], exist_ok=True)
    print(render_all(sys.argv[1]))
