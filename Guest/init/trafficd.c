/*
 * trafficd.c
 *
 * Guest-side network visibility for MSL's Traffic Monitor. Sibling to
 * fileopsd.c and built the same way: one connection = one request + one
 * response, no session state.
 *
 * This is the half of the monitor the host cannot see. `mslhd` observes
 * MSL's own traffic (control commands, the file bridge, X11) because all of
 * that crosses the host. What the guest itself opens to the internet lives
 * entirely inside the VM's network stack, so answering "what is this Linux
 * box actually talking to" has to happen in here.
 *
 * Everything comes from /proc; nothing is captured off the wire. That is a
 * deliberate limit worth stating plainly: this reports *sockets*, not
 * packets. It will show you a connection to 1.1.1.1:443 and which process
 * owns it; it will not show you what was sent.
 *
 * Wire format - one frame per request, one frame per response, matching
 * fileopsd exactly:
 *   [u32 LE length][payload]
 *
 * Request payload: op u8, then op-specific fields:
 *   SOCKETS  0x01  flags u8   (bit 0: attribute sockets to processes)
 *   IFSTATS  0x02  (no fields)
 *
 * Response payload: status u8 (0x00 ok, 0x01 err; if err, errno u32).
 *
 * SOCKETS ok payload: count u32, then `count` records:
 *   family u8 (4|6), proto u8 (6 tcp|17 udp), state u8,
 *   local  16 bytes, lport u16,
 *   remote 16 bytes, rport u16,
 *   inode u32, uid u32,
 *   namelen u16, name (process name, empty when unattributed)
 *
 * IFSTATS ok payload: count u32, then `count` records:
 *   namelen u16, name, rx_bytes u64, rx_packets u64, tx_bytes u64,
 *   tx_packets u64
 *
 * LENGTH-PREFIXED, NOT DELIMITED - on purpose. fileopsd's LIST uses
 * "name\tsize\n" text and a filename containing a tab corrupts every entry
 * after it; that is a real bug with a real fix pending (LIST2, see
 * IMAGE-REBUILD-SG.md). A process name is arbitrary bytes from /proc/comm
 * and can contain anything, so this protocol does not repeat the mistake.
 *
 * Addresses in /proc/net/tcp are hex words in HOST byte order, which on
 * every platform MSL runs on is little-endian - so 0100007F is 127.0.0.1,
 * not 1.0.0.127. Ports in the same lines are big-endian hex. Getting
 * exactly this backwards is the classic bug here, hence the host-side
 * fixture tests.
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
#include <ctype.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>

#define TRAFFIC_PORT 5006
#define MAX_FRAME (8 * 1024 * 1024)
/* A guest with more sockets than this is not something a UI list can
 * usefully show, and the cap keeps one response bounded. */
#define MAX_SOCKETS 4096
#define MAX_IFACES 64

enum {
    OP_SOCKETS = 0x01,
    OP_IFSTATS = 0x02,
};

/* ---------------------------------------------------------------- io */

