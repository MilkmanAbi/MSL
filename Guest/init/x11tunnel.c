/*
 * x11tunnel.c
 *
 * Ultra-experimental skeleton for MSL's GUI support (Phase 1 of
 * the archived msl-vgpu.md design - "X11 over vsock -> XQuartz"). NOT part
 * of the normal shell path - the VM stays headless unless this is started
 * deliberately (see `msl gui <instance>`), matching the doc's "completely
 * separate from the shell path" framing.
 *
 * X11 is just a byte-stream protocol over a connection - this doesn't
 * parse a single X request. It listens on a well-known local X display
 * socket (`/tmp/.X11-unix/X<N>`, what a guest process setting
 * `DISPLAY=:<N>` connects to - `N` defaults to 0, see `main`'s usage
 * comment) and, for each local X client that connects, dials a *fresh*
 * vsock connection out to the host and relays raw bytes bidirectionally
 * until either side closes. Which host-side listener it reaches depends
 * on the vsock port (also configurable, defaulting to Phase 1's
 * `DisplayBridge`/XQuartz path - see `Sources/MSLCore/DisplayBridge.swift`
 * vs. Phase 2's `X11Server`/"mslgd", `Sources/MSLCore/X11/X11Server.swift`)
 * - either way, THIS file never changes: it forwards bytes opaquely no
 * matter which server is actually interpreting the X11 protocol on the
 * other end. One X client = one local connection = one vsock connection =
 * one relay child - never multiplexed, since X11 inherently expects one
 * full-duplex byte stream per client.
 *
 * This is the *opposite* connection direction from shellinit.c/fileopsd.c
 * (guest listens, host connects) - here the guest is the vsock *client*,
 * dialing out fresh per local connection, since it's the guest side that
 * knows when a new X app actually needs one. See VMConfiguration.
 * displayVsockPort's doc comment for why port 5002 (not msl-vgpu.md's
 * suggested 5001, already owned by fileOpsVsockPort).
 *
 * Same two-generation fork/relay shape as shellinit.c's session handler,
 * minus the framing protocol entirely (no EXEC/DATA/RESIZE/EXIT frames -
 * X11 traffic passes through completely opaque, which is the whole point
 * of Phase 1: zero X protocol code needed on either side of this tunnel).
 */

/* `struct ucred`/`SO_PEERCRED` are GNU extensions; musl gates them on
 * this, so it must precede every include. */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <poll.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>

#define DEFAULT_DISPLAY_VSOCK_PORT 5002
#define X11_SOCKET_DIR "/tmp/.X11-unix"
/* 256 KB, not 8 KB. `BUF_SIZE` bounds how much one read() can return, and
 * a full repaint of a 1140x740 window is ~3.4 MB at depth 24 - which at
 * 8 KB was ~412 read/write pairs plus ~412 select()s for ONE frame.
 *
 * Safe on the stack here: `buf` lives in relay(), which runs in a process
 * forked from main, so it gets the process stack (RLIMIT_STACK, 8 MB by
 * default) - NOT a musl thread stack, which defaults to 128 KB and would
 * make this a genuine hazard. Heap-allocate if this ever moves into a
 * thread. */
#define BUF_SIZE 262144

/* Raises how much the peer may have in flight toward us.
 *
 * Expectation management, because this is easy to over-sell: on the virtio
 * transport, TX credit is derived from the PEER's buf_alloc, so setting
 * this on the guest socket raises what the HOST may send toward the GUEST
 * (replies and events). The heavy direction here is the opposite one -
 * guest->host PutImage - and its credit is set by the host side, which
 * Virtualization.framework does not expose. Expect better reply/event
 * latency and little repaint throughput; the buffer size and the drain
 * loop below are where the repaint win actually is.
 *
 * Order matters: the kernel rejects a MIN above the current MAX (and vice
 * versa) with EINVAL, so MAX first, then SIZE. Failures are ignored on
 * purpose - an older kernel without these options must not stop the
 * tunnel from working. */
static void tune_vsock_buffers(int fd) {
    unsigned long long size = 1u << 20; /* 1 MB */
    (void)setsockopt(fd, AF_VSOCK, SO_VM_SOCKETS_BUFFER_MAX_SIZE, &size, sizeof(size));
    (void)setsockopt(fd, AF_VSOCK, SO_VM_SOCKETS_BUFFER_SIZE, &size, sizeof(size));
}

