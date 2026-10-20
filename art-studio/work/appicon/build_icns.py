#!/usr/bin/env python3
"""Builds the two .icns of the chosen pair (variant 2) from the 1024 masters. Every size is scaled down from the master (premultiplied, box filter)."""
import os, sys, subprocess, shutil
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'dog')); sys.path.insert(0, os.path.join(HERE, '..', 'halo'))
from pngread import read_png
from halo_render import png_bytes

DEST = os.path.join(HERE, '..', '..', 'deliver', 'app-icon'); os.makedirs(DEST, exist_ok=True)
ENTRIES = [('icon_16x16', 16), ('icon_16x16@2x', 32), ('icon_32x32', 32), ('icon_32x32@2x', 64), ('icon_128x128', 128),
           ('icon_128x128@2x', 256), ('icon_256x256', 256), ('icon_256x256@2x', 512), ('icon_512x512', 512), ('icon_512x512@2x', 1024)]

def scaled(img, s):
    if s == 1024: return img
    a = img[..., 3:4].astype(np.float32) / 255
    pre = np.concatenate([img[..., :3].astype(np.float32) * a, a * 255], -1)
    k = 1024 // s
    sm = pre.reshape(s, k, s, k, 4).mean(axis=(1, 3))
    al = sm[..., 3:4] / 255
    rgb = np.where(al > 1e-4, sm[..., :3] / np.maximum(al, 1e-4), 0)
    return np.concatenate([np.clip(np.round(rgb), 0, 255), np.clip(np.round(sm[..., 3:4]), 0, 255)], -1).astype(np.uint8)

for state, name in (('idle', 'icon-idle'), ('active', 'icon-active')):
    master = read_png(os.path.join(HERE, 'out', 'v2-%s-1024.png' % state))
    iconset = os.path.join(HERE, name + '.iconset'); shutil.rmtree(iconset, ignore_errors=True); os.makedirs(iconset)
    for fn, s in ENTRIES:
        open(os.path.join(iconset, fn + '.png'), 'wb').write(png_bytes(scaled(master, s)))
    open(os.path.join(DEST, name + '-1024.png'), 'wb').write(png_bytes(master))
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(DEST, name + '.icns')], check=True)
    print(name, 'ok')
