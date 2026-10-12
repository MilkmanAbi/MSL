/*
 * msl-usbattach - hand a connected socket to the guest's vhci_hcd.
 *
 * MSL does not run usbip's userspace tools (no image ships them) and does
 * not need to: USB/IP's connection phase only exists so that a client can
 * discover and import a device over a network it does not control. MSL
 * controls both ends, so this connects straight to the Mac and writes the
 * live fd into /sys/devices/platform/vhci_hcd.0/attach. The kernel takes a
 * reference on the socket, so this process exits immediately afterwards
 * and the device stays attached.
 *
 * Needs to be a C program, not a shell script: sh cannot open an AF_VSOCK
 * socket, and the fd number written to `attach` has to belong to a process
 * that still holds it open at the moment of the write.
 *
 *   msl-usbattach --vsock <port> [--devid N] [--speed N]
 *   msl-usbattach --tcp <host> <port> [--devid N] [--speed N]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/vm_sockets.h>

#define VHCI "/sys/devices/platform/vhci_hcd.0"
/* VDEV_ST_NULL in the kernel's own numbering - a port with nothing on it. */
#define VDEV_ST_NULL 4

static int connect_vsock(unsigned int port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket(AF_VSOCK)"); return -1; }
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof sa);
    sa.svm_family = AF_VSOCK;
    sa.svm_cid = VMADDR_CID_HOST;   /* 2 - the Mac */
    sa.svm_port = port;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        fprintf(stderr, "connect(vsock:%u): %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_tcp(const char *host, unsigned short port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket(AF_INET)"); return -1; }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) {
        fprintf(stderr, "bad host address: %s\n", host);
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        fprintf(stderr, "connect(%s:%u): %s\n", host, port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

/*
 * Picks a free port of the right speed. A high-speed device must go on an
 * "hs" port and a super-speed device on an "ss" one; the kernel exposes
 * both kinds in one table and silently misbehaves if they are mixed up.
 */
static int free_port(unsigned int speed) {
    FILE *f = fopen(VHCI "/status", "r");
    if (!f) { perror("open " VHCI "/status"); return -1; }
    char line[256];
    const char *want = (speed >= 5) ? "ss" : "hs";
    int found = -1;
    /* Skip the header row. */
    if (!fgets(line, sizeof line, f)) { fclose(f); return -1; }
    while (fgets(line, sizeof line, f)) {
        char hub[8];
        unsigned int port, sta;
        if (sscanf(line, "%7s %u %u", hub, &port, &sta) != 3) continue;
        if (sta != VDEV_ST_NULL) continue;
        if (strcmp(hub, want) != 0) continue;
        found = (int)port;
        break;
    }
    fclose(f);
    if (found < 0) fprintf(stderr, "no free %s port on vhci_hcd\n", want);
    return found;
}

int main(int argc, char **argv) {
    unsigned int devid = 1, speed = 3;   /* 3 = USB_SPEED_HIGH */
    int fd = -1;
    int i = 1;

    while (i < argc) {
        if (!strcmp(argv[i], "--vsock") && i + 1 < argc) {
            fd = connect_vsock((unsigned int)strtoul(argv[i + 1], NULL, 10));
            i += 2;
        } else if (!strcmp(argv[i], "--tcp") && i + 2 < argc) {
            fd = connect_tcp(argv[i + 1], (unsigned short)strtoul(argv[i + 2], NULL, 10));
            i += 3;
        } else if (!strcmp(argv[i], "--devid") && i + 1 < argc) {
            devid = (unsigned int)strtoul(argv[i + 1], NULL, 0);
            i += 2;
        } else if (!strcmp(argv[i], "--speed") && i + 1 < argc) {
            speed = (unsigned int)strtoul(argv[i + 1], NULL, 10);
            i += 2;
        } else {
            fprintf(stderr, "usage: %s --vsock <port> | --tcp <host> <port>"
                            " [--devid N] [--speed N]\n", argv[0]);
            return 1;
        }
    }
    if (fd < 0) return 1;

    int port = free_port(speed);
    if (port < 0) { close(fd); return 1; }

    char line[64];
    int n = snprintf(line, sizeof line, "%u %u %u %u", (unsigned)port, (unsigned)fd, devid, speed);
    int af = open(VHCI "/attach", O_WRONLY);
    if (af < 0) { perror("open " VHCI "/attach"); close(fd); return 1; }
    if (write(af, line, n) < 0) {
        fprintf(stderr, "write attach (\"%s\"): %s\n", line, strerror(errno));
        close(af);
        close(fd);
        return 1;
    }
    close(af);
    printf("attached on vhci port %d (devid %u, speed %u)\n", port, devid, speed);
    /* The kernel holds its own reference now; nothing left to keep alive. */
    return 0;
}
