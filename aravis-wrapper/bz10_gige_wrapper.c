// AIPC prototype: BZCAMRAW/10G -> full-resolution RGB8 -> Aravis fake GV camera.
#define _POSIX_C_SOURCE 200809L
#include "frame_core.h"
#include <arv.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef enum { PREVIEW_ALL, PREVIEW_ODD, PREVIEW_EVEN } PreviewParity;

typedef struct {
    pthread_mutex_t lock;
    uint8_t *latest_rgb;
    uint8_t *staged_rgb;
    uint64_t generation;
    uint64_t last_queued;
    BzFrameKey key;
    BzFrameKey staged_key;
    int staged_pending;
    atomic_bool stop;
    const char *input;
    const char *control;
    const char *parity_file;
    PreviewParity parity;
    unsigned demo_fps;
    ArvFakeCamera *fake;
    uint64_t frames_received;
    uint64_t frames_sent;
    uint64_t frames_filtered;
    FILE *metadata;
} App;

static App *signal_app;
static void on_signal(int signum) {
    (void)signum;
    if (signal_app) atomic_store(&signal_app->stop, true);
}

static void publish_frame(App *app, uint8_t *rgb, BzFrameKey key) {
    pthread_mutex_lock(&app->lock);
    uint8_t *old = app->latest_rgb;
    app->latest_rgb = rgb;
    app->key = key;
    app->generation++;
    app->frames_received++;
    pthread_mutex_unlock(&app->lock);
    free(old);
}

static bool preview_accepts(App *app, BzFrameKey key) {
    if (app->parity_file) {
        FILE *file = fopen(app->parity_file, "r");
        if (file) {
            char value[16] = {0};
            if (fgets(value, sizeof(value), file)) {
                value[strcspn(value, "\r\n ")] = 0;
                PreviewParity next = app->parity;
                if (!strcmp(value, "all")) next = PREVIEW_ALL;
                else if (!strcmp(value, "odd")) next = PREVIEW_ODD;
                else if (!strcmp(value, "even")) next = PREVIEW_EVEN;
                if (next != app->parity) {
                    app->parity = next;
                    fprintf(stderr, "preview parity=%s\n",
                            next == PREVIEW_ALL ? "all" :
                            next == PREVIEW_ODD ? "odd" : "even");
                }
            }
            fclose(file);
        }
    }
    if (app->parity == PREVIEW_ALL) return true;
    if (key.version != 2) {
        app->frames_filtered++;
        return false;
    }
    bool odd = (key.frame_id & 1U) != 0;
    bool accepted = app->parity == PREVIEW_ODD ? odd : !odd;
    if (!accepted) app->frames_filtered++;
    return accepted;
}

static void *receive_thread(void *arg) {
    App *app = arg;
    BzAssembler assembler;
    if (bz_assembler_init(&assembler)) {
        fprintf(stderr, "cannot allocate RAW frame\n");
        atomic_store(&app->stop, true);
        return NULL;
    }
    unsigned ifindex = if_nametoindex(app->input);
    if (!ifindex) {
        perror("input interface");
        goto fail;
    }
    int fd = socket(AF_PACKET, SOCK_RAW, htons(0x88b5));
    if (fd < 0) { perror("AF_PACKET (CAP_NET_RAW required)"); goto fail; }
    int rcvbuf = 64 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval timeout = { .tv_sec = 1 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_ll addr = { .sll_family = AF_PACKET,
                                .sll_protocol = htons(0x88b5),
                                .sll_ifindex = (int)ifindex };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr))) {
        perror("bind camera interface"); close(fd); goto fail;
    }
    fprintf(stderr, "receiving BZCAMRAW v1/v2 on %s\n", app->input);
    uint8_t packet[2048];
    while (!atomic_load(&app->stop)) {
        ssize_t n = recv(fd, packet, sizeof(packet), 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            perror("receive camera packet"); break;
        }
        BzFrameKey key;
        if (bz_assembler_push(&assembler, packet, (size_t)n, &key) != 1) continue;
        if (!preview_accepts(app, key)) continue;
        uint8_t *rgb = malloc(BZ_RGB_BYTES);
        if (!rgb || bz_raw10_to_rgb8(assembler.raw, rgb)) {
            free(rgb); fprintf(stderr, "RGB conversion failed\n"); break;
        }
        publish_frame(app, rgb, key);
    }
    struct tpacket_stats stats;
    socklen_t stats_len = sizeof(stats);
    if (!getsockopt(fd, SOL_PACKET, PACKET_STATISTICS, &stats, &stats_len))
        fprintf(stderr, "socket packets=%u drops=%u\n", stats.tp_packets, stats.tp_drops);
    fprintf(stderr, "complete=%llu incomplete=%llu missing_ids=%llu malformed=%llu duplicates=%llu\n",
            (unsigned long long)assembler.complete,
            (unsigned long long)assembler.incomplete,
            (unsigned long long)assembler.missing_ids,
            (unsigned long long)assembler.malformed,
            (unsigned long long)assembler.duplicates);
    close(fd);
