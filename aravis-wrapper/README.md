# AIPC GigE Vision wrapper prototype

This directory contains a **working laptop and AIPC prototype** for one BZ-10 CAM0:

`BZCAMRAW v1/v2 packets → complete RAW10 frames → full-resolution RGB8 → Aravis fake GigE Vision camera`.

The stable Aravis 0.8 implementation is used as a library via its public
fake-camera fill callback. Aravis handles device discovery, GVCP, GenICam XML,
and GVSP packetization. See [PROTOCOL.md](PROTOCOL.md) for the exact interface
contract and current limitations. The laptop used Aravis 0.8.36 and the AIPC
used the NixOS Aravis 0.8.35 package. Board firmware is the separately
released BZCAMRAW v2 image.

For copy-and-run commands after reboot and live odd/even switching, see
[STARTUP_AIPC.md](STARTUP_AIPC.md).

## Build

Install a C compiler, `pkg-config`, and Aravis 0.8 development headers and
library on the AIPC. Then run `make` in this directory. `make test` builds and
tests the packet parser and RGB conversion without Aravis or privileges.
Aravis 0.8.36 was built from upstream tag `0.8.36` for the local laptop test;
the project does not vendor Aravis binaries.

On the tested NixOS AIPC, a temporary build environment works:

```sh
nix-shell -p gcc pkg-config aravis glib --run 'make test && make bz10_gige_wrapper'
```

The wrapper's live input needs `CAP_NET_RAW` (or root) to open AF_PACKET. Its
GigE Vision listener can bind to an AIPC IP or interface name. The control
agent is a separate small C program intended for the BZ-10 PS Linux system;
compile it for that target and run it with access to the trigger sysfs node.
The current board module path is
`/sys/bus/platform/devices/80040000.cam0-raw10g-trigger`.

## Laptop test without board or raw-socket permission

Generate two synthetic **v2** frames as a fixed-size L2 packet recording:

```sh
python3 synthetic_sender.py lo --version 2 --run-id 42 --frames 2 \
  --output /tmp/bz10-test.packets
./bz10_gige_wrapper --input replay:/tmp/bz10-test.packets \
  --listen 127.0.0.1 --control none --fps 50 \
  --metadata /tmp/bz10-gv-map.csv
```

In another terminal, run an Aravis 0.8 client:

```sh
arv-tool-0.8 --gv-discovery-interface=lo
arv-camera-test-0.8 --gv-discovery-interface=lo --duration=2 \
  --no-packet-socket --auto -r
```

`--auto` lets Aravis size its receive socket buffer for the large RGB8 frames.
Without it, a real 50-fps laptop loopback test lost GVSP packets even though
the BZ-10 input had no loss. `--input demo` generates RGB test frames without exercising the RAW packet
parser. The replay input uses the **same parser and RGB converter** as live
input; at end-of-file it loops the fixture, so the repeated frame IDs are
only for software testing. To try physical raw Ethernet input, use
`--input <SFP-interface>` instead of replay. The BZ-10 now sends v2 from its
SD-installed PL. Both laptop and AIPC optical-input/GigE-client paths have
been tested.

## Management cable and board control

On BZ-10, after compiling `bz10_control_agent` for its aarch64 Linux image:

```sh
./bz10_control_agent 192.168.50.2 5090 \
  /sys/bus/platform/devices/80040000.cam0-raw10g-trigger
```

On AIPC, attach the copper point-to-point management cable and pass
`--control 192.168.50.2:5090` to the wrapper. The management Ethernet is
independent of the 10G image input. `--control none` is only for an offline
simulation. A BZ-10 AArch64 build made with the PetaLinux 2025.2 sysroot is
saved as `bz10_control_agent_aarch64` (SHA-256
`3e5cb59c828fc551ef0c4e0762e9f0e53bc369a9c91a572404ad126327302ba3`).
It was smoke-tested over loopback and later copied through the AIPC management
cable into BZ-10 `/tmp`; the AIPC test used it bound to `192.168.50.2:5090`.
After the 2026-10-31 reboot, the verified binary was also placed at
`/home/root/bz10_control_agent` on BZ-10. It is **not** enabled as a boot
service, so its process must still be started after a BZ-10 reboot.

For the tested connection, BZ-10 `end0` is `192.168.50.2/24`, AIPC `eno1` is
`192.168.50.1/24`, and the FH1223 SFP4 optical link enters AIPC `ens1f0`.
The AIPC USB4 adapter (`DM7801BJ`) was initially present but unauthorized
under Thunderbolt `security=user`. Setting the attached device's
`authorized` sysfs value to `1` made the Intel 82599 ports `ens1f0` and
`ens1f1` enumerate; `ens1f0` then had 10 Gbps carrier. The sysfs device path
can change, and this authorization is not yet persisted.
For this particular attachment the one-time command was
`echo 1 | sudo tee /sys/bus/thunderbolt/devices/1-2/authorized`.

