#!/usr/bin/env python3
"""Step icons for Nimb (round, black and white): the glyph sits in a black glass disc, lit from above like everything else.
numpy only. All shapes are drawn here from simple primitives (signed distance fields); nothing is traced from other logos."""
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'halo'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'dog'))
from halo_render import smoothstep, downsample, png_bytes   # noqa: E402
from icon_render import gblur                                # noqa: E402

SS = 4
PPT = 2 * SS                                   # hi-res pixels per point
BOX = 80                                       # canvas, points
N = BOX * PPT
R = 30.0                                       # radius of the disc, points
C = N / 2
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
X = (xx + 0.5 - C) / PPT                       # coordinates in points from the middle, y down
Y = (yy + 0.5 - C) / PPT


def cov(sd, soft=1.1):
    """Coverage from a signed distance in points (positive inside)."""
    return np.clip(0.5 + sd * PPT / soft, 0, 1).astype(np.float32)


def capsule(ax, ay, bx, by, r):
    px, py = X - ax, Y - ay; ex, ey = bx - ax, by - ay
    t = np.clip((px * ex + py * ey) / (ex * ex + ey * ey), 0, 1)
    return r - np.hypot(px - t * ex, py - t * ey)


def disc(cx, cy, r):
    return r - np.hypot(X - cx, Y - cy)


def vesica(theta, r0, r1, width):
    """A lens-shaped petal along the direction theta, from r0 to r1 from the middle, with the given width."""
    L = r1 - r0
    Rp = (L * L / 4 + (width / 2) ** 2) / width            # radius of the two arcs
    d = Rp - width / 2
    ux, uy = math.cos(theta), math.sin(theta); nx, ny = -uy, ux
    mx, my = ux * (r0 + r1) / 2, uy * (r0 + r1) / 2
    a = Rp - np.hypot(X - (mx + nx * d), Y - (my + ny * d))
    b = Rp - np.hypot(X - (mx - nx * d), Y - (my - ny * d))
    return np.minimum(a, b)


def pearl(v0=0.99, v1=0.68, y0=-20, y1=20):
    u = np.clip((Y - y0) / (y1 - y0), 0, 1)
    return v0 + (v1 - v0) * u


def base_disc(lit=1.0):
    """The black glass disc: a soft light from above, a velvet sheen along the edge, a thin rim of light."""
    a = cov(disc(0, 0, R))
    inner = gblur(a, 0.16 * R * PPT)
    sheen = np.clip(1 - (inner - 0.5) * 2.2, 0, 1) ** 1.6
    u = np.clip((Y + R) / (2 * R), 0, 1)
    top = np.exp(-((X / 22) ** 2 + ((Y + 18) / 16) ** 2))
    k = 0.30 + 0.70 * lit
    lum = (0.014 + 0.035 * (1 - u) + 0.08 * top + 0.16 * sheen * (0.3 + 0.7 * (1 - u))) * (0.4 + 0.6 * k)
    edge = np.clip(a - gblur(a, 1.6 * SS), 0, 1)
    up = np.clip(-Y / R, 0, 1) * 0.7 + np.clip(-X / R, 0, 1) * 0.3
    lum = lum + edge * (0.10 + 0.55 * up) * k
    return lum, a


def finish(lum, alpha, glow_src, lit):
    """Compose and add the soft glow around the glyph."""
    g = glow_src
    pre = np.clip(lum, 0, 1) * alpha
    halo = gblur(alpha, 0.10 * R * PPT) * (0.05 + 0.06 * lit)
    ga = np.clip(halo, 0, 0.4) * (1 - alpha)
    return (pre + ga).astype(np.float32), (alpha + ga).astype(np.float32)


# ------------------------------------------------------------------------------------------------ the AI icon
def ai_flower(lit=1.0):
    """A rosette of six petals with a burst of rays between them: the idea of a chat mark (a flower knot) and of a spark (a burst) in one."""
    lum, a = base_disc(lit)
    k = 0.30 + 0.70 * lit
    glyph = np.zeros_like(lum)
    for i in range(6):
        th = math.radians(-90 + 60 * i)
        glyph = np.maximum(glyph, cov(vesica(th, 3.2, 18.5, 7.4)))
    rays = np.zeros_like(lum)
    for i in range(6):
        th = math.radians(-60 + 60 * i)
        ux, uy = math.cos(th), math.sin(th)
        rays = np.maximum(rays, cov(capsule(ux * 17.0, uy * 17.0, ux * 24.0, uy * 24.0, 0.8)))
        rays = np.maximum(rays, cov(disc(ux * 25.0, uy * 25.0, 1.3)))
    core = cov(disc(0, 0, 2.0))
    gl = np.maximum(glyph, rays) * (1 - core * 0.0)
    shade = pearl() * (0.35 + 0.65 * k)
    lum = lum * (1 - gl) + shade * gl
    lum = lum * (1 - core) + 0.02 * core
    return finish(lum + gblur(gl, 2.2 * PPT) * 0.30 * lit * a, a, gl, lit)


