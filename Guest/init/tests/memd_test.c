/*
 * Fixture tests for memd's /proc parsers.
 *
 * The parsing is where the bugs are, and none of it can be exercised from
 * the host. /proc/meminfo's fields are padded to no fixed width, several
 * of the ones that matter have to be summed rather than read (there is no
 * single "page cache" line - it is Active(file) + Inactive(file)), and a
 * couple of the keys are prefixes of each other: "MemTotal" is not
 * "MemTotalSomethingElse", and "Active(anon)" must never match "Active".
 * Getting any of that wrong produces a number that looks plausible and
 * quietly mis-sizes the guest.
 *
 * Build and run (inside any Linux container - no VM needed):
 *   cc -O2 -Wall -Wextra -o memd_test memd_test.c && ./memd_test
 */

#define MEMD_NO_MAIN
#include "../memd.c"

static int failures = 0;

static void check(int condition, const char *what) {
    if (condition) {
        printf("  ok   %s\n", what);
    } else {
        printf("  FAIL %s\n", what);
        failures++;
    }
}

static void check_u64(uint64_t got, uint64_t want, const char *what) {
    if (got == want) {
        printf("  ok   %s\n", what);
    } else {
        printf("  FAIL %s (got %llu, want %llu)\n", what,
               (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

/* A real /proc/meminfo, trimmed to the lines that matter plus enough
 * neighbours to catch a prefix match going wrong. */
static const char *DEBIAN_MEMINFO =
    "MemTotal:        4014520 kB\n"
    "MemFree:          182364 kB\n"
    "MemAvailable:    2938120 kB\n"
    "Buffers:           41232 kB\n"
    "Cached:          2610044 kB\n"
    "SwapCached:            0 kB\n"
    "Active:          1502180 kB\n"
    "Inactive:        1904736 kB\n"
    "Active(anon):     820160 kB\n"
    "Inactive(anon):    12048 kB\n"
    "Active(file):     682020 kB\n"
    "Inactive(file):  1892688 kB\n"
    "Unevictable:           0 kB\n"
    "Mlocked:               0 kB\n"
    "SwapTotal:             0 kB\n"
    "SwapFree:              0 kB\n"
    "Dirty:               128 kB\n"
    "AnonPages:        832100 kB\n"
    "Mapped:           294416 kB\n"
    "Shmem:              1024 kB\n";

static void test_meminfo(void) {
    printf("meminfo\n");
    struct meminfo info;
    check(memd_parse_meminfo(DEBIAN_MEMINFO, &info) == 0, "parses a real meminfo");
    check_u64(info.total_kb, 4014520, "MemTotal");
    check_u64(info.free_kb, 182364, "MemFree");
    check_u64(info.available_kb, 2938120, "MemAvailable");
    check_u64(info.swap_total_kb, 0, "SwapTotal - MSL's images have no swap");

    /* The two summed fields, which is where a naive parse goes wrong. */
    check_u64(info.file_cache_kb, 682020 + 1892688, "page cache = Active(file) + Inactive(file)");
    check_u64(info.anon_kb, 820160 + 12048, "anonymous = Active(anon) + Inactive(anon)");

    /* "Active:" must not be mistaken for "Active(anon):" or "Active(file):",
     * and it is 1502180 here - a value that would be obvious in the sums
     * above if it leaked in. */
    check(info.anon_kb != 1502180 && info.file_cache_kb != 1502180,
          "bare Active: does not contaminate the anon/file sums");
}

static void test_meminfo_without_memavailable(void) {
    printf("meminfo, pre-3.14 kernel\n");
    /* MemAvailable arrived in Linux 3.14. Falling back to MemFree
     * understates what is reclaimable, which keeps the guest larger than it
     * needs to be - the safe direction to be wrong in. */
    static const char *old =
        "MemTotal:        1048576 kB\n"
        "MemFree:          262144 kB\n"
        "Active(anon):      65536 kB\n"
        "Inactive(anon):     1024 kB\n"
        "Active(file):      32768 kB\n"
        "Inactive(file):    16384 kB\n";
    struct meminfo info;
    check(memd_parse_meminfo(old, &info) == 0, "parses without MemAvailable");
    check_u64(info.available_kb, 262144, "falls back to MemFree");
}

static void test_meminfo_rejects_garbage(void) {
    printf("meminfo, malformed\n");
    struct meminfo info;
    check(memd_parse_meminfo("", &info) < 0, "empty input is an error, not zeroes");
    check(memd_parse_meminfo("not a meminfo at all\n", &info) < 0, "garbage is an error");
    check(memd_parse_meminfo("MemTotal: abc kB\n", &info) < 0, "non-numeric MemTotal is an error");
}

static void test_pressure(void) {
    printf("pressure\n");
    uint32_t stall = 12345;

    static const char *idle =
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
        "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
    check(memd_parse_pressure(idle, &stall) == 1, "finds the some line");
    check_u64(stall, 0, "an idle guest reports zero stall");

    static const char *busy =
        "some avg10=17.42 avg60=9.03 avg300=2.11 total=98765432\n"
        "full avg10=8.20 avg60=4.00 avg300=1.00 total=12345\n";
    check(memd_parse_pressure(busy, &stall) == 1, "finds a real stall figure");
    check_u64(stall, 1742, "17.42% becomes 1742 hundredths");

    /* The "full" line's avg10 must never be read as the "some" one - they
     * differ, and "full" means every task stalled, which is far rarer. */
    check(stall != 820, "did not read the full line by mistake");

    static const char *absent = "";
    stall = 999;
    check(memd_parse_pressure(absent, &stall) == 0, "no PSI is reported as absent");
    check_u64(stall, 999, "leaves the output alone when absent");
}

static void test_pressure_clamps(void) {
    printf("pressure, out of range\n");
    uint32_t stall = 0;
    check(memd_parse_pressure("some avg10=250.00 avg60=0 avg300=0 total=0\n", &stall) == 1,
          "parses an impossible value");
    check_u64(stall, 10000, "clamped to 100%");
    check(memd_parse_pressure("some avg10=-4.00 avg60=0 avg300=0 total=0\n", &stall) == 1,
          "parses a negative value");
    check_u64(stall, 0, "clamped to zero");
}

/* Captured from a Debian guest with the balloon inflated, 2026-09-14. */
static const char *VMSTAT_BALLOONED =
    "nr_free_pages 555455\n"
    "nr_zone_inactive_anon 0\n"
    "nr_balloon_pages_extra 7\n"
    "nr_balloon_pages 393216\n"
    "balloon_inflate 393216\n"
    "balloon_deflate 0\n"
    "balloon_migrate 0\n";

static void test_balloon_pages(void) {
    printf("balloon pages\n");
    uint64_t pages = 0;
    check(memd_parse_balloon_pages(VMSTAT_BALLOONED, &pages) == 1, "finds nr_balloon_pages");
    check_u64(pages, 393216, "reads the current balloon size, not a similarly named counter");

    pages = 999;
    check(memd_parse_balloon_pages("nr_free_pages 12\nballoon_inflate 5\n", &pages) == 0,
          "a kernel without the line reports absent");
    check_u64(pages, 999, "leaves the output alone when absent");

    check(memd_parse_balloon_pages("nr_balloon_pages 0\n", &pages) == 1, "an empty balloon is present, with zero");
    check_u64(pages, 0, "zero pages");
}

int main(void) {
    test_meminfo();
    test_meminfo_without_memavailable();
    test_meminfo_rejects_garbage();
    test_pressure();
    test_pressure_clamps();
    test_balloon_pages();
    printf("\n%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
