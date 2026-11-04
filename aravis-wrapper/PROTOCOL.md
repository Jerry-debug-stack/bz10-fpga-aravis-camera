# BZ-10 → AIPC → GigE Vision contract (draft, 2026-10-30)

## Physical paths

- BZ-10 FH1223 10G → AIPC SFP input: best-effort raw Ethernet EtherType
  `0x88b5`. No IP, TCP, ACK, or resend on this path.
- AIPC copper Ethernet → BZ-10 PS management Ethernet: control only. The
  `bz10_control_agent` accepts one line per TCP connection on a dedicated
  point-to-point address. It writes the existing trigger module's sysfs files.
- AIPC's GigE Vision listener → downstream Aravis/GenICam client: GVCP for
  discovery/control and GVSP for RGB8 frames. This may be loopback for local
  inference or a separate AIPC output NIC for a remote consumer.

## Previous input v1 (compatibility)

Each image is 1280×1024 packed RAW10 = 1,638,400 bytes, sent as 1600 Ethernet
packets. Each packet is exactly 1072 bytes excluding Ethernet FCS: 14-byte
Ethernet header, 34-byte `BZCAMRAW` header, and 1024-byte image fragment.
The 34-byte header is little-endian after its 8-byte ASCII magic:

| Offset from Ethernet payload | Bytes | Field | v1 |
| ---: | ---: | --- | --- |
| 0 | 8 | magic | `BZCAMRAW` |
| 8 | 2 | version | `1` |
| 10 | 2 | flags | `0` |
| 12 | 4 | frame_id | increments at accepted CSI SOF; not reset by `run=1` |
| 16 | 4 | byte_offset | 0, 1024, …, 1,637,376 |
| 20 | 4 | frame_size | 1,638,400 |
| 24 | 2 | fragment_size | 1024 |
| 26 | 2 | width | 1280 |
| 28 | 2 | height | 1024 |
| 30 | 2 | reserved0 | 0 |
| 32 | 2 | reserved1 | 0 |

The wrapper accepts v1 for older hardware. V1 has no reliable per-run
odd/even mapping, run ID, or acquisition timestamp.

## Current input v2 (SD-installed on BZ-10)

- Keep the same packet size, payload packing, and all offsets.
- Set `version=2`. Interpret bytes 30..33 as one nonzero, little-endian
  `run_id:u32`. Increment `run_id` once for each **accepted PL start event**;
  skip zero on wrap. It may reset when the PL is reconfigured.
- Reset the packetizer's per-run frame counter at that same accepted start.
  The first **newly triggered** frame's CSI SOF receives `frame_id=1`, the
  next receives `2`, etc. Reserve `frame_id=0` as invalid/no frame; software
  needing a zero-based array index uses `frame_id-1`. All fragments of one
  image carry the same pair `(run_id, frame_id)`. The counter must be 32-bit;
  the trigger scheduler's
  14-bit debug count is insufficient for continuous acquisition.
- The J5 parity output is high for odd trigger ordinals and low for even.
  After sensor trigger-to-SOF alignment is physically verified, odd
  `frame_id` means high, even means low. A lost image does not change the
  classification of later images.
- A restart must prevent old in-flight CSI/FIFO packets from being assigned
  the new run ID. Either drain/flush before the start is accepted or tag the
  old frame in the pipeline with the old run ID. The AIPC receiver groups by
  `(version, run_id, frame_id)` and publishes only 1600-fragment frames.

The v2 bitstream was installed on BZ-10's SD root partition on 2026-10-30.
After reboot, the optical receiver measured `run=1/frame=1..3` and
`run=2/frame=1..3`, with all six frames complete and no socket drops.
Separate continuous-mode JTAG tests saw run IDs 3 and 4 each restart at
frame 1. The physical trigger-to-SOF and J5 level alignment was not measured
simultaneously in these packet tests; `odd_expected_high` remains an expected
polarity derived from the PL design.

## Control TCP contract

The control agent binds the BZ-10 management IP only. One ASCII request and
one ASCII response per TCP connection, newline terminated:

| Request | Effect | Response |
| --- | --- | --- |
| `FPS 50` | write `fps` while `run=0`; accepted range 16..240 | `OK` or `ERR` |
| `START` | write `frames=-1`, then `run=1` | `OK` or `ERR` |
| `STOP` | write `run=0`; in-flight image may finish | `OK` or `ERR` |
| `STATUS` | read `run`, `fps` | `OK run=… fps=…` or `ERR` |

The GigE Vision wrapper sends `FPS` then `START` on an
`AcquisitionStop`→`AcquisitionStart` transition and sends `STOP` on the reverse
transition. Its simulated camera is driven only by **new complete input
frames**: no output frame is generated merely because a timer elapsed. Input
or downstream overload drops frames and favors the newest complete frame.
The agent has no authentication; bind it to the dedicated point-to-point IP
and keep that network isolated. Repeated `AcquisitionStart` while already
active is not currently detected by the wrapper as a fresh start command.

## Downstream image and metadata

- GigE Vision image: `RGB8`, 1280×1024, 3,932,160 bytes/frame. The source
  packed RAW10 is unpacked, debayered at full resolution, corrected with the
  previously qualified BGGR white-balance/display profile, and sent as RGB.
- At 50 fps, input image payload is 81.92 MB/s and output RGB payload is
  196.608 MB/s before transport overhead. A 1G output link cannot sustain
  full-resolution RGB8 at 50 fps; use local AIPC inference or 10G output.
- Aravis fake camera assigns its own 16-bit GVSP frame ID. Optional
  `--metadata path.csv` records
  `gvsp_frame_id,input_version,run_id,input_frame_id,odd_expected_high` for
  frames handed to its GVSP sender. `odd_expected_high=-1` on v1 means
  **unknown**;
  only v2 permits parity interpretation. The sidecar is a prototype mapping,
  not a GenICam chunk feature. A receiver can still lose a GVSP frame after
  this record is made.
- The AIPC preview wrapper may read `all`, `odd`, or `even` from its
  `--parity-file` at each completed BZCAMRAW v2 input frame. Odd/even selection
  tests the **input** `frame_id` before RAW10-to-RGB conversion, while BZ-10
  keeps triggering and transmitting every frame. At 50 input fps, one parity
  gives about 25 preview fps. This is display selection, not a change to the
  J5 waveform or an independent physical measurement of J5 versus CSI SOF.
- The Aravis fake camera's stock GenICam XML exposes some settings (e.g.
  other image geometries/pixel formats) that this fixed-profile wrapper does
  not support. The prototype is interoperable for the tested RGB8/default
  configuration; restrict the XML feature set before product use.
