/*
 * shellinit.c
 *
 * vsock shell listener for the guest side of MSL. Meant to be invoked as
 * (or by) the guest's init process, or as a service started early in boot -
 * see Guest/init/README.md for how this fits into a minimal distro rootfs.
 *
 * Wire protocol on the data connection (host <-> guest), after connect -
 * see Sources/MSLCore/ShellProtocol.swift for the host-side mirror:
 *
 *   Frame format: [u8 type][u32 BE length][payload]
 *
 *     EXEC   0x01  host->guest, sent first, exactly once.
 *            payload: rows u16 BE, cols u16 BE, userlen u16 BE, user bytes,
 *            cmdlen u16 BE, cmd bytes (userlen == 0 means "root"; cmdlen == 0
 *            means "interactive login shell", not a one-shot command). An
 *            unknown user sends a single EXIT frame (status 127) and closes
 *            without ever forkpty()ing - see handle_session.
 *     DATA   0x02  both directions - raw bytes to/from the pty
 *     RESIZE 0x03  host->guest only - rows u16 BE, cols u16 BE
 *     EXIT   0x04  guest->host only, sent last, exactly once - payload:
 *            one byte, the child's exit status (0-255; a signal-killed
 *            child is reported as 128+signal, matching bash's own $?
 *            convention)
 *
 * One connection = one shell session; sessions run concurrently
 * (fork-per-connection, matching fileopsd.c's model). Each session process
 * then forkpty()s the actual shell - a two-generation fork tree (listener
 * -> session handler -> shell), which matters for SIGCHLD: the listener
 * ignores it to auto-reap session-handler children with no waitpid needed,
 * but each session handler resets it back to default for itself before
 * forkpty() (see main()'s fork() child branch) so its own waitpid() on the
 * shell child gets a real, meaningful exit status instead of losing it to
 * inherited auto-reap - and so the shell itself (which inherits whatever
 * the session handler has at forkpty time) gets normal SIGCHLD behavior
 * for its own job control.
 *
 * Replaces an earlier single-session, unframed version whose resize
 * mechanism spliced a raw `0x00 'R' ...` marker directly into the byte
 * stream - simple, but a real correctness gap ("assumes the interactive
 * stream doesn't otherwise contain a raw NUL byte"). Full framing removes
 * that gap entirely and gives EXEC/EXIT a clean home instead of needing
 * more magic-byte special cases.
 */

/* For accept4() and SOCK_CLOEXEC, which glibc only declares with it (musl
 * declares them regardless). Must come before every include. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pty.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <pwd.h>
#include <grp.h>
#include <stddef.h>
#include <time.h>

#define SHELL_PORT 5000
#define BUF_SIZE 4096
/* Sanity cap on an incoming frame's declared length - both peers only ever
 * actually send DATA payloads up to BUF_SIZE and small fixed-size EXEC/
 * RESIZE payloads, so this only guards against a corrupted/hostile length
 * field driving an oversized malloc, not a real operational limit. */
#define MAX_FRAME_PAYLOAD (1u << 20)

enum { FRAME_EXEC = 0x01, FRAME_DATA = 0x02, FRAME_RESIZE = 0x03, FRAME_EXIT = 0x04,
       /* Detachable sessions - see the block comment below. */
       FRAME_SESSION = 0x05, FRAME_ATTACH = 0x06, FRAME_DETACH = 0x07 };

