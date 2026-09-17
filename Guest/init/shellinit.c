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
#include <linux/vm_sockets.h>
#include <pwd.h>
#include <grp.h>

#define SHELL_PORT 5000
#define BUF_SIZE 4096
/* Sanity cap on an incoming frame's declared length - both peers only ever
 * actually send DATA payloads up to BUF_SIZE and small fixed-size EXEC/
 * RESIZE payloads, so this only guards against a corrupted/hostile length
 * field driving an oversized malloc, not a real operational limit. */
#define MAX_FRAME_PAYLOAD (1u << 20)

enum { FRAME_EXEC = 0x01, FRAME_DATA = 0x02, FRAME_RESIZE = 0x03, FRAME_EXIT = 0x04 };

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
        if (w < 0) { if (errno == EINTR) continue; return -1; }
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

static int write_frame(int fd, unsigned char type, const void *payload, uint32_t len) {
    unsigned char header[5] = {
        type,
        (unsigned char)(len >> 24), (unsigned char)(len >> 16),
        (unsigned char)(len >> 8), (unsigned char)len,
    };
    if (write_full(fd, header, sizeof(header)) < 0) return -1;
    if (len > 0 && write_full(fd, payload, len) < 0) return -1;
    return 0;
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

    /* Parent: relay conn_fd <-> master_fd using the framed protocol until
     * either side closes. */
    unsigned char buf[BUF_SIZE];
    fd_set readfds;
    int conn_active = 1; /* see the conn_fd EOF handling below */

    for (;;) {
        FD_ZERO(&readfds);
        if (conn_active) FD_SET(conn_fd, &readfds);
        FD_SET(master_fd, &readfds);
        int maxfd = (conn_fd > master_fd ? conn_fd : master_fd) + 1;

        if (select(maxfd, &readfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (conn_active && FD_ISSET(conn_fd, &readfds)) {
            unsigned char ftype;
            unsigned char *fpayload = NULL;
            uint32_t flen = 0;
            if (read_frame(conn_fd, &ftype, &fpayload, &flen) < 0) {
                /* Host has nothing more to send (a graceful half-close,
                 * e.g. its own stdin hit EOF - see msl's writer thread)
                 * or the connection genuinely died. Either way, stop
                 * selecting on conn_fd from here on - but do NOT tear the
                 * session down immediately: the shell/command may still
                 * be mid-execution and have output left to produce. Fall
                 * through to keep relaying master_fd until the child
                 * exits on its own (below), the same as it would with no
                 * more input ever coming. A hard, still-connected client
                 * disconnect looks identical from here to a graceful one -
                 * this process exits either way once the child does, and
                 * a failed final write_frame below is silently ignored if
                 * the peer is truly gone. */
                conn_active = 0;
            } else if (ftype == FRAME_DATA && flen > 0) {
                if (write_full(master_fd, fpayload, flen) < 0) { free(fpayload); break; }
                free(fpayload);
            } else if (ftype == FRAME_RESIZE && flen >= 4) {
                struct winsize nws;
                memset(&nws, 0, sizeof(nws));
                nws.ws_row = ((unsigned short)fpayload[0] << 8) | fpayload[1];
                nws.ws_col = ((unsigned short)fpayload[2] << 8) | fpayload[3];
                ioctl(master_fd, TIOCSWINSZ, &nws);
                free(fpayload);
            } else {
                free(fpayload);
            }
        }

        if (FD_ISSET(master_fd, &readfds)) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n <= 0) break; /* child exited (or errored) - pty closed */
            if (write_frame(conn_fd, FRAME_DATA, buf, (uint32_t)n) < 0) break;
        }
    }

    /* Harmless no-op if the child already exited on its own (ESRCH,
     * ignored) - only actually terminates anything if the loop broke
     * because the host disconnected while the shell was still running. */
    kill(child, SIGHUP);
    int status = 0;
    waitpid(child, &status, 0);
    unsigned char exit_byte = (unsigned char)(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    write_frame(conn_fd, FRAME_EXIT, &exit_byte, 1);

    close(conn_fd);
    close(master_fd);
}

int main(void) {
    signal(SIGCHLD, SIG_IGN); /* auto-reap the listener's own session-handler children */

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
