# Parallax Scrolling Demo — Amiga 1200 (AGA), pure 68k assembly

A parallax scrolling demo for AGA Amigas running **locked at 50 fps**:
hardware-scrolled dual playfield, a copper sky, a sprite sun and the blitter
streaming new columns into the scrolling buffers. It uses the war-torn
background art from
`craftpix-771800-free-war-pixel-art-2d-game-backgrounds.zip`
(the **War1 / Bright** layer set: sky, sun, ruins, houses, road, fence, craters).

The demo is written entirely in 68020 assembly (vasm). Every asset is
**embedded in the executable**; there is no data file, no file loading and no
Intuition screen. The only library opened is `graphics.library`, for
`WaitTOF()`, `LoadView()` and blitter ownership; everything else talks to the
custom chips directly.

![demo](docs/screenshot.png)

## What you see

* **320×228 PAL display**: a 28-line title band and the 320×200 scene.
* **Sky** — one colour per scanline, written to `COLOR00` by the copper.
* **Sun** — three 16-pixel hardware sprites placed *behind* both playfields,
  so its glow disappears behind the ruins.
* **Far background** (ruins) — playfield 1 above the foreground, 4 bitplanes,
  4 colours, scrolling at **0.25 px/frame** (12.5 px/s).
* **Midground** (house3 + houses2) — playfield 2, 4 bitplanes,
  15 colours, scrolling at **0.5 px/frame** (25 px/s).
* **Foreground** (houses1 + fence + road + craters) — playfield 1, 4
  bitplanes, 11 colours, scrolling at **1 px/frame** (50 px/s).
* Scroll steps are AGA **quarter pixels**, and the loop is locked to the
  vertical blank: every frame moves exactly the same distance.

The three layers are real, independently moving parallax layers. The far
layer shares PF1 with the foreground, but the two never occupy the same
scanlines: above `FG_Y0` PF1 shows the far layer and PF2 (midground) has
priority over it (`BPLCON2` bit 6); at `FG_Y0` PF1 switches to the foreground
and priority returns to normal.

The title band is a 4-plane bitmap baked by the asset generator with a small
8×8 font, so no font or `Text()` call is needed at run time.

## Controls

* **left or right mouse button** — quit
* **CTRL-C** — quit (also works from the DevBench bridge)

On a bootable floppy/hard-disk image there is no Workbench, so quitting drops
back to the boot CLI (or the insert-disk screen).

## Build

From the repository root:

```sh
make adf       # build build/parallax-demo.adf (default target)
make hdf       # build build/parallax-demo.hdf
make parallax  # just assemble build/parallax
```

`make` extracts the supplied zip into `assets/` (once), regenerates the planar
assets and `src/assets.i`, assembles `src/parallax.s` with vasm in the
`amigadev/crosstools:m68k-amigaos` Docker image, and creates the bootable
image with amitools.

Requirements: Docker, `python3` + Pillow + numpy, `unzip`, and amitools
(`xdftool`/`rdbtool`). If amitools is installed in a virtualenv:

```sh
make adf AMITOOLS_PY=/path/to/python-with-amitools
```

The direct assembly is still available (the repository root must be mounted so
that `build/` is visible):

```sh
docker run --rm -v "$PWD:/work" -w /work \
    amigadev/crosstools:m68k-amigaos make -C src
```

This produces `src/parallax` (a plain AmigaOS hunk executable). The demo needs
an AGA machine: it checks `DENISEID` and exits on OCS/ECS.

## Assets

The PNG layers were extracted from the supplied zip into `assets/`.
[`tools/build_assets.py`](tools/build_assets.py) performs the conversion:

1. Loads `assets/PNG/War1/Bright/*.png` and scales the layers to 320×200.
2. Builds a 12-bit palette for each playfield (median cut + k-means on the
   opaque pixels) and remaps each layer with Floyd–Steinberg dithering;
   transparent pixels are colour 0. PF1's 15 colours are partitioned:
   entries 1–11 for the foreground, 12–15 for the far layer. PF2 keeps its
   own 15 colours for the midground.
3. Turns the sky into one 12-bit colour per scanline and the sun into three
   3-colour sprites, with the sprite control words already baked in.
4. **Mirror-tiles** each layer (`[scene][mirror(scene)]`, period 640 px =
   40 words); row 0 of each strip is left empty on purpose (see below).
5. Renders the two title lines into a 4-plane bitmap using the built-in 8×8
   font.
6. Writes the files that the assembly source `incbin`s:

   | file | contents |
   |---|---|
   | `build/layers.bin` | far + PF2 + PF1 planar strips (119,680 B) |
   | `build/sprites.bin` | 3 sun sprites + null sprite, control words included |
   | `build/text.bin` | 4-plane title bitmap (5,040 B) |
   | `build/sky.bin` | 200 colour words (one per scene line) |
   | `build/palette.bin` | PF1 / PF2 / sun palettes |
   | `src/assets.i` | layout constants for the assembly source |

   `build/parallax.dat` and `src/assets.h` are still produced for reference /
   external tools, but the assembly build does not need them.

Regenerate with:

```sh
python3 tools/build_assets.py <output-dir>
```

or simply `make assets`.

## Run on the target

Copy `parallax` alone to the Amiga (the DevBench host share is mounted at
`/tmp/opencode/amiga_hd`) and run it. No data file is needed — the 120 KB of
planar data lives in the executable and is copied to chip RAM at startup.

## Bootable images

Two ready-to-boot images are built by `make adf` / `make hdf`:

