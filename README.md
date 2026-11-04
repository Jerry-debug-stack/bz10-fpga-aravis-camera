# BZ-10 FPGA Camera to Aravis

Source for the FPGA camera data path and its Aravis/GigE Vision adapter. The
repository is scoped to **one SC130GS camera on BZ-10 FMC3/J1**. It contains no
model, model configuration, training code, dataset, robot calibration, or
LeRobot runtime.

## Data path

```text
SC130GS --MIPI CSI-2--> BZ-10 PL --raw 10G Ethernet--> FH1223 SFP+
          BZ-10 PS control <----1G management---- AIPC
FH1223 SFP+ --> AIPC raw-frame receiver --> RGB8 --> Aravis fake GigE Vision camera
```

The PL uses the AMD/Xilinx MIPI CSI-2 receiver IP. It sends fixed-size RAW10
fragments with `run_id` and `frame_id`, without waiting for the AIPC. The AIPC
adapter accepts complete frames, converts them to RGB8, and supplies them to
Aravis. Aravis provides GigE Vision discovery, control, and stream delivery.
An acquisition start/stop request is relayed over the separate management link
to the BZ-10 trigger controller. See [the protocol](aravis-wrapper/PROTOCOL.md)
for the packet and control contracts.

The verified end-to-end configuration is one camera at 50 fps. Higher camera
rates and multiple cameras are outside this repository's verified scope.

## Contents

| Path | Purpose |
| --- | --- |
| `fpga/` | Vivado 2025.2 RTL, constraints, IP generation and build scripts |
| `board/kernel/` | Linux control module and device-tree source for PL trigger registers |
| `board/startup/` | Source of the tested PL0 clock setup helper |
| `aravis-wrapper/` | Raw-frame receiver, RGB conversion, Aravis adapter, board control agent, and tests |

`fpga/verilog-ethernet/` is a snapshot of the upstream Verilog Ethernet project
at commit `77320a9471d19c7dd383914bc049e02d9f4f1ffb` and retains its
[MIT license](fpga/verilog-ethernet/COPYING). The GigE Vision implementation
itself is provided by the external Aravis 0.8 library.

## Build

The FPGA build requires Vivado 2025.2 and the target BZ-10 device support:

```sh
cd fpga
vivado -mode batch -source create_project.tcl
vivado -mode batch -source generate_ip.tcl
vivado -mode batch -source build.tcl
bootgen -arch zynqmp -image trigger_fpga_manager.bif -process_bitstream bin -w on
```

The scripts write generated files to `fpga/out/`. The board control module
must be built against the *matching* BZ-10 Linux kernel:

```sh
make -C board/kernel KERNEL_SRC=/path/to/matching/kernel/build
```

The AIPC build requires a C compiler, `pkg-config`, and Aravis 0.8 development
headers. The parser/converter test only requires a C compiler:

```sh
make -C aravis-wrapper test
make -C aravis-wrapper
```

## Run

Boot BZ-10 with a compatible Linux image, load the matching FPGA image and
device-tree overlay, then load `bz10_cam0_ctl.ko`. Start the control agent on
the board and the adapter on the AIPC (substitute your own interface names and
addresses):

```sh
# BZ-10
./bz10_control_agent 192.168.50.2 5090 \
  /sys/bus/platform/devices/80040000.cam0-raw10g-trigger

# AIPC
sudo ./bz10_gige_wrapper --input ens1f0 --listen 192.168.50.1 \
  --control 192.168.50.2:5090 --fps 50
```

Open an Aravis 0.8 viewer/client on the AIPC and select the fake BZ-10 camera.
Starting acquisition starts the board; stopping acquisition stops it. The
management protocol is intended for a dedicated point-to-point network.

For the tested AIPC boot procedure and odd/even preview selector, see
[STARTUP_AIPC.md](aravis-wrapper/STARTUP_AIPC.md). This repository provides
source, not an SD-card image or a built bitstream.
