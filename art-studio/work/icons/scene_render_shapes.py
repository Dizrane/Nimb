"""The outline of the Discord-style mark of the app (ScreenArt.swift), as points of its own drawing box (100 x 76 units wide and tall of 66 x 50 in the old drawing)."""
import numpy as np


def _bez(p0, p1, p2, p3, n=30):
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    p0, p1, p2, p3 = map(np.array, (p0, p1, p2, p3))
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def mark_polygon_points():
    W_, H_ = 66.0, 50.0
    def M(x, y): return (x / 100 * W_, y / 76 * H_)
    segs = [(M(21, 7), M(29, 3), M(36, 5), M(41, 9)), (M(41, 9), M(47, 8), M(53, 8), M(59, 9)), (M(59, 9), M(64, 5), M(71, 3), M(79, 7)),
            (M(79, 7), M(90, 15), M(97, 36), M(98, 58)), (M(98, 58), M(91, 63), M(83, 67), M(75, 70)), (M(75, 70), M(73, 67), M(71, 64), M(70, 62)),
            (M(70, 62), M(57, 66), M(43, 66), M(30, 62)), (M(30, 62), M(29, 64), M(27, 67), M(25, 70)), (M(25, 70), M(17, 67), M(9, 63), M(2, 58)),
            (M(2, 58), M(3, 36), M(10, 15), M(21, 7))]
    pts = np.concatenate([_bez(*s) for s in segs])
    pts = [(float(x), float(y)) for x, y in pts]
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    # the bounding box of the shape, so that it can be centred
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    pts = [(x - (x0 + x1) / 2 + W_ / 2 * 0 + (x1 - x0) / 2, y - (y0 + y1) / 2 + (y1 - y0) / 2) for x, y in pts]
    def Mc(x, y):
        a, b = M(x, y); return (a - x0, b - y0)
    return pts, Mc, (x1 - x0, y1 - y0)
