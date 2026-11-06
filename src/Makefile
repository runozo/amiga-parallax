CC = m68k-amigaos-gcc
CFLAGS = -noixemul -O2 -m68020 -Wall -I.
LDFLAGS = -noixemul -lamiga
TARGET = parallax
OBJS = main.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

%.o: %.c assets.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f *.o $(TARGET)
