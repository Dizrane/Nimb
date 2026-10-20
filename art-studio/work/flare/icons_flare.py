import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'halo')); sys.path.insert(0, os.path.join(HERE, '..', 'appicon'))
import halo_render as hr
hr.PX = 8
from halo_render import to_png_alpha
from make_halo import VARIANTS
import render_flare_variants as rf
import make_icons as mi
big = os.path.join(HERE, '..', 'appicon', 'halo-big')
P = VARIANTS['photo']['params']
for mode in 'BCD':
    h = rf.FlareHalo(P); h.mode = mode; st = h.build_static()
    to_png_alpha(h.tone(st['back']), os.path.join(big, mode + '-back.png'), 1)
    to_png_alpha(h.tone(st['front']), os.path.join(big, mode + '-front.png'), 2)
import shutil
for a in ('back', 'front'): shutil.copy(os.path.join(big, 'photo-%s.png' % a), os.path.join(big, 'A-%s.png' % a))
mi.OUT = os.path.join(HERE, 'icons'); os.makedirs(mi.OUT, exist_ok=True)
for mode in 'ABCD':
    mi.PHOTO = (mode + '-back.png', mode + '-front.png')
    for st in ('idle', 'active'):
        mi.finish(mi.compose(2, st), '%s-%s' % (mode, st), size_list=(512, 128))
        print(mode, st, flush=True)
