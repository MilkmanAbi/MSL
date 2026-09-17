# Builds the MSL guest daemons.
#
# Intended to be run INSIDE the guest (or the image-build container) - there
# is no cross-compiler set up, and building against the guest's own libc is
# the whole point (musl on Alpine, glibc everywhere else).
#
#   make            build all of them
#   make install    build and put them in /usr/local/bin
#
# `forkpty` lives in libutil on glibc and in libc itself on musl, which is
# the only per-distro difference in any of this.

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
PREFIX  ?= /usr/local
LIBUTIL := $(shell echo 'int main(void){return 0;}' > /tmp/.msl-libutil.c 2>/dev/null; \
             $(CC) /tmp/.msl-libutil.c -lutil -o /tmp/.msl-libutil 2>/dev/null && echo -lutil; \
             rm -f /tmp/.msl-libutil.c /tmp/.msl-libutil)

DAEMONS := shellinit fileopsd x11tunnel trafficd memd

all: $(DAEMONS)

shellinit: shellinit.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBUTIL)

fileopsd: fileopsd.c
	$(CC) $(CFLAGS) -o $@ $<

x11tunnel: x11tunnel.c
	$(CC) $(CFLAGS) -o $@ $<

trafficd: trafficd.c
	$(CC) $(CFLAGS) -o $@ $<

memd: memd.c
	$(CC) $(CFLAGS) -o $@ $<

install: all
	mkdir -p $(PREFIX)/bin
	install -m 0755 $(DAEMONS) $(PREFIX)/bin/

clean:
	rm -f $(DAEMONS)

.PHONY: all install clean
