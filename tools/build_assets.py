#!/usr/bin/env python3
"""
Parallax demo asset generator for the Amiga 1200 blitter demo.

Source: craftpix "War1" bright layered background (1920x1080).
Output: planar 5-bitplane strips + mask planes, palette, and a static
background, plus a C header describing the layout.

Screen: 352x256, 5 planes, visible 320x200 window at (16,28).
Layers are mirror-tiled (period 640 px) and scrolled in 1-pixel steps
using the blitter's barrel shifter.
"""
import os, struct, sys
from PIL import Image
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "assets", "PNG", "War1", "Bright")
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/opencode/amiga_hd/parallax/data"
HDRDIR = os.path.join(HERE, "..", "src")
PREVDIR = "/tmp/opencode/preview"
os.makedirs(OUTDIR, exist_ok=True)
os.makedirs(PREVDIR, exist_ok=True)

# ---- geometry ----
SCREEN_W, SCREEN_H = 352, 256
WIN_X, WIN_Y = 16, 28
WIN_W, WIN_H = 320, 200
DEPTH = 5
NCOL = 1 << DEPTH
SCENE_W = WIN_W                 # 320
PERIOD = SCENE_W * 2            # 640 (mirror tile)
RUNOUT = 352                    # >= blit width
STRIP_W = PERIOD + RUNOUT       # 992
assert STRIP_W % 16 == 0
STRIP_BYTES = STRIP_W // 8       # 124
STRIP_WORDS = STRIP_W // 16      # 62

# Band split points (window coordinates), from opacity analysis.
MID_TOP = 27                    # mid layer fully opaque 27..199 (sky/black prefill)
NEAR_TOP, NEAR_SPLIT = 126, 171 # masked 126..170, opaque 171..199
MID_OPAQUE_H = WIN_H - MID_TOP
NEAR_MASK_H = NEAR_SPLIT - NEAR_TOP
NEAR_OPAQUE_H = WIN_H - NEAR_SPLIT

# scroll speeds, 16.16 fixed point (px/frame)
MID_SPEED = 0x6000    # 0.375
NEAR_SPEED = 0x10000  # 1.0

# ---- load layers, scaled to the 320x200 scene ----
def load(name):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA")
    return im.resize((SCENE_W, WIN_H), Image.BOX)

layers = {n: load(n + ".png") for n in
          ["sky", "sun", "ruins", "house3", "houses2", "houses1",
           "fence", "road", "crater1", "crater2", "crater3"]}

def over(base, *tops):
    out = base
    for t in tops:
        out = Image.alpha_composite(out, t)
    return out

BLANK = Image.new("RGBA", (SCENE_W, WIN_H), (0, 0, 0, 0))
BLACK = Image.new("RGBA", (SCENE_W, WIN_H), (0, 0, 0, 255))

bg_scene   = over(layers["sky"], layers["sun"])
mid_scene  = over(BLANK, layers["ruins"], layers["house3"], layers["houses2"])
near_scene = over(BLANK, layers["houses1"], layers["fence"], layers["road"],
                  layers["crater1"], layers["crater2"], layers["crater3"])
full_scene = over(BLANK, layers["sky"], layers["sun"], layers["ruins"],
                  layers["house3"], layers["houses2"], layers["houses1"],
                  layers["fence"], layers["road"], layers["crater1"],
                  layers["crater2"], layers["crater3"])

# ---- palette: distinct 12-bit colours, black at index 0 ----
def build_palette(img, ncol):
    arr = np.asarray(img.convert("RGB")) >> 4
    codes = ((arr[..., 0].astype(np.int32) << 8) |
             (arr[..., 1].astype(np.int32) << 4) | arr[..., 2])
    uniq, counts = np.unique(codes.ravel(), return_counts=True)
    order = np.argsort(counts)[::-1]
    colors = [(0, 0, 0)]           # index 0 = black
    seen = {(0, 0, 0)}
    for i in order:
        c = int(uniq[i])
        col = (c >> 8, (c >> 4) & 15, c & 15)
        if col in seen:
            continue
        # keep some separation so near-identical colours don't waste slots
        if any(abs(col[0]-p[0]) + abs(col[1]-p[1]) + abs(col[2]-p[2]) < 2
               for p in colors):
            continue
        colors.append(col)
        seen.add(col)
        if len(colors) == ncol:
            break
    # fill any remaining slots with the next distinct frequent colours
    if len(colors) < ncol:
        for i in order:
            c = int(uniq[i])
            col = (c >> 8, (c >> 4) & 15, c & 15)
            if col not in seen:
                colors.append(col)
                seen.add(col)
                if len(colors) == ncol:
                    break
    while len(colors) < ncol:
        colors.append((0, 0, 0))
    pal8 = []
    for (r, g, b) in colors:
        pal8 += [r * 17, g * 17, b * 17]
    pal8 += [0] * (768 - len(pal8))
    pimg = Image.new("P", (1, 1))
    pimg.putpalette(pal8)
    rgb4 = [v for c in colors for v in c]
    return pimg, rgb4, pal8

