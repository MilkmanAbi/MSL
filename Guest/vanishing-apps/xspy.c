/* xspy - captures what GIMP will not tell you, without rebuilding it.
 *
 * GDK installs an Xlib I/O error handler that calls _exit(1). That bypasses
 * atexit, core dumps and every crash reporter, which is why 56 recorded
 * deaths left no trace anywhere. This does three things about that:
 *
 *   1. Intercepts XSetIOErrorHandler so GDK's _exit handler is never the one
 *      that runs - ours is, and ours dumps state and a backtrace first.
 *   2. Intercepts _exit/exit as a backstop, in case something else leaves.
 *   3. Logs every read/write on the X11 socket itself. THAT is the open
 *      question: mslgd's rings prove it wrote the reply; this proves whether
 *      the bytes ever arrived. No amount of editing GIMP's own source can
 *      see that - it is below the library, at the syscall.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>

static FILE *lg = NULL;
static int xfds[64]; static int nxfds = 0;   /* GIMP holds several at once */
static int is_xfd(int fd) { for (int i=0;i<nxfds;i++) if (xfds[i]==fd) return 1; return 0; }
static void add_xfd(int fd) { if (nxfds < 64 && !is_xfd(fd)) xfds[nxfds++] = fd; }
static long long nread = 0, nwrit = 0, reads = 0, writes = 0;

static void op(void) {
    if (!lg) {
        const char *p = getenv("XSPY_LOG");
        lg = fopen(p ? p : "/tmp/xspy.log", "a");
        if (lg) setvbuf(lg, NULL, _IOLBF, 0);   /* line buffered: a dying
                                                   process must not lose the
                                                   last thing it said */
    }
}

static void stamp(const char *tag) {
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm; localtime_r(&ts.tv_sec, &tm);
    op(); if (!lg) return;
    fprintf(lg, "%02d:%02d:%02d.%03ld %s ", tm.tm_hour, tm.tm_min, tm.tm_sec,
            ts.tv_nsec / 1000000, tag);
}

static void dump(const char *why) {
    stamp("DEATH");
    if (!lg) return;
    fprintf(lg, "[pid %d] %s | xfds=%d reads=%lld (%lld bytes) writes=%lld (%lld bytes) errno=%d (%s)\n",
            getpid(), why, nxfds, reads, nread, writes, nwrit, errno, strerror(errno));
    void *bt[48];
    int n = backtrace(bt, 48);
    char **sym = backtrace_symbols(bt, n);
    for (int i = 0; i < n; i++) fprintf(lg, "   #%-2d %s\n", i, sym ? sym[i] : "?");
    fflush(lg);
}

/* --- our I/O error handler: look, then leave --- */
static int xspy_io_error(void *dpy) {
    (void)dpy;
    dump("Xlib I/O error (GDK would have called _exit(1) here)");
    _Exit(97);                  /* distinct code so the hunt can tell */
}

/* Xlib >= 1.7 splits this: GTK3 installs an "exit handler" that is called
   after the I/O error handler and is the one that actually terminates. Both
   have to be taken or GDK still gets the last word. */
typedef void (*iohx_t)(void *, void *);
static void xspy_io_exit(void *dpy, void *data) {
    (void)dpy; (void)data;
    dump("Xlib I/O error EXIT handler (this is where GDK terminates)");
    _Exit(97);
}
void XSetIOErrorExitHandler(void *dpy, iohx_t h, void *data) {
    static void (*real)(void *, iohx_t, void *) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "XSetIOErrorExitHandler");
    stamp("INFO"); if (lg) fprintf(lg, "XSetIOErrorExitHandler intercepted (was %p)\n", (void*)h);
    if (real) real(dpy, xspy_io_exit, data);
}

typedef int (*ioh_t)(void *);
ioh_t XSetIOErrorHandler(ioh_t h) {
    static ioh_t (*real)(ioh_t) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "XSetIOErrorHandler");
    stamp("INFO"); if (lg) fprintf(lg, "XSetIOErrorHandler intercepted - installing ours instead of %p\n", (void*)h);
    return real ? real(xspy_io_error) : NULL;
}

/* --- note which fd is the X connection --- */
int connect(int fd, const struct sockaddr *a, socklen_t len) {
    static int (*real)(int, const struct sockaddr *, socklen_t) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "connect");
    int r = real(fd, a, len);
    if (r == 0 && a && a->sa_family == AF_UNIX) {
        const struct sockaddr_un *u = (const struct sockaddr_un *)a;
        if (strstr(u->sun_path, "/tmp/.X11-unix/") || strstr(u->sun_path, "X11")) {
            add_xfd(fd);
            stamp("INFO"); if (lg) fprintf(lg, "[pid %d] X11 socket is fd %d (%s)\n", getpid(), fd, u->sun_path);
        }
    }
    return r;
}

/* --- every byte in and out of the X socket --- */
ssize_t read(int fd, void *buf, size_t n) {
    static ssize_t (*real)(int, void *, size_t) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "read");
    ssize_t r = real(fd, buf, n);
    if (is_xfd(fd)) {
        reads++; if (r > 0) nread += r;
        if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            stamp("XREAD"); if (lg)
                fprintf(lg, "read(%d) returned %zd errno=%d (%s) after %lld reads / %lld bytes\n",
                        fd, r, errno, strerror(errno), reads, nread);
        }
    }
    return r;
}

ssize_t recvmsg(int fd, struct msghdr *m, int flags) {
    static ssize_t (*real)(int, struct msghdr *, int) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "recvmsg");
    ssize_t r = real(fd, m, flags);
    if (is_xfd(fd)) {
        reads++; if (r > 0) nread += r;
        if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            stamp("XRECV"); if (lg)
                fprintf(lg, "recvmsg(%d) returned %zd errno=%d (%s) after %lld reads / %lld bytes\n",
                        fd, r, errno, strerror(errno), reads, nread);
        }
    }
    return r;
}

ssize_t writev(int fd, const struct iovec *v, int c) {
    static ssize_t (*real)(int, const struct iovec *, int) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "writev");
    ssize_t r = real(fd, v, c);
    if (is_xfd(fd)) {
        writes++; if (r > 0) nwrit += r;
        /* A SHORT write means the kernel's send buffer is full - the server
           is not draining this socket fast enough. That is the thing to
           prove: Xlib must flush its request buffer before it can wait for
           a reply in _XReply, and a flush that cannot complete is what turns
           into a fatal I/O error with nothing wrong with the socket. */
        size_t want = 0;
        for (int i = 0; i < c; i++) want += v[i].iov_len;
        if (r < 0 || (size_t)r < want) {
            static long long shorts = 0;
            shorts++;
            if (shorts < 40 || shorts % 500 == 0) {
                stamp("XWRITE"); if (lg)
                    fprintf(lg, "writev(%d) wanted %zu got %zd errno=%d (%s) "
                            "- short write #%lld, %lld bytes queued so far\n",
                            fd, want, r, errno, strerror(errno), shorts, nwrit);
            }
        }
    }
    return r;
}

/* --- backstops --- */
void _exit(int code) {
    static void (*real)(int) __attribute__((noreturn)) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "_exit");
    if (code != 97 && nxfds > 0) dump("_exit called");
    real(code);
}

void exit(int code) {
    static void (*real)(int) __attribute__((noreturn)) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "exit");
    if (code != 0 && nxfds > 0) dump("exit called");
    real(code);
}
