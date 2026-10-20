#!/usr/bin/env python3
"""Step icons for Telegram: the white muzzle of the dog looking out of the black disc (the hood and the nose are black, so only
the pearl face shows), or the paper plane. Shapes of the dog come from the user's drawing; the plane is the 3D model of the project."""
import sys, os, math
import numpy as np
from icons_render import *
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'plane'))
import plane_render as PR                                             # noqa: E402
from icon_render import load_masks                                    # noqa: E402
from halo_render import bilinear                                      # noqa: E402

_src = None
def src_masks():
    global _src
    if _src is None:
        hood, face, nose = load_masks()
        _src = dict(hood=hood, face=face, nose=nose)
    return _src


def mapped(name, sigma_src, scale, cx, cy, src_c=(150.0, 272.0)):
    """A mask of the drawing placed on the icon canvas: `scale` points per drawing pixel, the point src_c of the drawing at (cx, cy) points."""
    g = gblur(src_masks()[name], sigma_src)
    g = np.pad(g, 3)
    sx = src_c[0] + (X - cx) / scale; sy = src_c[1] + (Y - cy) / scale
    G = bilinear(g, sx + 3 - 0.5, sy + 3 - 0.5)
    inside = (sx > -3) & (sx < 303) & (sy > -3) & (sy < 383)
    G = np.where(inside, G, 0).astype(np.float32)
    gy, gx = np.gradient(G)
    dist = (G - 0.5) / (np.hypot(gx, gy) + 1e-6)
    return np.clip(0.5 + dist / 1.1, 0, 1).astype(np.float32)


def dog_face(lit, scale, cx, cy, hood_rim=0.0, lip=0.0):
    """The disc with the pearl face of the dog (and, if asked, a faint outline of the hood)."""
    lum, a = base_disc(lit)
    k = 0.30 + 0.70 * lit
    face = mapped('face', 5.0, scale, cx, cy) * a
    nose = mapped('nose', 3.0, scale, cx, cy) * face
    if hood_rim > 0:
        hood = mapped('hood', 9.0, scale, cx, cy)
        edge = np.clip(hood - gblur(hood, 1.6 * SS), 0, 1)
        up = np.clip(-Y / R, 0, 1) * 0.7 + np.clip(-X / R, 0, 1) * 0.3
        lum = lum + edge * (0.08 + 0.45 * up) * hood_rim * k * a
        inner = gblur(hood, 0.12 * R * PPT)
        lum = lum + np.clip(1 - (inner - 0.5) * 2.0, 0, 1) ** 2 * hood_rim * 0.05 * k * hood
    ys, xs = np.nonzero(face > 0.5)
    fy0, fy1 = ys.min(), ys.max()
    u = np.clip((yy - fy0) / (fy1 - fy0), 0, 1)
    pearl_l = (0.97 - 0.22 * smoothstep(0.55, 1.0, u))
    depth = gblur(face, 3.2 * PPT)
    pearl_l *= 0.58 + 0.42 * smoothstep(0.40, 0.97, depth)
    shade = gblur(np.roll(1 - face, int(1.8 * PPT), axis=0), 1.8 * PPT)
    pearl_l *= 1 - 0.5 * np.clip(shade * 1.3, 0, 1)
    pearl_l *= 0.34 + 0.66 * k
    # the nose: glossy black with a small light
    nys, nxs = np.nonzero(nose > 0.5)
    ncx, ncy = (nxs.min() + nxs.max()) / 2, (nys.min() + nys.max()) / 2
    nrx, nry = (nxs.max() - nxs.min()) / 2, (nys.max() - nys.min()) / 2
    r2 = ((xx - ncx) / nrx) ** 2 + ((yy - ncy) / nry) ** 2
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    nxn, nyn = (xx - ncx) / nrx * 0.8, (yy - ncy) / nry * 0.8
    nl = np.sqrt(nxn ** 2 + nyn ** 2 + z ** 2 + 1e-6)
    h_ = np.array([-0.28, -0.62, 0.74]); h_ /= np.linalg.norm(h_)
    spec = np.clip((nxn * h_[0] + nyn * h_[1] + z * h_[2]) / nl, 0, 1) ** 38
    sky = np.clip(-nyn / nl, 0, 1) ** 2 * 0.22
    nose_l = (0.010 + 0.95 * spec * k + sky * k * 0.5)
    lum = lum * (1 - face) + pearl_l * face
    lum = lum * (1 - nose) + nose_l * nose
    glow = gblur(face, 2.0 * PPT) * 0.10 * lit * a * (1 - face)          # a faint glow around the face, never over it
    return finish(lum + glow, a, face, lit)