pal_img, pal4, pal8 = build_palette(full_scene, NCOL)

def quantize(img, bg=BLACK):
    """Quantize an RGBA image over a background to the shared palette."""
    rgb = Image.alpha_composite(bg.copy(), img).convert("RGB")
    return np.asarray(rgb.quantize(palette=pal_img, dither=Image.FLOYDSTEINBERG))

def alpha_of(img):
    return np.asarray(img.getchannel("A")) > 128

mid_idx_full  = quantize(mid_scene)
mid_alpha     = alpha_of(mid_scene)
near_idx_full = quantize(near_scene)
near_alpha    = alpha_of(near_scene)

# ---- static background: sky + small sun above the mid band ----
sky_scene = layers["sky"]
bg_scene = sky_scene.copy()
sun_orig = Image.open(os.path.join(SRC, "sun.png")).convert("RGBA")
sun_disk = sun_orig.crop(sun_orig.getchannel("A").getbbox()).resize((30, 30), Image.LANCZOS)
bg_scene.alpha_composite(sun_disk, (60, 0))

def quantize_nd(img):
    return np.asarray(img.convert("RGB").quantize(palette=pal_img, dither=Image.NONE))

bg_idx_scene = quantize_nd(Image.alpha_composite(BLACK.copy(), bg_scene))

# ---- mid layer is fully opaque: sky above silhouette, black holes ----

sky_q = quantize_nd(sky_scene)
sky_idx = np.array([np.bincount(sky_q[y], minlength=NCOL).argmax()
                    for y in range(WIN_H)], dtype=np.uint8)

sil_top = np.full(SCENE_W, WIN_H, dtype=np.int32)
for x in range(SCENE_W):
    rows = np.where(mid_alpha[:, x])[0]
    if len(rows):
        sil_top[x] = rows[0]

mid_idx_filled = mid_idx_full.copy()
yy, xx = np.indices((WIN_H, SCENE_W))
transparent = ~mid_alpha
above = yy < sil_top[xx]
mid_idx_filled[transparent & above] = sky_idx[yy[transparent & above]]
mid_idx_filled[transparent & ~above] = 0

# ---- mirror-tile + runout for the strips ----
def make_strip(idx, alpha, y0, y1, masked):
    h = y1 - y0
    src_idx = idx[y0:y1]            # h x 320
    src_a = alpha[y0:y1]
    mirror = src_idx[:, ::-1]
    tile_idx = np.concatenate([src_idx, mirror], axis=1)     # h x 640
    tile_a = np.concatenate([src_a, src_a[:, ::-1]], axis=1)
    run_idx = tile_idx[:, :RUNOUT]
    run_a = tile_a[:, :RUNOUT]
    strip_idx = np.concatenate([tile_idx, run_idx], axis=1)  # h x 992
    strip_a = np.concatenate([tile_a, run_a], axis=1)
    if masked:
        strip_idx = np.where(strip_a, strip_idx, 0)
    return strip_idx.astype(np.uint8), strip_a

# parts: (name, y0, y1, masked, layer)
parts_def = [
    ("mid_opaque", MID_TOP,    WIN_H,      False, "mid"),
    ("near_mask",  NEAR_TOP,   NEAR_SPLIT, True,  "near"),
    ("near_opaque",NEAR_SPLIT, WIN_H,      False, "near"),
]

def pack_planar(idx, alpha, masked):
    """Return (planes[bytes], mask[bytes] or None) for a strip."""
    h, w = idx.shape
    assert w == STRIP_W
    # pad to word width
    planes = []
    for p in range(DEPTH):
        bits = ((idx >> p) & 1).astype(np.uint8)   # h x w
        # pack MSB-first 16 px per word
        words = np.zeros((h, STRIP_WORDS), dtype=np.uint16)
        for wi in range(STRIP_WORDS):
            chunk = bits[:, wi*16:(wi+1)*16]
            v = np.zeros(h, dtype=np.uint16)
            for b in range(16):
                v = (v << 1) | chunk[:, b]
            words[:, wi] = v
        planes.append(words.astype(">u2").tobytes())
    mask = None
    if masked:
        bits = alpha.astype(np.uint8)
        words = np.zeros((h, STRIP_WORDS), dtype=np.uint16)
        for wi in range(STRIP_WORDS):
            chunk = bits[:, wi*16:(wi+1)*16]
            v = np.zeros(h, dtype=np.uint16)
            for b in range(16):
                v = (v << 1) | chunk[:, b]
            words[:, wi] = v
        mask = words.astype(">u2").tobytes()
    return planes, mask