def hex_sdf(r, rot=0.0, round_=2.0):
    """Signed distance (positive inside) of a rounded regular hexagon of circumradius r."""
    px = X * math.cos(rot) + Y * math.sin(rot); py = -X * math.sin(rot) + Y * math.cos(rot)
    k = np.array([-0.8660254, 0.5, 0.57735027])
    px, py = np.abs(px), np.abs(py)
    d = k[0] * px + k[1] * py
    px -= 2 * np.minimum(d, 0) * k[0]; py -= 2 * np.minimum(d, 0) * k[1]
    inr = r * math.cos(math.pi / 6) - round_
    px -= np.clip(px, -k[2] * inr, k[2] * inr); py -= inr
    return -(np.hypot(px, py) * np.sign(py) - round_)


def ai_star(lit=1.0):
    """A hexagonal ring (a knot) with an asterisk of six rounded spokes inside it."""
    lum, a = base_disc(lit)
    k = 0.30 + 0.70 * lit
    ring = np.clip(np.minimum(cov(hex_sdf(23.5, 0.0, 8.0)), 1 - cov(hex_sdf(20.2, 0.0, 6.5))), 0, 1)
    spokes = np.zeros_like(lum)
    for i in range(3):
        th = math.radians(90 + 60 * i); ux, uy = math.cos(th), math.sin(th)
        spokes = np.maximum(spokes, cov(capsule(-ux * 13.0, -uy * 13.0, ux * 13.0, uy * 13.0, 2.0)))
    gl = np.maximum(ring, spokes)
    shade = pearl() * (0.35 + 0.65 * k)
    lum = lum * (1 - gl) + shade * gl
    return finish(lum + gblur(gl, 2.2 * PPT) * 0.28 * lit * a, a, gl, lit)


# ------------------------------------------------------------------------------------------------ the planet icons
def _noise3(x, y, z, seed=3):
    rng = np.random.default_rng(seed)
    out = 0
    for i in range(7):
        d = rng.normal(size=3); d /= np.linalg.norm(d)
        f = rng.uniform(1.6, 5.5); p = rng.uniform(0, 6.28); w = 1.0 / (0.6 + f * 0.35)
        out = out + w * np.sin(f * (d[0] * x + d[1] * y + d[2] * z) + p)
    return out


