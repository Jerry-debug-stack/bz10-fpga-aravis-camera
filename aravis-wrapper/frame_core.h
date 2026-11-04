#ifndef BZ10_FRAME_CORE_H
#define BZ10_FRAME_CORE_H

#include <stddef.h>
#include <stdint.h>

enum {
    BZ_WIDTH = 1280, BZ_HEIGHT = 1024,
    BZ_RAW_BYTES = BZ_WIDTH * BZ_HEIGHT * 5 / 4,
    BZ_RGB_BYTES = BZ_WIDTH * BZ_HEIGHT * 3,
    BZ_FRAGMENT_BYTES = 1024,
    BZ_FRAGMENTS = BZ_RAW_BYTES / BZ_FRAGMENT_BYTES,
    BZ_L2_BYTES = 14 + 34 + BZ_FRAGMENT_BYTES
};

typedef struct {
    uint16_t version;
    uint32_t run_id;
    uint32_t frame_id;
    uint32_t byte_offset;
    const uint8_t *payload;
} BzFragment;

typedef struct {
    uint16_t version;
    uint32_t run_id;
    uint32_t frame_id;
} BzFrameKey;

typedef struct {
    uint8_t *raw;
    uint8_t seen[BZ_FRAGMENTS];
    BzFrameKey key;
    unsigned received;
    int active;
    uint64_t complete;
    uint64_t incomplete;
    uint64_t malformed;
    uint64_t duplicates;
    uint64_t missing_ids;
} BzAssembler;

int bz_parse_packet(const uint8_t *packet, size_t len, BzFragment *out);
int bz_assembler_init(BzAssembler *a);
void bz_assembler_destroy(BzAssembler *a);
/* Returns 1 exactly once for a complete frame, 0 otherwise, -1 if malformed. */
int bz_assembler_push(BzAssembler *a, const uint8_t *packet, size_t len,
                      BzFrameKey *completed);
/* RGB output is interleaved R,G,B at the original 1280x1024 resolution. */
int bz_raw10_to_rgb8(const uint8_t *raw, uint8_t *rgb);

#endif
