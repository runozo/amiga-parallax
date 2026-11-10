# Direct build of the assembly demo (normally invoked by the top Makefile).
#
# The repository root must be mounted so that ../build is visible, e.g.:
#   docker run --rm -v "$PWD:/work" -w /work \
#       amigadev/crosstools:m68k-amigaos make -C src
#
AS      = vasmm68k_mot
ASFLAGS = -Fhunkexe -m68020 -I ../build
TARGET  = parallax

all: $(TARGET)

$(TARGET): parallax.s assets.i ../build/layers.bin
	$(AS) $(ASFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
