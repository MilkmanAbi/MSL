/*
 * memd.c
 *
 * Guest-side memory reporting for MSL's dynamic memory allocation. Sibling
 * to trafficd.c and fileopsd.c, built the same way: one connection = one
 * request + one response, no session state.
 *
 * The host can see how much memory it *gave* the guest. It cannot see what
 * the guest is doing with it - whether 4 GB is a working set or 300 MB of
 * program and 3.7 GB of stale page cache. Only the guest kernel knows that,
 * and getting it wrong in the shrinking direction is not a slowdown: MSL's
 * guest images are built without swap (nothing in the provisioning path
 * creates any), so an anonymous page that will not fit has nowhere to go
 * and the kernel OOM-kills instead. Hence this daemon.
 *
 * Cost when idle is zero. There is no polling loop and no timer here - the
 * process sleeps in accept() and does arithmetic only when the host asks,
 * which the host does on a slow cadence that it widens further when nothing
 * is changing.
 *
 * Wire format - one frame per request, one frame per response:
 *   [u32 LE length][payload]
 *
 * Request payload: op u8
 *   MEMSTAT  0x01   (no fields)
 *   COMPACT  0x02   (no fields)
 *
 * Response payload: status u8 (0x00 ok, 0x01 err; if err, errno u32).
 *
 * MEMSTAT ok payload, all little-endian:
 *   u64 total_kb, u64 available_kb, u64 free_kb,
 *   u64 file_cache_kb, u64 anon_kb, u64 swap_total_kb,
 *   u8  psi_present,
 *   u32 psi_some_avg10_centipercent   (0 when psi_present == 0)
 *   u8  balloon_present,              (added 2026-09-14; older memd stops above)
 *   u64 balloon_kb                    (/proc/vmstat nr_balloon_pages, in kB)
 *
 * COMPACT ok payload: empty. Asks the kernel to compact physical memory
 * (/proc/sys/vm/compact_memory), which the Virtualization framework
 * recommends before a balloon operation so the pages being handed back are
 * contiguous enough to actually be reclaimed. It costs real CPU, so the
 * host only asks before a substantial inflate.
 *
 * swap_total_kb is reported even though it is expected to be zero, because
 * the whole safety argument above depends on that being true. If a user
 * adds swap to their guest, the host can see that it did and say so rather
 * than silently continuing to reason about a machine that no longer exists.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>

/*
 * vsock is the one Linux-only dependency, and only main() touches it. Kept
 * behind the same guard as main() so the parsers - which is where the bugs
 * live - compile and run natively on the host, with no container and no
 * guest. `tests/memd_test.c` is therefore just `cc && ./a.out` anywhere.
 */
#ifndef MEMD_NO_MAIN
#include <linux/vm_sockets.h>
#endif

#define MEM_PORT 5007

#define OP_MEMSTAT 0x01
#define OP_COMPACT 0x02

#define STATUS_OK  0x00
#define STATUS_ERR 0x01

struct meminfo {
    uint64_t total_kb;
    uint64_t available_kb;
    uint64_t free_kb;
    uint64_t file_cache_kb;   /* Active(file) + Inactive(file) */
    uint64_t anon_kb;         /* Active(anon) + Inactive(anon) */
    uint64_t swap_total_kb;
};

/*
 * Reads one "Key:   value kB" line. /proc/meminfo pads with a variable
 * number of spaces, so this cannot be a fixed-width parse.
 *
 * Returns 1 and writes *out if the line's key matches, 0 otherwise.
 */
static int match_kb(const char *line, const char *key, uint64_t *out) {
    size_t key_len = strlen(key);
    if (strncmp(line, key, key_len) != 0) return 0;
    if (line[key_len] != ':') return 0;

    const char *cursor = line + key_len + 1;
    while (*cursor == ' ' || *cursor == '\t') cursor++;
    if (*cursor < '0' || *cursor > '9') return 0;

    *out = strtoull(cursor, NULL, 10);
    return 1;
}

/*
 * Parses the whole of /proc/meminfo out of a buffer.
 *
 * Takes text rather than a path so the host-side fixture tests can feed it
 * captured /proc/meminfo from several distros without needing a guest.
 */