def planet(lit=1.0, sparkle=False, tilt=22.0, spin=-0.3):
    """The whole disc is a planet: dotted continents (made up, not a map), a fine graticule, light from the upper left, a thin bright rim."""
    a = cov(disc(0, 0, R))
    x, y = X / R, Y / R
    r2 = x * x + y * y
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    k = 0.30 + 0.70 * lit
    t = math.radians(tilt)
    yp = y * math.cos(t) - z * math.sin(t); zp = y * math.sin(t) + z * math.cos(t)
    lat = np.arcsin(np.clip(-yp, -1, 1)); lon = np.arctan2(x, zp) + spin
    L = np.array([-0.42, -0.58, 0.69]); L /= np.linalg.norm(L)
    lam = np.clip(x * L[0] + y * L[1] + z * L[2], 0, 1)
    ocean = 0.030 + 0.20 * lam ** 0.9
    # dots on land: a lattice in latitude and longitude with equal spacing
    D = math.radians(4.6)
    lat_i = np.round(lat / D) * D
    step = D / np.maximum(np.cos(lat_i), 0.12)
    lon_i = np.round(lon / step) * step
    px, py_, pz = np.cos(lat_i) * np.sin(lon_i), np.sin(lat_i), np.cos(lat_i) * np.cos(lon_i)
    land = _noise3(px * LAND_SCALE, py_ * LAND_SCALE, pz * LAND_SCALE) > _land_cut()
    dl = lat - lat_i; dn = (lon - lon_i) * np.cos(lat_i)
    ang = np.hypot(dl, dn)
    rad = 0.40 * D * (0.35 + 0.65 * z)
    dots = np.clip((rad - ang) / (0.10 * D), 0, 1) * land * (z > 0.06) * (np.abs(lat_i) < 1.30)
    dot_lum = (0.28 + 0.72 * lam ** 0.8) * 0.95
    # fine graticule
    gl = np.zeros_like(x)
    for q in (math.radians(30),):
        a1 = np.abs(((lat / q) + 0.5) % 1 - 0.5) * q; a2 = np.abs(((lon / q) + 0.5) % 1 - 0.5) * q * np.cos(lat)
        gl = np.maximum(gl, np.clip(1 - np.minimum(a1, a2) / 0.012, 0, 1))
    lum = ocean + gl * 0.05 * (0.3 + lam) + dots * (dot_lum - ocean)
    # a thin bright rim and a faint air around the planet
    fres = np.clip(1 - z, 0, 1) ** 3
    up = np.clip(-y, 0, 1) * 0.7 + np.clip(-x, 0, 1) * 0.3
    lum = lum + fres * (0.10 + 0.60 * up) * 0.9
    edge = np.clip(a - gblur(a, 1.6 * SS), 0, 1)
    lum = lum + edge * (0.10 + 0.5 * up)
    lum = lum * (0.40 + 0.60 * k)
    glyph = np.zeros_like(lum)
    if sparkle:
        s1 = (np.abs(X) / 11.5) ** 0.62 + (np.abs(Y) / 11.5) ** 0.62
        star = np.clip((1 - s1) * 3.2, 0, 1)
        d = X * math.cos(math.pi / 4) + Y * math.sin(math.pi / 4); e = -X * math.sin(math.pi / 4) + Y * math.cos(math.pi / 4)
        s2 = (np.abs(d) / 4.6) ** 0.62 + (np.abs(e) / 4.6) ** 0.62
        star = np.maximum(star, np.clip((1 - s2) * 3.2, 0, 1) * 0.0)
        glyph = star * a
        lum = lum * (1 - 0.55 * gblur(glyph, 2.5 * PPT))          # the planet darkens a little around the star so that it reads
        lum = lum * (1 - glyph) + pearl() * (0.35 + 0.65 * k) * glyph
        lum = lum + gblur(glyph, 3.0 * PPT) * 0.30 * lit
    return finish(lum, a, glyph, lit)


LAND_SCALE, LAND_SHARE = 1.35, 0.60            # the size of the continents, and which part of the surface is sea (0.60 = 60 %)
_cut = None


def _land_cut():
    global _cut
    if _cut is None:
        v = np.random.default_rng(1).normal(size=(30000, 3)); v /= np.linalg.norm(v, axis=1)[:, None]
        _cut = float(np.percentile(_noise3(v[:, 0] * LAND_SCALE, v[:, 1] * LAND_SCALE, v[:, 2] * LAND_SCALE), 100 * LAND_SHARE))
    return _cut


ICONS = {
    'ai-flower': ai_flower, 'ai-star': ai_star,
    'ai-planet': lambda lit=1.0: planet(lit, False), 'ai-planet-spark': lambda lit=1.0: planet(lit, True),
}


def to_png(pre, alpha, path, seed=0):
    p = downsample(pre, SS); a = downsample(alpha, SS)
    straight = np.where(a > 1e-4, p / np.maximum(a, 1e-4), 0)
    rng = np.random.default_rng(seed)
    q = np.clip(np.round(straight * 255 + (rng.random(a.shape) - 0.5)), 0, 255).astype(np.uint8)
    qa = np.clip(np.round(a * 255 + (rng.random(a.shape) - 0.5) * (a > 0.002)), 0, 255).astype(np.uint8)
    rgba = np.empty(a.shape + (4,), np.uint8); rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = q; rgba[..., 3] = qa
    open(path, 'wb').write(png_bytes(rgba))


def on_black(pre, path):
    p = np.clip(downsample(pre, SS), 0, 1); g = np.clip(np.round(p * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    open(path, 'wb').write(png_bytes(rgba))


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    tiles = []
    for name, fn in ICONS.items():
        pre, a = fn(1.0)
        tiles.append(np.clip(downsample(pre, 2), 0, 1))
    m = np.concatenate(tiles, axis=1)
    g = np.clip(np.round(m * 255), 0, 255).astype(np.uint8)
    rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
    open(os.path.join(out, 'ai_test.png'), 'wb').write(png_bytes(rgba))
