# Parallax Scrolling Demo — Amiga 1200 (AGA)

A parallax scrolling demo for AGA Amigas running **locked at 50 fps**:
hardware-scrolled dual playfield, a copper sky, a sprite sun and the blitter
streaming new columns into the scrolling buffers. It uses the war-torn
background art from
`craftpix-771800-free-war-pixel-art-2d-game-backgrounds.zip`
(the **War1 / Bright** layer set: sky, sun, ruins, houses, road, fence, craters).

![demo](docs/screenshot.png)

## What you see

* **320×228 PAL display**: a 28-line title band and the 320×200 scene.
* **Sky** — one colour per scanline, written to `COLOR00` by the copper.
* **Sun** — three 16-pixel hardware sprites placed *behind* both playfields,
  so its glow disappears behind the ruins.
* **Midground** (ruins + house3 + houses2) — playfield 2, 4 bitplanes,
  15 colours, scrolling at **0.5 px/frame** (25 px/s).
* **Foreground** (houses1 + fence + road + craters) — playfield 1, 4
  bitplanes, 15 colours, scrolling at **1 px/frame** (50 px/s).
* Scroll steps are AGA **quarter pixels**, and the loop is locked to the
  vertical blank: every frame moves exactly the same distance.

## Controls

* **ESC**, the **left mouse button** or **CTRL-C** — quit and return to the OS.

## Build

From the repository root:

```sh
make adf       # build build/parallax-demo.adf (default target)
make hdf       # build build/parallax-demo.hdf
```

`make` extracts the supplied zip into `assets/` (once), regenerates the planar
assets and `src/assets.h`, cross-compiles the demo in the
`amigadev/crosstools:m68k-amigaos` Docker image, and creates the bootable image
with amitools.

Requirements: Docker, `python3` + Pillow, `unzip`, and amitools
(`xdftool`/`rdbtool`). If amitools is installed in a virtualenv:

```sh
make adf AMITOOLS_PY=/path/to/python-with-amitools
```

The direct cross-compile is still available:

```sh
docker run --rm -v "$PWD/src:/work" -w /work \
    amigadev/crosstools:m68k-amigaos make
```

This produces `src/parallax` (an AmigaOS `-noixemul` executable).

## Assets

The PNG layers were extracted from the supplied zip into `assets/`.
[`tools/build_assets.py`](tools/build_assets.py) performs the conversion:

1. Loads `assets/PNG/War1/Bright/*.png` and scales the layers to 320×200.
2. Builds a separate **15-colour, 12-bit palette** for each playfield
   (median cut + k-means on the opaque pixels) and remaps each layer with
   Floyd–Steinberg dithering; transparent pixels are colour 0.
3. Turns the sky into one 12-bit colour per scanline and the sun into three
   3-colour sprites.
4. **Mirror-tiles** each layer (`[scene][mirror(scene)]`, period 640 px =
   40 words); row 0 of each strip is left empty on purpose (see below).
5. Writes:
   * `parallax.dat` — PF2 and PF1 planar strips and sun sprite data (80 KB)
   * `palette.bin` — PF1, PF2 and sprite palettes (reference export)
   * `src/assets.h` — layout constants, palettes and the sky gradient
   * `preview/*.png` — what the hardware should display

Regenerate with:

```sh
python3 tools/build_assets.py <output-dir>
```

or simply:

```sh
make assets
```

which also extracts the supplied zip into `assets/` if it is missing.

The build outputs live in `build/` (ignored by git):
`parallax`, `parallax.dat`, `palette.bin`, `parallax-demo.adf` (880 KB
bootable floppy) and `parallax-demo.hdf` (16 MB bootable RDB hard-disk image).
The documentation screenshot is [`docs/screenshot.png`](docs/screenshot.png).

## Run on the target

Copy `parallax` and `parallax.dat` to `Work:parallax/` on the Amiga
(the DevBench host share is mounted at `/tmp/opencode/amiga_hd`), then start
`Work:parallax/parallax` from the AmigaBridge launch command or the boot
startup. The program needs the data file at
`Work:parallax/data/parallax.dat`; the palette is compiled into the executable.
If the absolute path is unavailable, the loader also tries
`parallax/data/parallax.dat` and `data/parallax.dat`, and it suppresses
AmigaDOS "insert volume" requesters, so the executable can be run from any
directory that contains the data tree.

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
parallax/parallax >NIL:
```

The demo starts automatically; ESC or CTRL-C returns to the OS. The images
were boot-tested with Amiberry using a Kickstart 3.1 A1200 ROM.

## How the scrolling works

* **Why not redraw with the blitter?** Redrawing two full-width layers every
  frame needs ~64,000 blitter cycles, more than the chip bus can give in one
  PAL frame with the display on: that design tops out around 25 fps, so it
  stutters. The demo now uses the technique of real Amiga games.
* **Dual playfield.** `BPLCON0 = $0611`: 8 bitplanes, dual playfield. PF1
  (odd planes) is the foreground and PF2 (even planes, colours 16–31 via
  `BPLCON3/PF2OF`) the midground. Each playfield has its own bitplane
  pointers and its own delay in `BPLCON1`, so the two layers scroll
  independently at zero CPU/blitter cost.
* **Quarter-pixel fine scroll.** `DDFSTRT = $30` fetches one extra word and
  `BPLCON1` delays each playfield by 0–63 quarter pixels (AGA adds two
  35 ns bits per playfield), while the bitplane pointer advances one word every
  16 pixels.
* **Sliding buffer + blitter column streaming.** Each playfield buffer has
  21 words per row and no modulo. When the start pointer advances by one
  word, the word that just left the screen on row *y+1* becomes the new
  right-hand word of row *y*. The blitter (A→D, 1 word × all rows × 4 planes)
  copies the next 16-pixel column from the mirror-tiled strip into exactly
  that word, at a moment when it is not visible. That is at most one tiny
  blit per layer per frame. The buffer has 32 KB of headroom per plane;
  when it runs out (after ~1.5 h) the position jumps back by whole periods
  and the window is rebuilt at the start of the buffer.
* **Copper.** The copper list sets the AGA registers, both palettes, the
  sprite pointers and one `COLOR00` per scanline (border blanking hides the
  colour changes outside the window). Playfields above their layer read the
  strip's empty first row with modulo −42; at the layer's first line the
  copper switches the modulo to 0 and the playfield starts walking its
  buffer. Two copper lists are double-buffered: the CPU patches the idle
  one (pointers + `BPLCON1`) and swaps `COP1LC` once per frame.
* **System friendly.** The OS keeps running: the demo opens a quiet screen
  for input, uses `LoadView(NULL)` + its own copper list, owns the blitter
  only for the column blits, and restores the system view on exit.

## Performance

Measured on the emulated A1200 with `parallax stats` (frames shown vs.
50 Hz `DateStamp` ticks): **1329 frames in 1331 ticks**, i.e. a locked
**50 fps**. A capture of the emulator display matched the expected rendering
pixel for pixel, before and after a buffer rebase (`parallax rebase` starts
next to the end of the buffer to test it).

For perfectly smooth motion in an emulator, run it at 50 Hz with VSync (or
WinUAE/FS-UAE's "low latency vsync" mode); a 60 Hz host display without
VSync adds judder of its own.

## Limitations / notes

* The source art is a single 1920×1080 scene; the layers are **mirror-tiled**
  (period 640 px, i.e. two screen widths) to obtain seamless horizontal
  wrapping.
* 15 colours per playfield with dithering; the original art has thousands
  of colours.
* Requires AGA (the demo checks for Lisa and exits on OCS/ECS).
