#!/usr/bin/env python3
"""Create and validate the sidecar metadata for an AxVisor RT-Thread image."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


SCHEMA = 1
EXPECTED_VENDOR_ID = "0x554d4551"
EXPECTED_IRQ = 48
BUILD_INPUT_TREES = (
    "os/axvisor/patches/rtthread",
    "os/axvisor/guests/rt-ipc/common",
    "os/axvisor/guests/rt-ipc/rtthread",
    "os/axvisor/guests/task3/src/common",
    "os/axvisor/guests/task3/src/rtthread",
    "os/axvisor/guests/rt-benchmark/rtthread",
)


def fail(message: str) -> "NoReturn":
    print(f"rtthread image metadata: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot read image {path}: {error}")
    return digest.hexdigest()


def source_commit(source: Path) -> str:
    marker = source / ".axvisor-rtthread-source-commit"
    if marker.is_file():
        value = marker.read_text(encoding="utf-8").strip()
        if value:
            return value
    try:
        result = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot determine RT-Thread source commit from {source}: {error}")
    value = result.stdout.strip()
    if not value:
        fail(f"RT-Thread source commit is empty: {source}")
    return value


def patch_digest(source: Path, supplied: str | None) -> str:
    if supplied is not None:
        value = supplied.strip()
    else:
        state = source / ".axvisor-rtthread-patch-state"
        try:
            value = state.read_text(encoding="utf-8").strip()
        except OSError as error:
            fail(f"cannot read patch-set state {state}: {error}")
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        # Test fixtures may use a symbolic value; production patch states are SHA-256.
        if supplied is None:
            fail(f"invalid patch-set digest in {source / '.axvisor-rtthread-patch-state'}")
    return value


def input_digest(value: str) -> str:
    digest = value.strip()
    if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        fail("RT-Thread build input digest must be a lowercase SHA-256 value")
    return digest


def calculate_input_digest(root: Path) -> str:
    digest = hashlib.sha256()
    root = root.resolve()
    for relative_tree in BUILD_INPUT_TREES:
        tree = root / relative_tree
        if not tree.is_dir():
            fail(f"RT-Thread build input tree is missing: {tree}")
        files = sorted(path for path in tree.rglob("*") if path.is_file())
        if not files:
            fail(f"RT-Thread build input tree is empty: {tree}")
        for path in files:
            relative_path = path.relative_to(root).as_posix().encode("utf-8")
            digest.update(len(relative_path).to_bytes(8, "big"))
            digest.update(relative_path)
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def print_input_digest(args: argparse.Namespace) -> None:
    print(calculate_input_digest(Path(args.root)))


def read_metadata(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read metadata {path}: {error}")
    if not isinstance(value, dict):
        fail(f"metadata root must be an object: {path}")
    return value


def require_image(path: Path) -> None:
    if not path.is_file():
        fail(f"RT-Thread image does not exist: {path}")


def write_metadata(args: argparse.Namespace) -> None:
    image = Path(args.image).resolve()
    source = Path(args.source).resolve()
    output = Path(args.output).resolve()
    require_image(image)
    if not source.is_dir():
        fail(f"RT-Thread source directory does not exist: {source}")
    digest = patch_digest(source, args.patch_digest)
    metadata = {
        "schema": SCHEMA,
        "image": {
            "sha256": sha256_file(image),
            "size": image.stat().st_size,
        },
        "source": {"commit": source_commit(source)},
        "patch_set_sha256": digest,
        "build_inputs_sha256": input_digest(args.input_digest),
        "virtio": {"vendor_id": EXPECTED_VENDOR_ID, "irq": EXPECTED_IRQ},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"RTTHREAD_IMAGE_METADATA_WRITTEN {output}")


def check_metadata(args: argparse.Namespace) -> None:
    image = Path(args.image).resolve()
    metadata_path = Path(args.metadata).resolve()
    require_image(image)
    if not metadata_path.is_file():
        fail(
            f"metadata is missing for {image}; expected {metadata_path}. "
            "rebuild RT-Thread with the current AxVisor patch set"
        )
    metadata = read_metadata(metadata_path)
    if metadata.get("schema") != SCHEMA:
        fail(f"unsupported metadata schema in {metadata_path}")

    image_data = metadata.get("image")
    if not isinstance(image_data, dict):
        fail(f"metadata image section is invalid: {metadata_path}")
    actual_digest = sha256_file(image)
    if image_data.get("sha256") != actual_digest:
        fail(
            f"image SHA-256 mismatch for {image}; metadata={image_data.get('sha256')}, "
            f"actual={actual_digest}"
        )
    if image_data.get("size") != image.stat().st_size:
        fail(f"image size mismatch for {image}")

    virtio = metadata.get("virtio")
    if not isinstance(virtio, dict):
        fail(f"metadata virtio section is invalid: {metadata_path}")
    if virtio.get("vendor_id") != EXPECTED_VENDOR_ID:
        fail(
            f"incompatible virtio vendor ID: {virtio.get('vendor_id')}; "
            f"expected {EXPECTED_VENDOR_ID}"
        )
    if virtio.get("irq") != EXPECTED_IRQ:
        fail(f"incompatible virtio IRQ: {virtio.get('irq')}; expected {EXPECTED_IRQ}")

    if args.source:
        source = Path(args.source).resolve()
        expected_commit = source_commit(source)
        source_data = metadata.get("source")
        if not isinstance(source_data, dict) or source_data.get("commit") != expected_commit:
            fail(
                f"RT-Thread source commit mismatch: metadata="
                f"{source_data.get('commit') if isinstance(source_data, dict) else None}, "
                f"current={expected_commit}"
            )
        expected_patch = patch_digest(source, args.patch_digest)
        if metadata.get("patch_set_sha256") != expected_patch:
            fail(
                f"patch-set digest mismatch: metadata={metadata.get('patch_set_sha256')}, "
                f"current={expected_patch}"
            )

    if args.input_digest:
        expected_inputs = input_digest(args.input_digest)
        if metadata.get("build_inputs_sha256") != expected_inputs:
            fail(
                f"build input digest mismatch: metadata="
                f"{metadata.get('build_inputs_sha256')}, current={expected_inputs}"
            )

    print(f"RTTHREAD_IMAGE_METADATA_OK {image}")


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser()
    subcommands = command.add_subparsers(dest="action", required=True)

    writer = subcommands.add_parser("write")
    writer.add_argument("--image", required=True)
    writer.add_argument("--source", required=True)
    writer.add_argument("--patch-digest")
    writer.add_argument("--input-digest", required=True)
    writer.add_argument("--output", required=True)
    writer.set_defaults(function=write_metadata)

    checker = subcommands.add_parser("check")
    checker.add_argument("--image", required=True)
    checker.add_argument("--metadata", required=True)
    checker.add_argument("--source")
    checker.add_argument("--patch-digest")
    checker.add_argument("--input-digest")
    checker.set_defaults(function=check_metadata)

    digest = subcommands.add_parser("input-digest")
    digest.add_argument("--root", required=True)
    digest.set_defaults(function=print_input_digest)
    return command


def main() -> None:
    args = parser().parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
