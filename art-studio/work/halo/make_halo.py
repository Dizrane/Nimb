#!/usr/bin/env python3
"""Renders the halo variants into previews/01-nimb/<variant>/ : back.png, front.png, sparkle-NN.png and manifest.json."""
import sys, os, json, time
from halo_render import *

VARIANTS = {
    # photographic, as close to the goal picture as possible
    'photo': dict(title='Фото', params=Params(band=1.15, core_gain=3.2, bloom=0.55, debris_gain=3.5, rays=0.6, ray_lobes=90,
                                              fiber_gain=1.5, ray_len=0.85, inner_ring=0.8)),
    # cleaner and thinner: holds up better when small
    'ribbon': dict(title='Лента', params=Params(band=0.8, core_gain=3.0, bloom=0.45, debris=1400, debris_gain=2.2, rays=0.28, ray_lobes=70,
                                                fibers=150, fiber_gain=1.2, ray_len=0.7, inner_ring=1.2, flare=0.6, flow_gain=0.8, seed=21)),
    # bigger glow, long rays, bright flare: the dramatic one
    'radiance': dict(title='Сияние', params=Params(band=1.05, core_gain=3.4, bloom=0.85, debris_gain=4.5, rays=1.25, ray_lobes=110,
                                                   fiber_gain=1.6, ray_len=1.25, inner_ring=0.8, flare=1.4, haze=1.5, flow_gain=1.2, seed=33)),
}

FRAMES, FPS = 24, 8
CROP_PT = (204, 100)                       # size of the animated layer, points
CENTER_PT = (CANVAS_PT[0] / 2, CANVAS_PT[1] / 2)


def crop_window(w, h):
    x = np.linspace(0, 1, w)[None, :]; y = np.linspace(0, 1, h)[:, None]
    return (smoothstep(0, 0.14, x) * smoothstep(0, 0.14, 1 - x) * smoothstep(0, 0.2, y) * smoothstep(0, 0.2, 1 - y)).astype(np.float32)


def render(key, out_root):
    v = VARIANTS[key]; P = v['params']
    out = os.path.join(out_root, key); os.makedirs(out, exist_ok=True)
    t0 = time.time()
    h = Halo(P)
    st = h.build_static()
    to_png_alpha(h.tone(st['back']), os.path.join(out, 'back.png'), 1)
    to_png_alpha(h.tone(st['front']), os.path.join(out, 'front.png'), 2)
    full_still = 1 - (1 - h.tone(st['front'])) * (1 - h.tone(st['back']))
    to_png_gray_on_black(full_still, os.path.join(out, 'still.png'))
    cw, ch = CROP_PT
    x0 = int((CENTER_PT[0] - cw / 2) * 2); y0 = int((CENTER_PT[1] - ch / 2) * 2)
    box = (x0, y0, x0 + cw * 2, y0 + ch * 2)
    win = crop_window(cw * 2, ch * 2)
    for i in range(FRAMES):
        a = h.build_anim(i / FRAMES)
        tone = h.tone(a)
        small = downsample(tone, 2)[box[1]:box[3], box[0]:box[2]] * win
        # to_png_alpha downsamples, so give it the 2x image again
        big = np.kron(small, np.ones((2, 2), np.float32))
        to_png_alpha(big, os.path.join(out, 'sparkle-%02d.png' % i), 100 + i)
        # the combined frame, for the preview and the sanity check
        if i == 0:
            still0 = full_still.copy()
    manifest = {
        'name': 'halo', 'variant': key, 'title': v['title'], 'version': 1, 'scale': 2,
        'pointSize': list(CANVAS_PT),
        'layers': [
            {'id': 'back', 'file': 'back.png', 'role': 'behind-figure', 'blend': 'screen'},
            {'id': 'front', 'file': 'front.png', 'role': 'in-front-of-figure', 'blend': 'screen'},
        ],
        'loops': [
            {'id': 'sparkle', 'kind': 'png-sequence', 'pattern': 'sparkle-%02d.png', 'frames': FRAMES, 'fps': FPS,
             'seconds': FRAMES / FPS, 'role': 'in-front-of-figure', 'blend': 'screen',
             'pointSize': [cw, ch], 'origin': [CENTER_PT[0] - cw / 2, CENTER_PT[1] - ch / 2]},
        ],
        'anchors': {'center': [CANVAS_PT[0] / 2, CANVAS_PT[1] / 2], 'crown': [CANVAS_PT[0] / 2, CANVAS_PT[1] / 2]},
        'ring': {'rx': P.rx_pt, 'ry': P.ry_pt, 'tiltDegrees': P.tilt_deg},
    }
    with open(os.path.join(out, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(key, 'done in %.1fs' % (time.time() - t0), flush=True)


if __name__ == '__main__':
    root = sys.argv[1]
    keys = sys.argv[2:] or list(VARIANTS)
    for k in keys:
        render(k, root)
