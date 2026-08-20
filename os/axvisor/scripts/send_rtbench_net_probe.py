#!/usr/bin/env python3
"""Send timestamp-test UDP probes through a QEMU user-network forward."""

import argparse
import socket
import struct
import time


MAGIC = 0x5254424E
READY = 0xFFFFFFFF


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--interval-us", type=int, default=2000)
    parser.add_argument("--ack-timeout-ms", type=int, default=1000)
    parser.add_argument(
        "--retries",
        type=int,
        default=16,
        help="additional attempts after the first send (default: 16)",
    )
    args = parser.parse_args()
    if not 1 <= args.count <= 100000 or not 1 <= args.port <= 65535:
        parser.error("count must be 1..100000 and port must be 1..65535")
    if args.interval_us < 0 or args.ack_timeout_ms <= 0:
        parser.error("interval-us must be non-negative and ack-timeout-ms positive")
    if not 0 <= args.retries <= 64:
        parser.error("retries must be 0..64")

    print(
        f"RTBENCH_NET_PROBE_BEGIN target={args.host}:{args.port} "
        f"count={args.count} interval_us={args.interval_us}",
        flush=True,
    )
    address = (args.host, args.port)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(args.ack_timeout_ms / 1000)
        sock.sendto(struct.pack("!II", MAGIC, READY), address)
        time.sleep(max(args.interval_us, 1000) / 1_000_000)
        retries = 0
        for sequence in range(args.count):
            payload = struct.pack("!II", MAGIC, sequence)
            acknowledged = False
            for _ in range(args.retries + 1):
                sock.sendto(payload, address)
                try:
                    ack, _ = sock.recvfrom(8)
                except socket.timeout:
                    retries += 1
                    continue
                if ack == payload:
                    acknowledged = True
                    break
            if not acknowledged:
                raise RuntimeError(f"probe sequence {sequence} was not acknowledged")
            if args.interval_us:
                time.sleep(args.interval_us / 1_000_000)
    print(
        f"RTBENCH_NET_PROBE_END sent={args.count} retries={retries}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
