// BZ-10 Linux management-port adapter for the existing trigger module.
// Bind only the dedicated point-to-point 1G address; this protocol has no auth.
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested;
static void on_signal(int signum) { (void)signum; stop_requested = 1; }

static int attr_write(const char *dir, const char *name, const char *value) {
    char path[512];
    if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) return -1;
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(value);
    ssize_t n = write(fd, value, len);
    int saved = errno;
    close(fd);
    errno = saved;
    return n == (ssize_t)len ? 0 : -1;
}

static int attr_read(const char *dir, const char *name, char *out, size_t size) {
    char path[512];
    if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) return -1;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, out, size - 1);
    close(fd);
    if (n < 0) return -1;
    out[n] = 0;
    return 0;
}

static void handle_request(int fd, const char *dir) {
    char request[80], reply[128] = "ERR\n";
    size_t used = 0;
    int complete = 0;
    while (used + 1 < sizeof(request)) {
        ssize_t n = recv(fd, request + used, sizeof(request) - used - 1, 0);
        if (n <= 0) return;
        used += (size_t)n;
        request[used] = 0;
        char *newline = strchr(request, '\n');
        if (newline) { *newline = 0; complete = 1; break; }
    }
    if (!complete) goto done;
    if (!strcmp(request, "START")) {
        if (!attr_write(dir, "frames", "-1\n") &&
            !attr_write(dir, "run", "1\n")) strcpy(reply, "OK\n");
    } else if (!strcmp(request, "STOP")) {
        if (!attr_write(dir, "run", "0\n")) strcpy(reply, "OK\n");
    } else if (!strncmp(request, "FPS ", 4)) {
        char *end;
        unsigned long fps = strtoul(request + 4, &end, 10);
        if (end != request + 4 && !*end && fps >= 16 && fps <= 240) {
            char run[16], value[16];
            if (!attr_read(dir, "run", run, sizeof(run)) && run[0] == '0') {
                snprintf(value, sizeof(value), "%lu\n", fps);
                if (!attr_write(dir, "fps", value)) strcpy(reply, "OK\n");
            }
        }
    } else if (!strcmp(request, "STATUS")) {
        char run[16], fps[16];
        if (!attr_read(dir, "run", run, sizeof(run)) &&
            !attr_read(dir, "fps", fps, sizeof(fps))) {
            run[strcspn(run, "\r\n")] = 0;
            fps[strcspn(fps, "\r\n")] = 0;
            snprintf(reply, sizeof(reply), "OK run=%s fps=%s\n", run, fps);
        }
    }
done:
    send(fd, reply, strlen(reply), MSG_NOSIGNAL);
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s bind-ip port sysfs-device-dir\n", argv[0]);
        return 2;
    }
    char *end;
    unsigned long port = strtoul(argv[2], &end, 10);
    if (*end || !port || port > 65535) return 2;
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    if (inet_pton(AF_INET, argv[1], &addr.sin_addr) != 1 ||
        bind(server, (struct sockaddr *)&addr, sizeof(addr)) || listen(server, 4)) {
        perror("bind/listen"); close(server); return 1;
    }
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    fprintf(stderr, "camera control listening on %s:%lu -> %s\n", argv[1], port, argv[3]);
    while (!stop_requested) {
        int client = accept(server, NULL, NULL);
        if (client < 0) { if (errno == EINTR) continue; perror("accept"); break; }
        struct timeval tv = { .tv_sec = 2 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        handle_request(client, argv[3]);
        close(client);
    }
    close(server);
    return 0;
}
