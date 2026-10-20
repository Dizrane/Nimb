#!/usr/bin/env python3
"""Photographic halo for Nimb: a long-exposure glowing ring, rendered in linear light.

Method (why it looks like a photo and not like a drawing):
  1. Sources in linear light: a blown-out band, fine fibres, an inner ring, flying debris.
  2. A lens point-spread function (sum of gaussians, power-law tail) turns sources into glow.
  3. A zoom blur (long exposure while zooming) turns bright things into rays, broken up by an angular dust mask.
  4. Tone mapping 1 - exp(-x). This is exactly the 'screen' blend, so separately rendered layers
     add up to the same picture when they are screen-composited.
Only numpy and the standard library are used.
"""
import numpy as np, zlib, struct, math, os
from dataclasses import dataclass, replace

PX = 4                      # working pixels per point (2x output, 2x supersampling)
CANVAS_PT = (336, 194)      # same canvas as the current halo of the app


@dataclass
class Params:
    rx_pt: float = 80.0
    ry_pt: float = 25.0
    tilt_deg: float = -2.5
    # band
    band: float = 1.0            # thickness multiplier of the white band
    core_gain: float = 4.0       # HDR value of the band
    fibers: int = 260
    fiber_gain: float = 1.0
    inner_ring: float = 1.0
    # debris (flying specks around the ring)
    debris: int = 2400
    debris_gain: float = 1.0
    # glow and rays
    bloom: float = 1.0
    rays: float = 1.0
    ray_len: float = 1.0
    ray_lobes: int = 170
    flare: float = 1.0
    haze: float = 1.0
    flow_gain: float = 1.0
    flare_static: float = 1.0
    exposure: float = 1.0
    seed: int = 7


# ---------------------------------------------------------------------------------------------- helpers