# ---- build background (full screen, black borders) ----
bg_idx = np.zeros((SCREEN_H, SCREEN_W), dtype=np.uint8)
bg_idx[WIN_Y:WIN_Y+WIN_H, WIN_X:WIN_X+WIN_W] = bg_idx_scene
# pack background planes (352 px = 22 words)
def pack_full(idx):
    h, w = idx.shape
    words_per_row = w // 16
    planes = []
    for p in range(DEPTH):
        bits = ((idx >> p) & 1).astype(np.uint8)
        words = np.zeros((h, words_per_row), dtype=np.uint16)
        for wi in range(words_per_row):
            chunk = bits[:, wi*16:(wi+1)*16]
            v = np.zeros(h, dtype=np.uint16)
            for b in range(16):
                v = (v << 1) | chunk[:, b]
            words[:, wi] = v
        planes.append(words.astype(">u2").tobytes())
    return planes

bg_planes = pack_full(bg_idx)

# ---- write binary ----
HEADER_SIZE = 160
records = []
data = bytearray(HEADER_SIZE)

def append_part(name, y0, y1, masked, layer):
    if layer == "mid":
        idx, alpha = mid_idx_filled, mid_alpha
    else:
        idx, alpha = near_idx_full, near_alpha
    strip_idx, strip_a = make_strip(idx, alpha, y0, y1, masked)
    planes, mask = pack_planar(strip_idx, strip_a, masked)
    rec = {
        "name": name, "y": WIN_Y + y0, "h": y1 - y0,
        "masked": masked, "plane_offsets": [], "mask_offset": 0,
    }
    for pl in planes:
        rec["plane_offsets"].append(len(data))
        data.extend(pl)
    if mask is not None:
        rec["mask_offset"] = len(data)
        data.extend(mask)
    records.append(rec)

for name, y0, y1, masked, layer in parts_def:
    append_part(name, y0, y1, masked, layer)

# background planes: put them after the parts (or before; header will say)
bg_offsets = []
for pl in bg_planes:
    bg_offsets.append(len(data))
    data.extend(pl)

# record layout table at fixed header position
# header: magic, version, depth, screen w/h, win x/y/w/h, nparts, bg offsets...
magic = b"PLX1"
hdr = bytearray(HEADER_SIZE)
hdr[0:4] = magic
struct.pack_into("<BBHHHHHHHH", hdr, 4,
                 1, DEPTH, SCREEN_W, SCREEN_H, WIN_X, WIN_Y, WIN_W, WIN_H,
                 len(records), STRIP_W)
# 4 part records, 24 bytes each, starting at 24
for i, rec in enumerate(records):
    off = 24 + i * 24
    struct.pack_into("<HHHHIII", hdr, off,
                     rec["y"], rec["h"], PERIOD, STRIP_BYTES,
                     1 if rec["masked"] else 0,
                     rec["plane_offsets"][0], rec["mask_offset"])
