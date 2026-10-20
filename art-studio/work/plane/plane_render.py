#!/usr/bin/env python3
"""A folded paper plane as a tiny 3D model: faces with creases, lit from above, rendered at any bank angle (numpy only)."""
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'halo'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'dog'))
from halo_render import smoothstep, downsample, png_bytes   # noqa: E402
from icon_render import gblur                                # noqa: E402

SS = 4
OUT = 128                         # output px (64 x 64 pt)
N = OUT * SS
LEN_PT = 40.0                     # length of the plane in points (before foreshortening)
S = LEN_PT * 2 * SS / 2.0         # hi-res px per model unit (the model is 2 units long)


class Model:
    """Vertices and triangles. Each triangle: (a, b, c, role). Roles: 'in' inner wing, 'out' outer wing, 'flap' ."""
    def __init__(self, v, tris, creases):
        self.v = {k: np.array(p, np.float32) for k, p in v.items()}
        self.tris = tris
        self.creases = creases        # per triangle: list of vertex names opposite the crease edges


def classic(span=0.80, depth=0.95, dih=0.22):
    v = {
        'N': (0, 1.0, 0.0),
        'K': (0, -depth * 0.74, -0.16),          # the keel at the tail: the notch of the trailing edge
        'QL': (-span * 0.48, -depth, 0.0), 'QR': (span * 0.48, -depth, 0.0),
        'WL': (-span, -depth, dih), 'WR': (span, -depth, dih),
        'KB': (0, -depth * 0.55, -0.30),         # the lowest point of the keel, seen when banked
    }
    tris = [
        ('N', 'K', 'QL', 'in'), ('N', 'QL', 'WL', 'out'),
        ('N', 'QR', 'K', 'in'), ('N', 'WR', 'QR', 'out'),
    ]
    creases = [['K'], ['WL'], ['K'], ['WR']]
    return Model(v, tris, creases)


def arrow():
    return classic(span=0.40, depth=1.05, dih=0.16)


class Look:
    def __init__(self, name, paper=1.0, edge_glow=0.0, face_dark=0.0, crease=0.28):
        self.name, self.paper, self.edge_glow, self.face_dark, self.crease = name, paper, edge_glow, face_dark, crease


def rotate(p, roll, tilt):
    cr, sr = math.cos(roll), math.sin(roll)
    x = p[0] * cr - p[2] * sr; z = p[0] * sr + p[2] * cr; y = p[1]
    ct, st = math.cos(tilt), math.sin(tilt)
    y2 = y * ct - z * st; z2 = y * st + z * ct
    return np.array([x, y2, z2], np.float32)


