CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2
# lround() was the only libm user; it is gone, so -lm is no longer needed.
LDLIBS ?=

all: fmtx

fmtx: fmtx.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

clean:
	rm -f fmtx

.PHONY: all clean
