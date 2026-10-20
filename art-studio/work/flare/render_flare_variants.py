#!/usr/bin/env python3
"""Photo halo (same params as deliver/halo) with different treatments of the bright hot spot and the vertical line over the ring.
A: as delivered. B: no vertical line, keeps the hot spot and the horizontal glint. C: no flare at all. D: a soft round glow instead of streaks.
Writes <key>-back.png / <key>-front.png (672x388, white light on alpha) into the folder given."""
import sys, os, math, time
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'halo'))
import halo_render as hr
from halo_render import *
from make_halo import VARIANTS


class FlareHalo(hr.Halo):
    mode = 'A'

    def flare(self, phase=0.0):
        P = self.P
        th = -math.pi / 2 + 0.05 + 0.06 * math.sin(2 * math.pi * phase)
        x, y = self.ring_point(np.array([th]), np.array([0.0])); x, y = float(x[0]), float(y[0])
        dx, dy = self.xx - x, self.yy - y
        r = self.rx
        spot = 40 * np.exp(-((dx / (0.07 * r)) ** 2 + (dy / (0.02 * r)) ** 2))
        blob = 6 * np.exp(-((dx / (0.03 * r)) ** 2 + (dy / (0.09 * r)) ** 2))
        glint = 2.4 * np.exp(-((dx / (0.34 * r)) ** 2 + (dy / (0.03 * r)) ** 2))
        up = np.where(dy < 0, np.exp(-np.abs(dy) / (0.16 * r)), np.exp(-np.abs(dy) / (0.02 * r)))
        shaft = 0.5 * np.exp(-(dx / (0.004 * r)) ** 2) * up + 0.2 * np.exp(-(dx / (0.012 * r)) ** 2) * up
        m = self.mode
        if m == 'A': out = spot + blob + glint + shaft
        elif m == 'B': out = spot + glint
        elif m == 'C': out = 0 * spot
        elif m == 'D': out = 9 * np.exp(-((dx / (0.05 * r)) ** 2 + (dy / (0.035 * r)) ** 2)) + 1.2 * np.exp(-((dx / (0.16 * r)) ** 2 + (dy / (0.05 * r)) ** 2))
        return out * P.flare * (1 + 0.1 * math.sin(2 * math.pi * phase + 1))


if __name__ == '__main__':
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    P = VARIANTS['photo']['params']
    for mode in sys.argv[2:] or ['A', 'B', 'C', 'D']:
        t0 = time.time(); h = FlareHalo(P); h.mode = mode; st = h.build_static()
        to_png_alpha(h.tone(st['back']), os.path.join(out, mode + '-back.png'), 1)
        to_png_alpha(h.tone(st['front']), os.path.join(out, mode + '-front.png'), 2)
        print(mode, '%.1fs' % (time.time() - t0), flush=True)
