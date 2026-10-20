#!/usr/bin/env python3
"""Step icon for YouTube and Discord, round, black and white. The black icon of YouTube would not show on the black disc, so its white play button
stands for it; the Discord mark is the second face of the icon (it comes on a tap) or stands next to the play button."""
import sys, os, math
import numpy as np
from icons_render import *                                        # X, Y, N, PPT, cov, capsule, disc, base_disc, gblur, ...
from tg_final import compose, finish_plain, soft, xform, over, add_glow, ease, ease_out3, ease_in3, clip01, smooth_step
from scene_render_shapes import mark_polygon_points

DISC = None


def poly_mask_pts(pts):
    """Even-odd fill of a polygon given in points from the middle of the picture."""
    px = np.array([p[0] for p in pts], np.float32); py = np.array([p[1] for p in pts], np.float32)
    sel = (X >= px.min() - 3) & (X <= px.max() + 3) & (Y >= py.min() - 3) & (Y <= py.max() + 3)
    inside = np.zeros(X.shape, bool); n = len(px)
    for i in range(n):
        ax, ay, bx, by = px[i], py[i], px[(i + 1) % n], py[(i + 1) % n]
        if ay == by: continue
        cond = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / (by - ay) + ax)
        inside ^= (cond & sel)
    return inside.astype(np.float32)


def pearl_grad(y0, y1, hi=0.99, lo=0.68):
    return hi + (lo - hi) * np.clip((Y - y0) / (y1 - y0), 0, 1)


def play_layer(lit=1.0, height=25.0, cx=0.0, cy=0.0):
    """A white, softly rounded play triangle (a little to the right of the middle of its box so that it looks centred)."""
    k = 0.30 + 0.70 * lit
    h = height / 2; w = height * 0.86
    pts = [(cx - w * 0.40, cy - h), (cx + w * 0.60, cy), (cx - w * 0.40, cy + h)]
    m = soft(poly_mask_pts(pts), 1.5)
    lum = pearl_grad(cy - h, cy + h) * (0.34 + 0.66 * k)
    return (lum * m).astype(np.float32), m.astype(np.float32)


def mark_layer(lit=1.0, width=34.0, cx=0.0, cy=0.0, blink=0.0, outline=0.0):
    """The Discord-style mark (the shape of the one in the app), pearl, with two dark eyes; blink 0..1 closes the eyes."""
    k = 0.30 + 0.70 * lit
    pts, M, (bw, bh) = mark_polygon_points()                     # points of the drawing, M maps the drawing's 0..100 x 0..76 box
    s = width / bw
    P = [((x - bw / 2) * s + cx, (y - bh / 2) * s + cy) for x, y in pts]
    m = soft(poly_mask_pts(P), 0.7)
    top, bot = cy - bh * s / 2, cy + bh * s / 2
    lum = pearl_grad(top, bot, 0.99, 0.66) * (0.34 + 0.66 * k)
    eyes = np.zeros_like(m); lids = np.zeros_like(m)
    for ex in (35.0, 65.0):
        ex_, ey_ = M(ex, 36.25); ex_ = (ex_ - bw / 2) * s + cx; ey_ = (ey_ - bh / 2) * s + cy
        rx, ry = 4.6 * s, 6.25 * s
        e = np.clip((1 - np.sqrt(((X - ex_) / rx) ** 2 + ((Y - ey_) / (ry * max(1 - blink * 0.92, 0.08))) ** 2)) * rx * PPT / 1.2 + 0.5, 0, 1)
        eyes = np.maximum(eyes, e)
    eye_l = (0.17 * (1 - np.clip((Y - (cy + 4 * s)) / (6 * s), 0, 1)) + 0.03)
    lum = lum * (1 - eyes) + eye_l * eyes
    out_m = m
    if outline > 0:
        ring = (gblur(m, outline * PPT) > 0.12).astype(np.float32)
        return (lum * m).astype(np.float32), m.astype(np.float32), ring
    return (lum * m).astype(np.float32), m.astype(np.float32)


def glyph_glow(alpha, strength=0.24):
    return gblur(alpha, 2.4 * PPT) * strength
