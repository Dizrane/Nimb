#!/usr/bin/env python3
"""Renders still halo layers at double resolution for the app icon (4 px per point instead of 2)."""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'halo'))
import halo_render as hr
hr.PX = 8
from halo_render import *
from make_halo import VARIANTS

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
for key in sys.argv[2:] or ['photo']:
    P = VARIANTS[key]['params']
    t0 = time.time(); h = hr.Halo(P); st = h.build_static()
    to_png_alpha(h.tone(st['back']), os.path.join(out, key + '-back.png'), 1)
    to_png_alpha(h.tone(st['front']), os.path.join(out, key + '-front.png'), 2)
    print(key, 'done %.1fs' % (time.time() - t0), flush=True)
