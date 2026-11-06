# Parallax demo for the Amiga 1200 (AGA)
#
# Targets:
#   make adf     build build/parallax-demo.adf   (default)
#   make hdf     build build/parallax-demo.hdf
#   make assets  regenerate the planar assets + src/assets.h
#   make clean   remove build outputs
#
# Requirements: Docker with amigadev/crosstools:m68k-amigaos, python3 +
# Pillow, amitools (xdftool/rdbtool) and unzip.
#
# If amitools lives in a venv, pass its interpreter:
#   make adf AMITOOLS_PY=/path/to/python

DOCKER_IMAGE ?= amigadev/crosstools:m68k-amigaos
DOCKER_RUN   ?= docker run --rm -v $(CURDIR)/src:/work -w /work $(DOCKER_IMAGE)

AMITOOLS_PY ?= $(shell if python3 -c 'import amitools' >/dev/null 2>&1; then echo python3; elif [ -x "$$HOME/.local/opt/amiga-16.2/libexec/amitools/bin/python" ]; then echo "$$HOME/.local/opt/amiga-16.2/libexec/amitools/bin/python"; else echo python3; fi)
XDFTOOL = $(AMITOOLS_PY) -m amitools.tools.xdftool
RDBTOOL = $(AMITOOLS_PY) -m amitools.tools.rdbtool

ZIP     = craftpix-771800-free-war-pixel-art-2d-game-backgrounds.zip
SLAYER  = assets/PNG/War1/Bright/sky.png
STARTUP = build/startup-sequence
ADF     = build/parallax-demo.adf
HDF     = build/parallax-demo.hdf
RAW     = build/dh0.hdf

.PHONY: all adf hdf assets parallax clean distclean

all: adf

adf: $(ADF)
hdf: $(HDF)

# ---- source art + generated planar assets ------------------------------
$(SLAYER): $(ZIP)
	mkdir -p assets
	unzip -q -o $(ZIP) -d assets

src/assets.h build/parallax.dat build/palette.bin: tools/build_assets.py $(SLAYER)
	mkdir -p build
	python3 tools/build_assets.py build

assets: src/assets.h build/parallax.dat

# ---- executable --------------------------------------------------------
src/parallax: src/main.c src/assets.h src/Makefile
	$(DOCKER_RUN) make

build/parallax: src/parallax
	mkdir -p build
	cp $< $@

parallax: build/parallax

# ---- bootable 880 KB ADF -----------------------------------------------
$(ADF): build/parallax build/parallax.dat
	rm -f $@
	$(XDFTOOL) $@ create
	$(XDFTOOL) $@ format "Work" ffs
	$(XDFTOOL) $@ boot install
	$(XDFTOOL) $@ makedir S
	$(XDFTOOL) $@ makedir parallax
	$(XDFTOOL) $@ makedir parallax/data
	$(XDFTOOL) $@ write build/parallax parallax/parallax
	$(XDFTOOL) $@ write build/parallax.dat parallax/data/parallax.dat
	printf 'CD Work:\nparallax/parallax >NIL:\n' > $(STARTUP)
	$(XDFTOOL) $@ write $(STARTUP) S/startup-sequence
	$(XDFTOOL) $@ protect parallax/parallax rwed
	@echo "built: $@"

# ---- bootable 16 MB RDB HDF --------------------------------------------
$(HDF): build/parallax build/parallax.dat
	rm -f $@ $(RAW)
	$(RDBTOOL) $@ create size=16M
	$(RDBTOOL) $@ init
	$(RDBTOOL) $@ add name=dh0 size=90% dostype=DOS3 bootable=1 pri=1
	printf 'CD Work:\nparallax/parallax >NIL:\n' > $(STARTUP)
	$(XDFTOOL) $(RAW) create chs=27,16,63
	$(XDFTOOL) $(RAW) open chs=27,16,63 + format "Work" ffs + boot install + makedir S + makedir parallax + makedir parallax/data + write build/parallax parallax/parallax + write build/parallax.dat parallax/data/parallax.dat + write $(STARTUP) S/startup-sequence + protect parallax/parallax rwed
	$(RDBTOOL) $@ import dh0 $(RAW) pad
	@echo "built: $@"

clean:
	rm -rf build src/assets.h src/*.o src/parallax

distclean: clean
	rm -rf assets
