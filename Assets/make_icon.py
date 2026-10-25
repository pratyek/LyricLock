import numpy as np
from PIL import Image, ImageDraw, ImageFilter
S = 2048
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(len(a)))

# --- squircle mask (macOS icon grid: 824/1024 body) ---
body = int(S*824/1024); off = (S-body)//2
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
cx = cy = S/2; r = body/2
n = 5.0
d = (np.abs((xx-cx)/r)**n + np.abs((yy-cy)/r)**n)
mask = np.clip((1.0 - d) * 220, 0, 1)  # soft edge
mask_img = Image.fromarray((mask*255).astype(np.uint8))

# --- background: deep night gradient + warm glow ---
t = np.clip((yy - off)/body, 0, 1)
top = np.array([46, 24, 92], np.float32); bot = np.array([12, 8, 28], np.float32)
bg = top[None,None,:]*(1-t[...,None]) + bot[None,None,:]*t[...,None]
# radial glows
def glow(px, py, rad, col, k):
    g = np.exp(-(((xx-px)**2+(yy-py)**2)/(2*rad**2)))[...,None]
    return g*np.array(col, np.float32)*k
bg += glow(S*0.5, S*0.60, S*0.22, [255, 70, 140], 0.55)
bg += glow(S*0.62, S*0.70, S*0.18, [255, 150, 60], 0.35)
bg += glow(S*0.30, S*0.25, S*0.20, [120, 90, 255], 0.30)
bg = np.clip(bg, 0, 255).astype(np.uint8)
base = Image.fromarray(bg, 'RGB').convert('RGBA')

layer = Image.new('RGBA', (S,S), (0,0,0,0))
dr = ImageDraw.Draw(layer)

# --- lock shackle ---
sw = int(S*0.040)                       # stroke width
bw, bh = int(S*0.44), int(S*0.30)       # lock body
bx0 = (S-bw)//2; by0 = int(S*0.46); bx1 = bx0+bw; by1 = by0+bh
shw = int(bw*0.56)
sx0 = (S-shw)//2; sx1 = sx0+shw
sy0 = int(S*0.255)
shack = Image.new('RGBA', (S,S), (0,0,0,0))
ImageDraw.Draw(shack).rounded_rectangle([sx0, sy0, sx1, by0+shw//2], radius=shw//2, outline=(255,255,255,240), width=sw)
cut = Image.new('L', (S,S), 255); ImageDraw.Draw(cut).rectangle([0, by0+int(S*0.01), S, S], fill=0)
shack.putalpha(Image.fromarray((np.array(shack.split()[3]).astype(np.float32)*np.array(cut)/255).astype(np.uint8)))
layer = Image.alpha_composite(layer, shack)
dr = ImageDraw.Draw(layer)
# cut the bottom of the shackle where body sits (body drawn on top anyway)

# --- lock body: frosted glass ---
bodymask = Image.new('L', (S,S), 0)
ImageDraw.Draw(bodymask).rounded_rectangle([bx0, by0, bx1, by1], radius=int(S*0.07), fill=255)
frost = Image.alpha_composite(base, layer).filter(ImageFilter.GaussianBlur(S*0.03))
frost = Image.alpha_composite(frost, Image.new('RGBA', (S,S), (255,255,255,52)))
frost.putalpha(bodymask)
layer = Image.alpha_composite(layer, frost)
glass = Image.new('RGBA', (S,S), (0,0,0,0))
ImageDraw.Draw(glass).rounded_rectangle([bx0, by0, bx1, by1], radius=int(S*0.07), outline=(255,255,255,140), width=int(S*0.005))
layer = Image.alpha_composite(layer, glass)
dr = ImageDraw.Draw(layer)

# --- lyric lines inside body ---
lh = int(S*0.034)
cxm = S//2
lines = [ (0.52, int(by0+bh*0.27), (255,255,255,90)),
          (0.74, int(by0+bh*0.50), None),
          (0.40, int(by0+bh*0.73), (255,255,255,90)) ]
for frac, y, col in lines:
    w = int(bw*frac)
    x0 = cxm - w//2; x1 = cxm + w//2
    if col:
        dr.rounded_rectangle([x0, y-lh//2, x1, y+lh//2], radius=lh//2, fill=col)
    else:
        # glowing gradient line (pink -> orange)
        g = Image.new('RGBA', (S,S), (0,0,0,0))
        grad = np.zeros((lh+2, w, 4), np.uint8)
        for i in range(w):
            c = lerp((255, 92, 170), (255, 186, 90), i/max(w-1,1))
            grad[:, i, :3] = c; grad[:, i, 3] = 255
        m = Image.new('L', (w, lh+2), 0)
        ImageDraw.Draw(m).rounded_rectangle([0,0,w-1,lh+1], radius=lh//2, fill=255)
        gi = Image.fromarray(grad, 'RGBA'); gi.putalpha(m)
        g.paste(gi, (x0, y-lh//2-1), gi)
        # blur only the alpha and fill with glow colour (blurring RGBA directly drags in black)
        halo = Image.new('RGBA', (S,S), (255, 120, 150, 0))
        halo.putalpha(g.split()[3].filter(ImageFilter.GaussianBlur(S*0.022)).point(lambda v: int(v*0.85)))
        layer = Image.alpha_composite(layer, halo)
        layer = Image.alpha_composite(layer, halo)
        layer = Image.alpha_composite(layer, g)
        dr = ImageDraw.Draw(layer)

# soft shadow under the glyph
shadow = layer.split()[3].filter(ImageFilter.GaussianBlur(S*0.015))
sh = Image.new('RGBA', (S,S), (0,0,0,0)); sh.putalpha(shadow.point(lambda v: int(v*0.05)))
sh = sh.transform((S,S), Image.AFFINE, (1,0,0,0,1,-int(S*0.012)))
icon = Image.alpha_composite(base, sh)
icon = Image.alpha_composite(icon, layer)

# top sheen
sheen = np.zeros((S,S,4), np.uint8); st = np.clip(1-(yy-off)/(body*0.5),0,1)
sheen[...,:3] = 255; sheen[...,3] = (st*22).astype(np.uint8)
icon = Image.alpha_composite(icon, Image.fromarray(sheen,'RGBA'))

icon.putalpha(Image.fromarray((np.array(icon.split()[3]).astype(np.float32)/255*mask*255).astype(np.uint8)))
# drop shadow of the whole tile (macOS style)
tile_shadow = mask_img.filter(ImageFilter.GaussianBlur(S*0.012)).point(lambda v: int(v*0.45))
canvas = Image.new('RGBA', (S,S), (0,0,0,0))
ts = Image.new('RGBA', (S,S), (0,0,0,255)); ts.putalpha(tile_shadow)
ts = ts.transform((S,S), Image.AFFINE, (1,0,0,0,1,-int(S*0.01)))
canvas = Image.alpha_composite(canvas, ts)
canvas = Image.alpha_composite(canvas, icon)
master = canvas.resize((1024,1024), Image.LANCZOS)
master.save('AppIcon-1024.png')

import os
os.makedirs('AppIcon.iconset', exist_ok=True)
for sz in [16,32,128,256,512]:
    master.resize((sz,sz), Image.LANCZOS).save(f'AppIcon.iconset/icon_{sz}x{sz}.png')
    master.resize((sz*2,sz*2), Image.LANCZOS).save(f'AppIcon.iconset/icon_{sz}x{sz}@2x.png')
print('ok')
