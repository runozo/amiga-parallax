#!/usr/bin/env python3
"""
Asset generator for the dual-playfield parallax demo (Amiga 1200 / AGA).

Source: craftpix "War1 / Bright" layered background (1920x1080).

Layers (scaled to a 320x200 scene):
  * sky       -> one 12-bit colour per scanline (copper COLOR00 gradient)
  * sun       -> three 16-pixel hardware sprites, 3 colours
  * far       -> PF1, 4 bitplanes, 4 colours   (ruins, above FG_Y0)
  * midground -> PF2, 4 bitplanes, 15 colours  (house3 + houses2)
  * foreground-> PF1, 4 bitplanes, 11 colours  (houses1 + fence + road + craters)

PF1's 15 colours are partitioned: entries 1..11 belong to the foreground,
entries 12..15 to the far layer.  The copper switches PF1's bitmap at
FG_Y0, so no palette reload is needed in the middle of a frame.

Each playfield layer is mirror-tiled to a 640-pixel period (40 words) and
stored as a planar strip; the demo streams 16-pixel columns out of it with
the blitter.  Row 0 of every strip is kept empty: the demo relies on it to
show a transparent playfield above each layer.

Outputs (in <outdir>):
  layers.bin     far + mid + fg planar strips, ready to be incbin'd
  sprites.bin    final 3-sprite sun block + null sprite (control words baked)
  text.bin       4-plane title bitmap (rendered from the built-in 8x8 font)
  sky.bin        200 colour words, one per scene line
  palette.bin    PF1 / PF2 / sun palettes
  parallax.dat   original PLX2 container (reference / external tools)
  preview/*.png  what the hardware should display
and src/assets.h + src/assets.i for the C and assembly sources.
"""
import os
import struct
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "assets", "PNG", "War1", "Bright")
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build")
HDRDIR = os.path.join(HERE, "..", "src")
PREVDIR = os.path.join(OUTDIR, "preview")

W, H = 320, 200            # scene size
TITLE_H = 28               # text band above the scene
PERIOD_WORDS = 40          # mirror tile period: 640 px
STRIP_BYTES = PERIOD_WORDS * 2
MID_Y0 = 26                # first scene row of the PF2 strip (empty row)
FG_Y0 = 125                # first scene row of the PF1 strip (empty row)
FAR_Y0 = 0                 # far layer starts at the top of the scene
FAR_H = FG_Y0 - FAR_Y0     # far layer rows (hidden below the foreground)
MID_H = H - MID_Y0
FG_H = H - FG_Y0
SUN_D = 46                 # sun diameter in pixels
SUN_X, SUN_Y = 56, 4       # sun position in the scene
SUN_SPRITES = 3            # 3 x 16 px = 48 px wide
FAR_SPEED = 1              # quarter pixels per frame (0.25 px)
MID_SPEED = 2              # quarter pixels per frame (0.5 px)
FG_SPEED = 4               # quarter pixels per frame (1 px)
TEXT_ROWS = TITLE_H + 2
ROW_BYTES = 21 * 2         # one display row: 21 fetched words
TEXT_PLANE = TEXT_ROWS * ROW_BYTES
DISP_TOP = 58              # display window vertical start
SCENE_TOP = DISP_TOP + TITLE_H

rng = np.random.default_rng(1234)
try:
    MEDIANCUT = Image.Quantize.MEDIANCUT
except AttributeError:
    MEDIANCUT = Image.MEDIANCUT