static void set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int connect_to_host(unsigned int vsock_port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    tune_vsock_buffers(fd); /* between socket() and connect(), while it still takes effect */

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_HOST;
    addr.svm_port = vsock_port;

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* NOTE: `write_full` used to live here, lifted from shellinit.c to fix
 * the relay treating a short write as fatal (doc 15 X4). The relay is
 * non-blocking now and `flush_direction` handles partial writes itself -
 * including EAGAIN, which a blocking-style helper cannot - so the helper
 * would be dead code. The bug it fixed stays fixed.
 */

/* One direction of the relay: what has been read but not yet written.
 *
 * A direction with a non-empty backlog stops reading and waits for its
 * destination to become writable. That is what stops one slow side from
 * freezing the other: the old code used BLOCKING writes, so while the
 * child sat in write() pushing guest->host it was not reading host->guest
 * at all, and vice versa. Worse, it fed the host's own backlog killer -
 * the host stops reading, the guest blocks in write, the guest stops
 * reading the host, the host's writeBacklog grows, and the host closes the
 * connection to bound it. */
struct direction {
    int src;
    int dst;
    unsigned char buf[BUF_SIZE];
    size_t pending;   /* bytes in buf still to write */
    size_t offset;    /* how far into buf the writes have got */
    int closed;       /* src reached EOF or errored */
};

/* Writes as much of the backlog as the destination will take. Returns -1
 * on a real error, 0 otherwise (including a partial write). */
static int flush_direction(struct direction *d) {
    while (d->pending > d->offset) {
        ssize_t w = write(d->dst, d->buf + d->offset, d->pending - d->offset);
        if (w > 0) {
            d->offset += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0; /* try again when writable */
        return -1;
    }
    d->pending = 0;
    d->offset = 0;
    return 0;
}

/* Drains the source until it would block, writing as it goes. Returns -1
 * when the direction is finished (EOF or error). */
static int pump_direction(struct direction *d) {
    for (;;) {
        if (d->pending > d->offset) return 0; /* backlog first; poll will tell us when */
        ssize_t n = read(d->src, d->buf, sizeof(d->buf));
        if (n == 0) return -1; /* orderly EOF */
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0; /* drained */
            return -1;
        }
        d->pending = (size_t)n;
        d->offset = 0;
        if (flush_direction(d) < 0) return -1;
    }
}

/* Relays until either side closes or errors - plain byte pump, no framing,
 * no interpretation. Returns once the X client's session is over.
 *
 * Each readable side is drained until EAGAIN rather than one buffer per
 * readiness call. The old loop returned to select() after every single
 * buffer, so a burst cost one select() per 8 KB purely to re-learn what it
 * already knew. */
static void relay(int a, int b) {
    static struct direction forward, backward; /* static: 256 KB each, too big for the stack twice over */
    forward.src = a; forward.dst = b;
    backward.src = b; backward.dst = a;
    forward.pending = forward.offset = forward.closed = 0;
    backward.pending = backward.offset = backward.closed = 0;

    set_nonblocking(a);
    set_nonblocking(b);

    for (;;) {
        struct pollfd pfd[2];
        int n = 0;
        int forward_slot = -1, backward_slot = -1;

        /* A direction waits to WRITE while it has a backlog, and to READ
         * otherwise. Both at once would spin. */
        if (!forward.closed || forward.pending > forward.offset) {
            pfd[n].fd = forward.pending > forward.offset ? forward.dst : forward.src;
            pfd[n].events = forward.pending > forward.offset ? POLLOUT : POLLIN;
            pfd[n].revents = 0;
            forward_slot = n++;
        }
        if (!backward.closed || backward.pending > backward.offset) {
            pfd[n].fd = backward.pending > backward.offset ? backward.dst : backward.src;
            pfd[n].events = backward.pending > backward.offset ? POLLOUT : POLLIN;
            pfd[n].revents = 0;
            backward_slot = n++;
        }
        if (n == 0) break; /* both directions done */

        if (poll(pfd, (nfds_t)n, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (forward_slot >= 0 && pfd[forward_slot].revents) {
            if (pfd[forward_slot].revents & POLLOUT) {
                if (flush_direction(&forward) < 0) break;
            } else if (pump_direction(&forward) < 0) {
                forward.closed = 1;
                /* Half-close so the far side sees the end of the stream
                 * rather than an abrupt reset, and let any backlog finish. */
                if (forward.pending <= forward.offset) shutdown(forward.dst, SHUT_WR);
            }
        }
        if (backward_slot >= 0 && pfd[backward_slot].revents) {
            if (pfd[backward_slot].revents & POLLOUT) {
                if (flush_direction(&backward) < 0) break;
            } else if (pump_direction(&backward) < 0) {
                backward.closed = 1;
                if (backward.pending <= backward.offset) shutdown(backward.dst, SHUT_WR);
            }
        }
        if (forward.closed && backward.closed
            && forward.pending <= forward.offset && backward.pending <= backward.offset) {
            break;
        }
    }
}

/* Tells the host WHICH guest program opened this connection, before a
 * single X11 byte is relayed.
 *
 * mslgd gives every Linux app its own macOS process so it can have its own
 * Dock tile, icon and name - and to route a connection to the right process
 * the host has to know the app's identity BEFORE the X11 stream starts.
 * It cannot work that out from the stream itself: X11's connection setup is
 * a request/RESPONSE handshake, so a host that reads ahead looking for
 * `WM_CLASS` deadlocks - the client will not send another byte until it is
 * answered, and answering means being the X server already. (Tried; it
 * hangs exactly there.)
 *
 * The guest, though, knows for free: the peer of a unix-domain socket is a
 * real local process, so SO_PEERCRED gives its pid and /proc gives its
 * name. One tiny frame, sent once, ahead of the opaque relay:
 *
 *     'M' 'S' 'L' 'A'  <uint8 length>  <length bytes of name>
 *
 * X11's own first byte is 'B' or 'l', never 'M', so a host reading one byte
 * can tell an announcement from a client that never sends one and fall
 * straight through to normal handling. Only sent when asked for
 * (`--announce`), so the Phase 1 XQuartz path on port 5002 - which expects
 * a pure byte pipe - is untouched.
 */
static void send_announce(int vsock_fd, int local_fd) {
    struct ucred cred;
    socklen_t cred_len = sizeof(cred);
    if (getsockopt(local_fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) < 0) return;
    if (cred.pid <= 0) return;

    /* cmdline's first field, not /proc/<pid>/comm: comm is truncated to 15
     * characters, which silently mangles longer app names. */
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)cred.pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return;
    char cmdline[256];
    ssize_t n = read(fd, cmdline, sizeof(cmdline) - 1);
    close(fd);
    if (n <= 0) return;
    cmdline[n] = '\0';

    const char *name = cmdline;              /* argv[0], NUL-terminated within the buffer */

    /* A process that rewrote its own title (Chromium and Electron apps do,
     * via setproctitle) has its whole command line - spaces, flags and all -
     * in argv[0]. The basename of that was garbage: Chromium's browser
     * process announced nothing usable and its GPU process announced
     * "Linux 13 (trixie)" from a flag, so the two landed in DIFFERENT host
     * processes and every frame the GPU process drew targeted a window the
     * other host owned. The real executable names every one of them the
     * same. Only taken when argv[0] has a space, so every app that already
     * named itself cleanly keeps exactly the name it had. */
    char exe[256];
    char *space = strchr(cmdline, ' ');
    if (space) {
        snprintf(path, sizeof(path), "/proc/%d/exe", (int)cred.pid);
        ssize_t m = readlink(path, exe, sizeof(exe) - 1);
        if (m > 0) {
            exe[m] = '\0';
            char *deleted = strstr(exe, " (deleted)"); /* binary replaced by an upgrade while running */
            if (deleted) *deleted = '\0';
            name = exe;
        } else {
            /* Chromium's zygote children are non-dumpable, which makes
             * /proc/<pid>/exe unreadable even to their own user. The title
             * still starts with the executable path, so keep only that. */
            *space = '\0';
        }
    }

    const char *slash = strrchr(name, '/');  /* basename: "/usr/bin/krita" -> "krita" */
    if (slash) name = slash + 1;
    size_t len = strlen(name);
    if (len == 0 || len > 200) return;

    unsigned char frame[5];
    frame[0] = 'M'; frame[1] = 'S'; frame[2] = 'L'; frame[3] = 'A';
    frame[4] = (unsigned char)len;
    /* One writev, not two writes: halves the syscalls on a path every app
     * launch pays, and closes the window where the host could read a
     * header with no name behind it yet. */
    struct iovec iov[2];
    iov[0].iov_base = frame;
    iov[0].iov_len = sizeof(frame);
    iov[1].iov_base = (void *)name;
    iov[1].iov_len = len;
    (void)!writev(vsock_fd, iov, 2);
}

static void handle_client(int local_fd, unsigned int vsock_port, int announce) {
    int vsock_fd = connect_to_host(vsock_port);
    if (vsock_fd < 0) {
        /* Host-side listener isn't up (GUI mode never started, or was
         * stopped) - nothing this X client can do but fail to connect,
         * same as any X server genuinely not being there. */
        close(local_fd);
        return;
    }
    if (announce) send_announce(vsock_fd, local_fd);
    relay(local_fd, vsock_fd);
    close(local_fd);
    close(vsock_fd);
}

/* Usage: x11tunnel [display-number [vsock-port]]
 *
 * Both optional, defaulting to (0, 5002) - the Phase 1/XQuartz path,
 * matching every call site before this became configurable. A SECOND,
 * independently-invoked x11tunnel with different arguments (e.g.
 * `x11tunnel 1 5003`) can run at the same time, bound to a DIFFERENT
 * local display socket and talking to a DIFFERENT host-side listener
 * (X11Server/"mslgd", Phase 2) - lets both GUI backends be tested/used
 * side by side without either interfering with the other. */
int main(int argc, char **argv) {
    int display_number = 0;
    unsigned int vsock_port = DEFAULT_DISPLAY_VSOCK_PORT;
    int announce = 0;
    const char *custom_socket = NULL;
    if (argc > 1) display_number = atoi(argv[1]);
    if (argc > 2) vsock_port = (unsigned int)atoi(argv[2]);
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--announce") == 0) announce = 1;
        /* --socket-path PATH: listen somewhere other than the X11 socket
         * directory. The relay itself carries any stream, so the same
         * binary bridges the GPU socket (/tmp/.virgl_test -> the host's
         * GPUBridge, see Guest/virtual-gpu) as well as a display. */
        else if (strcmp(argv[i], "--socket-path") == 0 && i + 1 < argc) custom_socket = argv[++i];
    }

    char socket_path[108];
    if (custom_socket) {
        snprintf(socket_path, sizeof(socket_path), "%s", custom_socket);
    } else {
        snprintf(socket_path, sizeof(socket_path), "%s/X%d", X11_SOCKET_DIR, display_number);
    }

    signal(SIGCHLD, SIG_IGN); /* auto-reap relay children, same as shellinit.c's listener */
    /* A write to a peer that has already closed must not kill this
     * process. Left at its default, SIGPIPE terminated the relay child
     * outright, so neither close() below ever ran and the other end saw an
     * abrupt drop instead of an orderly one. Every other MSL guest daemon
     * already does this - memd, trafficd, mslpsd, cagebridge, cageinput. */
    signal(SIGPIPE, SIG_IGN);

    /* mode 1777 matches every real X server's own convention for this
     * directory (world-writable + sticky, so any local user's X clients
     * can create their socket here) - harmless overkill in a single-user
     * guest, but matches what X client libraries actually expect to find. */
    if (!custom_socket) {
        mkdir(X11_SOCKET_DIR, 01777);
        chmod(X11_SOCKET_DIR, 01777);
    }
    unlink(socket_path); /* stale socket from a previous run */

    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("socket"); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    chmod(socket_path, 0777);

    if (listen(listen_fd, 16) < 0) {
        perror("listen");
        return 1;
    }

    for (;;) {
        /* accept4 with SOCK_CLOEXEC, like shellinit.c: no leak here today
         * (this child never execs and the parent closes its copy right
         * after the fork) but it is the same hygiene gap that caused the
         * session-vsock leak shellinit had, and it is free to close. */
        int client_fd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
        if (client_fd < 0) continue;

        pid_t pid = fork();
        if (pid == 0) {
            close(listen_fd);
            handle_client(client_fd, vsock_port, announce);
            _exit(0);
        }
        close(client_fd); /* parent doesn't need it - the forked child owns this X client's session */
    }

    return 0;
}
