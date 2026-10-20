import sys, os, json, time
from halo_render import *
over = json.loads(sys.argv[1]) if len(sys.argv)>1 else {}
name = sys.argv[2] if len(sys.argv)>2 else 'tune'
h = Halo(Params(**over))
r = h.build(t=None)
full = 1-(1-h.tone(r['front']))*(1-h.tone(r['back']))
to_png_gray_on_black(full, name+'.png')
