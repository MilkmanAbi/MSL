/*
 * fileopsd.c
 *
 * Minimal vsock file-operations daemon for the guest side of MSL's
 * sandbox (the Finder <-> Linux direction - see README's "MSL Sandbox").
 * Sibling to shellinit.c, built and installed the same way, but simpler:
 * one connection = exactly one request + one response, then close - no
 * session state to keep between requests, unlike shellinit's long-lived
 * pty. The host (mslhd's WebDAV bridge) dictates every path and this
 * daemon trusts it completely, operating on the guest's real filesystem
 * with no sandboxing of its own - same trust model as the mac_home
 * virtiofs share (whole-home-dir access), not a security boundary.
 *
 * Wire format - one frame per request, one frame per response:
 *   [u32 LE length][payload]
 *
 * Request payload: op u8, then op-specific fields (little-endian ints):
 *   LIST   0x01  pathlen u16, path
 *   STAT   0x02  pathlen u16, path
 *   READ   0x03  pathlen u16, path, offset u64, len u32
 *   WRITE  0x04  pathlen u16, path, offset u64, datalen u32, data
 *   MKDIR  0x05  pathlen u16, path
 *   RENAME 0x06  srclen u16, src, dstlen u16, dst
 *   UNLINK 0x07  pathlen u16, path
 *   CHMOD  0x08  pathlen u16, path, mode u32
 *   LIST2  0x09  pathlen u16, path
 *
 * Response payload: status u8 (0x00 ok, 0x01 err)
 *   if err: errno u32
 *   if ok:
 *     LIST   -> zero or more "name\tsize\tmtime\tmode\n" entries. A name
 *               containing \t or \n would break the delimiters, so such
 *               names are skipped - LIST2 is the fix.
 *     LIST2  -> zero or more binary entries, each:
 *               namelen u16, name (raw bytes), size u64, mtime u64, mode u32
 *               Every legal Linux filename round-trips, tabs and newlines
 *               included.
 *     STAT   -> size u64, mtime u64, mode u32
 *     READ   -> raw bytes (length implied by the frame itself)
 *     others -> empty
 *
 * An unknown opcode is answered with EINVAL. That is the capability probe
 * the host relies on: a host that knows LIST2 or CHMOD tries it, and falls
 * back to LIST or an in-place write when an older image says EINVAL - so an
 * old host with a new image and a new host with an old image both work.
 *
 * WRITE truncates the file when offset == 0 (establishing new complete
 * contents, matching a WebDAV PUT starting its first chunk at the top)
 * and does not otherwise - a nonzero-offset WRITE is a random-access
 * partial write that must not destroy the rest of the file.
 *
 * CHMOD exists so the host can write an overwrite to a temp file, give the
 * temp the original's mode, and rename it into place: without it, a rename
 * would replace the inode and drop a script's +x on every save.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>

#define FILEOPS_PORT 5001
#define MAX_FRAME (16 * 1024 * 1024) /* 16MB cap on request/response frames */

enum {
    OP_LIST = 0x01,
    OP_STAT = 0x02,
    OP_READ = 0x03,
    OP_WRITE = 0x04,
    OP_MKDIR = 0x05,
    OP_RENAME = 0x06,
    OP_UNLINK = 0x07,
    OP_CHMOD = 0x08,
    OP_LIST2 = 0x09,
};

/* WebDAVServer.handlePut writes large uploads to a sibling
 * ".msl-put-<uuid>.tmp" and renames it into place. When the upload dies by
 * timeout or a dropped connection the host can't clean up (the transport is
 * gone), so the temp is left behind. Nothing else creates files with this
 * name, and no upload runs for anywhere near an hour. */
#define PUT_TEMP_PREFIX ".msl-put-"
#define PUT_TEMP_SUFFIX ".tmp"
#define PUT_TEMP_STALE_SECONDS 3600