With the BZ-10 control agent running, start the wrapper on AIPC:

```sh
sudo ./bz10_gige_wrapper --input ens1f0 --listen 127.0.0.1 \
  --control 192.168.50.2:5090 --fps 50 --metadata /tmp/bz10_aipc_mapping.csv
```

An Aravis client on the same AIPC can discover and acquire it with:

```sh
nix-shell -p aravis --run 'arv-tool-0.8 --gv-discovery-interface=lo'
nix-shell -p aravis --run 'arv-camera-test-0.8 \
  --gv-discovery-interface=lo --duration=20 --no-packet-socket --auto -r'
```

## AIPC graphical preview with Aravis Viewer

The NixOS `aravis` package also includes the official `arv-viewer-0.8` GUI.
Its device list discovers the camera automatically when the wrapper listens
on AIPC's `eno1` address, rather than loopback:

```sh
sudo ./bz10_gige_wrapper --input ens1f0 --listen 192.168.50.1 \
  --control 192.168.50.2:5090 --fps 50 --metadata /tmp/bz10_viewer_mapping.csv
```

From the AIPC graphical desktop, launch:

```sh
nix-shell -p aravis --run 'arv-viewer-0.8 --auto-buffer-size --no-packet-resend'
```

Select `Aravis-Fake-BZ10-CAM0` and press Play. The wrapper sends `FPS 50` and
`START` to BZ-10; Stop sends `STOP`. On 2026-10-30, the AIPC viewer displayed
**50 fps and 0 errors** while BZ-10 reported `run=1 fps=50` and the wrapper
metadata file grew with delivered frames. After Stop, BZ-10 returned to
`run=0 fps=50`. Two Play/Stop cycles produced run IDs 9 and 10, each with
input frame IDs restarting at 1. This GUI path uses the same receiver and
RGB conversion as the command-line test.

The parity-capable wrapper accepts `--parity-file` and reads `all`, `odd`, or
`even` from that file at each complete input frame. For the deployed AIPC
instance, switch the one Viewer image while it is playing with:

```sh
bash /home/lumi/bz10-camera-wrapper/set_preview_parity.sh odd
bash /home/lumi/bz10-camera-wrapper/set_preview_parity.sh even
bash /home/lumi/bz10-camera-wrapper/set_preview_parity.sh all
```

The BZ-10 still triggers at 50 Hz; odd/even views each publish approximately
25 fps. Filtering uses BZCAMRAW v2 input `frame_id`, not the independent GVSP
frame ID. V1 input lacks reliable run parity and produces no selected frames
in odd/even mode.

## Recovery after reboot (checked 2026-10-31)

The AIPC `eno1` static address and SSH firewall setting survived reboot.
The USB4 adapter returned to `authorized=0`, and the wrapper and Viewer
processes were gone. BZ-10 had lost its previous `/tmp` copy and control
process; this recovery placed the binary in `/home/root` for future boots.
The trigger module reported `run=1` after the BZ-10 reboot, so stop it before
reconnecting a preview client.

On BZ-10, run:

```sh
echo 0 > /sys/bus/platform/devices/80040000.cam0-raw10g-trigger/run
systemd-run --unit=bz10-camera-control --collect \
  /home/root/bz10_control_agent 192.168.50.2 5090 \
  /sys/bus/platform/devices/80040000.cam0-raw10g-trigger
```

On AIPC, verify the USB4 device path and authorize the attached `DM7801BJ`.
For the tested port it was `1-2`; the path may change after moving the cable:

```sh
cat /sys/bus/thunderbolt/devices/1-2/device_name
echo 1 | sudo tee /sys/bus/thunderbolt/devices/1-2/authorized
ip -br link show ens1f0
printf 'all\n' > /home/lumi/bz10-camera-wrapper/preview-parity.txt
sudo systemd-run --unit=bz10-gige-wrapper --collect \
  /home/lumi/bz10-camera-wrapper/bz10_gige_wrapper \
  --input ens1f0 --listen 192.168.50.1 \
  --control 192.168.50.2:5090 --fps 50 \
  --parity-file /home/lumi/bz10-camera-wrapper/preview-parity.txt \
  --metadata /tmp/bz10_viewer_mapping.csv
nix-shell -p aravis --run 'arv-viewer-0.8 --auto-buffer-size --no-packet-resend'
```

The board agent and AIPC wrapper above are transient systemd units: they
survive SSH disconnection but are not enabled for the next boot. Viewer Play
starts acquisition; Viewer Stop returns BZ-10 to `run=0`.
After this recovery, a two-second Aravis client check completed 100 RGB8
frames at 50 fps with zero failures and zero missing GVSP packets.