static int read_full(int fd, void *buf, size_t n) {
    unsigned char *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
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
static void write_u16le(unsigned char *p, uint16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }
static void write_u32le(unsigned char *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}
static void write_u64le(unsigned char *p, uint64_t v) {
    write_u32le(p, (uint32_t)(v & 0xFFFFFFFFu));
    write_u32le(p + 4, (uint32_t)(v >> 32));
}

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

/* ------------------------------------------------------------ sockets */

struct sock_row {
    unsigned char family;   /* 4 or 6 */
    unsigned char proto;    /* 6 tcp, 17 udp */
    unsigned char state;    /* /proc's st field, verbatim */
    unsigned char local[16];
    unsigned char remote[16];
    uint16_t lport, rport;
    uint32_t inode;
    uint32_t uid;
    char name[64];
};

/* Parses one hex address word group. /proc writes IPv4 as 8 hex chars and
 * IPv6 as 32, in host byte order per 4-byte word - so each group of 8 hex
 * chars is one little-endian u32 and its bytes come out reversed. */
static int parse_hex_addr(const char *hex, size_t hexlen, unsigned char *out16) {
    memset(out16, 0, 16);
    if (hexlen != 8 && hexlen != 32) return -1;
    size_t words = hexlen / 8;
    for (size_t w = 0; w < words; w++) {
        uint32_t value = 0;
        for (size_t i = 0; i < 8; i++) {
            char c = hex[w * 8 + i];
            int digit;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            else return -1;
            value = (value << 4) | (uint32_t)digit;
        }
        /* Host order: least significant byte is the first address byte. */
        out16[w * 4 + 0] = (unsigned char)(value & 0xFF);
        out16[w * 4 + 1] = (unsigned char)((value >> 8) & 0xFF);
        out16[w * 4 + 2] = (unsigned char)((value >> 16) & 0xFF);
        out16[w * 4 + 3] = (unsigned char)((value >> 24) & 0xFF);
    }
    return 0;
}

/* "0100007F:1F90" -> address + port. Ports are big-endian hex, unlike the
 * address words. */
static int parse_endpoint(const char *token, unsigned char *addr16, uint16_t *port, unsigned char *family) {
    const char *colon = strchr(token, ':');
    if (!colon) return -1;
    size_t hexlen = (size_t)(colon - token);
    if (parse_hex_addr(token, hexlen, addr16) < 0) return -1;
    *family = (hexlen == 8) ? 4 : 6;
    unsigned int p = 0;
    if (sscanf(colon + 1, "%4x", &p) != 1) return -1;
    *port = (uint16_t)p;
    return 0;
}

/* Reads one /proc/net/{tcp,tcp6,udp,udp6} table. A line that does not parse
 * is skipped and counted, never fatal: these tables are fixed-width-ish
 * text whose exact columns have shifted between kernel versions, and one
 * odd row must not hide the whole table (the same failure that once drew a
 * full guest directory as empty in Finder). */
static int read_sock_table(const char *path, unsigned char proto,
                           struct sock_row *rows, int max, int *count, int *skipped) {
    FILE *f = fopen(path, "r");
    if (!f) return -1; /* e.g. no IPv6 in this kernel - caller carries on */
    char line[512];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; } /* header */
    while (fgets(line, sizeof(line), f)) {
        if (*count >= max) break;
        char local[64], remote[64];
        unsigned int slot, st;
        unsigned long txq, rxq, uid = 0, inode = 0;
        /* sl local rem st tx:rx tr:when retrnsmt uid timeout inode */
        int n = sscanf(line, "%u: %63s %63s %x %lx:%lx %*x:%*x %*x %lu %*u %lu",
                       &slot, local, remote, &st, &txq, &rxq, &uid, &inode);
        if (n < 8) { (*skipped)++; continue; }

        struct sock_row *row = &rows[*count];
        memset(row, 0, sizeof(*row));
        unsigned char lfam = 0, rfam = 0;
        if (parse_endpoint(local, row->local, &row->lport, &lfam) < 0) { (*skipped)++; continue; }
        if (parse_endpoint(remote, row->remote, &row->rport, &rfam) < 0) { (*skipped)++; continue; }
        row->family = lfam;
        row->proto = proto;
        row->state = (unsigned char)st;
        row->inode = (uint32_t)inode;
        row->uid = (uint32_t)uid;
        (*count)++;
    }
    fclose(f);
    return 0;
}

/* Maps socket inodes to process names by walking /proc/<pid>/fd and reading
 * the "socket:[12345]" symlink targets.
 *
 * DELIBERATELY OPTIONAL. This is every fd of every process - hundreds of
 * readlink() calls on a busy guest - so the host asks for it only when a
 * view that shows process names is actually open, and never on a poll that
 * just wants counts. */
static void attribute_processes(struct sock_row *rows, int count) {
    DIR *proc = opendir("/proc");
    if (!proc) return;
    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        if (!isdigit((unsigned char)entry->d_name[0])) continue;

        char fdpath[512];
        int written = snprintf(fdpath, sizeof(fdpath), "/proc/%s/fd", entry->d_name);
        if (written < 0 || (size_t)written >= sizeof(fdpath)) continue;
        DIR *fds = opendir(fdpath);
        if (!fds) continue; /* the process exited, or is not ours to read */

        char comm[64] = {0};
        char commpath[512];
        written = snprintf(commpath, sizeof(commpath), "/proc/%s/comm", entry->d_name);
        if (written > 0 && (size_t)written < sizeof(commpath)) {
            FILE *cf = fopen(commpath, "r");
            if (cf) {
                if (fgets(comm, sizeof(comm), cf)) {
                    size_t len = strlen(comm);
                    while (len > 0 && (comm[len - 1] == '\n' || comm[len - 1] == '\r')) comm[--len] = 0;
                }
                fclose(cf);
            }
        }

        struct dirent *fd_entry;
        while ((fd_entry = readdir(fds)) != NULL) {
            if (fd_entry->d_name[0] == '.') continue;
            char linkpath[1024], target[128];
            written = snprintf(linkpath, sizeof(linkpath), "%s/%s", fdpath, fd_entry->d_name);
            if (written < 0 || (size_t)written >= sizeof(linkpath)) continue;
            ssize_t got = readlink(linkpath, target, sizeof(target) - 1);
            if (got <= 0) continue;
            target[got] = 0;
            unsigned long inode = 0;
            if (sscanf(target, "socket:[%lu]", &inode) != 1) continue;
            for (int i = 0; i < count; i++) {
                if (rows[i].inode == (uint32_t)inode && rows[i].name[0] == 0) {
                    snprintf(rows[i].name, sizeof(rows[i].name), "%s", comm);
                }
            }
        }
        closedir(fds);
    }
    closedir(proc);
}

