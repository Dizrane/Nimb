#!/usr/bin/env python3
"""YouTube and Discord icon, the same move as the "Нейросети" icon: the play button folds into a point with a flash, the Discord mark grows out of
the point, rests for two seconds and blinks twice, and everything runs back (the same frames backwards) to the play button."""
import sys, os, math
import numpy as np
from yd_icons import *
from yd_icons import play_layer, mark_layer, glyph_glow
from tg_final import compose, finish_plain, xform, over, add_glow, clip01
from tg_morph import disc_layer
from morph_render import ease_in, ease_out, ease_io, ease_out_back

N_CHANGE, N_REST = 24, 24                 # change: 24 fps = 1 s; rest: 12 fps = 2 s
_cache = {}


def parts(lit=1.0):
    if 'p' not in _cache:
        _cache['p'] = dict(disc=disc_layer(lit), play=play_layer(lit), mark=mark_layer(lit)[:2])
    return _cache['p']


def finish_scaled(layers, flash=None):
    """layers (premultiplied, bottom first, the disc among them) -> the picture with the soft glow round the glyph and round the disc."""
    out = layers[0]
    for l in layers[1:]: out = over(l, out)
    pre, a = out
    if flash is not None: pre, a = add_glow((pre, a), flash)
    return finish_plain(pre, np.clip(a, 0, 1))


def with_glyph_glow(disc_x, glyph_x, strength=0.24):
    g = glyph_glow(glyph_x[1], strength) * disc_x[1]
    return add_glow(over(glyph_x, disc_x), g)


# 1. exactly the move of the "Нейросети" icon: the whole icon folds, the new one grows
def v_whole(t, P):
    if t < 0.44:
        u = t / 0.44; e = ease_in(u); s = max(1 - e, 0.0)
        disc_x = xform(P['disc'], s); glyph_x = xform(P['play'], s, rot=math.radians(90) * e)
        pre, a = with_glyph_glow(disc_x, glyph_x)
        g = np.exp(-(np.hypot(X, Y) / (2.5 + 5 * e)) ** 2) * 0.9 * (0.25 + 0.75 * e)
        return finish_plain(*add_glow((pre, a), g))
    u = (t - 0.44) / 0.56
    s = max(ease_out_back(u), 0.0)
    disc_x = xform(P['disc'], s); glyph_x = xform(P['mark'], s, rot=-math.radians(60) * (1 - ease_out(u)))
    pre, a = with_glyph_glow(disc_x, glyph_x)
    g = np.exp(-(np.hypot(X, Y) / (3 + 7 * u)) ** 2) * 0.8 * math.exp(-u * 5)
    return finish_plain(*add_glow((pre, a), g))


# 2. calmer: the disc stays, only the glyph folds into the middle and the other grows from it
def v_inside(t, P):
    if t < 0.46:
        e = ease_in(t / 0.46); glyph = xform(P['play'], max(1 - e, 0.0))
    else:
        e = ease_out(clip01((t - 0.50) / 0.50)); glyph = xform(P['mark'], max(e, 0.0)) if t >= 0.50 else None
    objs = [glyph] if glyph is not None else []
    alpha = glyph[1] if glyph is not None else None
    glow = glyph_glow(alpha) if alpha is not None else None
    return compose(objs, glow=glow)


# 3. the Discord mark opens from the middle like an iris, with a thin bright ring at the edge, while the play button turns and folds
def v_iris(t, P):
    e = ease_io(clip01(t / 0.7))
    play = xform(P['play'], max(1 - 0.98 * e, 0.0), rot=math.radians(120) * e)
    ri = 22.0 * ease_out(clip01((t - 0.2) / 0.8))
    dist = np.hypot(X, Y)
    mask = np.clip((ri - dist) * PPT / 1.4 + 0.5, 0, 1)
    mark = (P['mark'][0] * mask, P['mark'][1] * mask)
    ring = np.exp(-((dist - ri) / 0.9) ** 2) * 0.7 * math.sin(math.pi * clip01(t)) ** 0.7 * (ri > 0.5) * (dist < 29)
    objs = [play, mark]
    alpha = np.maximum(play[1], mark[1])
    return compose(objs, glow=glyph_glow(alpha) + ring)


VARIANTS = {'whole': v_whole, 'inside': v_inside, 'iris': v_iris}
BLINKS = {5: 0.6, 6: 1.0, 7: 0.5, 12: 0.6, 13: 1.0, 14: 0.5}                 # two blinks over the two seconds


def render_all(root):
    P = parts()
    sp = compose([P['play']], glow=glyph_glow(P['play'][1])); sm = compose([P['mark']], glow=glyph_glow(P['mark'][1]))
    to_png(*sp, os.path.join(root, 'play.png'), 1); to_png(*sm, os.path.join(root, 'mark.png'), 2)
    pre, a = compose([P['play']], lit=0.0); to_png(pre, a, os.path.join(root, 'play-off.png'), 3)
    for name, fn in VARIANTS.items():
        d = os.path.join(root, name); os.makedirs(d, exist_ok=True)
        for i in range(N_CHANGE):
            t = i / (N_CHANGE - 1)
            pre, a = sp if i == 0 else sm if i == N_CHANGE - 1 else fn(t, P)
            to_png(pre, a, os.path.join(d, 'c%02d.png' % i), 10 + i)
        print(name, 'ok', flush=True)
    d = os.path.join(root, 'rest'); os.makedirs(d, exist_ok=True)
    for k in range(N_REST):
        if k in BLINKS:
            m = mark_layer(blink=BLINKS[k])[:2]
            pre, a = compose([m], glow=glyph_glow(m[1]))
        else:
            pre, a = sm
        to_png(pre, a, os.path.join(d, 'r%02d.png' % k), 60 + k)
    print('rest ok')


if __name__ == '__main__':
    os.makedirs(sys.argv[1], exist_ok=True)
    render_all(sys.argv[1])