fail:
    bz_assembler_destroy(&assembler);
    atomic_store(&app->stop, true);
    return NULL;
}

static void *demo_thread(void *arg) {
    App *app = arg;
    uint32_t id = 0;
    struct timespec period = { .tv_sec = 0, .tv_nsec = 1000000000L / app->demo_fps };
    while (!atomic_load(&app->stop)) {
        ++id;
        if (!preview_accepts(app, (BzFrameKey){ .version = 2, .run_id = 1, .frame_id = id })) {
            nanosleep(&period, NULL);
            continue;
        }
        uint8_t *rgb = malloc(BZ_RGB_BYTES);
        if (!rgb) break;
        for (int y = 0; y < BZ_HEIGHT; y++) for (int x = 0; x < BZ_WIDTH; x++) {
            size_t p = 3 * ((size_t)y * BZ_WIDTH + x);
            rgb[p] = (uint8_t)((x + id) >> 2);
            rgb[p+1] = (uint8_t)(y >> 2);
            rgb[p+2] = (uint8_t)((x / 64 + y / 64 + id) & 1 ? 210 : 20);
        }
        publish_frame(app, rgb, (BzFrameKey){ .version = 2, .run_id = 1, .frame_id = id });
        nanosleep(&period, NULL);
    }
    atomic_store(&app->stop, true);
    return NULL;
}

static void *replay_thread(void *arg) {
    App *app = arg;
    FILE *source = fopen(app->input + 7, "rb");
    BzAssembler assembler;
    if (!source || bz_assembler_init(&assembler)) {
        perror("open replay file / allocate frame");
        if (source) fclose(source);
        atomic_store(&app->stop, true);
        return NULL;
    }
    if (fseek(source, 0, SEEK_END) || ftell(source) < BZ_L2_BYTES ||
        fseek(source, 0, SEEK_SET)) {
        fprintf(stderr, "replay file is empty or too short\n");
        bz_assembler_destroy(&assembler);
        fclose(source);
        atomic_store(&app->stop, true);
        return NULL;
    }
    uint8_t packet[BZ_L2_BYTES];
    struct timespec period = { .tv_sec = 0, .tv_nsec = 1000000000L / app->demo_fps };
    while (!atomic_load(&app->stop)) {
        size_t n = fread(packet, 1, sizeof(packet), source);
        if (n == 0 && feof(source)) {
            clearerr(source);
            rewind(source);
            continue;
        }
        if (n != sizeof(packet)) {
            fprintf(stderr, "replay file must contain whole %d-byte packets\n", BZ_L2_BYTES);
            break;
        }
        BzFrameKey key;
        int state = bz_assembler_push(&assembler, packet, n, &key);
        if (state == 1) {
            if (!preview_accepts(app, key)) {
                nanosleep(&period, NULL);
                continue;
            }
            uint8_t *rgb = malloc(BZ_RGB_BYTES);
            if (!rgb || bz_raw10_to_rgb8(assembler.raw, rgb)) {
                free(rgb); break;
            }
            publish_frame(app, rgb, key);
            nanosleep(&period, NULL);
        }
    }
    fprintf(stderr, "replay complete=%llu malformed=%llu\n",
            (unsigned long long)assembler.complete,
            (unsigned long long)assembler.malformed);
    bz_assembler_destroy(&assembler);
    fclose(source);
    atomic_store(&app->stop, true);
    return NULL;
}

static void fill_pattern(ArvBuffer *buffer, void *user, guint32 exposure_us,
                         guint32 gain, ArvPixelFormat format) {
    (void)exposure_us; (void)gain;
    App *app = user;
    if (format != ARV_PIXEL_FORMAT_RGB_8_PACKED) return;
    /* Aravis's public getter is const, but this callback owns the allocated
       fake-camera buffer. The GVSP sender reads its payload after return. */
    uint8_t *target = (uint8_t *)(uintptr_t)arv_buffer_get_data(buffer, NULL);
    if (!target) return;
    pthread_mutex_lock(&app->lock);
    memcpy(target, app->staged_rgb, BZ_RGB_BYTES);
    if (app->metadata) {
        fprintf(app->metadata, "%llu,%u,%u,%u,%d\n",
                (unsigned long long)arv_buffer_get_frame_id(buffer),
                app->staged_key.version, app->staged_key.run_id,
                app->staged_key.frame_id,
                app->staged_key.version == 2 ?
                    (int)(app->staged_key.frame_id & 1U) : -1);
        fflush(app->metadata);
    }
    app->staged_pending = 0;
    app->frames_sent++;
    pthread_mutex_unlock(&app->lock);
}

