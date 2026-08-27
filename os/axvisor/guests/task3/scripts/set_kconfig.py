#!/usr/bin/env python3
"""Apply explicit Kconfig assignments without generating derived headers."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


ASSIGNMENT = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
DISABLED = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def read_fragment(path: Path) -> list[str]:
    values: list[str] = []
    for raw in path.read_text(encoding="ascii").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") and not DISABLED.match(line):
            continue
        disabled = DISABLED.match(line)
        values.append(f"{disabled.group(1)}=n" if disabled else line)
    return values


def parse_values(arguments: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for argument in arguments:
        match = ASSIGNMENT.match(argument)
        if match is None:
            raise ValueError(f"invalid Kconfig assignment: {argument}")
        values[match.group(1)] = match.group(2)
    return values


def apply(config: Path, requested: dict[str, str]) -> None:
    output: list[str] = []
    remaining = dict(requested)
    for line in config.read_text(encoding="ascii").splitlines():
        assignment = ASSIGNMENT.match(line)
        disabled = DISABLED.match(line)
        name = assignment.group(1) if assignment else disabled.group(1) if disabled else None
        if name not in remaining:
            output.append(line)
            continue
        value = remaining.pop(name)
        output.append(f"# {name} is not set" if value == "n" else f"{name}={value}")
    for name in sorted(remaining):
        value = remaining[name]
        output.append(f"# {name} is not set" if value == "n" else f"{name}={value}")

    descriptor, temporary = tempfile.mkstemp(
        dir=config.parent, prefix=f".{config.name}.", text=True
    )
    try:
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as stream:
            stream.write("\n".join(output) + "\n")
        os.replace(temporary, config)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("assignments", nargs="*")
    parser.add_argument("--fragment", action="append", type=Path, default=[])
    args = parser.parse_args()
    assignments: list[str] = []
    for fragment in args.fragment:
        assignments.extend(read_fragment(fragment))
    assignments.extend(args.assignments)
    apply(args.config, parse_values(assignments))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
