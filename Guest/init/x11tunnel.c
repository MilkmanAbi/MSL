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
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>

#define DEFAULT_DISPLAY_VSOCK_PORT 5002
#define X11_SOCKET_DIR "/tmp/.X11-unix"
#define BUF_SIZE 8192

static int connect_to_host(unsigned int vsock_port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;

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

/* Relays until either side closes or errors - plain byte pump, no framing,
 * no interpretation. Returns once the X client's session is over. */
static void relay(int a, int b) {
    unsigned char buf[BUF_SIZE];
    fd_set readfds;

    for (;;) {
        FD_ZERO(&readfds);
        FD_SET(a, &readfds);
        FD_SET(b, &readfds);
        int maxfd = (a > b ? a : b) + 1;

        if (select(maxfd, &readfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (FD_ISSET(a, &readfds)) {
            ssize_t n = read(a, buf, sizeof(buf));
            if (n <= 0) break;
            if (write(b, buf, (size_t)n) != n) break;
        }
        if (FD_ISSET(b, &readfds)) {
            ssize_t n = read(b, buf, sizeof(buf));
            if (n <= 0) break;
            if (write(a, buf, (size_t)n) != n) break;
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
    if (write(vsock_fd, frame, sizeof(frame)) != (ssize_t)sizeof(frame)) return;
    (void)!write(vsock_fd, name, len);
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
    if (argc > 1) display_number = atoi(argv[1]);
    if (argc > 2) vsock_port = (unsigned int)atoi(argv[2]);
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--announce") == 0) announce = 1;
    }

    char socket_path[64];
    snprintf(socket_path, sizeof(socket_path), "%s/X%d", X11_SOCKET_DIR, display_number);

    signal(SIGCHLD, SIG_IGN); /* auto-reap relay children, same as shellinit.c's listener */

    /* mode 1777 matches every real X server's own convention for this
     * directory (world-writable + sticky, so any local user's X clients
     * can create their socket here) - harmless overkill in a single-user
     * guest, but matches what X client libraries actually expect to find. */
    mkdir(X11_SOCKET_DIR, 01777);
    chmod(X11_SOCKET_DIR, 01777);
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
        int client_fd = accept(listen_fd, NULL, NULL);
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
