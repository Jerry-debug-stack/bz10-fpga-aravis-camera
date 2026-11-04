#!/usr/bin/env bash
# Run on the AIPC after both machines boot. Starts control and wrapper only;
# the camera remains stopped until an Aravis client presses Play.
set -euo pipefail

camera_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
selector=$camera_dir/preview-parity.txt
trigger=/sys/bus/platform/devices/80040000.cam0-raw10g-trigger

if ! ip -4 -br addr show eno1 | grep -q '192\.168\.50\.1/24'; then
    nmcli connection up bz10-control
fi
ping -c 1 -W 1 192.168.50.2

adapter=
for device in /sys/bus/thunderbolt/devices/*; do
    if [[ -r $device/device_name && $(cat "$device/device_name") == DM7801BJ ]]; then
        adapter=$device
        break
    fi
done
if [[ -z $adapter ]]; then
    echo 'DM7801BJ USB4-to-SFP adapter was not found' >&2
    exit 1
fi
if [[ $(cat "$adapter/authorized") != 1 ]]; then
    printf '1\n' | sudo tee "$adapter/authorized" >/dev/null
fi
if [[ $(cat /sys/class/net/ens1f0/carrier) != 1 ]]; then
    echo 'ens1f0 has no optical carrier' >&2
    exit 1
fi

# The BZ-10 root password is entered interactively; none is stored here.
ssh root@192.168.50.2 \
    "if ! systemctl is-active --quiet bz10-camera-control; then
         echo 0 > $trigger/run
         systemd-run --unit=bz10-camera-control --collect /home/root/bz10_control_agent 192.168.50.2 5090 $trigger
     fi"
control_status=
for attempt in 1 2 3 4 5; do
    control_status=$(printf 'STATUS\n' | nc -N -w 2 192.168.50.2 5090) || true
    [[ $control_status == OK\ * ]] && break
    sleep 1
done
if [[ $control_status != OK\ * ]]; then
    echo "BZ-10 control agent did not become ready: $control_status" >&2
    exit 1
fi
echo "$control_status"

if [[ ! -x $camera_dir/bz10_gige_wrapper ]]; then
    echo "Missing $camera_dir/bz10_gige_wrapper" >&2
    exit 1
fi
if ! systemctl is-active --quiet bz10-gige-wrapper; then
    printf 'all\n' > "$selector"
    metadata=/tmp/bz10_viewer_$(date +%Y%m%d_%H%M%S).csv
    sudo systemd-run --unit=bz10-gige-wrapper --collect \
        "$camera_dir/bz10_gige_wrapper" \
        --input ens1f0 --listen 192.168.50.1 \
        --control 192.168.50.2:5090 --fps 50 \
        --parity-file "$selector" --metadata "$metadata"
fi

echo 'Ready. Open Aravis Viewer; Play starts BZ-10, Stop stops it.'
echo "Preview mode file: $selector (all, odd, or even)"