/* ---- Detachable sessions --------------------------------------------
 *
 * A hibernate does not kill a shell. `saveMachineStateTo` writes the
 * guest's whole RAM to disk, so on resume the shell, its pty and its
 * children are exactly where they were - measured on a real hibernate: a
 * `sleep 9999` started before one was still running after it.
 *
 * What is gone is the vsock. And it does not *error*: the restored
 * handler sits in select() on a dead fd that simply never becomes
 * readable (`wchan=poll_schedule_timeout`, measured). So nothing woke the
 * old loop, which is why every hibernate stranded a handler and a live
 * shell forever while the user was given a brand-new session.
 *
 * So a session owns a second way in: its own vsock port, held in the same
 * select() set. A reattach arriving there wakes the handler even though
 * the dead one never will. vsock rather than a unix socket because the
 * thing reconnecting is on the **Mac**, which cannot reach a unix socket
 * in the guest at all - and that also means no fd has to be passed from
 * the listener to this handler.
 *
 * While detached the pty keeps being drained into a ring buffer. That is
 * not optional: a pty whose buffer fills blocks the shell on write, so
 * not reading would freeze a detached session mid-command. The buffer
 * doubles as the scrollback replayed on reattach.
 *
 * All of it is opt-in. A host that sends no session id in EXEC gets
 * exactly the old behaviour - which is what every already-shipped host
 * does, and what makes this safe to deploy under them.
 */
#define SESSION_ID_MAX 64
#define RING_SIZE (256u * 1024u)
/* A detached session with a live shell is hung up after this, so a
 * forgotten one cannot live forever. */
#define DETACHED_TTL_SECONDS (12 * 60 * 60)

struct ring {
    unsigned char *buf;
    size_t len;      /* bytes held, <= RING_SIZE */
    size_t start;    /* index of the oldest byte */
};

static void ring_put(struct ring *r, const unsigned char *data, size_t n) {
    if (!r->buf) return;
    /* One byte at a time: every caller writes at most BUF_SIZE, far under
     * RING_SIZE, so a memcpy fast path would be unreachable code that gcc
     * cannot see is unreachable (it warns about a copy larger than the
     * source buffer). */
    for (size_t i = 0; i < n; i++) {
        size_t at = (r->start + r->len) % RING_SIZE;
        r->buf[at] = data[i];
        if (r->len < RING_SIZE) r->len++;
        else r->start = (r->start + 1) % RING_SIZE;
    }
}

/* Copies the ring out in order. Caller frees. */
static unsigned char *ring_take(struct ring *r, size_t *out_len) {
    *out_len = r->len;
    if (!r->buf || r->len == 0) return NULL;
    unsigned char *flat = malloc(r->len);
    if (!flat) { *out_len = 0; return NULL; }
    for (size_t i = 0; i < r->len; i++) flat[i] = r->buf[(r->start + i) % RING_SIZE];
    return flat;
}

/* The port a session waits on to be reattached to. Assigned by the kernel
 * and reported to the host in the SESSION frame, so nothing has to agree
 * on a number in advance or risk colliding with another session. */
static int session_listen(unsigned int *out_port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof(sa));
    sa.svm_family = AF_VSOCK;
    sa.svm_cid = VMADDR_CID_ANY;
    sa.svm_port = VMADDR_PORT_ANY;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    struct sockaddr_vm got;
    socklen_t gotlen = sizeof(got);
    if (getsockname(fd, (struct sockaddr *)&got, &gotlen) < 0) { close(fd); return -1; }
    *out_port = got.svm_port;
    return fd;
}

static int read_full(int fd, void *buf, size_t n) {
    unsigned char *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1; /* EOF */
        got += (size_t)r;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t n) {
    const unsigned char *p = buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, p + sent, n - sent);
        if (w < 0) {
            if (errno == EINTR) continue;
            /* conn_fd is non-blocking for the whole relay loop (see struct
             * frame_reader), so a full socket buffer surfaces here as
             * EAGAIN rather than simply blocking. Wait for room and carry
             * on, which keeps every caller's existing semantics: output is
             * back-pressured, never dropped or truncated. */
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(fd, &wfds);
                if (select(fd + 1, NULL, &wfds, NULL, NULL) < 0 && errno != EINTR) return -1;
                continue;
            }
            return -1;
        }
        sent += (size_t)w;
    }
    return 0;
}

/* Reads one frame's header + payload. *payload is malloc'd on success
 * (caller frees) - NULL if the payload is empty. Returns 0 on success, -1
 * on EOF/error/oversized-length. */