def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def bilinear(img, xs, ys):
    h, w = img.shape
    xs = np.clip(xs, 0, w - 1.001); ys = np.clip(ys, 0, h - 1.001)
    x0 = xs.astype(np.int32); y0 = ys.astype(np.int32)
    fx = xs - x0; fy = ys - y0
    a = img[y0, x0]; b = img[y0, x0 + 1]; c = img[y0 + 1, x0]; d = img[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def downsample(img, k):
    h, w = img.shape
    return img[:h // k * k, :w // k * k].reshape(h // k, k, w // k, k).mean(axis=(1, 3))


def upsample_to(img, shape):
    h, w = shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    sy = img.shape[0] / h; sx = img.shape[1] / w
    return bilinear(img, (xs + 0.5) * sx - 0.5, (ys + 0.5) * sy - 0.5)


class Noise:
    """Smooth value noise on a wrapping lattice."""
    def __init__(self, seed, size=64):
        self.t = np.random.default_rng(seed).random((size, size)).astype(np.float32); self.n = size

    def __call__(self, x, y):
        n = self.n
        x0 = np.floor(x); y0 = np.floor(y)
        fx = x - x0; fy = y - y0
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        x0 = x0.astype(np.int32) % n; y0 = y0.astype(np.int32) % n
        x1 = (x0 + 1) % n; y1 = (y0 + 1) % n
        t = self.t
        return (t[y0, x0] * (1 - fx) + t[y0, x1] * fx) * (1 - fy) + (t[y1, x0] * (1 - fx) + t[y1, x1] * fx) * fy


def splat(shape, xs, ys, ws):
    """Accumulate weighted points with bilinear weights."""
    h, w = shape
    x0 = np.floor(xs).astype(np.int64); y0 = np.floor(ys).astype(np.int64)
    fx = (xs - x0).astype(np.float32); fy = (ys - y0).astype(np.float32)
    out = np.zeros(h * w, np.float32)
    for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        xi = x0 + dx; yi = y0 + dy
        ok = (xi >= 0) & (xi < w) & (yi >= 0) & (yi < h)
        out += np.bincount(yi[ok] * w + xi[ok], weights=(ws * wt)[ok], minlength=h * w).astype(np.float32)
    return out.reshape(h, w)


def strokes(shape, x, y, ang, length, weight, step=0.6):
    """Draw straight strokes (start x,y; direction ang; length in px; brightness per px), tapered at both ends."""
    counts = np.maximum(np.ceil(length / step).astype(np.int64), 1) + 1
    total = counts.sum()
    idx = np.repeat(np.arange(len(x)), counts)
    first = np.repeat(np.cumsum(counts) - counts, counts)
    t = (np.arange(total) - first) / np.maximum(counts[idx] - 1, 1)
    taper = np.sin(np.pi * t) ** 0.6
    px = x[idx] + np.cos(ang[idx]) * length[idx] * t
    py = y[idx] + np.sin(ang[idx]) * length[idx] * t
    return splat(shape, px, py, (weight[idx] * taper * step).astype(np.float32))


class Lens:
    """Gaussian-sum point-spread function applied in the Fourier domain."""
    def __init__(self, shape, sigmas, weights, pad=None):
        h, w = shape
        pad = pad or int(max(sigmas) * 2.2)
        self.shape, self.pad = shape, pad
        self.H, self.W = h + 2 * pad, w + 2 * pad
        fy = np.fft.fftfreq(self.H)[:, None]; fx = np.fft.rfftfreq(self.W)[None, :]
        f2 = fx * fx + fy * fy
        self.k = sum(wt * np.exp(-2 * np.pi ** 2 * s * s * f2) for s, wt in zip(sigmas, weights)).astype(np.float32)

    def __call__(self, img):
        h, w = self.shape; p = self.pad
        big = np.zeros((self.H, self.W), np.float32)
        big[p:p + h, p:p + w] = img
        out = np.fft.irfft2(np.fft.rfft2(big) * self.k, s=(self.H, self.W))
        return out[p:p + h, p:p + w].astype(np.float32)


# ---------------------------------------------------------------------------------------------- the halo

class Halo:
    def __init__(self, P: Params):
        self.P = P
        self.W, self.H = CANVAS_PT[0] * PX, CANVAS_PT[1] * PX
        self.rx, self.ry = P.rx_pt * PX, P.ry_pt * PX
        self.cx, self.cy = self.W / 2, self.H / 2
        a = math.radians(P.tilt_deg)
        self.ca, self.sa = math.cos(a), math.sin(a)
        yy, xx = np.mgrid[0:self.H, 0:self.W].astype(np.float32)
        self.xx, self.yy = xx, yy
        dx, dy = xx - self.cx, yy - self.cy
        xr = dx * self.ca + dy * self.sa
        yr = -dx * self.sa + dy * self.ca
        self.xr, self.yr = xr, yr
        u, v = xr / self.rx, yr / self.ry
        r = np.sqrt(u * u + v * v) + 1e-6
        self.th = np.arctan2(v, u).astype(np.float32)          # image coordinates: -pi/2 is the top
        g = np.sqrt((u / self.rx) ** 2 + (v / self.ry) ** 2) / r
        self.d = ((r - 1) / np.maximum(g, 1e-9)).astype(np.float32)   # signed distance from the ring, px, outward positive
        self.u, self.v, self.r = u, v, r
        sh = (self.H, self.W)
        ws = P.bloom
        sig = np.array([0.0035, 0.008, 0.017, 0.038, 0.085, 0.19, 0.45]) * self.rx
        wgt = np.array([0.42, 0.34, 0.27, 0.20, 0.13, 0.075, 0.05 * P.haze]) * ws
        self.lens = Lens(sh, sig, wgt)
        self.lens_ray = Lens(sh, sig[1:5] * 1.1, wgt[:4])
        self.noise = Noise(P.seed)
        self.mid = (self.H // 2, self.W // 2)

    # -- geometry of the ring ------------------------------------------------------------------------
    def width(self, th):
        up = 0.5 * (1 - np.sin(th)); left = 0.5 * (1 - np.cos(th))
        return self.rx * (0.018 + 0.066 * up ** 1.4 + 0.030 * left * up + 0.012 * left) * self.P.band

    def front_weight(self, th):
        """1 on the near (upper) half, 0 on the far half, a soft handover at the ends."""
        return smoothstep(-0.16, 0.16, -np.sin(th))

    def ring_point(self, th, d):
        nx = np.cos(th) / self.rx; ny = np.sin(th) / self.ry
        n = np.hypot(nx, ny); nx /= n; ny /= n
        xr = self.rx * np.cos(th) + nx * d; yr = self.ry * np.sin(th) + ny * d
        return self.cx + xr * self.ca - yr * self.sa, self.cy + xr * self.sa + yr * self.ca

    def tangent(self, th):
        tx = -self.rx * np.sin(th); ty = self.ry * np.cos(th)
        n = np.hypot(tx, ty); tx /= n; ty /= n
        return tx * self.ca - ty * self.sa, tx * self.sa + ty * self.ca

    # -- sources (linear light) ----------------------------------------------------------------------
    def core(self):
        P = self.P; th, d = self.th, self.d
        w = self.width(th)
        z = np.where(d < 0, -d / (0.52 * w), d / (0.48 * w))
        band = np.exp(-z ** 2.6)
        # intensity along the ring: hottest at the near, upper-left; the far edge is thinner and dimmer
        up = 0.5 * (1 - np.sin(th))
        gain = 0.55 + 0.45 * up ** 0.6
        slow = 1 + 0.16 * (self.noise(th * (16 / (2 * np.pi)), np.zeros_like(th) + 3.3) - 0.5) * 2
        # streaks across the band (long exposure fibres)
        zz = d / np.maximum(w, 1) * 22
        fib = self.noise(th * (16 / (2 * np.pi)) * 0.5 + 40, zz + 17)
        tex = 0.62 + 0.38 * fib
        return band * gain * slow * tex * P.core_gain

    def inner_ring(self):
        P = self.P
        # a thinner second ring just inside the first, a little lower, broken into arcs
        s = 0.915
        u2 = self.xr / (self.rx * s); v2 = (self.yr - 0.05 * self.ry) / (self.ry * s * 0.95)
        r2 = np.sqrt(u2 * u2 + v2 * v2) + 1e-6
        g2 = np.sqrt((u2 / (self.rx * s)) ** 2 + (v2 / (self.ry * s * 0.95)) ** 2) / r2
        d2 = (r2 - 1) / np.maximum(g2, 1e-9)
        th2 = np.arctan2(v2, u2)
        wd = self.rx * 0.010 * (1 + 0.8 * (0.5 * (1 - np.sin(th2))))
        line = np.exp(-(d2 / wd) ** 2)
        br = self.noise(th2 * (16 / (2 * np.pi)) * 1.5 + 9, np.full_like(th2, 5.5))
        arcs = smoothstep(0.32, 0.7, br)
        return line * arcs * 1.5 * P.inner_ring

    def fibers(self, rng, t=None):
        """Thin concentric arcs inside and around the band, like the grain of a long exposure."""
        P = self.P; shape = (self.H, self.W)
        n = P.fibers
        th0 = rng.uniform(-np.pi, np.pi, n)
        span = rng.uniform(0.25, 2.2, n)
        z0 = np.concatenate([rng.uniform(-0.55, 0.55, int(n * 0.6)), rng.uniform(-1.6, -0.6, int(n * 0.25)), rng.uniform(0.55, 1.9, n - int(n * 0.6) - int(n * 0.25))])
        rng.shuffle(z0)
        amp = np.exp(rng.normal(-0.2, 0.55, n)) * P.fiber_gain
        wob = rng.uniform(0, 6.28, n); wfreq = rng.uniform(2, 9, n)
        X, Y, Wt = [], [], []
        for i in range(n):
            length = span[i] * self.rx * 0.8
            m = max(int(length / 0.7), 2)
            th = th0[i] + span[i] * np.linspace(0, 1, m)
            w = self.width(th)
            d = z0[i] * w + 0.9 * np.sin(wob[i] + th * wfreq[i])
            x, y = self.ring_point(th, d)
            taper = np.sin(np.pi * np.linspace(0, 1, m)) ** 0.7
            fw = self.front_weight(th)
            X.append(x); Y.append(y); Wt.append(amp[i] * taper * 0.55 * np.where(np.abs(z0[i]) < 0.55, 1.0, 0.6))
            X[-1] = X[-1].astype(np.float32); Y[-1] = Y[-1].astype(np.float32)
            Wt[-1] = (Wt[-1], fw)
        x = np.concatenate(X); y = np.concatenate(Y)
        w_all = np.concatenate([a for a, _ in Wt]); fw = np.concatenate([b for _, b in Wt])
        return splat(shape, x, y, (w_all * fw).astype(np.float32)), splat(shape, x, y, (w_all * (1 - fw)).astype(np.float32))

    def debris(self, rng, t):
        """Short tangential specks around the ring. Each slot lives m times per loop and respawns elsewhere.
        t in [0,1) is the loop phase; t=None gives all specks at full strength (still image)."""
        P = self.P; shape = (self.H, self.W); n = P.debris
        lives = rng.integers(1, 4, n)
        phase = rng.random(n)
        K = 3
        # position of every life of every slot
        th = self._sample_theta(rng, n * K).reshape(n, K)
        side = rng.random((n, K))
        half = 0.5 * self.width(th)
        dist = np.where(side < 0.8, half * 0.85 + rng.exponential(0.026, (n, K)) * self.rx, -half * 0.9 - rng.exponential(0.014, (n, K)) * self.rx)
        length = np.exp(rng.normal(np.log(14.0), 0.6, (n, K)))
        skew = rng.normal(0, 0.10, (n, K)) + np.where(rng.random((n, K)) < 0.15, rng.normal(0, 0.5, (n, K)), 0)
        base = np.exp(rng.normal(-0.9, 0.9, (n, K)))
        if t is None:
            life = np.zeros(n, np.int64); env = np.ones(n); drift = np.zeros(n)
        else:
            s = t * lives + phase
            life = np.floor(s).astype(np.int64) % lives
            local = s - np.floor(s)
            env = np.sin(np.pi * local) ** 2
            drift = (local - 0.5) * 9.0
        ar = np.arange(n)
        th_, dist_, len_, skew_, base_ = th[ar, life], dist[ar, life], length[ar, life], skew[ar, life], base[ar, life]
        # each speck is a short arc that follows the ring (a streak of the orbiting dust)
        step = 0.6
        counts = np.maximum(np.ceil(len_ / step).astype(np.int64), 1) + 1
        total = counts.sum()
        idx = np.repeat(np.arange(n), counts)
        first = np.repeat(np.cumsum(counts) - counts, counts)
        tt = (np.arange(total) - first) / np.maximum(counts[idx] - 1, 1)
        per_rad = np.sqrt((self.rx * np.sin(th_)) ** 2 + (self.ry * np.cos(th_)) ** 2)
        thp = th_[idx] + (tt - 0.5) * len_[idx] / per_rad[idx] + drift[idx] / per_rad[idx]
        dp = dist_[idx] + skew_[idx] * len_[idx] * (tt - 0.5)
        x, y = self.ring_point(thp, dp)
        fall = np.exp(-np.abs(dist_) / (0.06 * self.rx))
        wgt = base_ * env * (0.3 + fall) * P.debris_gain * 1.1
        taper = np.sin(np.pi * tt) ** 0.6
        w_pt = wgt[idx] * taper * step
        fw = self.front_weight(thp)
        f = splat(shape, x.astype(np.float32), y.astype(np.float32), (w_pt * fw).astype(np.float32))
        b = splat(shape, x.astype(np.float32), y.astype(np.float32), (w_pt * (1 - fw)).astype(np.float32))
        return f, b

    def flow(self, rng, t, n=None):
        """Long, faint arcs that slide along the band and fade in and out: the shimmer of the long exposure.
        Seamless loop: every slot lives m times per loop and respawns at another place."""
        P = self.P; shape = (self.H, self.W); n = n or int(P.fibers * 0.7)
        K = 3
        lives = rng.integers(1, 4, n); phase = rng.random(n)
        th = rng.uniform(-np.pi, np.pi, (n, K))
        z = rng.uniform(-1.1, 1.3, (n, K))
        length = np.exp(rng.normal(np.log(70.0), 0.5, (n, K)))
        base = np.exp(rng.normal(-0.6, 0.5, (n, K)))
        s = t * lives + phase
        life = np.floor(s).astype(np.int64) % lives
        local = s - np.floor(s)
        env = np.sin(np.pi * local) ** 2
        ar = np.arange(n)
        th_, z_, len_, base_ = th[ar, life], z[ar, life], length[ar, life], base[ar, life]
        w = self.width(th_)
        per_rad = np.sqrt((self.rx * np.sin(th_)) ** 2 + (self.ry * np.cos(th_)) ** 2)
        step = 0.8
        counts = np.maximum(np.ceil(len_ / step).astype(np.int64), 1) + 1
        total = counts.sum()
        idx = np.repeat(np.arange(n), counts)
        first = np.repeat(np.cumsum(counts) - counts, counts)
        tt = (np.arange(total) - first) / np.maximum(counts[idx] - 1, 1)
        thp = th_[idx] + (tt - 0.5) * len_[idx] / per_rad[idx] + (local[idx] - 0.5) * 38.0 / per_rad[idx]
        dp = z_[idx] * w[idx] * 0.5
        x, y = self.ring_point(thp, dp)
        wgt = (base_ * env * P.flow_gain)[idx] * np.sin(np.pi * tt) ** 0.8 * step * 0.5
        fw = self.front_weight(thp)
        f = splat(shape, x.astype(np.float32), y.astype(np.float32), (wgt * fw).astype(np.float32))
        b = splat(shape, x.astype(np.float32), y.astype(np.float32), (wgt * (1 - fw)).astype(np.float32))
        return f, b

    def _sample_theta(self, rng, n):
        out = np.empty(0)
        while len(out) < n:
            c = rng.uniform(-np.pi, np.pi, n * 3)
            dens = (0.30 + 1.0 * np.exp(-((c + 0.35) / 0.8) ** 2) + 0.55 * np.exp(-((c + 2.4) / 0.7) ** 2)
                    + 0.35 * np.exp(-((np.abs(c) - np.pi) / 0.5) ** 2) + 0.25 * np.exp(-((c - 1.0) / 0.9) ** 2))
            out = np.concatenate([out, c[rng.random(len(c)) * 1.6 < dens]])
        return out[:n]

    # -- rays ----------------------------------------------------------------------------------------
    def ray_mask(self, rng):
        """Dust on the lens: uneven brightness of the rays by angle."""
        P = self.P
        ph = np.arctan2(self.v, self.u)
        n = P.ray_lobes
        tab = np.exp(rng.normal(0, 0.9, 1024)).astype(np.float32)
        tab = np.convolve(np.concatenate([tab[-8:], tab, tab[:8]]), np.ones(3) / 3, 'same')[8:-8]
        pos = (ph + np.pi) / (2 * np.pi) * n
        i0 = np.floor(pos).astype(np.int64); f = pos - i0
        big = np.exp(rng.normal(0, 0.5, n + 1)).astype(np.float32); big[-1] = big[0]
        m = big[i0 % n] * (1 - f) + big[(i0 + 1) % n] * f
        m = m ** 1.25
        horiz = 0.30 + 0.70 * np.cos(ph) ** 2 + 0.18 * np.maximum(np.sin(ph), 0)
        return (m / m.mean() * horiz).astype(np.float32)

    def zoom_rays(self, src, mask, n=44):
        """Long-exposure zoom: smear the bright parts radially (computed at quarter resolution)."""
        P = self.P
        k = 4
        s = downsample(src, k)
        h, w = s.shape
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        cx, cy = self.cx / k, self.cy / k
        out = np.zeros_like(s)
        sx_max = 1.55 * P.ray_len; sy_max = 1.10 * P.ray_len
        for i in range(n):
            f = i / (n - 1)
            sx = 1 + sx_max * f; sy = 1 + sy_max * f
            out += (1 - f) ** 1.6 * bilinear(s, (xx - cx) / sx + cx, (yy - cy) / sy + cy)
        out *= 0.012 * k * 0.5
        return upsample_to(out, src.shape) * mask

    # -- the flare at the hot spot --------------------------------------------------------------------
    def flare(self, phase=0.0):
        P = self.P
        th = -math.pi / 2 + 0.05 + 0.06 * math.sin(2 * math.pi * phase)
        x, y = self.ring_point(np.array([th]), np.array([0.0])); x, y = float(x[0]), float(y[0])
        dx, dy = self.xx - x, self.yy - y
        r = self.rx
        out = 40 * np.exp(-((dx / (0.07 * r)) ** 2 + (dy / (0.02 * r)) ** 2))
        out += 6 * np.exp(-((dx / (0.03 * r)) ** 2 + (dy / (0.09 * r)) ** 2))
        out += 2.4 * np.exp(-((dx / (0.34 * r)) ** 2 + (dy / (0.03 * r)) ** 2))
        # thin vertical shafts, longer upward than downward
        up = np.where(dy < 0, np.exp(-np.abs(dy) / (0.16 * r)), np.exp(-np.abs(dy) / (0.02 * r)))
        out += 0.5 * np.exp(-(dx / (0.004 * r)) ** 2) * up
        out += 0.2 * np.exp(-(dx / (0.012 * r)) ** 2) * up
        return out * P.flare * (1 + 0.1 * math.sin(2 * math.pi * phase + 1))

    # -- the full still image of each half ------------------------------------------------------------
    def build(self, t=None, with_static=True, with_anim=True):
        """Returns {'back': hdr, 'front': hdr} in linear light (before tone mapping)."""
        P = self.P
        rng = np.random.default_rng(P.seed)
        mask = self.ray_mask(np.random.default_rng(P.seed + 11))
        fw = self.front_weight(self.th)
        res = {}
        parts = {'front': np.zeros((self.H, self.W), np.float32), 'back': np.zeros((self.H, self.W), np.float32)}
        rays_src = {'front': np.zeros_like(parts['front']), 'back': np.zeros_like(parts['back'])}
        if with_static:
            core = self.core() + self.inner_ring()
            ff, fb = self.fibers(np.random.default_rng(P.seed + 2))
            parts['front'] += core * fw + ff
            parts['back'] += core * (1 - fw) + fb
            rays_src['front'] += core * fw * 0.5 + ff
            rays_src['back'] += core * (1 - fw) * 0.5 + fb
        if with_anim:
            df, db = self.debris(np.random.default_rng(P.seed + 3), t)
            parts['front'] += df; parts['back'] += db
            rays_src['front'] += df * 2.2; rays_src['back'] += db * 2.2
        for name in ('front', 'back'):
            hdr = self.lens(parts[name])
            if P.rays > 0:
                hdr += P.rays * self.lens_ray(self.zoom_rays(rays_src[name], mask))
            res[name] = hdr
        if with_static and with_anim:
            res['front'] += self.flare(0 if t is None else t) * 0.9
        return res

    def _finish(self, parts, rays_src, mask):
        res = {}
        for name in ('front', 'back'):
            hdr = self.lens(parts[name])
            if self.P.rays > 0:
                hdr += self.P.rays * self.lens_ray(self.zoom_rays(rays_src[name], mask))
            res[name] = hdr
        return res

    def _blank(self):
        z = lambda: np.zeros((self.H, self.W), np.float32)
        return {'front': z(), 'back': z()}, {'front': z(), 'back': z()}

    def build_static(self):
        """Everything that does not move: band, fibres, inner ring, glow, rays, the steady flare, a frozen far half of the dust."""
        P = self.P
        mask = self.ray_mask(np.random.default_rng(P.seed + 11))
        fw = self.front_weight(self.th)
        parts, rs = self._blank()
        core = self.core() + self.inner_ring()
        ff, fb = self.fibers(np.random.default_rng(P.seed + 2))
        parts['front'] += core * fw + ff; parts['back'] += core * (1 - fw) + fb
        rs['front'] += core * fw * 0.5 + ff; rs['back'] += core * (1 - fw) * 0.5 + fb
        df, db = self.debris(np.random.default_rng(P.seed + 3), None)
        parts['back'] += db * 0.7; rs['back'] += db * 1.5
        res = self._finish(parts, rs, mask)
        res['front'] += self.flare(0) * 0.9 * P.flare_static
        return res

    def build_anim(self, t):
        """What moves, front half only: flying dust, sliding streaks (all with their own rays). Loop phase t in [0,1)."""
        P = self.P
        mask = self.ray_mask(np.random.default_rng(P.seed + 11))
        parts, rs = self._blank()
        df, _ = self.debris(np.random.default_rng(P.seed + 3), t)
        ff, _ = self.flow(np.random.default_rng(P.seed + 5), t)
        parts['front'] += df + ff
        rs['front'] += df * 2.2 + ff * 0.6
        return self._finish(parts, rs, mask)['front']

    def edge_window(self):
        """Fade to zero at the edges of the canvas, so that the glow never ends with a visible line."""
        fx = smoothstep(0, 0.22, self.xx / self.W) * smoothstep(0, 0.22, 1 - self.xx / self.W)
        fy = smoothstep(0, 0.14, self.yy / self.H) * smoothstep(0, 0.14, 1 - self.yy / self.H)
        return (fx * fy).astype(np.float32)

    def tone(self, hdr):
        return (1 - np.exp(-hdr * self.P.exposure)) * self.edge_window()


# ---------------------------------------------------------------------------------------------- output

def png_bytes(rgba):
    h, w, _ = rgba.shape
    raw = b''.join(b'\x00' + rgba[y].tobytes() for y in range(h))
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def to_png_alpha(alpha_hi, path, seed=0, crop=None):
    """White light on transparency: RGB 255, alpha = brightness. Downsampled 2x, dithered against banding."""
    a = downsample(alpha_hi, 2)
    if crop:
        x0, y0, x1, y1 = crop; a = a[y0:y1, x0:x1]
    dither = (np.random.default_rng(seed).random(a.shape) - 0.5) / 255.0
    q = np.clip(np.round((a + dither * (a > 0.0005)) * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(a.shape + (4,), np.uint8)
    rgba[..., :3] = 255; rgba[..., 3] = q
    with open(path, 'wb') as f:
        f.write(png_bytes(rgba))
    return q


def to_png_gray_on_black(alpha_hi, path):
    a = downsample(alpha_hi, 2)
    g = np.clip(np.round(a * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(a.shape + (4,), np.uint8)
    rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    with open(path, 'wb') as f:
        f.write(png_bytes(rgba))


if __name__ == '__main__':
    import sys, time
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    t0 = time.time()
    h = Halo(Params())
    r = h.build(t=None)
    full = 1 - (1 - h.tone(r['front'])) * (1 - h.tone(r['back']))
    to_png_gray_on_black(full, os.path.join(out, 'test_full.png'))
    print('done in %.1fs' % (time.time() - t0))
