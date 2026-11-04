#!/usr/bin/env python3
"""Inject test BZCAMRAW packets on a Linux interface; no camera is required."""
import argparse
import socket
import struct
import time

WIDTH, HEIGHT = 1280, 1024
RAW_BYTES = WIDTH * HEIGHT * 5 // 4
FRAGMENT = 1024
L2 = bytes.fromhex("ffffffffffff02000000000488b5")


def image() -> bytes:
    # Repeating BGGR scene: blue=100, green=300, red=500.
    def pack(values):
        bits = sum(v << (10 * i) for i, v in enumerate(values))
        return bits.to_bytes(5, "little")
    even = pack((100, 300, 100, 300)) * (WIDTH // 4)
    odd = pack((300, 500, 300, 500)) * (WIDTH // 4)
    return (even + odd) * (HEIGHT // 2)


def packet(version: int, run_id: int, frame_id: int,
           offset: int, raw: bytes) -> bytes:
    head = struct.pack("<8sHHIIIHHHHH", b"BZCAMRAW", version, 0,
                       frame_id, offset, RAW_BYTES, FRAGMENT,
                       WIDTH, HEIGHT, run_id & 0xffff, run_id >> 16)
    assert len(head) == 34
    return L2 + head + raw[offset:offset + FRAGMENT]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("interface")
    ap.add_argument("--version", type=int, choices=(1, 2), default=2)
    ap.add_argument("--run-id", type=int, default=1)
    ap.add_argument("--frames", type=int, default=50)
    ap.add_argument("--fps", type=float, default=5)
    ap.add_argument("--output", help="write fixed-size L2 packets to a file instead of sending")
    args = ap.parse_args()
    if args.frames < 1 or args.fps <= 0 or not 0 <= args.run_id <= 0xffffffff:
        ap.error("invalid frame count, fps, or run ID")
    run_id = args.run_id if args.version == 2 else 0
    if args.version == 2 and run_id == 0:
        ap.error("v2 requires nonzero run ID")
    raw = image()
    assert len(raw) == RAW_BYTES
    sock = None
    output = None
    if args.output:
        output = open(args.output, "xb")
    else:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88b5))
        sock.bind((args.interface, 0))
    deadline = time.monotonic()
    for frame_id in range(1, args.frames + 1):
        for offset in range(0, RAW_BYTES, FRAGMENT):
            data = packet(args.version, run_id, frame_id, offset, raw)
            if output:
                output.write(data)
            else:
                sock.send(data)
        deadline += 1 / args.fps
        if not output:
            time.sleep(max(0, deadline - time.monotonic()))
    if output:
        output.close()
    print(f"sent {args.frames} frames, {args.frames * RAW_BYTES // FRAGMENT} packets")


if __name__ == "__main__":
    main()