static int read_frame(int fd, unsigned char *type, unsigned char **payload, uint32_t *len) {
    unsigned char header[5];
    if (read_full(fd, header, sizeof(header)) < 0) return -1;
    *type = header[0];
    *len = ((uint32_t)header[1] << 24) | ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 8) | header[4];
    if (*len > MAX_FRAME_PAYLOAD) return -1;
    if (*len == 0) { *payload = NULL; return 0; }
    *payload = malloc(*len);
    if (!*payload) return -1;
    if (read_full(fd, *payload, *len) < 0) { free(*payload); return -1; }
    return 0;
}

/* Incremental frame assembly, for the relay loop's side of the connection.
 *
 * `read_frame` above cannot be used once a session is relaying. select()
 * promises only that ONE byte is readable, while read_frame sits inside
 * read_full until the entire 5-byte header AND the entire payload have
 * arrived. Every moment it waits there, master_fd is not being read: the
 * pty's output buffer (~64 KB) fills and the user's shell blocks in
 * write(), so a session can stall on nothing worse than a frame split
 * across two packets. read_frame is still right for the one-shot EXEC
 * frame, which is read before there is any pty to starve.
 *
 * So the relay keeps this accumulator across select() iterations instead:
 * read whatever happens to be there, act only on the frames it completes,
 * and keep the remainder for next time.
 */
struct frame_reader {
    unsigned char header[5];
    size_t header_got;
    unsigned char *payload;  /* malloc'd once the length is known */
    uint32_t payload_len;
    size_t payload_got;
};

static void fr_reset(struct frame_reader *fr) {
    free(fr->payload);
    fr->payload = NULL;
    fr->header_got = 0;
    fr->payload_len = 0;
    fr->payload_got = 0;
}

/* Acts on one complete frame. Returns 0, or -1 if the session must end. */
static int apply_frame(int master_fd, unsigned char type, const unsigned char *payload, uint32_t len) {
    if (type == FRAME_DATA && len > 0) {
        if (write_full(master_fd, payload, len) < 0) return -1;
    } else if (type == FRAME_RESIZE && len >= 4) {
        struct winsize nws;
        memset(&nws, 0, sizeof(nws));
        nws.ws_row = ((unsigned short)payload[0] << 8) | payload[1];
        nws.ws_col = ((unsigned short)payload[2] << 8) | payload[3];
        ioctl(master_fd, TIOCSWINSZ, &nws);
    }
    return 0;
}

/* Feeds n freshly-read bytes in, applying every frame they complete.
 * Returns 0 to keep relaying, -1 to end the session. */
static int fr_feed(struct frame_reader *fr, const unsigned char *data, size_t n, int master_fd) {
    for (;;) {
        if (fr->header_got < sizeof(fr->header)) {
            size_t want = sizeof(fr->header) - fr->header_got;
            if (want > n) want = n;
            memcpy(fr->header + fr->header_got, data, want);
            fr->header_got += want;
            data += want;
            n -= want;
            if (fr->header_got < sizeof(fr->header)) return 0; /* header still short */
            fr->payload_len = ((uint32_t)fr->header[1] << 24) | ((uint32_t)fr->header[2] << 16)
                            | ((uint32_t)fr->header[3] << 8) | fr->header[4];
            if (fr->payload_len > MAX_FRAME_PAYLOAD) return -1;
            fr->payload_got = 0;
            if (fr->payload_len > 0) {
                fr->payload = malloc(fr->payload_len);
                if (!fr->payload) return -1;
            }
        }
        if (fr->payload_got < fr->payload_len) {
            size_t want = fr->payload_len - fr->payload_got;
            if (want > n) want = n;
            memcpy(fr->payload + fr->payload_got, data, want);
            fr->payload_got += want;
            data += want;
            n -= want;
            if (fr->payload_got < fr->payload_len) return 0; /* payload still short */
        }
        int rc = apply_frame(master_fd, fr->header[0], fr->payload, fr->payload_len);
        fr_reset(fr);
        if (rc < 0) return -1;
        if (n == 0) return 0;
    }
}

