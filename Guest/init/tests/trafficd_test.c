/*
 * Fixture tests for trafficd's /proc parsers.
 *
 * These exist because the parsing is where the bugs are, and none of it can
 * be exercised from the host: /proc/net/tcp is fixed-width-ish text whose
 * columns have shifted between kernel versions, and its hex addresses are
 * in host byte order per 4-byte word while the ports beside them are
 * big-endian. Reading 0100007F as 1.0.0.127 instead of 127.0.0.1 is the
 * classic mistake and looks entirely plausible in a UI.
 *
 * Build and run (inside any Linux container - no VM needed):
 *   cc -O2 -Wall -Wextra -o trafficd_test trafficd_test.c && ./trafficd_test
 */

#define TRAFFICD_NO_MAIN
#include "../trafficd.c"

static int failures = 0;

static void check(int condition, const char *what) {
    if (condition) {
        printf("  ok   %s\n", what);
    } else {
        printf("  FAIL %s\n", what);
        failures++;
    }
}

static void check_addr(const unsigned char *addr, int a, int b, int c, int d, const char *what) {
    check(addr[0] == a && addr[1] == b && addr[2] == c && addr[3] == d, what);
    if (!(addr[0] == a && addr[1] == b && addr[2] == c && addr[3] == d)) {
        printf("       got %u.%u.%u.%u, wanted %d.%d.%d.%d\n",
               addr[0], addr[1], addr[2], addr[3], a, b, c, d);
    }
}

static void write_fixture(const char *path, const char *contents) {
    FILE *f = fopen(path, "w");
    if (!f) { printf("  FAIL could not write fixture %s\n", path); failures++; return; }
    fputs(contents, f);
    fclose(f);
}

int main(void) {
    printf("address parsing (host byte order per word)\n");
    unsigned char addr[16];
    uint16_t port;
    unsigned char family;

    /* 0100007F is 127.0.0.1, NOT 1.0.0.127. */
    check(parse_endpoint("0100007F:0016", addr, &port, &family) == 0, "loopback endpoint parses");
    check_addr(addr, 127, 0, 0, 1, "0100007F is 127.0.0.1");
    check(port == 22, "port 0016 is 22 (big-endian hex)");
    check(family == 4, "8 hex chars means IPv4");

    check(parse_endpoint("0101A8C0:1F90", addr, &port, &family) == 0, "LAN endpoint parses");
    check_addr(addr, 192, 168, 1, 1, "0101A8C0 is 192.168.1.1");
    check(port == 8080, "port 1F90 is 8080");

    check(parse_endpoint("00000000:0000", addr, &port, &family) == 0, "wildcard endpoint parses");
    check_addr(addr, 0, 0, 0, 0, "all zeroes is 0.0.0.0");
    check(port == 0, "port 0000 is 0");

    printf("IPv6\n");
    /* ::1 - 32 hex chars, last word 01000000 in host order. */
    check(parse_endpoint("00000000000000000000000001000000:0050", addr, &port, &family) == 0,
          "IPv6 loopback parses");
    check(family == 6, "32 hex chars means IPv6");
    check(addr[15] == 1, "::1 has its 1 in the last byte");
    check(port == 80, "IPv6 port parses too");

    printf("malformed input is refused, not guessed at\n");
    check(parse_endpoint("0100007F", addr, &port, &family) < 0, "no colon is rejected");
    check(parse_endpoint("XYZ:0016", addr, &port, &family) < 0, "non-hex is rejected");
    check(parse_endpoint("010:0016", addr, &port, &family) < 0, "wrong-length address is rejected");

    printf("table parsing\n");
    /* A real Linux 6.x /proc/net/tcp, plus one truncated row in the middle. */
    write_fixture("/tmp/fixture_tcp",
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000 100 0 0 10 0\n"
        "   1: 0101A8C0:1F90 0201A8C0:D431 01 00000000:00000000 00:00000000 00000000  1000        0 67890 1 0000 100 0 0 10 0\n"
        "   2: this line is truncated\n"
        "   3: 0100007F:1388 0100007F:C350 06 00000000:00000000 00:00000000 00000000     0        0 24680 1 0000 100 0 0 10 0\n");

    struct sock_row rows[16];
    int count = 0, skipped = 0;
    check(read_sock_table("/tmp/fixture_tcp", 6, rows, 16, &count, &skipped) == 0, "table reads");
    check(count == 3, "three good rows parsed");
    check(skipped == 1, "the truncated row is skipped and counted, not fatal");
    check_addr(rows[0].local, 127, 0, 0, 1, "row 0 local is 127.0.0.1");
    check(rows[0].lport == 22, "row 0 is listening on 22");
    check(rows[0].state == 0x0A, "row 0 state is LISTEN (0x0A)");
    check(rows[1].uid == 1000, "row 1 uid parsed");
    check(rows[1].inode == 67890, "row 1 inode parsed");
    check(rows[1].rport == 54321, "row 1 remote port D431 is 54321");
    check(rows[2].state == 0x06, "row 3 state is TIME_WAIT (0x06)");
    check(rows[0].proto == 6, "protocol is recorded as passed in");

    printf("a row after a bad one still parses (no whole-table loss)\n");
    check(rows[2].lport == 5000, "the row after the truncated one is intact");

    printf("missing table is not an error\n");
    count = 0; skipped = 0;
    check(read_sock_table("/tmp/definitely_not_here", 6, rows, 16, &count, &skipped) < 0,
          "a missing file reports failure to the caller");
    check(count == 0, "and adds no rows");

    printf("table cap is respected\n");
    write_fixture("/tmp/fixture_big",
        "  sl  local_address rem_address   st\n"
        "   0: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 1 1 0000 100 0 0 10 0\n"
        "   1: 0100007F:0017 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 2 1 0000 100 0 0 10 0\n"
        "   2: 0100007F:0018 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 3 1 0000 100 0 0 10 0\n");
    count = 0; skipped = 0;
    read_sock_table("/tmp/fixture_big", 6, rows, 2, &count, &skipped);
    check(count == 2, "stops at the caller's maximum");

    printf("\n%s\n", failures == 0 ? "ALL TRAFFICD PARSER TESTS PASSED" : "SOME TESTS FAILED");
    return failures == 0 ? 0 : 1;
}