def render(model, look, roll_deg=0.0, tilt_deg=26.0, yaw_deg=0.0, glow=1.0):
    roll, tilt = math.radians(roll_deg), math.radians(tilt_deg)
    yaw = math.radians(yaw_deg)
    cy_, sy_ = math.cos(yaw), math.sin(yaw)
    P = {}
    for k, p in model.v.items():
        q = rotate(p, roll, tilt)
        P[k] = np.array([q[0] * cy_ - q[1] * sy_, q[0] * sy_ + q[1] * cy_, q[2]], np.float32)
    # centre the plane's middle on the canvas
    mid = (P['N'] + P['K']) / 2
    L = np.array([-0.50, 0.02, 0.87], np.float32); L /= np.linalg.norm(L)
    img = np.zeros((N, N), np.float32); alpha = np.zeros((N, N), np.float32)
    zbuf = np.full((N, N), -1e9, np.float32)
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    shade = np.zeros((N, N), np.float32)
    for (a, b, c, role), cre in zip(model.tris, model.creases):
        pa, pb, pc = P[a], P[b], P[c]
        pts = np.array([[N / 2 + S * (p[0] - mid[0]), N / 2 - S * (p[1] - mid[1])] for p in (pa, pb, pc)], np.float32)
        x0 = int(max(pts[:, 0].min() - 2, 0)); x1 = int(min(pts[:, 0].max() + 3, N)); y0 = int(max(pts[:, 1].min() - 2, 0)); y1 = int(min(pts[:, 1].max() + 3, N))
        if x1 <= x0 or y1 <= y0: continue
        X = xx[y0:y1, x0:x1] + 0.5; Y = yy[y0:y1, x0:x1] + 0.5
        (ax, ay), (bx, by), (cx, cy) = pts
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-6: continue
        w0 = ((by - cy) * (X - cx) + (cx - bx) * (Y - cy)) / den
        w1 = ((cy - ay) * (X - cx) + (ax - cx) * (Y - cy)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        z = w0 * pa[2] + w1 * pb[2] + w2 * pc[2]
        win = inside & (z > zbuf[y0:y1, x0:x1])
        if not win.any(): continue
        n = np.cross(pb - pa, pc - pa); n /= (np.linalg.norm(n) + 1e-9)
        back = n[2] < 0
        if back: n = -n
        lam = float(np.dot(n, L))
        base = 0.10 + 1.0 * np.clip(lam * 1.15 + 0.30, 0, 1) ** 1.2
        if back: base *= 0.60
        w = {a: w0, b: w1, c: w2}
        # brighter towards the nose, a very soft gradient across every face
        ynorm = (w0 * pa[1] + w1 * pb[1] + w2 * pc[1] - P['K'][1]) / max(P['N'][1] - P['K'][1], 1e-6)
        base = base * (0.80 + 0.28 * np.clip(ynorm, 0, 1))
        # soft occlusion deep in the valley along the keel, dark creases between the wing faces
        ao = np.ones_like(w0)
        if role == 'in':
            q = [name for name in (a, b, c) if name.startswith('Q')][0]    # the vertex across from the keel line
            ao = 1 - 0.55 * (1 - smoothstep(0.0, 0.32, w[q]))
        line = np.zeros_like(w0)
        for vname in cre:
            line = np.maximum(line, np.exp(-(w[vname] / 0.016) ** 2))
        s_ = base * ao * (1 - look.crease * line) * look.paper
        # a thin bright edge of the paper along the leading edge of the outer wings
        rim = np.zeros_like(w0)
        if role == 'out':
            q = [name for name in (a, b, c) if name.startswith('Q')][0]
            rim = np.exp(-(w[q] / 0.011) ** 2)
        s_ = s_ + 0.55 * rim * (1 - look.face_dark)
        edge = np.exp(-(np.minimum(np.minimum(w0, w1), w2) / 0.010) ** 2)
        if look.face_dark:
            s_ = 0.015 + 0.20 * s_ * look.face_dark + (1 - look.face_dark) * s_
        if not look.face_dark:
            s_ = s_ * 1.6
            s_ = np.where(s_ < 0.8, s_, 0.8 + 0.2 * np.tanh((s_ - 0.8) / 0.2))
        sh = s_ + look.edge_glow * edge
        zs = zbuf[y0:y1, x0:x1]; sub = shade[y0:y1, x0:x1]; al = alpha[y0:y1, x0:x1]
        sub[win] = sh[win]; zs[win] = z[win]; al[win] = 1.0
    return shade, alpha, P, mid


def finish(shade, alpha, bloom=0.0):
    pre = np.clip(shade, 0, 1.2) * alpha
    a = alpha.copy()
    if bloom:
        g = gblur(np.clip(shade, 0, 1.5) * alpha, 5.0 * SS / 4) * bloom + gblur(np.clip(shade, 0, 1.5) * alpha, 14.0 * SS / 4) * bloom * 0.6
        ga = np.clip(g, 0, 0.9) * (1 - alpha)
        pre = pre + ga; a = a + ga
    return pre, a


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


LOOKS = {
    'paper': (classic, Look('paper')),
    'arrow': (arrow, Look('arrow', crease=0.22)),
    'edge': (classic, Look('edge', face_dark=1.0, edge_glow=1.1, crease=0.0)),
}


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    for name, (maker, look) in LOOKS.items():
        tiles = []
        for roll in (-24, 0, 24):
            sh, al, P, mid = render(maker(), look, roll_deg=roll)
            pre, a = finish(sh, al, bloom=0.5 if look.edge_glow else 0.0); tiles.append(np.clip(pre, 0, 1))
        m = np.concatenate(tiles, axis=1)
        g = np.clip(np.round(m * 255), 0, 255).astype(np.uint8)
        rgba = np.empty(g.shape + (4,), np.uint8); rgba[..., :3] = g[..., None]; rgba[..., 3] = 255
        open(os.path.join(out, 'plane_%s.png' % name), 'wb').write(png_bytes(rgba))