# ---------------------------------------------------------------- tiny font
# 5x7 glyphs in an 8x8 cell (one pixel of left padding, one row of leading).
FONT = {
    " ": (".....", ".....", ".....", ".....", ".....", ".....", "....."),
    "A": (".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
    "B": ("####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."),
    "C": (".####", "#....", "#....", "#....", "#....", "#....", ".####"),
    "D": ("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),
    "E": ("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
    "F": ("#####", "#....", "#....", "####.", "#....", "#....", "#...."),
    "G": (".####", "#....", "#....", "#.###", "#...#", "#...#", ".####"),
    "I": ("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"),
    "L": ("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
    "O": (".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "P": ("####.", "#...#", "#...#", "####.", "#....", "#....", "#...."),
    "R": ("####.", "#...#", "#...#", "####.", "#..#.", "#...#", "#...#"),
    "S": (".####", "#....", "#....", ".###.", "....#", "....#", "####."),
    "T": ("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),
    "U": ("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "X": ("#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"),
    "Y": ("#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."),
    "0": (".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."),
    "1": ("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", "#####"),
    "2": (".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
    "5": ("#####", "#....", "#....", "####.", "....#", "#...#", ".###."),
    "+": (".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."),
    "/": ("....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."),
}
TEXT_LINES = (
    ("PARALLAX  //  BLITTER + COPPER SCROLL", 4),
    ("A1200 AGA  DUAL PLAYFIELD  50 FPS", 16),
)


def load(name):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA")
    return im.resize((W, H), Image.BOX)


def over(*imgs):
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for im in imgs:
        out = Image.alpha_composite(out, im)
    return out


def snap4(rgb):
    return np.clip(np.rint(np.asarray(rgb, float) / 17.0), 0, 15).astype(int)


def kmeans_palette(px, n, iters=12):
    """n colours (12-bit tuples) for the given (N,3) pixels."""
    px = np.asarray(px, float)
    img = Image.fromarray(px.reshape(1, -1, 3).astype(np.uint8), "RGB")
    q = img.quantize(colors=n, method=MEDIANCUT)
    cent = np.array(q.getpalette()[: n * 3], float).reshape(-1, 3)
    sample = px if len(px) <= 40000 else px[rng.choice(len(px), 40000, replace=False)]
    for _ in range(iters):
        lab = ((sample[:, None, :] - cent[None, :, :]) ** 2).sum(2).argmin(1)
        for k in range(len(cent)):
            m = lab == k
            if m.any():
                cent[k] = sample[m].mean(0)
    uniq = []
    for c in map(tuple, snap4(cent)):
        if c not in uniq:
            uniq.append(c)
    return uniq


def dither(rgb, mask, pal4):
    """Floyd-Steinberg onto pal4 (indices 1..n); 0 where mask is False."""
    P = np.array(pal4, float) * 17.0
    img = np.asarray(rgb, float).copy()
    h, w = mask.shape
    out = np.zeros((h, w), np.uint8)
    for y in range(h):
        row = img[y]
        for x in range(w):
            if not mask[y, x]:
                continue
            c = np.clip(row[x], 0, 255)
            i = int(((P - c) ** 2).sum(1).argmin())
            out[y, x] = i + 1
            e = c - P[i]
            if x + 1 < w and mask[y, x + 1]:
                img[y, x + 1] += e * (7 / 16)
            if y + 1 < h:
                if x > 0 and mask[y + 1, x - 1]:
                    img[y + 1, x - 1] += e * (3 / 16)
                if mask[y + 1, x]:
                    img[y + 1, x] += e * (5 / 16)
                if x + 1 < w and mask[y + 1, x + 1]:
                    img[y + 1, x + 1] += e * (1 / 16)
    return out


def layer_indices(img, n=15):
    arr = np.asarray(img)
    mask = arr[..., 3] > 128
    pal = kmeans_palette(arr[..., :3][mask], n)
    return dither(arr[..., :3], mask, pal), pal


def pad_pal(pal, n):
    """Exactly n colour entries; duplicate the last one if quantisation
    returned fewer unique colours, so pen offsets stay predictable."""
    pal = list(pal)
    while len(pal) < n:
        pal.append(pal[-1] if pal else (0, 0, 0))
    return pal[:n]


def mirror_strip(idx, y0):
    s = idx[y0:]
    tile = np.concatenate([s, s[:, ::-1]], axis=1).copy()
    assert tile.shape[1] == PERIOD_WORDS * 16
    tile[0, :] = 0
    return tile


def pack_planes(tile, depth=4):
    out = bytearray()
    for p in range(depth):
        bits = ((tile >> p) & 1).astype(np.uint8)
        out += np.packbits(bits, axis=1).tobytes()
    return bytes(out)


def rgb12(c):
    return (int(c[0]) << 8) | (int(c[1]) << 4) | int(c[2])


# ---------------------------------------------------------------- layers
L = {n: load(n + ".png") for n in
     ["sky", "ruins", "house3", "houses2", "houses1", "fence", "road",
      "crater1", "crater2", "crater3"]}

far_img = L["ruins"].crop((0, FAR_Y0, W, FAR_Y0 + FAR_H))
mid_img = over(L["house3"], L["houses2"])
fg_img = over(L["houses1"], L["fence"], L["road"],
              L["crater1"], L["crater2"], L["crater3"])

far_alpha = np.asarray(far_img)[..., 3] > 128
mid_alpha = np.asarray(mid_img)[..., 3] > 128
fg_alpha = np.asarray(fg_img)[..., 3] > 128
assert far_alpha.any(), "far layer is empty"
assert not mid_alpha[: MID_Y0 + 1].any(), "midground content above MID_Y0+1"
assert not fg_alpha[: FG_Y0 + 1].any(), "foreground content above FG_Y0+1"

mid_idx, pf2_pal = layer_indices(mid_img)
far_idx, far_pal = layer_indices(far_img, 4)
fg_idx, pf1_pal = layer_indices(fg_img, 11)

# PF1 pens: 1..11 foreground, 12..15 far layer.
far_pal = pad_pal(far_pal, 4)
pf1_pal = pad_pal(pf1_pal, 11) + far_pal
assert len(pf1_pal) == 15
far_idx[far_idx > 0] += 11

# ---------------------------------------------------------------- sky
sky = np.asarray(L["sky"])[..., :3].astype(float)
sky4 = [tuple(snap4(np.median(sky[y], axis=0))) for y in range(H)]

# ---------------------------------------------------------------- sun
sun = Image.open(os.path.join(SRC, "sun.png")).convert("RGBA")
sun = sun.crop(sun.getchannel("A").getbbox()).resize((SUN_D, SUN_D), Image.LANCZOS)
sa = np.asarray(sun).astype(float)
alpha = sa[..., 3] / 255.0
sun_mask = alpha > 0.16
back = np.array([np.array(sky4[min(SUN_Y + r, H - 1)]) * 17.0 for r in range(SUN_D)])
comp = sa[..., :3] * alpha[..., None] + back[:, None, :] * (1 - alpha[..., None])
sun_pal = kmeans_palette(comp[sun_mask], 3)
while len(sun_pal) < 3:
    sun_pal.append(sun_pal[-1])
sun_pal.sort(key=lambda c: sum(c))      # 1 = darkest glow, 3 = disk
SP = np.array(sun_pal, float) * 17.0
sun_idx = np.zeros((SUN_D, SUN_D), np.uint8)
for y in range(SUN_D):
    for x in range(SUN_D):
        if sun_mask[y, x]:
            sun_idx[y, x] = int(((SP - comp[y, x]) ** 2).sum(1).argmin()) + 1

spr_grid = np.zeros((SUN_D, SUN_SPRITES * 16), np.uint8)
spr_grid[:, 1:1 + SUN_D] = sun_idx
sun_words = bytearray()
for s in range(SUN_SPRITES):
    for r in range(SUN_D):
        blk = spr_grid[r, s * 16:(s + 1) * 16]
        a = b = 0
        for v in blk:
            a = (a << 1) | (int(v) & 1)
            b = (b << 1) | ((int(v) >> 1) & 1)
        sun_words += struct.pack(">HH", a, b)

# ---------------------------------------------------------------- strips
far_strip = mirror_strip(far_idx, FAR_Y0)
mid_strip = mirror_strip(mid_idx, MID_Y0)
fg_strip = mirror_strip(fg_idx, FG_Y0)
far_bytes = pack_planes(far_strip)
mid_bytes = pack_planes(mid_strip)
fg_bytes = pack_planes(fg_strip)
assert len(far_bytes) == 4 * FAR_H * STRIP_BYTES
assert len(mid_bytes) == 4 * MID_H * STRIP_BYTES
assert len(fg_bytes) == 4 * FG_H * STRIP_BYTES

HDR = 16
OFF_FAR = HDR
OFF_MID = OFF_FAR + len(far_bytes)
OFF_FG = OFF_MID + len(mid_bytes)
OFF_SUN = OFF_FG + len(fg_bytes)
data = bytearray(b"PLX2")
data += struct.pack(">HHHHH", 3, FAR_H, MID_H, FG_H, SUN_D)
data += bytes(HDR - len(data))
data += far_bytes + mid_bytes + fg_bytes + sun_words
while len(data) % 4:
    data += b"\0"

# ---------------------------------------------------------------- sprites
# The demo's sprite block: 3 sun sprites (2 control words + 46 rows) with the
# original 96-word stride, then the null sprite used by sprites 3..7.
spr_block = bytearray()
for s in range(SUN_SPRITES):
    hs = 0x80 + SUN_X + s * 16
    vs = SCENE_TOP + SUN_Y
    ve = vs + SUN_D
    sp0 = ((vs & 0xFF) << 8) | ((hs >> 1) & 0xFF)
    sp1 = ((ve & 0xFF) << 8) | (((vs >> 8) & 1) << 2) | (((ve >> 8) & 1) << 1) | (hs & 1)
    spr_block += struct.pack(">HH", sp0, sp1)
    spr_block += sun_words[s * SUN_D * 4:(s + 1) * SUN_D * 4]
    spr_block += b"\0\0\0\0"            # 2 words padding to the 96-word stride
spr_block += b"\0" * 8                  # null sprite (4 words)
assert len(spr_block) == SUN_SPRITES * (SUN_D * 4 + 8) + 8

# ---------------------------------------------------------------- text
text_pen = 1 + int(np.argmax([sum(c) for c in pf1_pal]))
text_mask = np.zeros((TEXT_ROWS, ROW_BYTES * 8), np.uint8)
for line, y0 in TEXT_LINES:
    x = 16 + (W - 8 * len(line)) // 2
    for i, ch in enumerate(line):
        glyph = FONT[ch]
        for row in range(7):
            for col in range(5):
                if glyph[row][col] == "#":
                    text_mask[y0 + row, x + i * 8 + 1 + col] = 1
text_planes = bytearray()
for p in range(4):
    plane = text_mask * ((text_pen >> p) & 1)
    text_planes += np.packbits(plane, axis=1).tobytes()
assert len(text_planes) == 4 * TEXT_PLANE

# ---------------------------------------------------------------- outputs
os.makedirs(OUTDIR, exist_ok=True)
with open(os.path.join(OUTDIR, "parallax.dat"), "wb") as f:
    f.write(data)
with open(os.path.join(OUTDIR, "layers.bin"), "wb") as f:
    f.write(far_bytes + mid_bytes + fg_bytes)
with open(os.path.join(OUTDIR, "sprites.bin"), "wb") as f:
    f.write(spr_block)
with open(os.path.join(OUTDIR, "text.bin"), "wb") as f:
    f.write(text_planes)
with open(os.path.join(OUTDIR, "sky.bin"), "wb") as f:
    for c in sky4:
        f.write(struct.pack(">H", rgb12(c)))

pf1 = [(0, 0, 0)] + list(pf1_pal) + [(0, 0, 0)] * (15 - len(pf1_pal))
pf2 = [(0, 0, 0)] + list(pf2_pal) + [(0, 0, 0)] * (15 - len(pf2_pal))
sunc = [(0, 0, 0)] + list(sun_pal)
with open(os.path.join(OUTDIR, "palette.bin"), "wb") as f:
    for c in pf1 + pf2 + sunc:
        f.write(struct.pack(">H", rgb12(c)))


def carray(name, cols):
    body = ",".join("0x%03X" % rgb12(c) for c in cols)
    return "static const UWORD %s[%d] = {%s};\n" % (name, len(cols), body)


os.makedirs(HDRDIR, exist_ok=True)
consts = [("SCENE_W", W), ("SCENE_H", H), ("TITLE_H", TITLE_H),
          ("PERIOD_WORDS", PERIOD_WORDS), ("STRIP_BYTES", STRIP_BYTES),
          ("FAR_Y0", FAR_Y0), ("FAR_H", FAR_H),
          ("MID_Y0", MID_Y0), ("MID_H", MID_H),
          ("FG_Y0", FG_Y0), ("FG_H", FG_H),
          ("SUN_H", SUN_D), ("SUN_X", SUN_X), ("SUN_Y", SUN_Y),
          ("SUN_SPRITES", SUN_SPRITES),
          ("FAR_SPEED", FAR_SPEED),
          ("MID_SPEED", MID_SPEED), ("FG_SPEED", FG_SPEED),
          ("OFF_FAR", OFF_FAR),
          ("OFF_MID", OFF_MID), ("OFF_FG", OFF_FG), ("OFF_SUN", OFF_SUN),
          ("ASSET_SIZE", len(data)), ("TEXT_PEN", text_pen)]
with open(os.path.join(HDRDIR, "assets.h"), "w") as f:
    f.write("/* generated by tools/build_assets.py -- do not edit */\n")
    for k, v in consts:
        f.write("#define %s %d\n" % (k, v))
    f.write(carray("pf1_colors", pf1))
    f.write(carray("pf2_colors", pf2))
    f.write(carray("sun_colors", sunc))
    f.write(carray("sky_colors", sky4))
with open(os.path.join(HDRDIR, "assets.i"), "w") as f:
    f.write("; generated by tools/build_assets.py -- do not edit\n")
    for k, v in consts:
        f.write("%-16s equ %d\n" % (k, v))

# ---------------------------------------------------------------- preview
os.makedirs(PREVDIR, exist_ok=True)


def render(far_px, mid_px, fg_px):
    img = np.zeros((TITLE_H + H, W, 3), np.uint8)
    for y in range(H):
        img[TITLE_H + y] = np.array(sky4[y]) * 17
    for y in range(SUN_D):
        for x in range(SUN_D):
            v = sun_idx[y, x]
            if v:
                img[TITLE_H + SUN_Y + y, SUN_X + 1 + x] = np.array(sun_pal[v - 1]) * 17
    for strip, y0, pal, off in [(far_strip, FAR_Y0, pf1, far_px),
                                (mid_strip, MID_Y0, pf2, mid_px),
                                (fg_strip, FG_Y0, pf1, fg_px)]:
        P = np.array(pal) * 17
        cols = (np.arange(W) + off) % strip.shape[1]
        win = strip[:, cols]
        rows = img[TITLE_H + y0:TITLE_H + y0 + win.shape[0]]
        m = win > 0
        rows[m] = P[win[m]]
    # title text (the visible window starts 16 bitmap pixels in)
    tp = np.array(pf1[text_pen]) * 17
    for y in range(TITLE_H):
        for x in range(W):
            if text_mask[y, x + 16]:
                img[y, x] = tp
    return Image.fromarray(img, "RGB")


render(0, 0, 0).save(os.path.join(PREVDIR, "preview_0.png"))
render(64, 160, 320).save(os.path.join(PREVDIR, "preview_1.png"))

print("parallax.dat: %d bytes" % len(data))
print("PF1 colours: %d  PF2 colours: %d  sun colours: %d  text pen: %d"
      % (len(pf1_pal), len(pf2_pal), len(sun_pal), text_pen))
