/*
 * Tests for fileopsd's request handling, driven through the real
 * handle_connection() over a Unix socketpair - the same frames the host
 * sends over vsock, with no VM involved.
 *
 * Covers the listing rules that only show up with awkward filenames (tabs,
 * newlines, dangling symlinks), the LIST2 and CHMOD opcodes, the lazy
 * cleanup of abandoned upload temps, and the EINVAL answer to an unknown
 * opcode that the host's capability probing depends on.
 *
 * Build and run (inside any Linux container - no VM needed):
 *   cc -O2 -Wall -Wextra -o fileopsd_test fileopsd_test.c && ./fileopsd_test
 */

#define FILEOPSD_NO_MAIN
#include "../fileopsd.c"

#include <sys/time.h>

static int failures = 0;

static void check(int condition, const char *what) {
    printf("  %s %s\n", condition ? "ok  " : "FAIL", what);
    if (!condition) failures++;
}

/* Sends one request frame and returns the response payload (status byte
 * first) in a malloc'd buffer, with its length in *len. */
static unsigned char *roundtrip(const unsigned char *req, uint32_t reqlen, uint32_t *len) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); exit(2); }
    unsigned char lenbuf[4];
    write_u32le(lenbuf, reqlen);
    if (write_full(sv[0], lenbuf, 4) != 0 || write_full(sv[0], req, reqlen) != 0) { perror("write"); exit(2); }
    handle_connection(sv[1]); /* reads the request, writes the response, closes sv[1] */
    unsigned char *resp = NULL;
    long n = read_frame(sv[0], &resp);
    close(sv[0]);
    if (n < 1) { printf("  FAIL no response frame\n"); failures++; *len = 0; return NULL; }
    *len = (uint32_t)n;
    return resp;
}

static uint32_t path_request(unsigned char *buf, uint8_t op, const char *path) {
    size_t plen = strlen(path);
    buf[0] = op;
    write_u16le(buf + 1, (uint16_t)plen);
    memcpy(buf + 3, path, plen);
    return (uint32_t)(3 + plen);
}

/* Writes `src` in `parent` (so it exists and has the parent's owner), then
 * RENAMEs it over `dst` in the same directory. */
static void rename_over(unsigned char *req, const char *parent, const char *src, const char *dst,
                        uint32_t *len, unsigned char **resp) {
    char sp[8608], dp[8608];
    snprintf(sp, sizeof(sp), "%s/%s", parent, src);
    snprintf(dp, sizeof(dp), "%s/%s", parent, dst);

    uint32_t n = path_request(req, OP_WRITE, sp);
    write_u64le(req + n, 0);
    write_u32le(req + n + 8, 2);
    memcpy(req + n + 12, "hi", 2);
    free(roundtrip(req, n + 14, len));

    n = path_request(req, OP_RENAME, sp);
    size_t dlen = strlen(dp);
    write_u16le(req + n, (uint16_t)dlen);
    memcpy(req + n + 2, dp, dlen);
    *resp = roundtrip(req, n + (uint32_t)(2 + dlen), len);
}

static int response_errno(const unsigned char *resp, uint32_t len) {
    return (len == 5 && resp[0] == 0x01) ? (int)read_u32le(resp + 1) : -1;
}

static void touch_with_age(const char *path, const char *contents, long age_seconds) {
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    fputs(contents, f);
    fclose(f);
    if (age_seconds > 0) {
        struct timeval tv[2];
        gettimeofday(&tv[0], NULL);
        tv[0].tv_sec -= age_seconds;
        tv[1] = tv[0];
        utimes(path, tv);
    }
}

/* Does a LIST2 payload contain an entry called `name`? Fills *mode. */
static int list2_has(const unsigned char *payload, uint32_t len, const char *name, uint32_t *mode, uint64_t *size) {
    uint32_t pos = 0;
    size_t want = strlen(name);
    while (pos + 2 <= len) {
        uint16_t nlen = read_u16le(payload + pos);
        if (pos + 2 + nlen + 20 > len) return -1; /* malformed */
        const unsigned char *n = payload + pos + 2;
        if (nlen == want && memcmp(n, name, want) == 0) {
            if (size) *size = read_u64le(n + nlen);
            if (mode) *mode = read_u32le(n + nlen + 16);
            return 1;
        }
        pos += 2 + nlen + 20;
    }
    return pos == len ? 0 : -1;
}

