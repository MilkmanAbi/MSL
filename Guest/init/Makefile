# NOT THE ONE THE IMAGES ARE BUILT WITH. The real guest kit - x11tunnel,
# fileopsd, mslpsd, memd, trafficd and shellinit together - is built by
# `Linux-Side/daemons/Makefile`. This file builds shellinit alone and is kept
# only for a quick one-off compile of it; it has no x11tunnel target, which
# is what sends people looking for a bug that isn't here.
#
# Builds the guest-side shell listener. Intended to be cross-compiled or
# built inside an Alpine-based build environment targeting the guest arch
# (arm64, since Apple Silicon Linux guests run natively as arm64).
#
# On a glibc-based guest, forkpty/openpty live in libutil - link with -lutil.
# On musl (Alpine's libc), they're part of libc directly - drop -lutil.

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

shellinit: shellinit.c
	$(CC) $(CFLAGS) -o $@ $< -lutil

shellinit-musl: shellinit.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f shellinit shellinit-musl

# Everything else in the kit: use Linux-Side/daemons/Makefile.
others x11tunnel fileopsd mslpsd memd trafficd:
	@echo "$@ is built by Linux-Side/daemons/Makefile, not this one." >&2; exit 1

.PHONY: others x11tunnel fileopsd mslpsd memd trafficd clean