int memd_parse_meminfo(const char *text, struct meminfo *out) {
    memset(out, 0, sizeof(*out));
    uint64_t active_file = 0, inactive_file = 0, active_anon = 0, inactive_anon = 0;
    int saw_total = 0;

    const char *line = text;
    while (line && *line) {
        if (match_kb(line, "MemTotal", &out->total_kb)) saw_total = 1;
        else if (match_kb(line, "MemAvailable", &out->available_kb)) { }
        else if (match_kb(line, "MemFree", &out->free_kb)) { }
        else if (match_kb(line, "Active(file)", &active_file)) { }
        else if (match_kb(line, "Inactive(file)", &inactive_file)) { }
        else if (match_kb(line, "Active(anon)", &active_anon)) { }
        else if (match_kb(line, "Inactive(anon)", &inactive_anon)) { }
        else if (match_kb(line, "SwapTotal", &out->swap_total_kb)) { }

        const char *newline = strchr(line, '\n');
        line = newline ? newline + 1 : NULL;
    }

    out->file_cache_kb = active_file + inactive_file;
    out->anon_kb = active_anon + inactive_anon;

    /*
     * A kernel too old for MemAvailable (pre-3.14) reports MemFree only.
     * Falling back to it understates what is reclaimable, which makes the
     * host keep the guest larger than it strictly needs - the safe direction
     * to be wrong in.
     */
    if (out->available_kb == 0) out->available_kb = out->free_kb;

    return saw_total ? 0 : -1;
}

/*
 * Parses /proc/pressure/memory, whose "some" line looks like:
 *   some avg10=0.42 avg60=0.13 avg300=0.04 total=1234567
 *
 * Returns 1 if avg10 was found, writing hundredths of a percent to *out
 * (so 0.42% becomes 42). Integers on the wire on purpose: the value is a
 * percentage with two decimal places and nothing here needs a float.
 */
int memd_parse_pressure(const char *text, uint32_t *out) {
    const char *line = text;
    while (line && *line) {
        if (strncmp(line, "some ", 5) == 0) {
            const char *field = strstr(line, "avg10=");
            const char *newline = strchr(line, '\n');
            if (field && (!newline || field < newline)) {
                double value = strtod(field + 6, NULL);
                if (value < 0) value = 0;
                if (value > 100) value = 100;
                *out = (uint32_t)(value * 100.0 + 0.5);
                return 1;
            }
        }
        const char *newline = strchr(line, '\n');
        line = newline ? newline + 1 : NULL;
    }
    return 0;
}

/*
 * Parses /proc/vmstat's "nr_balloon_pages <n>" - pages the virtio balloon
 * currently holds. Returns 1 and writes *out if present, 0 otherwise (a
 * kernel without balloon support has no such line).
 *
 * The host needs this because Virtualization.framework's balloon negotiates
 * VIRTIO_BALLOON_F_DEFLATE_ON_OOM, and with that feature Linux leaves
 * ballooned pages *in* MemTotal: they read as used memory. Without the exact
 * figure the host saw its own reclaim as the guest's demand and flapped
 * (2026-09-14: nr_balloon_pages 393216 - 1.5 GiB - on an idle guest the host
 * then believed was using 1.7 GiB).
 */
int memd_parse_balloon_pages(const char *text, uint64_t *out) {
    const char *line = text;
    while (line && *line) {
        if (strncmp(line, "nr_balloon_pages ", 17) == 0) {
            *out = strtoull(line + 17, NULL, 10);
            return 1;
        }
        const char *newline = strchr(line, '\n');
        line = newline ? newline + 1 : NULL;
    }
    return 0;
}

/* ---------------------------------------------------------------- I/O */

/*
 * Everything below needs a real socket, so it shares main()'s guard: with
 * MEMD_NO_MAIN the file is just the two parsers, which compile anywhere.
 */
#ifndef MEMD_NO_MAIN

static int read_file(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t total = 0;
    for (;;) {
        ssize_t got = read(fd, buffer + total, size - 1 - (size_t)total);
        if (got < 0) { if (errno == EINTR) continue; close(fd); return -1; }
        if (got == 0) break;
        total += got;
        if ((size_t)total >= size - 1) break;
    }
    close(fd);
    buffer[total] = '\0';
    return 0;
}

static int write_all(int fd, const void *data, size_t length) {
    const uint8_t *bytes = data;
    size_t sent = 0;
    while (sent < length) {
        ssize_t wrote = write(fd, bytes + sent, length - sent);
        if (wrote < 0) { if (errno == EINTR) continue; return -1; }
        if (wrote == 0) return -1;
        sent += (size_t)wrote;
    }
    return 0;
}

