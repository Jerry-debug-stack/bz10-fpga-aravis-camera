#!/usr/bin/env bash
# Change the single Aravis preview without restarting the camera or wrapper.
set -euo pipefail

case ${1:-} in
    all|odd|even) ;;
    *) echo 'usage: set_preview_parity.sh all|odd|even' >&2; exit 2 ;;
esac

camera_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
printf '%s\n' "$1" > "$camera_dir/preview-parity.txt"
echo "Preview: $1 (BZ-10 trigger remains 50 Hz)"