static int read_full(int fd, void *buf, size_t n) {
    unsigned char *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1; /* EOF before n bytes */
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

static uint32_t read_u32le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t read_u16le(const unsigned char *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static uint64_t read_u64le(const unsigned char *p) {
    uint64_t lo = read_u32le(p);
    uint64_t hi = read_u32le(p + 4);
    return lo | (hi << 32);
}
static void write_u16le(unsigned char *p, uint16_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
}
static void write_u32le(unsigned char *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}
static void write_u64le(unsigned char *p, uint64_t v) {
    write_u32le(p, (uint32_t)(v & 0xFFFFFFFFu));
    write_u32le(p + 4, (uint32_t)(v >> 32));
}

/* Reads a full request frame into a malloc'd buffer. Returns length, or -1
 * on I/O error / EOF / an oversized length prefix. */
static long read_frame(int fd, unsigned char **out) {
    unsigned char lenbuf[4];
    if (read_full(fd, lenbuf, 4) < 0) return -1;
    uint32_t len = read_u32le(lenbuf);
    if (len > MAX_FRAME) return -1;
    unsigned char *buf = malloc(len ? len : 1);
    if (!buf) return -1;
    if (len > 0 && read_full(fd, buf, len) < 0) { free(buf); return -1; }
    *out = buf;
    return (long)len;
}

static int write_frame(int fd, const unsigned char *buf, uint32_t len) {
    unsigned char lenbuf[4];
    write_u32le(lenbuf, len);
    if (write_full(fd, lenbuf, 4) < 0) return -1;
    if (len > 0 && write_full(fd, buf, len) < 0) return -1;
    return 0;
}

static int send_ok(int fd, const unsigned char *payload, uint32_t payload_len) {
    unsigned char *buf = malloc((size_t)payload_len + 1);
    if (!buf) return -1;
    buf[0] = 0x00;
    if (payload_len) memcpy(buf + 1, payload, payload_len);
    int rc = write_frame(fd, buf, payload_len + 1);
    free(buf);
    return rc;
}

static int send_err(int fd, int err) {
    unsigned char buf[5];
    buf[0] = 0x01;
    write_u32le(buf + 1, (uint32_t)err);
    return write_frame(fd, buf, sizeof(buf));
}

/* Parses a length-prefixed path field starting at *pos, bounds-checked
 * against the frame's declared length. Advances *pos past the field on
 * success. Returns a NUL-terminated malloc'd string the caller must free,
 * or NULL on a malformed/truncated frame. */
static char *parse_path(const unsigned char *frame, uint32_t frame_len, uint32_t *pos) {
    if (*pos + 2 > frame_len) return NULL;
    uint16_t plen = read_u16le(frame + *pos);
    *pos += 2;
    if (*pos + plen > frame_len) return NULL;
    char *path = malloc((size_t)plen + 1);
    if (!path) return NULL;
    memcpy(path, frame + *pos, plen);
    path[plen] = '\0';
    *pos += plen;
    return path;
}

/* A growable output buffer. `ok` goes false on the first allocation
 * failure and every later append is a no-op, so callers check once. */
struct outbuf { unsigned char *data; size_t len, cap; int ok; };

static void outbuf_init(struct outbuf *b) {
    b->cap = 4096; b->len = 0;
    b->data = malloc(b->cap);
    b->ok = b->data != NULL;
}

static void outbuf_append(struct outbuf *b, const void *bytes, size_t n) {
    if (!b->ok) return;
    if (b->len + n > b->cap) {
        size_t cap = b->cap;
        while (b->len + n > cap) cap *= 2;
        unsigned char *grown = realloc(b->data, cap);
        if (!grown) { b->ok = 0; return; }
        b->data = grown; b->cap = cap;
    }
    memcpy(b->data + b->len, bytes, n);
    b->len += n;
}

static int is_put_temp_name(const char *name) {
    size_t n = strlen(name), pre = strlen(PUT_TEMP_PREFIX), suf = strlen(PUT_TEMP_SUFFIX);
    return n > pre + suf
        && strncmp(name, PUT_TEMP_PREFIX, pre) == 0
        && strcmp(name + n - suf, PUT_TEMP_SUFFIX) == 0;
}

/* Removes abandoned upload temps from one directory - the one being listed.
 * Lazy rather than a filesystem-wide sweep at startup: a temp is only ever
 * a sibling of the file it was uploading, anywhere in the tree, and walking
 * the whole filesystem on every boot to find a rare leftover would cost far
 * more than the leftover does. Listing is exactly when one would otherwise
 * show up. Best-effort: a failure here never fails the listing. */
static void sweep_stale_put_temps(const char *path) {
    DIR *d = opendir(path);
    if (!d) return;
    time_t now = time(NULL);
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (!is_put_temp_name(ent->d_name)) continue;
        char full[4096];
        int flen = snprintf(full, sizeof(full), "%s/%s", path, ent->d_name);
        if (flen < 0 || (size_t)flen >= sizeof(full)) continue;
        struct stat st;
        if (lstat(full, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (now - st.st_mtime < PUT_TEMP_STALE_SECONDS) continue;
        unlink(full);
    }
    closedir(d);
}

/* Walks `path`, calling `emit` for every entry except . and .. with its
 * lstat. Returns 0, or an errno if the directory can't be opened. */
static int for_each_entry(const char *path, void (*emit)(struct outbuf *, const char *, const struct stat *), struct outbuf *out) {
    DIR *d = opendir(path);
    if (!d) return errno;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;

        char full[4096];
        int flen = snprintf(full, sizeof(full), "%s/%s", path, ent->d_name);
        if (flen < 0 || (size_t)flen >= sizeof(full)) continue; /* truncated - would stat the wrong path */

        /* lstat, not stat: stat() follows the link, so a symlink whose
         * target is missing fails here and the entry vanished from the
         * listing entirely - a file visible in `ls` that Finder swore did
         * not exist. lstat describes the link itself, which always
         * exists. */
        struct stat st;
        if (lstat(full, &st) != 0) continue; /* skip genuinely unreadable entries */
        emit(out, ent->d_name, &st);
    }
    closedir(d);
    return 0;
}

static void emit_text(struct outbuf *out, const char *name, const struct stat *st) {
    /* A tab or a newline in a name would break the delimiters and corrupt
     * every entry after it in this listing - the host would then drop the
     * malformed lines and silently show the wrong directory contents.
     * Skipping the one offending name keeps the rest correct; LIST2 lists
     * it properly. */
    if (strpbrk(name, "\t\n") != NULL) return;
    char line[4096 + 128];
    int n = snprintf(line, sizeof(line), "%s\t%llu\t%llu\t%u\n",
                     name,
                     (unsigned long long)st->st_size,
                     (unsigned long long)st->st_mtime,
                     (unsigned int)st->st_mode);
    if (n < 0 || (size_t)n >= sizeof(line)) return;
    outbuf_append(out, line, (size_t)n);
}

static void emit_binary(struct outbuf *out, const char *name, const struct stat *st) {
    size_t namelen = strlen(name);
    if (namelen > 0xFFFF) return; /* NAME_MAX is 255; cannot happen */
    unsigned char head[2], tail[20];
    write_u16le(head, (uint16_t)namelen);
    write_u64le(tail, (uint64_t)st->st_size);
    write_u64le(tail + 8, (uint64_t)st->st_mtime);
    write_u32le(tail + 16, (uint32_t)st->st_mode);
    outbuf_append(out, head, sizeof(head));
    outbuf_append(out, name, namelen);
    outbuf_append(out, tail, sizeof(tail));
}

static void handle_list_with(int fd, const char *path, void (*emit)(struct outbuf *, const char *, const struct stat *)) {
    sweep_stale_put_temps(path);
    struct outbuf out;
    outbuf_init(&out);
    int err = for_each_entry(path, emit, &out);
    if (err) { free(out.data); send_err(fd, err); return; }
    if (!out.ok) { free(out.data); send_err(fd, ENOMEM); return; }
    if (out.len > MAX_FRAME - 1) { free(out.data); send_err(fd, E2BIG); return; }
    send_ok(fd, out.data, (uint32_t)out.len);
    free(out.data);
}

static void handle_stat(int fd, const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) { send_err(fd, errno); return; }
    unsigned char buf[20];
    write_u64le(buf, (uint64_t)st.st_size);
    write_u64le(buf + 8, (uint64_t)st.st_mtime);
    write_u32le(buf + 16, (uint32_t)st.st_mode);
    send_ok(fd, buf, sizeof(buf));
}

static void handle_read(int fd, const char *path, uint64_t offset, uint32_t len) {
    int f = open(path, O_RDONLY);
    if (f < 0) { send_err(fd, errno); return; }

    unsigned char *buf = malloc(len ? len : 1);
    if (!buf) { close(f); send_err(fd, ENOMEM); return; }

    size_t total = 0;
    while (total < len) {
        ssize_t n = pread(f, buf + total, len - total, (off_t)(offset + (uint64_t)total));
        if (n < 0) { if (errno == EINTR) continue; free(buf); close(f); send_err(fd, errno); return; }
        if (n == 0) break; /* EOF */
        total += (size_t)n;
    }
    close(f);
    send_ok(fd, buf, (uint32_t)total);
    free(buf);
}

static void handle_write(int fd, const char *path, uint64_t offset, const unsigned char *data, uint32_t datalen) {
    int flags = O_WRONLY | O_CREAT | (offset == 0 ? O_TRUNC : 0);
    int f = open(path, flags, 0644);
    if (f < 0) { send_err(fd, errno); return; }

    size_t total = 0;
    while (total < datalen) {
        ssize_t n = pwrite(f, data + total, datalen - total, (off_t)(offset + total));
        if (n < 0) { if (errno == EINTR) continue; close(f); send_err(fd, errno); return; }
        total += (size_t)n;
    }
    close(f);
    send_ok(fd, NULL, 0);
}

static void handle_mkdir(int fd, const char *path) {
    if (mkdir(path, 0755) != 0) { send_err(fd, errno); return; }
    send_ok(fd, NULL, 0);
}

static void handle_rename(int fd, const char *src, const char *dst) {
    if (rename(src, dst) != 0) { send_err(fd, errno); return; }
    send_ok(fd, NULL, 0);
}

static void handle_unlink(int fd, const char *path) {
    struct stat st;
    int rc;
    if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
        rc = rmdir(path);
    } else {
        rc = unlink(path);
    }
    if (rc != 0) { send_err(fd, errno); return; }
    send_ok(fd, NULL, 0);
}

