import sys, os
import tg_final as T
from tg_final import *

LOOKS = {                                   # name: (plane size in points per unit, muzzle lower by)
    'was': (0.46, 1.0),
    'v1': (0.37, 3.0),                      # the plane as wide as on the Telegram icon (54 % of the disc), the muzzle 2 pt lower
    'v2': (0.31, 5.0),
    'v3': (0.26, 7.0),
}

def render_variant(root, key):
    units, cy = LOOKS[key]
    T.set_look(units, 1.0 + (cy - 1.0))
    d = os.path.join(root, key); os.makedirs(d, exist_ok=True)
    _, da = T.disc_layer()
    sp = T.compose([T.plane_at()]); sf = T.compose([T.face_at(dict(scale=1.0))])
    T.to_png(*sp, os.path.join(d, 'plane.png'), 1); T.to_png(*sf, os.path.join(d, 'face.png'), 2)
    worst = 0.0
    for i in range(T.OUT_N):
        (pre, a), p, m = T.build_frame('quiet', 'out', i, T.OUT_N)
        if i == 0: pre, a = sp
        if i == T.OUT_N - 1: pre, a = sf
        worst = max(worst, T.overlap(p, m, da)); T.to_png(pre, a, os.path.join(d, 'out%02d.png' % i), 10 + i)
    for i in range(T.IN_N):
        (pre, a), p, m = T.build_frame('quiet', 'in', i, T.IN_N)
        if i == 0: pre, a = sf
        if i == T.IN_N - 1: pre, a = sp
        worst = max(worst, T.overlap(p, m, da)); T.to_png(pre, a, os.path.join(d, 'in%02d.png' % i), 50 + i)
    rd = os.path.join(d, 'rest'); os.makedirs(rd, exist_ok=True)
    for k in range(T.REST_N):
        if k in (0, T.REST_N - 1): pre, a = sf
        else:
            pre, a = T.compose([T.face_at(dict(scale=1.0 + 0.02 * math.sin(math.pi * k / (T.REST_N - 1)), dy=-0.6 * math.sin(math.pi * k / (T.REST_N - 1))))])
        T.to_png(pre, a, os.path.join(rd, 'r%02d.png' % k), 90 + k)
    # how big the plane is against the disc, for the record
    ys, xs = np.nonzero(sp[1] > 0.3)
    print(key, 'plane width %.1f pt = %.0f %% of the disc; muzzle %.1f pt lower than the middle; worst overlap %.1f px' % ((xs.max() - xs.min()) / T.PPT, 100 * (xs.max() - xs.min()) / T.PPT / 60, cy, worst), flush=True)

if __name__ == '__main__':
    for k in LOOKS: render_variant(sys.argv[1], k)
