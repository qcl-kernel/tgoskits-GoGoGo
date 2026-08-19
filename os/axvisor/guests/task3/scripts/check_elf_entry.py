#!/usr/bin/env python3
"""Validate that an ELF entry address is inside RT-Thread QEMU RAM."""

from __future__ import annotations

import argparse


RAM_START = 0x40000000
RAM_END = 0x48000000


def parse_entry(text: str) -> int:
    try:
        entry = int(text, 0)
    except ValueError as error:
        raise ValueError(f"invalid ELF entry address: {text}") from error
    if not RAM_START <= entry < RAM_END:
        raise ValueError(
            f"ELF entry {text} is outside QEMU RAM "
            f"[0x{RAM_START:x}, 0x{RAM_END:x})"
        )
    return entry


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("entry")
    args = parser.parse_args()
    try:
        parse_entry(args.entry)
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
