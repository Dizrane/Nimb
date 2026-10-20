#!/usr/bin/env python3
"""App icon pairs for Nimb: idle (the halo alone) and active (a black disc with the halo).
The halo layers come from render_halo_big.py. Everything is composited in linear 'screen' light on the macOS icon tile.
Output: out/<variant>-<state>.png at 1024 px, plus small sizes for the preview page."""
import sys, os
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'dog')); sys.path.insert(0, os.path.join(HERE, '..', 'halo'))
from pngread import read_png
from halo_render import png_bytes, bilinear

N = 1024
OUT = os.path.join(HERE, 'out')
YY, XX = np.mgrid[0:N, 0:N].astype(np.float32)
LAYER_C = (672.0, 388.0)      # centre of the 1344x776 halo layers
LAYER_RX = 320.0              # ring semi-width in the layers (80 pt * 4 px)


def layer(name):
    return read_png(os.path.join(HERE, 'halo-big', name))[..., 3].astype(np.float32) / 255.0


def halo_on_canvas(img, cx, cy, rx, gain=1.6):
    s = rx / LAYER_RX
    L = bilinear(img, (XX - cx) / s + LAYER_C[0], (YY - cy) / s + LAYER_C[1]) * (((XX - cx) / s + LAYER_C[0] >= 0) & ((XX - cx) / s + LAYER_C[0] < 1343) & ((YY - cy) / s + LAYER_C[1] >= 0) & ((YY - cy) / s + LAYER_C[1] < 775))
    return 1 - (1 - np.clip(L, 0, 1)) ** gain          # more exposure: the ring reads at icon size


def screen(base, light):
    return 1 - (1 - base) * (1 - np.clip(light, 0, 1))


def sdf_round_rect(cx, cy, hw, hh, r):
    qx = np.abs(XX - cx) - (hw - r); qy = np.abs(YY - cy) - (hh - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def cover(d):                  # coverage from a signed distance, one pixel soft edge
    return np.clip(0.5 - d, 0, 1)


def gblur(img, sigma):
    h, w = img.shape; p = int(sigma * 3)
    big = np.zeros((h + 2 * p, w + 2 * p), np.float32); big[p:p + h, p:p + w] = img
    fy = np.fft.fftfreq(big.shape[0])[:, None]; fx = np.fft.rfftfreq(big.shape[1])[None, :]
    k = np.exp(-2 * np.pi ** 2 * sigma ** 2 * (fx * fx + fy * fy))
    return np.fft.irfft2(np.fft.rfft2(big) * k, s=big.shape)[p:p + h, p:p + w].astype(np.float32)


def disc(img, cx, cy, r, rim=0.7, rim_w=5.0, top=0.16, bottom=0.01, lift=0.0):
    """An opaque black glass disc: a dark vertical gradient and a hairline rim that is brighter on top where the halo light falls."""
    d = np.hypot(XX - cx, YY - cy) - r
    inside = cover(d)
    ny = np.clip((YY - (cy - r)) / (2 * r), 0, 1)
    body = (top + (bottom - top) * ny ** 0.8) + lift * np.exp(-((XX - cx) ** 2 / (0.5 * r) ** 2 + (YY - (cy - r * 0.9)) ** 2 / (0.35 * r) ** 2))
    img = img * (1 - inside) + body * inside
    up = np.clip(-(YY - cy) / r, -1, 1) * 0.5 + 0.5          # 1 on top, 0 at the bottom
    ring = cover(np.abs(d) - rim_w / 2) * (0.25 + 0.75 * up ** 1.5) * rim
    return screen(img, ring)


def tile_bg():
    ny = np.clip((YY - 100) / 824, 0, 1)
    return 0.025 * (1 - ny)


def finish(gray, name, size_list=(512, 128, 64, 32, 16)):
    rr = sdf_round_rect(512, 512, 412, 412, 185)
    m = cover(rr)
    sh = np.clip(gblur(np.roll(cover(rr), 14, axis=0), 15) * 0.5, 0, 1)
    hair = cover(np.abs(rr) - 1.5) * 0.2
    g = screen(gray, hair) * m
    a = m + sh * (1 - m)
    rgba_pre = np.stack([g, g, g, a], -1)                     # premultiplied
    out = OUT; os.makedirs(out, exist_ok=True)

    def save(pre, path, seed):
        al = pre[..., 3:4]
        rgb = np.where(al > 1e-4, pre[..., :3] / np.maximum(al, 1e-4), 0)
        dith = (np.random.default_rng(seed).random(rgb.shape[:2])[..., None] - 0.5) / 255
        q = np.empty(pre.shape, np.uint8)
        q[..., :3] = np.clip(np.round((rgb + dith * (rgb > 0.001)) * 255), 0, 255)
        q[..., 3] = np.clip(np.round(al[..., 0] * 255), 0, 255)
        open(path, 'wb').write(png_bytes(q))
    save(rgba_pre, os.path.join(out, name + '-1024.png'), 1)
    for s in size_list:
        k = N // s
        small = rgba_pre.reshape(s, k, s, k, 4).mean(axis=(1, 3))
        save(small, os.path.join(out, '%s-%d.png' % (name, s)), 2)


PHOTO = ('photo-back.png', 'photo-front.png')
RIBBON = ('ribbon-back.png', 'ribbon-front.png')


def compose(variant, state):
    back, front = (layer(f) for f in (RIBBON if variant == 4 else PHOTO))
    g = tile_bg()
    if variant == 2:
        if state == 'idle':
            g = screen(g, halo_on_canvas(back, 512, 504, 360)); g = screen(g, halo_on_canvas(front, 512, 504, 360))
        else:                                          # the composition of the current icon: a planet rising from the bottom
            glow = np.clip(1 - np.hypot(XX - 512, YY - 464) / 520, 0, 1) * 0.2
            g = screen(g, glow)
            g = screen(g, halo_on_canvas(back, 512, 454, 330))
            g = disc(g, 512, 809, 330, rim=0.85, rim_w=6, top=0.16, bottom=0.01)
            g = screen(g, halo_on_canvas(front, 512, 454, 330))
    elif variant == 3:
        if state == 'idle':
            g = screen(g, halo_on_canvas(back, 512, 512, 340)); g = screen(g, halo_on_canvas(front, 512, 512, 340))
        else:                                          # a whole disc below, the ring round its top like a halo round a head
            g = screen(g, halo_on_canvas(back, 512, 392, 300))
            g = disc(g, 512, 655, 230, rim=0.55, rim_w=4, top=0.15, bottom=0.01, lift=0.07)
            g = screen(g, halo_on_canvas(front, 512, 392, 300))
    elif variant == 4:
        if state == 'idle':
            g = screen(g, halo_on_canvas(back, 512, 512, 385)); g = screen(g, halo_on_canvas(front, 512, 512, 385))
        else:                                          # the ring goes round the middle of the disc: far half hidden, near half in front
            g = screen(g, halo_on_canvas(back, 512, 530, 365))
            g = disc(g, 512, 512, 185, rim=0.6, rim_w=4, top=0.15, bottom=0.01, lift=0.05)
            g = screen(g, halo_on_canvas(front, 512, 530, 365))
    return g


if __name__ == '__main__':
    for v in (2, 3, 4):
        for st in ('idle', 'active'):
            finish(compose(v, st), 'v%d-%s' % (v, st))
            print('v%d %s' % (v, st), flush=True)