static int write_frame(int fd, unsigned char type, const void *payload, uint32_t len) {
    unsigned char header[5] = {
        type,
        (unsigned char)(len >> 24), (unsigned char)(len >> 16),
        (unsigned char)(len >> 8), (unsigned char)len,
    };
    /* Header and payload in one writev where the whole frame goes out at
     * once - every DATA frame carrying pty output used to cost two
     * writes. A short writev falls back to the two-call path rather than
     * growing a partial-iovec loop here; it is rare and the fallback is
     * already correct. */
    struct iovec iov[2];
    iov[0].iov_base = header;
    iov[0].iov_len = sizeof(header);
    iov[1].iov_base = (void *)payload;
    iov[1].iov_len = len;
    if (len > 0) {
        ssize_t sent = writev(fd, iov, 2);
        if (sent == (ssize_t)(sizeof(header) + len)) return 0;
        if (sent < 0 && errno != EINTR && errno != EAGAIN) return -1;
        if (sent <= 0) {
            if (write_full(fd, header, sizeof(header)) < 0) return -1;
            return write_full(fd, payload, len);
        }
        /* Partial: finish whatever is left of each part in order. */
        size_t done = (size_t)sent;
        if (done < sizeof(header)) {
            if (write_full(fd, header + done, sizeof(header) - done) < 0) return -1;
            done = sizeof(header);
        }
        size_t payload_done = done - sizeof(header);
        if (payload_done < len) {
            return write_full(fd, (const unsigned char *)payload + payload_done, len - payload_done);
        }
        return 0;
    }
    return write_full(fd, header, sizeof(header));
}