static void handle_sockets(int fd, unsigned char flags) {
    struct sock_row *rows = calloc(MAX_SOCKETS, sizeof(struct sock_row));
    if (!rows) { send_err(fd, ENOMEM); return; }
    int count = 0, skipped = 0;

    /* A missing table is normal (a kernel with no IPv6), not an error. */
    read_sock_table("/proc/net/tcp",  6,  rows, MAX_SOCKETS, &count, &skipped);
    read_sock_table("/proc/net/tcp6", 6,  rows, MAX_SOCKETS, &count, &skipped);
    read_sock_table("/proc/net/udp",  17, rows, MAX_SOCKETS, &count, &skipped);
    read_sock_table("/proc/net/udp6", 17, rows, MAX_SOCKETS, &count, &skipped);

    if (flags & 0x01) attribute_processes(rows, count);

    size_t cap = 4 + (size_t)count * (1 + 1 + 1 + 16 + 2 + 16 + 2 + 4 + 4 + 2 + 64);
    unsigned char *out = malloc(cap);
    if (!out) { free(rows); send_err(fd, ENOMEM); return; }
    size_t at = 0;
    write_u32le(out + at, (uint32_t)count); at += 4;
    for (int i = 0; i < count; i++) {
        struct sock_row *row = &rows[i];
        out[at++] = row->family;
        out[at++] = row->proto;
        out[at++] = row->state;
        memcpy(out + at, row->local, 16);  at += 16;
        write_u16le(out + at, row->lport); at += 2;
        memcpy(out + at, row->remote, 16); at += 16;
        write_u16le(out + at, row->rport); at += 2;
        write_u32le(out + at, row->inode); at += 4;
        write_u32le(out + at, row->uid);   at += 4;
        size_t namelen = strlen(row->name);
        write_u16le(out + at, (uint16_t)namelen); at += 2;
        memcpy(out + at, row->name, namelen); at += namelen;
    }
    send_ok(fd, out, (uint32_t)at);
    free(out);
    free(rows);
}

/* --------------------------------------------------------- interfaces */

static void handle_ifstats(int fd) {
    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) { send_err(fd, errno); return; }
    char line[512];
    /* Two header lines. */
    if (!fgets(line, sizeof(line), f) || !fgets(line, sizeof(line), f)) { fclose(f); send_err(fd, EIO); return; }

    unsigned char *out = malloc(4 + (size_t)MAX_IFACES * (2 + 32 + 8 * 4));
    if (!out) { fclose(f); send_err(fd, ENOMEM); return; }
    size_t at = 4;
    uint32_t count = 0;

    while (fgets(line, sizeof(line), f) && count < MAX_IFACES) {
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = 0;
        char *name = line;
        while (*name == ' ' || *name == '\t') name++;
        unsigned long long rx_bytes = 0, rx_packets = 0, tx_bytes = 0, tx_packets = 0;
        /* rx: bytes packets errs drop fifo frame compressed multicast
         * tx: bytes packets ... - the two counters we want are the 1st/2nd
         * of each group, with six ignored fields between them. */
        if (sscanf(colon + 1, "%llu %llu %*u %*u %*u %*u %*u %*u %llu %llu",
                   &rx_bytes, &rx_packets, &tx_bytes, &tx_packets) != 4) continue;

        size_t namelen = strlen(name);
        if (namelen > 32) namelen = 32;
        write_u16le(out + at, (uint16_t)namelen); at += 2;
        memcpy(out + at, name, namelen); at += namelen;
        write_u64le(out + at, rx_bytes);   at += 8;
        write_u64le(out + at, rx_packets); at += 8;
        write_u64le(out + at, tx_bytes);   at += 8;
        write_u64le(out + at, tx_packets); at += 8;
        count++;
    }
    fclose(f);
    write_u32le(out, count);
    send_ok(fd, out, (uint32_t)at);
    free(out);
}

/* --------------------------------------------------------------- main */

/* `main` is compiled out when this file is #included by its test harness
 * (Guest/init/tests/trafficd_test.c), which exercises the /proc parsers
 * against fixture files. The parsers are static, so testing them means
 * including the translation unit rather than linking against it. */
#ifndef TRAFFICD_NO_MAIN

static void handle_connection(int fd) {
    unsigned char *req = NULL;
    long len = read_frame(fd, &req);
    if (len < 1) { free(req); return; }

    switch (req[0]) {
    case OP_SOCKETS:
        handle_sockets(fd, len >= 2 ? req[1] : 0);
        break;
    case OP_IFSTATS:
        handle_ifstats(fd);
        break;
    default:
        /* Same contract as fileopsd: an unknown opcode is a clean EINVAL,
         * which is what lets a newer host probe for features against an
         * older guest without breaking either. */
        send_err(fd, EINVAL);
        break;
    }
    free(req);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) { perror("trafficd: socket"); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = TRAFFIC_PORT;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("trafficd: bind"); close(listener); return 1;
    }
    if (listen(listener, 8) < 0) {
        perror("trafficd: listen"); close(listener); return 1;
    }

    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) { if (errno == EINTR) continue; break; }
        handle_connection(fd);
        close(fd);
    }
    close(listener);
    return 0;
}
#endif /* TRAFFICD_NO_MAIN */
