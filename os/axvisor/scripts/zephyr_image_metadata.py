#!/usr/bin/env python3
"""Validate sidecar metadata for the AxVisor Zephyr Task123 image."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SCHEMA = 1


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read Zephyr metadata {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"Zephyr metadata root must be an object: {path}")
    return value


def write(args: argparse.Namespace) -> None:
    image = Path(args.image)
    metadata = Path(args.output)
    payload = image.read_bytes()
    source = load_json(Path(args.source))
    record = {
        "schema": SCHEMA,
        "rtos": "zephyr",
        "image_sha256": hashlib.sha256(payload).hexdigest(),
        "image_size": len(payload),
        "entry_point": source["entry_point"],
        "zephyr_version": source["zephyr_version"],
        "zephyr_commit": source["zephyr_commit"],
        "zephyr_sdk_version": source["zephyr_sdk_version"],
        "board": source["board"],
        "virtio_net": True,
        "real_spi_interrupt": True,
    }
    if isinstance(source.get("board_target"), str):
        record["board_target"] = source["board_target"]
    metadata.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"ZEPHYR_IMAGE_METADATA_WRITTEN {metadata}")


def check(args: argparse.Namespace) -> None:
    image = Path(args.image)
    metadata_path = Path(args.metadata)
    if not image.is_file():
        raise SystemExit(f"Zephyr image does not exist: {image}")
    if not metadata_path.is_file():
        raise SystemExit(
            f"metadata is missing for {image}; expected {metadata_path}. "
            "rebuild Zephyr with the pinned AxVisor builder"
        )
    record = load_json(metadata_path)
    payload = image.read_bytes()
    if record.get("schema") != SCHEMA or record.get("rtos") != "zephyr":
        raise SystemExit(f"unsupported Zephyr metadata schema: {metadata_path}")
    if record.get("image_sha256") != hashlib.sha256(payload).hexdigest():
        raise SystemExit(f"Zephyr image SHA-256 mismatch: {image}")
    if record.get("image_size") != len(payload):
        raise SystemExit(f"Zephyr image size mismatch: {image}")
    if not isinstance(record.get("entry_point"), int):
        raise SystemExit("Zephyr entry point is invalid")
    for key in ("zephyr_version", "zephyr_commit", "zephyr_sdk_version", "board"):
        if not isinstance(record.get(key), str) or not record[key]:
            raise SystemExit(f"Zephyr metadata field is invalid: {key}")
    if args.board_target is not None and record.get("board_target") != args.board_target:
        raise SystemExit(
            "Zephyr image board target mismatch: "
            f"expected {args.board_target}, got {record.get('board_target')}"
        )
    if record.get("virtio_net") is not True or record.get("real_spi_interrupt") is not True:
        raise SystemExit("Zephyr image does not record the required real virtio IRQ build")
    print(f"ZEPHYR_IMAGE_METADATA_OK {image}")


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser()
    subcommands = command.add_subparsers(dest="action", required=True)
    writer = subcommands.add_parser("write")
    writer.add_argument("--image", required=True)
    writer.add_argument("--source", required=True)
    writer.add_argument("--output", required=True)
    writer.set_defaults(function=write)
    checker = subcommands.add_parser("check")
    checker.add_argument("--image", required=True)
    checker.add_argument("--metadata", required=True)
    checker.add_argument("--board-target")
    checker.set_defaults(function=check)
    return command


def main() -> None:
    args = parser().parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
