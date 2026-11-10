# Parallax demo for the Amiga 1200 (AGA) -- pure 68k assembly
#
# Targets:
#   make adf     build build/parallax-demo.adf   (default)
#   make hdf     build build/parallax-demo.hdf
#   make assets  regenerate the planar assets + src/assets.i
#   make clean   remove build outputs
#
# Requirements: Docker with amigadev/crosstools:m68k-amigaos (vasm),
# python3 + Pillow + numpy, amitools (xdftool/rdbtool) and unzip.
#
# If amitools lives in a venv, pass its interpreter:
#   make adf AMITOOLS_PY=/path/to/python

DOCKER_IMAGE ?= amigadev/crosstools:m68k-amigaos
DOCKER_RUN   ?= docker run --rm -v $(CURDIR):/work -w /work $(DOCKER_IMAGE)

AMITOOLS_PY ?= $(shell if python3 -c 'import amitools' >/dev/null 2>&1; then echo python3; elif [ -x "$$HOME/.local/opt/amiga-16.2/libexec/amitools/bin/python" ]; then echo "$$HOME/.local/opt/amiga-16.2/libexec/amitools/bin/python"; else echo python3; fi)
XDFTOOL = $(AMITOOLS_PY) -m amitools.tools.xdftool
RDBTOOL = $(AMITOOLS_PY) -m amitools.tools.rdbtool

ZIP     = craftpix-771800-free-war-pixel-art-2d-game-backgrounds.zip
SLAYER  = assets/PNG/War1/Bright/sky.png
STARTUP = build/startup-sequence
ADF     = build/parallax-demo.adf
HDF     = build/parallax-demo.hdf
RAW     = build/dh0.hdf

DATA    = build/layers.bin build/sprites.bin build/text.bin build/sky.bin build/palette.bin

.PHONY: all adf hdf assets parallax clean distclean

all: adf

adf: $(ADF)
hdf: $(HDF)

# ---- source art + generated planar assets ------------------------------
$(SLAYER): $(ZIP)
	mkdir -p assets
	unzip -q -o $(ZIP) -d assets

src/assets.i src/assets.h $(DATA) build/parallax.dat: tools/build_assets.py $(SLAYER)
	mkdir -p build
	python3 tools/build_assets.py build

assets: src/assets.i $(DATA)

# ---- executable (vasm hunk executable, assets incbin'd) ----------------
src/parallax: src/parallax.s src/assets.i $(DATA)
	$(DOCKER_RUN) vasmm68k_mot -Fhunkexe -m68020 -I build -o src/parallax src/parallax.s

build/parallax: src/parallax
	mkdir -p build
	cp $< $@

parallax: build/parallax

# ---- bootable 880 KB ADF -----------------------------------------------
$(ADF): build/parallax
	rm -f $@
	$(XDFTOOL) $@ create
	$(XDFTOOL) $@ format "Work" ffs
	$(XDFTOOL) $@ boot install
	$(XDFTOOL) $@ makedir S
	$(XDFTOOL) $@ write build/parallax parallax
	printf 'CD Work:\nparallax >NIL:\n' > $(STARTUP)
	$(XDFTOOL) $@ write $(STARTUP) S/startup-sequence
	$(XDFTOOL) $@ protect parallax rwed
	@echo "built: $@"

# ---- bootable 16 MB RDB HDF --------------------------------------------
$(HDF): build/parallax
	rm -f $@ $(RAW)
	$(RDBTOOL) $@ create size=16M
	$(RDBTOOL) $@ init
	$(RDBTOOL) $@ add name=dh0 size=90% dostype=DOS3 bootable=1 pri=1
	printf 'CD Work:\nparallax >NIL:\n' > $(STARTUP)
	$(XDFTOOL) $(RAW) create chs=27,16,63
	$(XDFTOOL) $(RAW) open chs=27,16,63 + format "Work" ffs + boot install + makedir S + write build/parallax parallax + write $(STARTUP) S/startup-sequence + protect parallax rwed
	$(RDBTOOL) $@ import dh0 $(RAW) pad
	@echo "built: $@"

clean:
	rm -rf build src/assets.i src/assets.h src/*.o src/parallax

distclean: clean
	rm -rf assets
