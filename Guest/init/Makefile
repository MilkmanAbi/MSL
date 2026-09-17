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
