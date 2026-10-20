#!/usr/bin/env python3
"""The dog of the Telegram page as a clean black-and-white icon, with the shapes of the user's drawing.
Shapes come from the drawing (hood, face, nose), rounded; light is minimal: a thin rim, soft volume, a shine on the nose."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'halo'))
from halo_render import smoothstep, downsample, png_bytes, bilinear   # noqa: E402
from pngread import read_png                                            # noqa: E402

SS = 4
OUT_W, OUT_H = 256, 308
W, H = OUT_W * SS, OUT_H * SS
FIG_W = 100.0 * 2 * SS                   # hi-res px of the figure width
MARGIN_X, MARGIN_Y = 14.0 * 2 * SS, 14.0 * 2 * SS
SRC = os.path.join(os.path.dirname(__file__), '..', '..', 'references', 'dog-from-app-filled-face.png')


def gblur(img, s):
    if s < 0.6: return img
    pad = int(s * 3) + 2; h, w = img.shape; ph, pw = h + 2 * pad, w + 2 * pad
    fy = np.fft.fftfreq(ph)[:, None]; fx = np.fft.rfftfreq(pw)[None, :]
    k = np.exp(-2 * np.pi ** 2 * s * s * (fx * fx + fy * fy)).astype(np.float32)
    big = np.zeros((ph, pw), np.float32); big[pad:pad + h, pad:pad + w] = img
    return np.fft.irfft2(np.fft.rfft2(big) * k, s=(ph, pw))[pad:pad + h, pad:pad + w].astype(np.float32)


def holes_of(face):
    """Pixels enclosed by the face (the nose): between its first and last pixel in the row and in the column."""
    f = face > 0.5
    rows = np.zeros_like(f); cols = np.zeros_like(f)
    for y in range(f.shape[0]):
        xs = np.nonzero(f[y])[0]
        if len(xs): rows[y, xs[0]:xs[-1] + 1] = True
    for x in range(f.shape[1]):
        ys = np.nonzero(f[:, x])[0]
        if len(ys): cols[ys[0]:ys[-1] + 1, x] = True
    return rows & cols & ~f


def component(mask, seed):
    """The connected part of `mask` that contains `seed` (x, y)."""
    m = mask > 0.5
    reg = np.zeros_like(m); reg[seed[1], seed[0]] = True
    assert m[seed[1], seed[0]], 'seed is not inside the mask'
    while True:
        d = reg.copy()
        d[1:, :] |= reg[:-1, :]; d[:-1, :] |= reg[1:, :]; d[:, 1:] |= reg[:, :-1]; d[:, :-1] |= reg[:, 1:]
        d &= m
        if (d == reg).all(): return reg.astype(np.float32)
        reg = d


def load_masks():
    im = read_png(SRC).astype(np.float32) / 255
    a = im[..., 3]; lum = im[..., :3].mean(axis=2)
    hood = (a > 0.5).astype(np.float32)
    white = ((lum > 0.6) & (a > 0.5)).astype(np.float32)
    face = component(white, (110, 300))                    # the pearl face only, not the white specks of the hood
    hole = holes_of(face).astype(np.float32)
    nose = component(hole, (152, 295))                     # what is enclosed by the face: the nose
    face_full = np.clip(face + nose, 0, 1)
    nose = (gblur(nose, 2.0) > 0.5).astype(np.float32)
    return hood, face_full, nose


def aa(g_src, sigma_src, y_off=0):
    """Smooth a source-resolution mask, bring it up to the big canvas and cut it with an anti-aliased edge."""
    g = gblur(g_src, sigma_src)
    sh, sw = g.shape
    scale = FIG_W / sw
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    sx = (xx - MARGIN_X) / scale - 0.5; sy = (yy - MARGIN_Y) / scale - 0.5
    inside = (sx > -1) & (sx < sw) & (sy > -1) & (sy < sh)
    G = np.where(inside, bilinear(np.pad(g, 2), sx + 2, sy + 2), 0).astype(np.float32)
    gy, gx = np.gradient(G)
    dist = (G - 0.5) / (np.hypot(gx, gy) + 1e-6)
    return np.clip(0.5 + dist / 1.1, 0, 1).astype(np.float32), G


class Icon:
    def __init__(self, vol=1.0):
        self.vol = vol
        hood, face, nose = load_masks()
        self.hood, self.Gh = aa(hood, 9.0)
        self.face, _ = aa(face, 5.0)
        self.nose, _ = aa(nose, 3.0)
        self.face *= self.hood; self.nose *= self.face
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        self.xx, self.yy = xx, yy
        self.top = MARGIN_Y
        self.fh = FIG_W * 380 / 300         # figure height in px
        self.cx = W / 2

    def render(self, lit=1.0, glow=True):
        v = self.vol
        hood, face, nose = self.hood, self.face, self.nose
        u = (self.yy - self.top) / self.fh                  # 0 at the peak, 1 at the hem
        xn = (self.xx - self.cx) / (FIG_W / 2)
        k = 0.28 + 0.72 * lit
        # --- the hood: black, a soft light from the halo at the top and a velvet sheen along the edges
        body = np.clip(hood - face, 0, 1)
        fall = np.clip(1.1 - 0.9 * u, 0, 1)
        top_glow = np.exp(-(((xn + 0.15) / 0.75) ** 2 + ((u - 0.16) / 0.30) ** 2))
        inner = gblur(hood, 0.16 * FIG_W / 2)                  # 1 deep inside, falling to 0.5 at the outline
        sheen = np.clip(1 - (inner - 0.5) * 2.2, 0, 1) ** 1.6
        hood_l = 0.016 + 0.040 * fall + v * (0.11 * top_glow + 0.20 * sheen * (0.25 + 0.75 * fall))
        hood_l = hood_l * (0.35 + 0.65 * k)
        # --- the face: pearl; the hood throws a soft shadow on its upper part
        pearl = 0.97 - 0.20 * smoothstep(0.55, 1.0, u) - 0.10 * (1 - np.clip(gblur(face, 0.12 * FIG_W / 2) * 1.0, 0, 1))
        fv = gblur(face, 0.16 * FIG_W / 2)
        pearl = pearl - v * 0.10 * (1 - smoothstep(0.35, 0.95, fv))
        shade = gblur(np.roll(hood - face, int(0.045 * self.fh), axis=0), 0.05 * FIG_W / 2)
        pearl *= 1 - 0.50 * np.clip(shade * 1.5, 0, 1) * (0.55 + 0.45 * v)
        pearl *= 0.30 + 0.70 * k
        # --- the nose: glossy black with a small shine
        ncy = (np.nonzero(nose.sum(axis=1) > 1)[0])
        y0, y1 = ncy[0], ncy[-1]; nxs = np.nonzero(nose.sum(axis=0) > 1)[0]; x0, x1 = nxs[0], nxs[-1]
        ncx_, ncy_ = (x0 + x1) / 2, (y0 + y1) / 2; nrx, nry = (x1 - x0) / 2, (y1 - y0) / 2
        r2 = ((self.xx - ncx_) / nrx) ** 2 + ((self.yy - ncy_) / nry) ** 2
        z = np.sqrt(np.clip(1 - r2, 0, 1))
        nx_, ny_ = (self.xx - ncx_) / nrx * 0.8, (self.yy - ncy_) / nry * 0.8
        nl = np.sqrt(nx_ ** 2 + ny_ ** 2 + z ** 2 + 1e-6)
        h_ = np.array([-0.28, -0.62, 0.74]); h_ /= np.linalg.norm(h_)
        spec = np.clip((nx_ * h_[0] + ny_ * h_[1] + z * h_[2]) / nl, 0, 1) ** 38
        sky = np.clip(-ny_ / nl, 0, 1) ** 2 * 0.22
        nose_l = (0.010 + 0.95 * spec * k + sky * k * v) * 1.0
        lum = hood_l * (1 - face) + pearl * face
        lum = lum * (1 - nose) + nose_l * nose
        # thin rim of light on the outline (strongest where it faces up and left)
        edge = np.clip(hood - gblur(hood, 1.8 * SS), 0, 1)
        up = np.clip(-np.gradient(gblur(hood, 3.0 * SS), axis=0), 0, 1); up /= up.max() + 1e-6
        left = np.clip(-np.gradient(gblur(hood, 3.0 * SS), axis=1), 0, 1); left /= left.max() + 1e-6
        lum += edge * (0.12 + 0.55 * np.maximum(up, 0.7 * left)) * k * (1.0 if v else 1.0)
        lum = np.clip(lum, 0, 1)
        alpha = hood; pre = lum * alpha
        if glow:
            g = gblur(hood, 0.09 * FIG_W / 2) * (0.05 + 0.09 * lit) * 0.9
            ga = np.clip(g, 0, 0.5) * (1 - alpha); pre = pre + ga; alpha = alpha + ga
        return pre.astype(np.float32), alpha.astype(np.float32)


def on_black(pre, path):
    p = np.clip(downsample(pre, SS), 0, 1); g = np.clip(np.round(p * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    open(path, 'wb').write(png_bytes(rgba))


def to_png(pre, alpha, path, seed=0):
    p = downsample(pre, SS); a = downsample(alpha, SS)
    straight = np.where(a > 1e-4, p / np.maximum(a, 1e-4), 0)
    rng = np.random.default_rng(seed)
    q = np.clip(np.round(straight * 255 + (rng.random(a.shape) - 0.5)), 0, 255).astype(np.uint8)
    qa = np.clip(np.round(a * 255 + (rng.random(a.shape) - 0.5) * (a > 0.002)), 0, 255).astype(np.uint8)
    rgba = np.empty(a.shape + (4,), np.uint8); rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = q; rgba[..., 3] = qa
    open(path, 'wb').write(png_bytes(rgba))


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    for vol, name in ((1.0, 'soft'), (0.0, 'flat')):
        ic = Icon(vol)
        pre, a = ic.render(1.0); on_black(pre, os.path.join(out, 'icon_%s.png' % name))