On 2026-10-31, a single uninterrupted real optical acquisition switched
`all → odd → even` by updating the parity file. Aravis showed about 50 fps
before filtering and about 25 fps afterward, with 472 completed RGB8 buffers,
0 failures, and 0 missing GVSP packets. The CSV map showed a sustained
consecutive-ID interval, then odd-only IDs stepping by two, then even-only
IDs stepping by two. J5 high/low alignment with CSI SOF was not measured
simultaneously in this test.

## Test evidence and remaining gates

- `make test`: v1/v2 packet parsing, complete-frame assembly, duplicate and
  missing-frame accounting, and a BGGR test pattern passed. The C RGB output
  was also compared pixel by pixel with the existing 1280×1024 Python preview
  on a random RAW10 image: maximum difference **0**.
- On this laptop, one-frame RGB conversion measured approximately **303
  fps** in a 20-frame microbenchmark. This measures conversion alone.
- Locally built Aravis 0.8.36 discovered the simulator as
  `Aravis-Fake-BZ10-CAM0`. A two-second `demo` test produced 93 complete
  RGB8 frames, 0 failures in one run; a full synthetic packet-replay test
  produced 78 complete frames and 2 failures with default 1400-byte GVSP
  packets in one run. The client validated width 1280, height 1024, RGB8,
  and 3,932,160 bytes per image. These short loopback tests do **not** prove
  sustained 50 fps on the AIPC or real 10G output.
- The control agent's `STATUS`, `FPS`, `START`, `STOP`, and refusal to change
  FPS while running passed against mock sysfs files. Aravis client
  `AcquisitionStart`/`Stop` changed the same mock `run` file through the
  wrapper. On BZ-10 itself, the UART-uploaded agent returned `OK` for
  `FPS 50`, `START`, and `STOP`; `STATUS` reported `run=1` after start and
  `run=0` after stop. The temporary loopback agent was then stopped.
- The installed BZ-10 SD firmware now transmits v2. It was reboot-verified:
  two 50-Hz runs each restarted frame ID at 1 and incremented run ID, with
  six complete frames and no socket drops. See
  `../../release/bz10-cam0-raw10g-external-trigger-v2-20261030/README.md`.
  The laptop wrapper was then tested with real optical input. The Aravis
  fake camera's advertised GenICam features must be restricted to the
  supported fixed RGB8 format before general client deployment.
- Real 50-Hz laptop test with BZ-10 optical input: the wrapper assembled
  **201/201** RAW10 frames, with 0 socket drops, incomplete frames, missing
  IDs, malformed packets, or duplicates in each of two runs. Aravis discovered
  `Aravis-Fake-BZ10-CAM0` and read 1280×1024 RGB8 frames. Without client
  `--auto`, it completed 162 buffers with 9 failures and 12,800 missing GVSP
  packets. With `--auto`, it completed 137 buffers at steady 50 fps with
  **0 failures and 0 missing GVSP packets**. The client acquisition window
  covered only part of the four-second board run. These are short laptop
  loopback tests. The AIPC and management-cable results are below.

## AIPC end-to-end result (2026-10-30)

- AIPC Aravis discovered `Aravis-Fake-BZ10-CAM0` on loopback. Its 20-second
  50-Hz run completed **1001 RGB8 buffers** at 1280×1024 with **0 failures,
  0 missing GVSP packets**, and 0 resend requests. A four-second run completed
  200 buffers with the same zero-error counters.
- The wrapper assembled **1001/1001 complete RAW10 frames** with **0 socket
  drops, incomplete frames, missing input frame IDs, malformed fragments, or
  duplicates**. It sent 1001 frames to Aravis. A CPU sample during the run
  showed about 44% for the wrapper process and 26 MiB resident memory.
- Input metadata recorded run ID 7 and consecutive input frame IDs 1–1001;
  `odd_expected_high` alternated 1, 0, 1, … . Aravis acquisition start and
  stop drove the BZ-10 agent; afterward `STATUS` returned `OK run=0 fps=50`.
  This parity field is derived from the PL counter; J5 level and CSI SOF were
  not probed simultaneously in this AIPC run.
- A one-frame Aravis capture produced a real 1280×1024 RGB8 image. The
  current scene contains saturated bright areas and the camera is physically
  inverted; this establishes image delivery, not final color or orientation
  tuning.
- The AIPC kernel reported the USB4 adapter's PCIe path as 2.0 Gb/s
  available bandwidth (2.5 GT/s x1). That is above the approximately
  0.66 Gb/s packed RAW10 input at 50 Hz, but constrains future higher-rate
  or multi-camera designs.

The default GVSP packet size is 1400 bytes. `--gv-packet-size` is available
for isolated MTU tuning; 8192-byte packets performed **worse** in one laptop
loopback test, so do not assume jumbo packets improve the target system.
