#include "frame_core.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void wr16(uint8_t *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void wr32(uint8_t *p, uint32_t v) {
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

static void packet(uint8_t *p, unsigned version, unsigned run, unsigned id,
                   unsigned index, const uint8_t *raw) {
    memset(p, 0, BZ_L2_BYTES);
    p[12] = 0x88; p[13] = 0xb5;
    memcpy(p+14, "BZCAMRAW", 8);
    wr16(p+22, version);
    wr32(p+26, id);
    wr32(p+30, index * BZ_FRAGMENT_BYTES);
    wr32(p+34, BZ_RAW_BYTES);
    wr16(p+38, BZ_FRAGMENT_BYTES);
    wr16(p+40, BZ_WIDTH);
    wr16(p+42, BZ_HEIGHT);
    wr32(p+44, run);
    memcpy(p+48, raw + (size_t)index * BZ_FRAGMENT_BYTES, BZ_FRAGMENT_BYTES);
}

static void pack_four(uint8_t *p, unsigned a, unsigned b, unsigned c, unsigned d) {
    uint64_t bits = a | (uint64_t)b << 10 | (uint64_t)c << 20 | (uint64_t)d << 30;
    for (int i = 0; i < 5; i++) p[i] = (uint8_t)(bits >> (8*i));
}

static double seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(void) {
    uint8_t *raw = malloc(BZ_RAW_BYTES), *rgb = malloc(BZ_RGB_BYTES);
    assert(raw && rgb);
    // BGGR cell B=100, G=300, G=300, R=500. Four pixels span two cells.
    for (int y = 0; y < BZ_HEIGHT; y++) for (int x = 0; x < BZ_WIDTH; x += 4) {
        uint8_t *p = raw + (size_t)y * BZ_WIDTH * 5 / 4 + x * 5 / 4;
        if (y & 1) pack_four(p, 300, 500, 300, 500);
        else pack_four(p, 100, 300, 100, 300);
    }
    BzAssembler a;
    assert(!bz_assembler_init(&a));
    uint8_t p[BZ_L2_BYTES];
    BzFrameKey key;
    for (unsigned i = 0; i < BZ_FRAGMENTS; i++) {
        packet(p, 1, 0, 7, i, raw);
        assert(bz_assembler_push(&a, p, sizeof(p), &key) ==
               (i == BZ_FRAGMENTS - 1 ? 1 : 0));
    }
    assert(key.version == 1 && key.run_id == 0 && key.frame_id == 7);
    assert(a.complete == 1 && !memcmp(a.raw, raw, BZ_RAW_BYTES));
    assert(bz_assembler_push(&a, p, sizeof(p), &key) == 0 && a.duplicates == 1);
    packet(p, 2, 42, 1, 0, raw);
    assert(bz_assembler_push(&a, p, sizeof(p), &key) == 0);
    for (unsigned i = 1; i < BZ_FRAGMENTS; i++) {
        packet(p, 2, 42, 1, i, raw);
        assert(bz_assembler_push(&a, p, sizeof(p), &key) ==
               (i == BZ_FRAGMENTS - 1 ? 1 : 0));
    }
    assert(key.version == 2 && key.run_id == 42 && key.frame_id == 1);
    assert(a.complete == 2 && a.incomplete == 0);
    packet(p, 2, 42, 3, 0, raw);
    assert(bz_assembler_push(&a, p, sizeof(p), &key) == 0);
    assert(a.missing_ids == 1);
    packet(p, 2, 0, 4, 0, raw);
    assert(bz_assembler_push(&a, p, sizeof(p), &key) == -1);
    assert(a.malformed == 1);
    assert(!bz_raw10_to_rgb8(raw, rgb));
    for (int y = 1; y < 5; y++) for (int x = 1; x < 5; x++) {
        size_t k = 3 * ((size_t)y * BZ_WIDTH + x);
        assert(rgb[k] > rgb[k+1] && rgb[k+1] > rgb[k+2]);
    }
    double start = seconds();
    for (int i = 0; i < 20; i++) assert(!bz_raw10_to_rgb8(raw, rgb));
    double fps = 20.0 / (seconds() - start);
    printf("frame protocol and RGB tests passed; conversion %.1f fps on this laptop\n", fps);
    bz_assembler_destroy(&a);
    free(raw); free(rgb);
    return 0;
}
