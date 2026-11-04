#!/bin/sh
# Run only before loading the BZ10 CAM0 clockfix bitstream.  This changes
# PL0_REF_CTRL alone; it does not change the IOPLL or other PS clock users.
set -eu

ctrl=$(devmem 0xFF5E00C0 32)
iopll=$(devmem 0xFF5E0020 32)
status=$(devmem 0xFF5E0040 32)
case "$ctrl" in
    0x01010F00|0x01010f00)
        printf 'PL0 already uses IOPLL / 15 (100 MHz)\n'
        exit 0
        ;;
    0x01010B02|0x01010b02|0x00010B02|0x00010b02) ;;
    *)
        printf 'Unexpected PL0_REF_CTRL=%s; refusing to change it\n' "$ctrl" >&2
        exit 1
        ;;
esac
if [ $((status & 1)) -ne 1 ] || [ $((iopll & 8)) -ne 0 ]; then
    printf 'IOPLL is not locked or is bypassed: ctrl=%s status=%s\n' "$iopll" "$status" >&2
    exit 1
fi
devmem 0xFF5E00C0 32 0x01010F00
after=$(devmem 0xFF5E00C0 32)
case "$after" in
    0x01010F00|0x01010f00) printf 'PL0 switched to IOPLL / 15 (100 MHz)\n' ;;
    *) printf 'PL0 write verification failed: %s\n' "$after" >&2; exit 1 ;;
esac