static int read_all(int fd, void *data, size_t length) {
    uint8_t *bytes = data;
    size_t got = 0;
    while (got < length) {
        ssize_t chunk = read(fd, bytes + got, length - got);
        if (chunk < 0) { if (errno == EINTR) continue; return -1; }
        if (chunk == 0) return -1;
        got += (size_t)chunk;
    }
    return 0;
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v); p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static void put_u64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static int send_frame(int fd, const uint8_t *payload, uint32_t length) {
    uint8_t header[4];
    put_u32(header, length);
    if (write_all(fd, header, 4) < 0) return -1;
    if (length == 0) return 0;
    return write_all(fd, payload, length);
}

static int send_error(int fd, int error_number) {
    uint8_t payload[5];
    payload[0] = STATUS_ERR;
    put_u32(payload + 1, (uint32_t)error_number);
    return send_frame(fd, payload, sizeof(payload));
}

static int handle_memstat(int fd) {
    char buffer[8192];
    if (read_file("/proc/meminfo", buffer, sizeof(buffer)) < 0) return send_error(fd, errno);

    struct meminfo info;
    if (memd_parse_meminfo(buffer, &info) < 0) return send_error(fd, EINVAL);

    uint32_t stall = 0;
    uint8_t stall_present = 0;
    /*
     * Absent unless the guest kernel has CONFIG_PSI and it is enabled. Not
     * an error - the host's controller is correct without it and merely
     * slower to notice a guest in trouble.
     */
    if (read_file("/proc/pressure/memory", buffer, sizeof(buffer)) == 0) {
        if (memd_parse_pressure(buffer, &stall)) stall_present = 1;
    }

    /*
     * Appended after the original fields, so a host that predates it reads
     * exactly the bytes it always did. Pages are 4 KiB on MSL's arm64 kernel;
     * sysconf answers for whatever this one actually uses.
     */
    uint64_t balloon_pages = 0;
    uint8_t balloon_present = 0;
    if (read_file("/proc/vmstat", buffer, sizeof(buffer)) == 0) {
        if (memd_parse_balloon_pages(buffer, &balloon_pages)) balloon_present = 1;
    }
    long page_kb = sysconf(_SC_PAGESIZE) / 1024;
    if (page_kb <= 0) page_kb = 4;

    uint8_t payload[1 + 6 * 8 + 1 + 4 + 1 + 8];
    size_t at = 0;
    payload[at++] = STATUS_OK;
    put_u64(payload + at, info.total_kb);       at += 8;
    put_u64(payload + at, info.available_kb);   at += 8;
    put_u64(payload + at, info.free_kb);        at += 8;
    put_u64(payload + at, info.file_cache_kb);  at += 8;
    put_u64(payload + at, info.anon_kb);        at += 8;
    put_u64(payload + at, info.swap_total_kb);  at += 8;
    payload[at++] = stall_present;
    put_u32(payload + at, stall);               at += 4;
    payload[at++] = balloon_present;
    put_u64(payload + at, balloon_pages * (uint64_t)page_kb); at += 8;

    return send_frame(fd, payload, (uint32_t)at);
}

static int handle_compact(int fd) {
    int sysctl_fd = open("/proc/sys/vm/compact_memory", O_WRONLY);
    if (sysctl_fd < 0) return send_error(fd, errno);
    ssize_t wrote = write(sysctl_fd, "1\n", 2);
    int saved = errno;
    close(sysctl_fd);
    if (wrote < 0) return send_error(fd, saved);

    uint8_t status = STATUS_OK;
    return send_frame(fd, &status, 1);
}

static void handle_connection(int fd) {
    uint8_t header[4];
    if (read_all(fd, header, 4) < 0) return;
    uint32_t length = (uint32_t)header[0] | ((uint32_t)header[1] << 8)
                    | ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 24);
    if (length < 1 || length > 64) return;

    uint8_t request[64];
    if (read_all(fd, request, length) < 0) return;

    switch (request[0]) {
    case OP_MEMSTAT: handle_memstat(fd); break;
    case OP_COMPACT: handle_compact(fd); break;
    default:         send_error(fd, EINVAL); break;
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) { perror("memd: socket"); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = MEM_PORT;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("memd: bind"); close(listener); return 1;
    }
    if (listen(listener, 8) < 0) {
        perror("memd: listen"); close(listener); return 1;
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
#endif
