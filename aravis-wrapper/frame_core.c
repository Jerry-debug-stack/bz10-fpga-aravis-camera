#include "frame_core.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static uint16_t rd16(const uint8_t *p) {
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

int bz_parse_packet(const uint8_t *p, size_t len, BzFragment *out) {
    if (!p || !out || len != BZ_L2_BYTES || p[12] != 0x88 || p[13] != 0xb5 ||
        memcmp(p + 14, "BZCAMRAW", 8) || rd16(p + 24) != 0 ||
        rd32(p + 34) != BZ_RAW_BYTES || rd16(p + 38) != BZ_FRAGMENT_BYTES ||
        rd16(p + 40) != BZ_WIDTH || rd16(p + 42) != BZ_HEIGHT)
        return -1;
    uint16_t version = rd16(p + 22);
    uint32_t run_id = rd32(p + 44);
    uint32_t offset = rd32(p + 30);
    if ((version != 1 && version != 2) ||
        (version == 1 && run_id != 0) || (version == 2 && run_id == 0) ||
        offset >= BZ_RAW_BYTES || offset % BZ_FRAGMENT_BYTES)
        return -1;
    out->version = version;
    out->run_id = run_id;
    out->frame_id = rd32(p + 26);
    out->byte_offset = offset;
    out->payload = p + 48;
    return 0;
}

int bz_assembler_init(BzAssembler *a) {
    if (!a) return -1;
    memset(a, 0, sizeof(*a));
    a->raw = malloc(BZ_RAW_BYTES);
    return a->raw ? 0 : -1;
}

void bz_assembler_destroy(BzAssembler *a) {
    if (a) { free(a->raw); a->raw = NULL; }
}

int bz_assembler_push(BzAssembler *a, const uint8_t *packet, size_t len,
                      BzFrameKey *completed) {
    BzFragment f;
    if (!a || !a->raw || bz_parse_packet(packet, len, &f)) {
        if (a) a->malformed++;
        return -1;
    }
    BzFrameKey next = { f.version, f.run_id, f.frame_id };
    if (!a->active || a->key.version != next.version ||
        a->key.run_id != next.run_id || a->key.frame_id != next.frame_id) {
        if (a->active) {
            if (a->received != BZ_FRAGMENTS) a->incomplete++;
            if (a->key.version == next.version && a->key.run_id == next.run_id) {
                uint32_t delta = next.frame_id - a->key.frame_id;
                if (delta > 1 && delta < 10000) a->missing_ids += delta - 1;
            }
        }
        a->key = next;
        a->received = 0;
        a->active = 1;
        memset(a->seen, 0, sizeof(a->seen));
    }
    unsigned index = f.byte_offset / BZ_FRAGMENT_BYTES;
    if (a->seen[index]) { a->duplicates++; return 0; }
    a->seen[index] = 1;
    memcpy(a->raw + f.byte_offset, f.payload, BZ_FRAGMENT_BYTES);
    if (++a->received == BZ_FRAGMENTS) {
        a->complete++;
        if (completed) *completed = a->key;
        return 1;
    }
    return 0;
}

static uint8_t lut[3][1024];
static int lut_ready;
static void init_lut(void) {
    const unsigned gains[3] = {1024, 473, 841}; /* R/G/B profile */
    for (int c = 0; c < 3; c++) for (int v = 0; v < 1024; v++) {
        double linear = (v > 64 ? v - 64 : 0) * gains[c] /
                        (1024.0 * (1023 - 64));
        if (linear > 1.0) linear = 1.0;
        double srgb = linear <= 0.0031308 ? 12.92 * linear :
                      1.055 * pow(linear, 1.0 / 2.4) - 0.055;
        int code = (int)lrint(srgb * 255.0);
        lut[c][v] = (uint8_t)(code < 0 ? 0 : code > 255 ? 255 : code);
    }
    lut_ready = 1;
}

static unsigned sample(const uint16_t *r, int y, int x) {
    return r[(size_t)y * BZ_WIDTH + x];
}
static unsigned avg2(unsigned a, unsigned b) { return (a + b + 1) / 2; }
static unsigned avg4(unsigned a, unsigned b, unsigned c, unsigned d) {
    return (a + b + c + d + 2) / 4;
}

int bz_raw10_to_rgb8(const uint8_t *raw, uint8_t *rgb) {
    if (!raw || !rgb) return -1;
    if (!lut_ready) init_lut();
    uint16_t *pix = malloc((size_t)BZ_WIDTH * BZ_HEIGHT * sizeof(*pix));
    if (!pix) return -1;
    for (size_t i = 0, j = 0; i < (size_t)BZ_WIDTH * BZ_HEIGHT; i += 4, j += 5) {
        pix[i]   = raw[j] | (raw[j+1] & 3) << 8;
        pix[i+1] = raw[j+1] >> 2 | (raw[j+2] & 15) << 6;
        pix[i+2] = raw[j+2] >> 4 | (raw[j+3] & 63) << 4;
        pix[i+3] = raw[j+3] >> 6 | raw[j+4] << 2;
    }
    for (int y = 0; y < BZ_HEIGHT; y++) {
        int ym = y ? y - 1 : y + 1;
        int yp = y + 1 < BZ_HEIGHT ? y + 1 : y - 1;
        for (int x = 0; x < BZ_WIDTH; x++) {
            int xm = x ? x - 1 : x + 1;
            int xp = x + 1 < BZ_WIDTH ? x + 1 : x - 1;
            unsigned center = sample(pix, y, x);
            unsigned h = avg2(sample(pix, y, xm), sample(pix, y, xp));
            unsigned v = avg2(sample(pix, ym, x), sample(pix, yp, x));
            unsigned cross = avg4(sample(pix, ym, x), sample(pix, yp, x),
                                  sample(pix, y, xm), sample(pix, y, xp));
            unsigned diag = avg4(sample(pix, ym, xm), sample(pix, ym, xp),
                                 sample(pix, yp, xm), sample(pix, yp, xp));
            unsigned r, g, b;
            if (!(y & 1) && !(x & 1)) { b = center; g = cross; r = diag; }
            else if ((y & 1) && (x & 1)) { r = center; g = cross; b = diag; }
            else if (!(y & 1)) { b = h; g = center; r = v; }
            else { r = h; g = center; b = v; }
            size_t dst = 3 * ((size_t)y * BZ_WIDTH + x);
            rgb[dst] = lut[0][r];
            rgb[dst+1] = lut[1][g];
            rgb[dst+2] = lut[2][b];
            unsigned least = r < g ? r : g;
            if (b < least) least = b;
            if (least > 900) {
                unsigned weight = least - 900;
                if (weight > 123) weight = 123;
                unsigned neutral = rgb[dst];
                if (rgb[dst+1] > neutral) neutral = rgb[dst+1];
                if (rgb[dst+2] > neutral) neutral = rgb[dst+2];
                for (int c = 0; c < 3; c++)
                    rgb[dst+c] = (uint8_t)((rgb[dst+c] * (123 - weight) +
                                            neutral * weight + 61) / 123);
            }
        }
    }
    free(pix);
    return 0;
}
