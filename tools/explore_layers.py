#!/usr/bin/env python3
"""Explore War1 layers: depth order, opacity per row, palette previews."""
from PIL import Image
import numpy as np
import os

SRC = os.path.join(os.path.dirname(__file__), "..", "assets", "PNG", "War1", "Bright")
OUT = "/tmp/opencode/preview"
os.makedirs(OUT, exist_ok=True)

W, H = 320, 200  # visible window

def load(name, scale=True):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA")
    if scale:
        im = im.resize((W, H), Image.BOX)
    return im

sky   = load("sky.png")
sun   = load("sun.png")
ruins = load("ruins.png")
h3    = load("house3.png")
h2    = load("houses2.png")
h1    = load("houses1.png")
fence = load("fence.png")
road  = load("road.png")
cr1   = load("crater1.png")
cr2   = load("crater2.png")
cr3   = load("crater3.png")

def comp(layers, base=None):
    if base is None:
        base = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    for l in layers:
        base = Image.alpha_composite(base, l)
    return base

# candidate depth orders
orders = {
    "A": [sun, ruins, h3, h2, h1, fence, road, cr1, cr2, cr3],
    "B": [sun, ruins, h2, h3, h1, fence, road, cr1, cr2, cr3],
    "C": [sun, h3, ruins, h2, h1, fence, road, cr1, cr2, cr3],
}
ref = Image.open(os.path.join(SRC, "War.png")).convert("RGB").resize((W, H), Image.BOX)
refa = np.asarray(ref).astype(np.int32)
for name, layers in orders.items():
    full = comp([sky] + layers)
    arr = np.asarray(full.convert("RGB")).astype(np.int32)
    diff = np.abs(arr - refa).mean()
    print(f"order {name}: mean abs diff vs War.png = {diff:.2f}")
    full.convert("RGB").save(f"{OUT}/order_{name}.png")

# per-row opacity for mid and near
mid = comp([ruins, h3, h2], Image.new("RGBA", (W, H), (0, 0, 0, 0)))
near = comp([h1, fence, road, cr1, cr2, cr3], Image.new("RGBA", (W, H), (0, 0, 0, 0)))
mid_a = np.asarray(mid.getchannel("A"))
near_a = np.asarray(near.getchannel("A"))
print("\nrow opacity (alpha>128):")
print(" row   mid%  near%")
for y in range(0, H, 5):
    print(f"{y:4d}  {100*(mid_a[y]>128).mean():5.1f}  {100*(near_a[y]>128).mean():5.1f}")

# find first row after which mid opacity >= 98% for all remaining rows
def split_row(a, thresh=0.98):
    frac = (a > 128).mean(axis=1)
    for y in range(H):
        if (frac[y:] >= thresh).all():
            return y
    return None
sm = split_row(mid_a)
sn = split_row(near_a)
print(f"\nmid fully-opaque from row: {sm}")
print(f"near fully-opaque from row: {sn}")

# bounding row of non-empty content
for nm, a in [("mid", mid_a), ("near", near_a)]:
    rows = np.where((a > 128).any(axis=1))[0]
    print(f"{nm}: first content row {rows.min()}, last {rows.max()}")

mid.convert("RGB").save(f"{OUT}/mid_rgba_on_black.png")
near.convert("RGB").save(f"{OUT}/near_rgba_on_black.png")
Image.alpha_composite(sky, mid).convert("RGB").save(f"{OUT}/mid_on_sky.png")