static void handle_chmod(int fd, const char *path, uint32_t mode) {
    /* Permission bits plus setuid/setgid/sticky only - the file-type bits
     * of a STAT'd mode are not something chmod can or should apply. */
    if (chmod(path, (mode_t)(mode & 07777)) != 0) { send_err(fd, errno); return; }
    send_ok(fd, NULL, 0);
}

static void handle_connection(int conn_fd) {
    unsigned char *frame = NULL;
    long flen = read_frame(conn_fd, &frame);
    if (flen < 1) { free(frame); close(conn_fd); return; }

    uint8_t op = frame[0];
    uint32_t pos = 1;

    switch (op) {
    case OP_LIST:
    case OP_LIST2: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path) handle_list_with(conn_fd, path, op == OP_LIST ? emit_text : emit_binary);
        else send_err(conn_fd, EINVAL);
        free(path);
        break;
    }
    case OP_STAT: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path) handle_stat(conn_fd, path); else send_err(conn_fd, EINVAL);
        free(path);
        break;
    }
    case OP_READ: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path && pos + 12 <= (uint32_t)flen) {
            uint64_t offset = read_u64le(frame + pos);
            uint32_t len = read_u32le(frame + pos + 8);
            handle_read(conn_fd, path, offset, len);
        } else {
            send_err(conn_fd, EINVAL);
        }
        free(path);
        break;
    }
    case OP_WRITE: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path && pos + 12 <= (uint32_t)flen) {
            uint64_t offset = read_u64le(frame + pos);
            uint32_t datalen = read_u32le(frame + pos + 8);
            pos += 12;
            if (pos + datalen <= (uint32_t)flen) {
                handle_write(conn_fd, path, offset, frame + pos, datalen);
            } else {
                send_err(conn_fd, EINVAL);
            }
        } else {
            send_err(conn_fd, EINVAL);
        }
        free(path);
        break;
    }
    case OP_MKDIR: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path) handle_mkdir(conn_fd, path); else send_err(conn_fd, EINVAL);
        free(path);
        break;
    }
    case OP_RENAME: {
        char *src = parse_path(frame, (uint32_t)flen, &pos);
        char *dst = src ? parse_path(frame, (uint32_t)flen, &pos) : NULL;
        if (src && dst) handle_rename(conn_fd, src, dst); else send_err(conn_fd, EINVAL);
        free(src);
        free(dst);
        break;
    }
    case OP_UNLINK: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path) handle_unlink(conn_fd, path); else send_err(conn_fd, EINVAL);
        free(path);
        break;
    }
    case OP_CHMOD: {
        char *path = parse_path(frame, (uint32_t)flen, &pos);
        if (path && pos + 4 <= (uint32_t)flen) {
            handle_chmod(conn_fd, path, read_u32le(frame + pos));
        } else {
            send_err(conn_fd, EINVAL);
        }
        free(path);
        break;
    }
    default:
        send_err(conn_fd, EINVAL);
        break;
    }

    free(frame);
    close(conn_fd);
}

#ifndef FILEOPSD_NO_MAIN
int main(void) {
    signal(SIGCHLD, SIG_IGN); /* auto-reap children, no zombies, no wait() needed */

    int listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("socket"); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = FILEOPS_PORT;

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (listen(listen_fd, 16) < 0) { perror("listen"); return 1; }

    /* Fork per connection - each connection is exactly one request/
     * response with no session state, so concurrent WebDAV/Finder
     * requests just become concurrent short-lived child processes. */
    for (;;) {
        int conn_fd = accept(listen_fd, NULL, NULL);
        if (conn_fd < 0) continue;

        pid_t pid = fork();
        if (pid == 0) {
            close(listen_fd);
            handle_connection(conn_fd);
            _exit(0);
        }
        close(conn_fd);
    }

    return 0;
}
#endif
