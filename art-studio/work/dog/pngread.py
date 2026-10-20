import struct, zlib
import numpy as np

def read_png(path):
    d = open(path, 'rb').read()
    pos = 8; idat = b''; ihdr = None
    while pos < len(d):
        n, = struct.unpack('>I', d[pos:pos + 4]); tag = d[pos + 4:pos + 8]
        if tag == b'IHDR': ihdr = struct.unpack('>IIBBBBB', d[pos + 8:pos + 21])
        if tag == b'IDAT': idat += d[pos + 8:pos + 8 + n]
        pos += 12 + n
    w, h, depth, ctype, _, _, inter = ihdr
    assert depth == 8 and ctype in (2, 6) and inter == 0
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp
    out = np.zeros((h, stride), np.uint8); prev = np.zeros(stride, np.int32); p = 0
    for y in range(h):
        f = raw[p]; line = np.frombuffer(raw[p + 1:p + 1 + stride], np.uint8).astype(np.int32); p += 1 + stride
        if f == 0: cur = line
        elif f == 1:
            cur = line.copy()
            for i in range(bpp, stride): cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif f == 2: cur = (line + prev) & 255
        elif f == 3:
            cur = line.copy()
            for i in range(stride): cur[i] = (cur[i] + (((cur[i - bpp] if i >= bpp else 0) + prev[i]) >> 1)) & 255
        else:
            cur = line.copy()
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
                pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 255
        out[y] = cur; prev = cur
    img = out.reshape(h, w, bpp)
    if bpp == 3: img = np.concatenate([img, np.full((h, w, 1), 255, np.uint8)], axis=2)
    return img