static void handle_session(int conn_fd) {
    unsigned char type;
    unsigned char *payload = NULL;
    uint32_t len = 0;

    if (read_frame(conn_fd, &type, &payload, &len) < 0 || type != FRAME_EXEC || len < 6) {
        free(payload);
        close(conn_fd);
        return;
    }

    unsigned short rows = ((unsigned short)payload[0] << 8) | payload[1];
    unsigned short cols = ((unsigned short)payload[2] << 8) | payload[3];
    unsigned short userlen = ((unsigned short)payload[4] << 8) | payload[5];

    size_t off = 6;
    char *username = NULL;
    if (userlen > 0 && len >= off + userlen) {
        username = malloc((size_t)userlen + 1);
        if (username) {
            memcpy(username, payload + off, userlen);
            username[userlen] = '\0';
        }
        off += userlen;
    }

    unsigned short cmdlen = 0;
    char *command = NULL;
    if (len >= off + 2) {
        cmdlen = ((unsigned short)payload[off] << 8) | payload[off + 1];
        off += 2;
        if (cmdlen > 0 && len >= off + cmdlen) {
            command = malloc((size_t)cmdlen + 1);
            if (command) {
                memcpy(command, payload + off, cmdlen);
                command[cmdlen] = '\0';
            }
            /* Past the command, so anything appended after it is read from
             * the right place. The original stopped here and left `off`
             * pointing at the command's first byte - harmless while nothing
             * followed, and exactly wrong the moment something did: the
             * session id below was being parsed out of the command's own
             * bytes, so a session was only ever created for an EXEC with no
             * command at all. */
            off += cmdlen;
        }
    }
    /* An optional trailing field: the host's session id. Everything above
     * is length-prefixed and parsing stops after the command, so a host
     * that sends one is simply ignored by an older shellinit - which is
     * what makes this safe to add with no version number anywhere. */
    char session_id[SESSION_ID_MAX + 1];
    session_id[0] = '\0';
    if (len >= off + 2) {
        unsigned short idlen = ((unsigned short)payload[off] << 8) | payload[off + 1];
        off += 2;
        if (idlen > 0 && idlen <= SESSION_ID_MAX && len >= off + idlen) {
            memcpy(session_id, payload + off, idlen);
            session_id[idlen] = '\0';
        }
    }
    free(payload);

    /* Resolved *before* forkpty() so an unknown user fails immediately -
     * a single EXIT frame, no pty ever created - rather than starting a
     * session that would just fail deep inside the child. getpwnam()'s
     * return value lives in static storage that a later libc call could
     * clobber, so the fields actually needed are copied out now rather
     * than held as a pointer across the fork below. */
    const char *requested_user = (username && username[0]) ? username : "root";
    struct passwd *pw = getpwnam(requested_user);
    if (!pw) {
        free(username);
        free(command);
        unsigned char exit_byte = 127; /* matches shell convention for "command not found" - there's no user to run anything as */
        write_frame(conn_fd, FRAME_EXIT, &exit_byte, 1);
        close(conn_fd);
        return;
    }
    uid_t target_uid = pw->pw_uid;
    gid_t target_gid = pw->pw_gid;
    char home_dir[512];
    strncpy(home_dir, pw->pw_dir, sizeof(home_dir) - 1);
    home_dir[sizeof(home_dir) - 1] = '\0';
    char pw_name[64];
    strncpy(pw_name, pw->pw_name, sizeof(pw_name) - 1);
    pw_name[sizeof(pw_name) - 1] = '\0';
    free(username);

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;

    int master_fd;
    pid_t child = forkpty(&master_fd, NULL, NULL, &ws);

    if (child < 0) {
        perror("forkpty");
        free(command);
        close(conn_fd);
        return;
    }

    if (child == 0) {
        /* The session's own connection must not reach the shell. Inherited,
         * anything long-running the command starts in the background - the
         * X11 tunnel, a server - keeps the vsock open after the session
         * ends, so the host never sees EOF and waits forever. It made the
         * first Linux app launched after every boot hang: its tunnel start
         * held the connection, and the app itself never ran (2026-09-14).
         * accept4's SOCK_CLOEXEC below covers it too; this is the explicit
         * half. */
        close(conn_fd);

        /* Real privilege drop, root only until this point - order matters:
         * initgroups (supplementary groups) and setgid both need root,
         * setuid must come last since it's what actually gives up root.
         * Skipped entirely for target_uid 0 (root) - setuid(0) would be a
         * no-op anyway, but there's nothing to drop in the first place. */
        if (target_uid != 0) {
            if (initgroups(pw_name, target_gid) < 0 || setgid(target_gid) < 0 || setuid(target_uid) < 0) {
                _exit(126); /* matches shell convention for "found but couldn't be executed" */
            }
        }

        /* HOME/USER/LOGNAME/SHELL set here, unconditionally, for every
         * session regardless of user - not left to whatever the service
         * definition's own environment happened to hardcode (previously
         * just `Environment=HOME=/root`/`export HOME=/root`, baked in for
         * root only). Self-contained and correct for any resolved user
         * now, not just root. */
        const char *shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh";
        setenv("HOME", home_dir, 1);
        setenv("USER", pw_name, 1);
        setenv("LOGNAME", pw_name, 1);
        setenv("SHELL", shell, 1);
        if (chdir(home_dir) != 0) { chdir("/"); } /* best-effort - a missing/unreadable home dir shouldn't abort the session */

        /* Real bash for real bash semantics (job control, [[ ]], arrays,
         * etc.) when present - falls back to /bin/sh (whatever that is on
         * this distro) if not, rather than failing the session outright. */
        if (command) {
            /* One-shot command: non-login, matches `ssh host cmd`. */
            execl(shell, shell, "-c", command, (char *)NULL);
        } else {
            /* Interactive: login shell (leading '-' in argv[0]). */
            const char *base = strrchr(shell, '/');
            base = base ? base + 1 : shell;
            char login_arg[32];
            snprintf(login_arg, sizeof(login_arg), "-%s", base);
            execl(shell, login_arg, (char *)NULL);
        }
        _exit(127);
    }
    free(command);

    /* Parent: relay conn_fd <-> master_fd until the CHILD exits. Note "the
     * child", not "the connection" - that is the whole difference from the
     * old loop, which ended the session when the host went away and so
     * could not survive a hibernate. */
    unsigned char buf[BUF_SIZE];
    unsigned char inbuf[BUF_SIZE];
    fd_set readfds;
    struct frame_reader fr;
    memset(&fr, 0, sizeof(fr));

    /* Opt-in: no session id from the host means no session port, no ring,
     * and exactly the old behaviour below. */
    int sess_fd = -1;
    struct ring ring;
    memset(&ring, 0, sizeof(ring));
    if (session_id[0]) {
        unsigned int sess_port = 0;
        sess_fd = session_listen(&sess_port);
        if (sess_fd >= 0) {
            ring.buf = malloc(RING_SIZE);
            /* "<id> <port>", sent once before any DATA. Its absence is how
             * a host detects an older shellinit. */
            char hello[SESSION_ID_MAX + 24];
            int hl = snprintf(hello, sizeof(hello), "%s %u", session_id, sess_port);
            if (hl > 0) write_frame(conn_fd, FRAME_SESSION, hello, (uint32_t)hl);
        }
    }
    const int detachable = (sess_fd >= 0);
    time_t detached_since = 0;
    /* Without a session, a half-closed connection is still WRITTEN to -
     * the shell may have output left - it is just no longer read from.
     * That is the old behaviour, kept exactly. */
    int conn_readable = 1;

    /* Non-blocking from here on, so that a frame arriving in pieces can
     * never hold this loop away from master_fd - see struct frame_reader.
     * Deliberately not set earlier: the EXEC frame above is read with the
     * blocking read_frame, before there is a pty to starve. */
    int conn_flags = fcntl(conn_fd, F_GETFL, 0);
    if (conn_flags >= 0) fcntl(conn_fd, F_SETFL, conn_flags | O_NONBLOCK);

    for (;;) {
        FD_ZERO(&readfds);
        int maxfd = master_fd;
        if (conn_fd >= 0 && conn_readable) {
            FD_SET(conn_fd, &readfds);
            if (conn_fd > maxfd) maxfd = conn_fd;
        }
        FD_SET(master_fd, &readfds);
        /* **The one that matters after a hibernate.** The dead vsock never
         * becomes readable, so without this in the set nothing would ever
         * wake this process again. */
        if (sess_fd >= 0) { FD_SET(sess_fd, &readfds); if (sess_fd > maxfd) maxfd = sess_fd; }

        struct timeval tv, *timeout = NULL;
        if (conn_fd < 0 && detachable) { tv.tv_sec = 60; tv.tv_usec = 0; timeout = &tv; }

        if (select(maxfd + 1, &readfds, NULL, NULL, timeout) < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (conn_fd < 0 && detached_since &&
            time(NULL) - detached_since > DETACHED_TTL_SECONDS) {
            break; /* nobody came back; hang the shell up */
        }

        /* A reattach. Takes over from whatever was there before, which is
         * what lets a session survive its host being killed outright. */
        if (sess_fd >= 0 && FD_ISSET(sess_fd, &readfds)) {
            int next_fd = accept4(sess_fd, NULL, NULL, SOCK_CLOEXEC);
            if (next_fd >= 0) {
                unsigned char atype; unsigned char *apayload = NULL; uint32_t alen = 0;
                /* ATTACH carries the terminal size, which may have changed
                 * while detached. Applied before the replay so a
                 * full-screen app redraws into the right shape. */
                if (read_frame(next_fd, &atype, &apayload, &alen) == 0 &&
                    atype == FRAME_ATTACH && alen >= 4) {
                    struct winsize nws;
                    memset(&nws, 0, sizeof(nws));
                    nws.ws_row = ((unsigned short)apayload[0] << 8) | apayload[1];
                    nws.ws_col = ((unsigned short)apayload[2] << 8) | apayload[3];
                    ioctl(master_fd, TIOCSWINSZ, &nws);

                    if (conn_fd >= 0) close(conn_fd); /* an older client, displaced */
                    conn_fd = next_fd;
                    conn_readable = 1;
                    detached_since = 0;
                    fr_reset(&fr);
                    int f = fcntl(conn_fd, F_GETFL, 0);
                    if (f >= 0) fcntl(conn_fd, F_SETFL, f | O_NONBLOCK);

                    size_t rlen = 0;
                    unsigned char *flat = ring_take(&ring, &rlen);
                    if (flat) {
                        /* Reset attributes first: the ring can begin in the
                         * middle of an escape sequence, and replaying that
                         * raw leaves the terminal wearing whatever colour
                         * the truncation happened to land in. */
                        write_frame(conn_fd, FRAME_DATA, "\033[0m", 4);
                        write_frame(conn_fd, FRAME_DATA, flat, (uint32_t)rlen);
                        free(flat);
                    }
                    ring.len = 0; ring.start = 0;
                    /* Nudge the shell into repainting its prompt, and any
                     * full-screen app into redrawing completely. */
                    kill(child, SIGWINCH);
                } else {
                    close(next_fd);
                }
                free(apayload);
            }
        }

        if (conn_fd >= 0 && conn_readable && FD_ISSET(conn_fd, &readfds)) {
            ssize_t got = read(conn_fd, inbuf, sizeof(inbuf));
            if (got < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
                /* Readable but nothing there after all - try again. */
            } else if (got <= 0) {
                /* The host is gone: a graceful half-close, a dropped
                 * connection, or this guest hibernated out from under it. */
                if (detachable) {
                    close(conn_fd);
                    conn_fd = -1;
                    detached_since = time(NULL);
                } else {
                    conn_readable = 0;
                }
            } else if (fr_feed(&fr, inbuf, (size_t)got, master_fd) < 0) {
                break; /* malformed length, or the pty went away */
            }
        }

        if (FD_ISSET(master_fd, &readfds)) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n <= 0) break; /* child exited (or errored) - pty closed */
            if (conn_fd >= 0) {
                if (write_frame(conn_fd, FRAME_DATA, buf, (uint32_t)n) < 0) {
                    /* The peer died mid-write. Same answer as a read EOF. */
                    if (detachable) {
                        close(conn_fd); conn_fd = -1; detached_since = time(NULL);
                    } else break;
                }
            } else {
                /* Detached: keep draining, or a full pty blocks the shell. */
                ring_put(&ring, buf, (size_t)n);
            }
        }
    }

    if (sess_fd >= 0) close(sess_fd);
    free(ring.buf);

    /* Harmless no-op if the child already exited on its own (ESRCH,
     * ignored) - only actually terminates anything if the loop broke
     * because the host disconnected while the shell was still running. */
    kill(child, SIGHUP);
    fr_reset(&fr);
    int status = 0;
    waitpid(child, &status, 0);
    unsigned char exit_byte = (unsigned char)(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    if (conn_fd >= 0) {
        write_frame(conn_fd, FRAME_EXIT, &exit_byte, 1);
        close(conn_fd);
    }
    close(master_fd);
}

int main(void) {
    signal(SIGCHLD, SIG_IGN); /* auto-reap the listener's own session-handler children */
    /* And SIGPIPE, which matters more here than a missing close(): dying
     * on the signal means kill(child, SIGHUP) and waitpid never run, so an
     * abrupt host disconnect ORPHANS the user's shell rather than hanging
     * it up. One leaked shell per dropped connection. */
    signal(SIGPIPE, SIG_IGN);

    int listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("socket"); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = SHELL_PORT;

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(listen_fd, 8) < 0) {
        perror("listen");
        return 1;
    }

    for (;;) {
        /* CLOEXEC: the session handler relays this connection itself and
         * never execs, so nothing that *is* exec'd - the shell, and what the
         * shell starts - may inherit it. See handle_session's child branch. */
        int conn_fd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
        if (conn_fd < 0) continue;

        pid_t pid = fork();
        if (pid == 0) {
            close(listen_fd);
            /* See the top-of-file comment on why this has to be reset
             * here, in this specific generation, before forkpty(). */
            signal(SIGCHLD, SIG_DFL);
            handle_session(conn_fd);
            _exit(0);
        }
        close(conn_fd); /* parent doesn't need it - the forked child owns the session */
    }

    return 0;
}