static int control_command(const char *endpoint, const char *command) {
    if (!endpoint || !strcmp(endpoint, "none")) return 0;
    const char *colon = strrchr(endpoint, ':');
    if (!colon) return -1;
    char ip[64];
    size_t n = (size_t)(colon - endpoint);
    if (!n || n >= sizeof(ip)) return -1;
    memcpy(ip, endpoint, n); ip[n] = 0;
    char *end;
    unsigned long port = strtoul(colon+1, &end, 10);
    if (*end || !port || port > 65535) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = { .tv_sec = 2 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) { close(fd); return -1; }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) {
        close(fd); return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
        if (errno != EINPROGRESS) { close(fd); return -1; }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int error = 0;
        socklen_t error_len = sizeof(error);
        if (poll(&pfd, 1, 2000) != 1 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_len) || error) {
            close(fd); return -1;
        }
    }
    if (fcntl(fd, F_SETFL, flags)) { close(fd); return -1; }
    char line[80];
    int len = snprintf(line, sizeof(line), "%s\n", command);
    if (len <= 0 || len >= (int)sizeof(line)) { close(fd); return -1; }
    size_t sent = 0;
    while (sent < (size_t)len) {
        ssize_t n = send(fd, line + sent, (size_t)len - sent, MSG_NOSIGNAL);
        if (n <= 0) { close(fd); return -1; }
        sent += (size_t)n;
    }
    char reply[16] = {0};
    size_t got = 0;
    while (got + 1 < sizeof(reply) && !strchr(reply, '\n')) {
        ssize_t n = recv(fd, reply + got, sizeof(reply) - got - 1, 0);
        if (n <= 0) { close(fd); return -1; }
        got += (size_t)n;
        reply[got] = 0;
    }
    close(fd);
    return got >= 3 && !strncmp(reply, "OK\n", 3) ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *input = "demo", *listen = "127.0.0.1", *control = "none";
    const char *metadata_path = NULL, *parity_file = NULL;
    unsigned fps = 50, gv_packet_size = 1400;
    for (int i = 1; i < argc; i++) {
        const char *option = argv[i];
        if (strcmp(option, "--input") && strcmp(option, "--listen") &&
            strcmp(option, "--control") && strcmp(option, "--metadata") &&
            strcmp(option, "--fps") && strcmp(option, "--gv-packet-size") &&
            strcmp(option, "--parity-file")) {
            fprintf(stderr, "unknown option: %s\n", option);
            fprintf(stderr, "usage: %s [--input demo|replay:FILE|10g-interface] [--listen IP|interface] [--control none|IP:PORT] [--fps 1..240] [--gv-packet-size 1400..8192] [--metadata CSV] [--parity-file PATH]\n", argv[0]);
            return 2;
        }
        if (++i >= argc) {
            fprintf(stderr, "missing value after %s\n", option);
            return 2;
        }
        if (!strcmp(option, "--input")) input = argv[i];
        else if (!strcmp(option, "--listen")) listen = argv[i];
        else if (!strcmp(option, "--control")) control = argv[i];
        else if (!strcmp(option, "--metadata")) metadata_path = argv[i];
        else if (!strcmp(option, "--parity-file")) parity_file = argv[i];
        else if (!strcmp(option, "--fps")) fps = (unsigned)atoi(argv[i]);
        else if (!strcmp(option, "--gv-packet-size"))
            gv_packet_size = (unsigned)atoi(argv[i]);
    }
    if (fps < 1 || fps > 240) { fprintf(stderr, "fps must be 1..240\n"); return 2; }
    if (gv_packet_size < 1400 || gv_packet_size > 8192) {
        fprintf(stderr, "GVSP packet size must be 1400..8192\n"); return 2;
    }
    App app = { .input = input, .control = control, .parity_file = parity_file,
                .demo_fps = fps };
    pthread_mutex_init(&app.lock, NULL);
    atomic_init(&app.stop, false);
    app.staged_rgb = calloc(1, BZ_RGB_BYTES);
    if (!app.staged_rgb) return 1;
    if (metadata_path) {
        app.metadata = fopen(metadata_path, "wx");
        if (!app.metadata) { perror("open metadata CSV"); return 1; }
        fprintf(app.metadata, "gvsp_frame_id,input_version,run_id,input_frame_id,odd_expected_high\n");
    }
    ArvGvFakeCamera *gv = arv_gv_fake_camera_new(listen, "BZ10-CAM0");
    if (!gv || !arv_gv_fake_camera_is_running(gv)) {
        fprintf(stderr, "cannot bind GigE Vision fake camera to %s\n", listen);
        return 1;
    }
    app.fake = arv_gv_fake_camera_get_fake_camera(gv);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_WIDTH, BZ_WIDTH);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_HEIGHT, BZ_HEIGHT);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_PIXEL_FORMAT,
                                   ARV_PIXEL_FORMAT_RGB_8_PACKED);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_TRIGGER_MODE, 1);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_TRIGGER_SOURCE, 1);
    arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_ACQUISITION_FRAME_PERIOD_US,
                                   1000000 / fps);
    // GigE Vision bootstrap stream channel 0 packet-size register.
    arv_fake_camera_write_register(app.fake, 0x00000d04, gv_packet_size);
    arv_fake_camera_set_trigger_frequency(app.fake, 1000.0);
    arv_fake_camera_set_fill_pattern(app.fake, fill_pattern, &app);
    signal_app = &app;
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    pthread_t producer;
    void *(*producer_fn)(void *) = !strcmp(input, "demo") ? demo_thread :
        !strncmp(input, "replay:", 7) ? replay_thread : receive_thread;
    if (pthread_create(&producer, NULL, producer_fn, &app)) {
        perror("pthread_create"); return 1;
    }
    fprintf(stderr, "GigE Vision camera on %s; input=%s; control=%s\n", listen, input, control);
    int board_active = 0;
    struct timespec tick = { .tv_sec = 0, .tv_nsec = 1000000 };
    while (!atomic_load(&app.stop)) {
        unsigned active = arv_fake_camera_get_acquisition_status(app.fake) != 0;
        // Clients may write these fake-camera registers. The camera is fixed
        // RGB8 and producer-paced; restore our supported mode before streaming.
        arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_TRIGGER_MODE, 1);
        arv_fake_camera_write_register(app.fake, ARV_FAKE_CAMERA_REGISTER_TRIGGER_SOURCE, 1);
        if (active && !board_active) {
            char command[32];
            uint32_t period = 0;
            arv_fake_camera_read_register(app.fake,
                ARV_FAKE_CAMERA_REGISTER_ACQUISITION_FRAME_PERIOD_US, &period);
            unsigned requested_fps = period ? (1000000U + period/2) / period : fps;
            snprintf(command, sizeof(command), "FPS %u", requested_fps);
            if (control_command(control, command) || control_command(control, "START")) {
                fprintf(stderr, "board control start failed; retrying\n");
                nanosleep(&tick, NULL); continue;
            }
            pthread_mutex_lock(&app.lock);
            app.last_queued = app.generation;
            app.staged_pending = 0;
            pthread_mutex_unlock(&app.lock);
            board_active = 1;
            fprintf(stderr, "acquisition started at requested %u fps\n", requested_fps);
        } else if (!active && board_active) {
            if (control_command(control, "STOP"))
                fprintf(stderr, "board control stop failed; retrying\n");
            else {
                board_active = 0;
                arv_fake_camera_write_register(app.fake,
                    ARV_FAKE_CAMERA_REGISTER_TRIGGER_SOFTWARE, 0);
                fprintf(stderr, "acquisition stopped\n");
            }
        }
        if (active && board_active) {
            pthread_mutex_lock(&app.lock);
            if (!app.staged_pending && app.latest_rgb && app.generation > app.last_queued) {
                memcpy(app.staged_rgb, app.latest_rgb, BZ_RGB_BYTES);
                app.staged_key = app.key;
                app.last_queued = app.generation;
                app.staged_pending = 1;
                arv_fake_camera_write_register(app.fake,
                    ARV_FAKE_CAMERA_REGISTER_TRIGGER_SOFTWARE, 1);
            }
            pthread_mutex_unlock(&app.lock);
        }
        nanosleep(&tick, NULL);
    }
    if (board_active) control_command(control, "STOP");
    pthread_join(producer, NULL);
    g_object_unref(gv);
    fprintf(stderr, "received=%llu sent=%llu parity_filtered=%llu\n",
            (unsigned long long)app.frames_received,
            (unsigned long long)app.frames_sent,
            (unsigned long long)app.frames_filtered);
    free(app.latest_rgb);
    free(app.staged_rgb);
    if (app.metadata) fclose(app.metadata);
    pthread_mutex_destroy(&app.lock);
    return 0;
}