# bg descriptor after the parts
struct.pack_into("<II", hdr, 24 + 4*24, bg_offsets[0], SCREEN_W * SCREEN_H * DEPTH // 8)
data[0:HEADER_SIZE] = hdr

datpath = os.path.join(OUTDIR, "parallax.dat")
with open(datpath, "wb") as f:
    f.write(data)

# ---- palette ------------------------------------------------
palpath = os.path.join(OUTDIR, "palette.bin")
with open(palpath, "wb") as f:
    for i in range(NCOL):
        r, g, b = pal4[i*3], pal4[i*3+1], pal4[i*3+2]
        f.write(struct.pack(">H", (r << 8) | (g << 4) | b))

# ---- C header -----------------------------------------------
os.makedirs(HDRDIR, exist_ok=True)
with open(os.path.join(HDRDIR, "assets.h"), "w") as f:
    f.write("/* generated by tools/build_assets.py -- do not edit */\n")
    f.write(f"#define SCREEN_W {SCREEN_W}\n#define SCREEN_H {SCREEN_H}\n")
    f.write(f"#define WIN_X {WIN_X}\n#define WIN_Y {WIN_Y}\n")
    f.write(f"#define WIN_W {WIN_W}\n#define WIN_H {WIN_H}\n")
    f.write(f"#define DEPTH {DEPTH}\n#define NCOL {NCOL}\n")
    f.write(f"#define STRIP_W {STRIP_W}\n#define STRIP_BYTES {STRIP_BYTES}\n")
    f.write(f"#define PERIOD {PERIOD}\n#define RUNOUT {RUNOUT}\n")
    f.write(f"#define MID_SPEED 0x{MID_SPEED:04X}\n#define NEAR_SPEED 0x{NEAR_SPEED:05X}\n")
    f.write(f"#define HEADER_SIZE {HEADER_SIZE}\n")
    f.write(f"#define ASSET_SIZE {len(data)}\n")
    f.write(f"#define BG_OFFSET {bg_offsets[0]}\n")
    f.write(f"#define BG_SIZE {SCREEN_W*SCREEN_H*DEPTH//8}\n")
    for rec in records:
        nm = rec["name"].upper()
        f.write(f"#define P_{nm}_Y {rec['y']}\n#define P_{nm}_H {rec['h']}\n")
        f.write(f"#define P_{nm}_OFF {rec['plane_offsets'][0]}\n")
        f.write(f"#define P_{nm}_PLANESZ {STRIP_BYTES*rec['h']}\n")
        if rec["masked"]:
            f.write(f"#define P_{nm}_MASK {rec['mask_offset']}\n")
        else:
            f.write(f"#define P_{nm}_MASK 0\n")
    f.write("static const UWORD palette[NCOL] = {\n")
    for i in range(NCOL):
        r, g, b = pal4[i*3], pal4[i*3+1], pal4[i*3+2]
        f.write(f"  0x{(r<<8)|(g<<4)|b:03X},\n")
    f.write("};\n")

# ---- previews -----------------------------------------------
def render_scene(mid_p, near_p, path):
    # background full screen
    img = Image.new("RGB", (SCREEN_W, SCREEN_H), (0, 0, 0))
    bg_rgb = np.zeros((SCREEN_H, SCREEN_W, 3), np.uint8)
    pal = np.array(pal8, np.uint8).reshape(256, 3)
    bg_rgb[:] = pal[bg_idx]
    img = Image.fromarray(bg_rgb, "RGB")
    # palette helper
    def blit(strip_idx, strip_a, y, h, p, masked):
        tile = strip_idx
        ph = p % PERIOD
        # source window of 320 px starting at ph
        win = tile[:, ph:ph+WIN_W]
        wa = strip_a[:, ph:ph+WIN_W]
        arr = np.asarray(img).copy()
        rgb = pal[win]
        region = arr[y:y+h, WIN_X:WIN_X+WIN_W]
        if masked:
            m = wa
            region[m] = rgb[m]
        else:
            region[:] = rgb
        arr[y:y+h, WIN_X:WIN_X+WIN_W] = region
        return Image.fromarray(arr, "RGB")
    # build strips for preview
    for name, y0, y1, masked, layer in parts_def:
        if layer == "mid":
            idx, alpha = mid_idx_filled, mid_alpha
            p = mid_p
        else:
            idx, alpha = near_idx_full, near_alpha
            p = near_p
        strip_idx, strip_a = make_strip(idx, alpha, y0, y1, masked)
        img = blit(strip_idx, strip_a, WIN_Y + y0, y1 - y0, p, masked)
    img.save(path)

render_scene(0, 0, os.path.join(PREVDIR, "amiga_preview_0.png"))
render_scene(160, 320, os.path.join(PREVDIR, "amiga_preview_1.png"))

# palette swatch
sw = Image.new("RGB", (NCOL * 32, 32))
for i in range(NCOL):
    r, g, b = pal4[i*3], pal4[i*3+1], pal4[i*3+2]
    for y in range(32):
        for x in range(32):
            sw.putpixel((i*32+x, y), (r*17, g*17, b*17))
sw.save(os.path.join(PREVDIR, "palette.png"))

print(f"wrote {datpath}: {len(data)} bytes")
print(f"parts:")
for rec in records:
    print(f"  {rec['name']:12s} y={rec['y']:3d} h={rec['h']:3d} masked={rec['masked']}")
print(f"palette: {NCOL} colours")
for i in range(NCOL):
    r, g, b = pal4[i*3:i*3+3]
    print(f"  {i:2d}: {r:X}{g:X}{b:X}")
