#!/usr/bin/env python3
"""Create a Task 1/2/3 U-Boot config that waits for physical stability."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path


STARRY_EXIT_MARKER = "TASK123_STARRY_EXIT status=0"
SUCCESS_ARRAY = re.compile(r"(?ms)^success_regex\s*=\s*\[.*?^\]\s*$")
SHELL_PREFIX = 'shell_prefix = "uart:~$ "'
SHELL_INIT_COMMAND = "rtbench_stability 300"


def parse_args() -> tuple[str, str, int | None, Path, Path]:
    args = sys.argv[1:]
    rtos = "rtthread"
    app_guest = "starryos"
    samples: int | None = None
    while args and args[0].startswith("--"):
        option = args.pop(0)
        if option not in ("--rtos", "--app-guest", "--rtbench-samples") or not args:
            raise SystemExit(
                "usage: prepare_task123_uboot_config.py "
                "[--rtos rtthread|zephyr] [--app-guest linux|starryos] "
                "[--rtbench-samples N] "
                "INPUT.toml OUTPUT.toml"
            )
        value = args.pop(0)
        if option == "--rtos":
            rtos = value
        elif option == "--app-guest":
            app_guest = value
        else:
            try:
                samples = int(value)
            except ValueError as error:
                raise SystemExit("--rtbench-samples must be an integer") from error
            if not 1 <= samples <= 100_000:
                raise SystemExit("--rtbench-samples must be between 1 and 100000")
    if len(args) != 2 or rtos not in ("rtthread", "zephyr") or app_guest not in (
        "linux",
        "starryos",
    ):
        raise SystemExit(
            "usage: prepare_task123_uboot_config.py "
            "[--rtos rtthread|zephyr] [--app-guest linux|starryos] "
            "[--rtbench-samples N] "
            "INPUT.toml OUTPUT.toml"
        )
    return rtos, app_guest, samples, Path(args[0]), Path(args[1])


def task123_marker(app_guest: str, realtime: bool = False) -> str:
    guest_name = "STARRY" if app_guest == "starryos" else "LINUX"
    suffix = "_RTBENCH" if realtime else ""
    return f"TASK123_{guest_name}{suffix}_END status=PASS"


def combined_success_regex(app_guest: str, samples: int | None) -> str:
    marker = task123_marker(app_guest, realtime=samples is not None)
    benchmark_marker = "RTBENCH_END|RTBENCH_STABILITY_END" if samples else "RTBENCH_STABILITY_END"
    return (
        rf"(?s:(?:(?:{benchmark_marker}) status=PASS.*{marker}|"
        rf"{marker}.*(?:{benchmark_marker}) status=PASS))"
    )


def main() -> int:
    rtos, app_guest, samples, source, target = parse_args()
    text = source.read_text(encoding="utf-8")
    config = tomllib.loads(text)
    success_regex = config.get("success_regex")
    required_marker = (
        STARRY_EXIT_MARKER if app_guest == "starryos" else task123_marker(app_guest)
    )
    if not isinstance(success_regex, list) or required_marker not in success_regex:
        raise SystemExit(
            f"U-Boot config success_regex must contain {required_marker!r}"
        )

    rewritten, replacements = SUCCESS_ARRAY.subn(
        f"success_regex = [{combined_success_regex(app_guest, samples)!r}]", text, count=1
    )
    if replacements != 1:
        raise SystemExit("U-Boot config success_regex array was not found")
    if rtos == "zephyr":
        if "shell_prefix" not in rewritten:
            rewritten += f"\n{SHELL_PREFIX}\n"
        if "shell_init_cmd" not in rewritten:
            shell_command = f"benchmark {samples}" if samples is not None else SHELL_INIT_COMMAND
            rewritten += f'shell_init_cmd = "{shell_command}"\n'
    target.write_text(rewritten, encoding="utf-8")
    print(f"TASK123_UBOOT_CONFIG_WRITTEN {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