* **`parallax-demo.adf`** — 880 KB bootable FFS floppy (volume `Work`).
  Attach as `DF0:` with an Amiga 1200 Kickstart 3.1 ROM and boot.
* **`parallax-demo.hdf`** — 16 MB hard-disk image with an RDB and one
  bootable 13.9 MB FFS partition (volume `Work`). Attach as a hard disk, e.g.
  Amiberry `-W DH0:build/parallax-demo.hdf`, or the WinUAE/FS-UAE hardfile
  option, with the same ROM and boot.

Both images boot `S/startup-sequence`, which does:

```
CD Work:
parallax >NIL:
```

The demo starts automatically; the left/right mouse button or CTRL-C returns
to the CLI. The images were boot-tested with Amiberry using a Kickstart 3.1
A1200 ROM.

## How it works

* **Why not redraw with the blitter?** Redrawing the full-width layers every
  frame needs tens of thousands of blitter cycles, more than the chip bus can
  give in one PAL frame with the display on. The demo uses the technique of
  real Amiga games instead.
* **Dual playfield, three layers.** `BPLCON0 = $0611`: 8 bitplanes (AGA BPU3),
  dual playfield. PF1 (odd planes) carries the far layer above `FG_Y0` and
  the foreground below it; PF2 (even planes, colours 16–31 via
  `BPLCON3/PF2OF`) carries the midground. Above `FG_Y0` the copper sets
  `BPLCON2` bit 6 (`PF2PRI`) so the midground is in front of the far layer;
  at `FG_Y0` it clears the bit so the foreground is in front of the
  midground. Each playfield still has one pointer group and one `BPLCON1`
  delay, and the copper switches PF1's delay together with its pointers, so
  all three layers scroll independently.
* **Quarter-pixel fine scroll.** `DDFSTRT = $30` fetches one extra word and
  `BPLCON1` delays each playfield by 0–63 quarter pixels (AGA adds two
  35 ns bits per playfield), while the bitplane pointer advances one word
  every 16 pixels.
* **Sliding buffer + blitter column streaming.** Each playfield buffer has
  21 words per row and no modulo. When the start pointer advances by one
  word, the word that just left the screen on row *y+1* becomes the new
  right-hand word of row *y*. The blitter (A→D, 1 word × all rows × 4
  planes) copies the next 16-pixel column from the mirror-tiled strip into
  exactly that word, during vertical blank. That is at most one tiny blit per
  layer per 16/32/64 frames. Each buffer has 4 KB of headroom per plane; when
  it runs out (every ~11 min for the foreground, ~21 min for the midground,
  ~43 min for the far layer) the position is reduced modulo one strip period
  and the 21-column window is rebuilt. The jump preserves the visual phase,
  so it is invisible.
* **Copper.** The copper list sets the AGA registers, both palettes, the
  sprite pointers, one `COLOR00` per scanline, and the playfield pointer
  patches. Above `FG_Y0` PF1 shows the far layer and PF2 shows the empty row
  until `MID_Y0`; at each layer's first line the copper switches the modulo
  to 0 and the pointers to the scrolling buffer, and at `FG_Y0` it switches
  PF1 to the foreground, changes `BPLCON1` and clears `PF2PRI`. Two copper
  lists are double-buffered: the CPU patches the idle one (26 words) and
  swaps `COP1LC` once per frame.
* **Fixed transparent rows.** The previous C version pointed the “empty”
  part of each playfield at `base + w·2 − 42`, which walks into real image
  data after a while; the assembly version uses a fixed empty row (the
  64-byte guard before each buffer), so the title band and the sky above each
  layer stay clean forever.
* **Memory.** One `AllocMem(MEMF_CHIP|MEMF_CLEAR)` block of 244,728 bytes:
  strips (119,680), far buffer (4×9,456), PF2 buffer (4×11,512), PF1 buffer
  (4×7,352), title (5,040), sprites (584) and two 3,072-byte copper lists.
* **OS friendliness.** The OS keeps running: `LoadView(NULL)` detaches the
  system view while the demo owns `COP1LC`; the blitter is owned only around
  the column blits; `LoadView(oldview)` restores the display and
  `DisownBlitter`/`FreeMem`/`CloseLibrary` release everything on exit.

## Performance

The main loop waits for the 50 Hz vertical blank with `WaitTOF()`. Per frame
it only:

1. advances the three quarter-pixel positions,
2. computes the two `BPLCON1` words,
3. patches 26 copper words,
4. swaps `COP1LC`.

That is a few hundred cycles; the only real work is four tiny blits every
16, 32 or 64 frames (one word per row). The far layer adds no bitplane DMA —
its scanlines were already being fetched for the empty PF1 row — so the
demo stays VBL-locked at 50 fps with a large margin, and the CPU spends
almost all of its time in `WaitTOF()`.

## Limitations / notes

* The source art is a single 1920×1080 scene; the layers are **mirror-tiled**
  (period 640 px, i.e. two screen widths) to obtain seamless horizontal
  wrapping.
* PF1's 15 colours are split between the foreground (11) and the far layer
  (4); PF2 keeps 15 colours for the midground. The original art has thousands
  of colours.
* The far layer is only displayed above `FG_Y0`, where PF1 is not used by the
  foreground; it is hidden behind the midground/foreground below that line.
* Requires AGA (the demo checks for Lisa and exits on OCS/ECS).
* The title band uses the demo's own 8×8 pixel font (the C version used the
  ROM Topaz font via `Text()`).
