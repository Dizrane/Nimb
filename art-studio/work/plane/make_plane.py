#!/usr/bin/env python3
"""Renders the paper plane looks into previews/03-samolet/<look>/ : bank-00..12.png (roll -36..+36 deg), glow.png, manifest.json."""
import sys, os, json
from plane_render import *

BANKS = list(range(-36, 37, 6))
TITLES = {'paper': 'Бумага', 'arrow': 'Стрела', 'edge': 'Контур'}


def glow_png(path):
    n = 64
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    r = np.hypot(xx - n / 2 + 0.5, yy - n / 2 + 0.5) / (n / 2)
    a = np.clip(np.exp(-(r * 2.4) ** 2) * 0.9 + np.exp(-(r * 1.2) ** 2) * 0.25, 0, 1) * (1 - smoothstep(0.7, 1.0, r))
    rng = np.random.default_rng(3)
    qa = np.clip(np.round(a * 255 + (rng.random(a.shape) - 0.5)), 0, 255).astype(np.uint8)
    rgba = np.empty((n, n, 4), np.uint8); rgba[..., :3] = 255; rgba[..., 3] = qa
    open(path, 'wb').write(png_bytes(rgba))


def run(root, keys):
    for key in keys:
        maker, look = LOOKS[key]
        out = os.path.join(root, key); os.makedirs(out, exist_ok=True)
        for i, b in enumerate(BANKS):
            sh, al, P, mid = render(maker(), look, roll_deg=b)
            pre, a = finish(sh, al, bloom=0.5 if look.edge_glow else 0.0)
            to_png(pre, a, os.path.join(out, 'bank-%02d.png' % i), i)
        glow_png(os.path.join(out, 'glow.png'))
        # where the nose and the tail are in the picture, in points from the top-left of the 64 x 64 pt canvas (level flight)
        sh, al, P, mid = render(maker(), look, roll_deg=0)
        nose = [32 + S * (P['N'][0] - mid[0]) / SS / 2, 32 - S * (P['N'][1] - mid[1]) / SS / 2]
        tail = [32 + S * (P['K'][0] - mid[0]) / SS / 2, 32 - S * (P['K'][1] - mid[1]) / SS / 2]
        json.dump({'name': 'paper-plane', 'look': key, 'title': TITLES[key], 'nose': [round(float(v), 2) for v in nose], 'tail': [round(float(v), 2) for v in tail]}, open(os.path.join(out, 'meta.json'), 'w'))
        print(key, 'ok', [round(v, 1) for v in nose], [round(v, 1) for v in tail], flush=True)


if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2:] or list(LOOKS))