int main(void) {
    char dir[] = "/tmp/fileopsd-test-XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    char p[4096];

    #define AT(name) (snprintf(p, sizeof(p), "%s/%s", dir, name), p)
    /* Its own buffer, so a path built here can be held across a call that
     * builds another one. */
    char q[8608]; /* holds a 4200-byte parent plus a name, without truncation */
    #define PATH_IN(parent, name) (snprintf(q, sizeof(q), "%s/%s", parent, name), q)
    touch_with_age(AT("plain.txt"), "hello", 0);
    touch_with_age(AT("tab\tname"), "x", 0);
    touch_with_age(AT("new\nline"), "x", 0);
    symlink("/nonexistent/target", AT("dangling"));
    mkdir(AT("sub"), 0755);
    touch_with_age(AT(".msl-put-0000-stale.tmp"), "partial upload", 2 * 3600);
    touch_with_age(AT(".msl-put-1111-fresh.tmp"), "upload in progress", 0);
    touch_with_age(AT("user-file.tmp"), "not ours", 2 * 3600);

    unsigned char req[8192];
    uint32_t len;
    unsigned char *resp;

    printf("LIST (text)\n");
    resp = roundtrip(req, path_request(req, OP_LIST, dir), &len);
    check(resp && resp[0] == 0x00, "succeeds");
    if (resp) {
        char *text = strndup((char *)resp + 1, len - 1);
        check(strstr(text, "plain.txt\t5\t") != NULL, "plain file listed with its size");
        check(strstr(text, "dangling\t") != NULL, "dangling symlink listed (lstat, not stat)");
        check(strstr(text, "tab\tname") == NULL && strstr(text, "new\nline") == NULL,
              "names with tab/newline skipped rather than corrupting the listing");
        check(strstr(text, "sub\t") != NULL, "subdirectory listed");
        check(strstr(text, ".msl-put-0000-stale.tmp") == NULL, "stale upload temp not listed");
        check(strstr(text, ".msl-put-1111-fresh.tmp") != NULL, "fresh upload temp still listed");
        free(text);
        free(resp);
    }

    printf("stale upload temps\n");
    struct stat st;
    check(lstat(AT(".msl-put-0000-stale.tmp"), &st) != 0 && errno == ENOENT, "an hour-old .msl-put-*.tmp is removed by listing");
    check(lstat(AT(".msl-put-1111-fresh.tmp"), &st) == 0, "a fresh one is left alone - an upload may be writing it");
    check(lstat(AT("user-file.tmp"), &st) == 0, "an old .tmp that isn't MSL's is left alone");

    printf("LIST2 (binary)\n");
    resp = roundtrip(req, path_request(req, OP_LIST2, dir), &len);
    check(resp && resp[0] == 0x00, "succeeds");
    if (resp) {
        uint32_t mode = 0;
        uint64_t size = 0;
        check(list2_has(resp + 1, len - 1, "plain.txt", &mode, &size) == 1 && size == 5 && S_ISREG(mode),
              "plain file with size and regular-file mode");
        check(list2_has(resp + 1, len - 1, "tab\tname", NULL, NULL) == 1, "name containing a tab round-trips");
        check(list2_has(resp + 1, len - 1, "new\nline", NULL, NULL) == 1, "name containing a newline round-trips");
        check(list2_has(resp + 1, len - 1, "dangling", &mode, NULL) == 1 && S_ISLNK(mode), "dangling symlink listed as a link");
        check(list2_has(resp + 1, len - 1, "sub", &mode, NULL) == 1 && S_ISDIR(mode), "subdirectory has directory mode");
        check(list2_has(resp + 1, len - 1, "no-such-entry", NULL, NULL) == 0, "payload parses to its end with no stray bytes");
        free(resp);
    }
    resp = roundtrip(req, path_request(req, OP_LIST2, AT("missing-dir")), &len);
    check(resp && response_errno(resp, len) == ENOENT, "LIST2 of a missing directory answers ENOENT");
    free(resp);

    printf("CHMOD\n");
    chmod(AT("plain.txt"), 0644);
    uint32_t n = path_request(req, OP_CHMOD, AT("plain.txt"));
    write_u32le(req + n, 0100755); /* a STAT'd mode, file-type bits included */
    resp = roundtrip(req, n + 4, &len);
    check(resp && len == 1 && resp[0] == 0x00, "succeeds with an empty ok");
    free(resp);
    check(stat(AT("plain.txt"), &st) == 0 && (st.st_mode & 07777) == 0755, "mode applied, file-type bits ignored");

    n = path_request(req, OP_CHMOD, AT("missing-file"));
    write_u32le(req + n, 0644);
    resp = roundtrip(req, n + 4, &len);
    check(resp && response_errno(resp, len) == ENOENT, "missing file answers ENOENT");
    free(resp);

    n = path_request(req, OP_CHMOD, AT("plain.txt"));
    resp = roundtrip(req, n + 2, &len); /* mode field truncated */
    check(resp && response_errno(resp, len) == EINVAL, "truncated mode field answers EINVAL");
    free(resp);

    /* Ownership. The daemon runs as root in a real guest, so everything it
     * created used to belong to root - including files it put in someone's
     * home directory, which they could then neither edit nor delete. The
     * chowns are best effort, so unprivileged the only thing to assert is
     * that nothing breaks; run this as root to check the rule itself. */
    printf("ownership\n");
    {
        int privileged = geteuid() == 0;
        char owned[4200];
        snprintf(owned, sizeof(owned), "%s/owned", dir);
        check(mkdir(owned, 0755) == 0, "a parent directory to inherit from");
        if (privileged) check(chown(owned, 1001, 1001) == 0, "parent given a non-root owner");

        n = path_request(req, OP_WRITE, PATH_IN(owned, "new.txt"));
        write_u64le(req + n, 0);
        write_u32le(req + n + 8, 3);
        memcpy(req + n + 12, "abc", 3);
        resp = roundtrip(req, n + 15, &len);
        check(resp && len == 1 && resp[0] == 0x00, "WRITE creates a file");
        free(resp);
        check(stat(PATH_IN(owned, "new.txt"), &st) == 0 && st.st_size == 3, "with its contents");
        if (privileged) check(st.st_uid == 1001 && st.st_gid == 1001, "a new file takes its parent's owner");

        resp = roundtrip(req, path_request(req, OP_MKDIR, PATH_IN(owned, "sub2")), &len);
        check(resp && len == 1 && resp[0] == 0x00, "MKDIR succeeds");
        check(stat(PATH_IN(owned, "sub2"), &st) == 0, "directory created");
        if (privileged) check(st.st_uid == 1001 && st.st_gid == 1001, "a new directory takes its parent's owner");
        free(resp);

        /* An overwrite arrives as a temp file plus a rename, and the rename
         * replaces the inode - so without care the file would silently
         * change hands on every save. */
        if (privileged) {
            check(chown(PATH_IN(owned, "new.txt"), 1002, 1002) == 0, "existing file given a different owner");
            /* An upload temp: the host's own overwrite, which must leave the
             * saved file belonging to whoever owned it before. */
            rename_over(req, owned, PUT_TEMP_PREFIX "abc" PUT_TEMP_SUFFIX, "new.txt", &len, &resp);
            check(resp && len == 1 && resp[0] == 0x00, "RENAME over an existing file succeeds");
            free(resp);
            check(stat(PATH_IN(owned, "new.txt"), &st) == 0 && st.st_uid == 1002 && st.st_gid == 1002,
                  "an upload overwrite keeps the original file's owner");

            /* A rename the person asked for is a real `mv`, and `mv` keeps
             * the MOVED file's owner, not the replaced one's. */
            rename_over(req, owned, "moved.txt", "new.txt", &len, &resp);
            check(resp && len == 1 && resp[0] == 0x00, "a plain RENAME succeeds");
            free(resp);
            check(stat(PATH_IN(owned, "new.txt"), &st) == 0 && st.st_uid == 1001 && st.st_gid == 1001,
                  "a plain move keeps the moved file's owner, not the replaced one's");
        } else {
            printf("  (skipped the root-only ownership checks)\n");
        }
    }

    printf("capability probing\n");
    req[0] = 0x7F;
    resp = roundtrip(req, 1, &len);
    check(resp && response_errno(resp, len) == EINVAL, "an unknown opcode answers EINVAL");
    free(resp);

    printf("existing opcodes still behave\n");
    resp = roundtrip(req, path_request(req, OP_STAT, AT("plain.txt")), &len);
    check(resp && len == 21 && resp[0] == 0x00 && read_u64le(resp + 1) == 5, "STAT returns size");
    free(resp);

    char cmd[4200];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    if (system(cmd) != 0) printf("  (could not remove %s)\n", dir);

    printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