def plane_icon(lit=1.0, roll=12.0, tilt=26.0, yaw=-36.0, length=36.0, trail=True):
    """The paper plane of the project, large, flying up and to the right, with a faint dotted trail."""
    lum, a = base_disc(lit)
    k = 0.30 + 0.70 * lit
    PR.S = length * 2 * PR.SS / 2.0 * 1.0 * 1.02
    sh, al, P, mid = PR.render(PR.classic(), PR.LOOKS['paper'][1], roll_deg=roll, tilt_deg=tilt, yaw_deg=yaw)
    pre, alpha = PR.finish(sh, al)
    pad = (N - PR.N) // 2
    big_pre = np.zeros((N, N), np.float32); big_a = np.zeros((N, N), np.float32)
    big_pre[pad:pad + PR.N, pad:pad + PR.N] = pre; big_a[pad:pad + PR.N, pad:pad + PR.N] = alpha
    big_pre = big_pre * (0.30 + 0.70 * k) / 1.0; big_a = big_a * a
    # a faint dotted trail behind it
    tr = np.zeros((N, N), np.float32)
    # the nose points to (sin(-yaw), cos(yaw)) in x right, y up; the trail goes the opposite way and curls a little
    nx_, ny_ = math.sin(math.radians(-yaw)), math.cos(math.radians(yaw))
    for i in range(1, 11):
        d = 14.5 + i * 2.5
        curl = 0.6 * (i / 10) ** 2 * 6
        px = -nx_ * d + ny_ * curl; py = -ny_ * d - nx_ * curl            # opposite to the nose (up is -y on the screen)
        tr = np.maximum(tr, cov(disc(px, -py, 1.15 * (1 - i / 14))) * (1 - i / 11) ** 1.4 * 0.55)
    if not trail: tr *= 0
    lum = lum * (1 - big_a) + 0.0
    lum = lum + tr * (0.30 + 0.70 * k) * a
    pre_out = (lum * a)
    pre_out = pre_out * (1 - big_a) + big_pre
    glow = gblur(big_a, 2.4 * PPT) * 0.22 * lit * a
    pre_out = pre_out + glow * (1 - big_a)
    return finish_plain(pre_out, a)


def finish_plain(pre, a):
    halo = gblur(a, 0.10 * R * PPT) * 0.11
    ga = np.clip(halo, 0, 0.4) * (1 - a)
    return (pre + ga).astype(np.float32), (a + ga).astype(np.float32)


TG = {
    'tg-face': lambda lit=1.0: dog_face(lit, 0.215, 0.0, 1.0),
    'tg-dog': lambda lit=1.0: dog_face(lit, 0.108, 0.0, 6.5, hood_rim=1.0),
    'tg-peek': lambda lit=1.0: dog_face(lit, 0.27, 0.0, 9.5, hood_rim=0.0),
    'tg-plane': lambda lit=1.0: plane_icon(lit),
}


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    tiles = []
    for name, fn in TG.items():
        pre, a = fn(1.0)
        tiles.append(np.clip(downsample(pre, 2), 0, 1))
    m = np.concatenate(tiles, axis=1)
    g = np.clip(np.round(m * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    open(os.path.join(out, 'tg_test.png'), 'wb').write(png_bytes(rgba))
