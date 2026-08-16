#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE_REL="container/Dockerfile.rtthread-repro"
COMPOSE_REL="compose.rtthread-repro.yml"
PREFLIGHT_REL="container/rtthread-repro-preflight.sh"
DOCKERFILE="$ROOT/$DOCKERFILE_REL"
COMPOSE_FILE="$ROOT/$COMPOSE_REL"
PREFLIGHT="$ROOT/$PREFLIGHT_REL"
PREFLIGHT_COMMANDS=(
    qemu-system-aarch64
    uv
    uclampset
    pidstat
    socat
    aarch64-linux-gnu-strip
)

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

validate_dockerfile_contract() {
    python3 -c '
import re
import sys


BASE_ARG = "ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4"
UV_ARG = "ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4"
QEMU_VERSION_ARG = "ARG QEMU_VERSION=11.0.2"
QEMU_COMMIT_ARG = "ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482"
REQUIRED_COMMANDS = (
    "aarch64-linux-gnu-strip",
    "pidstat",
    "socat",
    "uclampset",
)
REQUIRED_PACKAGES = {
    "binutils-aarch64-linux-gnu",
    "sysstat",
    "socat",
    "util-linux",
}
APT_PREFIX = "RUN apt-get update && apt-get install -y --no-install-recommends "
APT_SUFFIX = " && rm -rf /var/lib/apt/lists/*"


def fail(message):
    print(f"FAIL: Dockerfile contract {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_instructions(source):
    instructions = []
    continued = []

    for raw_line in source.splitlines():
        stripped = raw_line.strip()
        if not continued and (not stripped or stripped.startswith("#")):
            continue
        if "<<" in stripped:
            fail("does not allow heredoc instructions")

        if raw_line.rstrip().endswith("\\"):
            continued.append(raw_line.rstrip()[:-1].strip())
            continue

        continued.append(stripped)
        logical = re.sub(r"\s+", " ", " ".join(continued)).strip()
        continued = []
        match = re.fullmatch(r"([A-Za-z]+)\s+(.+)", logical)
        if match is None:
            fail(f"contains malformed top-level instruction: {logical!r}")
        instructions.append(f"{match.group(1).upper()} {match.group(2)}")

    if continued:
        fail("ends with a dangling line continuation")
    return instructions


instructions = parse_instructions(sys.stdin.read())
for required in (BASE_ARG, UV_ARG, QEMU_VERSION_ARG, QEMU_COMMIT_ARG):
    if instructions.count(required) != 1:
        fail(f"must contain exactly one {required}")

if any(instruction.startswith("SHELL ") for instruction in instructions):
    fail("does not allow SHELL instructions")

from_indices = [
    index
    for index, instruction in enumerate(instructions)
    if instruction.startswith("FROM ")
]
if not from_indices:
    fail("must contain a FROM instruction")
first_from = from_indices[0]
for global_arg in (BASE_ARG, UV_ARG):
    if instructions.index(global_arg) >= first_from:
        argument_name = global_arg.split("=", 1)[0]
        fail(f"{argument_name} must be global before the first FROM")

base_stage = re.compile(
    r"FROM \$\{BASE_IMAGE\}(?: AS [A-Za-z0-9_.-]+)?", re.IGNORECASE
)
uv_stage = re.compile(
    r"FROM \$\{UV_IMAGE\}(?: AS [A-Za-z0-9_.-]+)?", re.IGNORECASE
)
if not any(uv_stage.fullmatch(instruction) for instruction in instructions):
    fail("must contain a FROM ${UV_IMAGE} stage")

runtime_from = from_indices[-1]
if base_stage.fullmatch(instructions[runtime_from]) is None:
    fail("final stage must use FROM ${BASE_IMAGE}")
runtime_instructions = instructions[runtime_from + 1:]

for command in REQUIRED_COMMANDS:
    required_run = f"RUN command -v {command} >/dev/null 2>&1"
    if runtime_instructions.count(required_run) != 1:
        fail(f"final runtime stage must contain exact top-level instruction: {required_run}")

apt_runs = [
    instruction
    for instruction in runtime_instructions
    if instruction.startswith(APT_PREFIX)
]
if len(apt_runs) != 1:
    fail("final runtime stage must contain exactly one normalized apt-get update/install RUN instruction")
apt_run = apt_runs[0]
if not apt_run.endswith(APT_SUFFIX):
    fail(f"apt RUN must end with {APT_SUFFIX.strip()}")
package_text = apt_run[len(APT_PREFIX):-len(APT_SUFFIX)]
packages = package_text.split()
if not packages or any(re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package) is None for package in packages):
    fail("apt RUN package list must contain only Debian package-name arguments")
missing_packages = sorted(REQUIRED_PACKAGES.difference(packages))
if missing_packages:
    fail("apt RUN is missing packages: " + ", ".join(missing_packages))
'
}

validate_preflight_contract() {
    local preflight="$1"
    local shim_dir
    local command_name
    local result=0

    shim_dir="$(mktemp -d)" || return 1
    for command_name in "${PREFLIGHT_COMMANDS[@]}"; do
        printf '%s\n' '#!/bin/sh' 'exit 0' >"$shim_dir/$command_name"
        chmod +x "$shim_dir/$command_name"
    done

    if ! PATH="$shim_dir" "$BASH" "$preflight" --check-tools \
        >/dev/null 2>&1; then
        result=1
    else
        for command_name in "${PREFLIGHT_COMMANDS[@]}"; do
            mv "$shim_dir/$command_name" "$shim_dir/$command_name.missing"
            if PATH="$shim_dir" "$BASH" "$preflight" --check-tools \
                >/dev/null 2>&1; then
                result=1
            fi
            mv "$shim_dir/$command_name.missing" "$shim_dir/$command_name"
        done
    fi

    for command_name in "${PREFLIGHT_COMMANDS[@]}"; do
        rm -f -- "$shim_dir/$command_name" "$shim_dir/$command_name.missing"
    done
    rmdir "$shim_dir"
    return "$result"
}

capture_rendered_stdout() {
    local stderr_file="$1"
    shift

    "$@" 2>"$stderr_file"
}

validate_compose_json() {
    local expected_uid="$1"
    local expected_gid="$2"
    local expected_cpuset="$3"

    python3 -c '
import json
import sys


def fail(message):
    print(f"FAIL: rendered Compose configuration {message}", file=sys.stderr)
    raise SystemExit(1)


expected_uid, expected_gid, expected_cpuset = sys.argv[1:4]

try:
    document = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError) as error:
    fail(f"is not valid JSON: {error}")

if not isinstance(document, dict):
    fail("root must be an object")

services = document.get("services")
if not isinstance(services, dict):
    fail("services must be an object")

service = services.get("rtthread-repro")
if not isinstance(service, dict):
    fail("must define service rtthread-repro")

cap_add = service.get("cap_add")
if not isinstance(cap_add, list) or not all(isinstance(item, str) for item in cap_add):
    fail("service rtthread-repro cap_add must be a string array")
if "SYS_NICE" not in cap_add:
    fail("service rtthread-repro cap_add must contain SYS_NICE")

if service.get("cpuset") != expected_cpuset:
    fail(f"service rtthread-repro cpuset must be exactly {expected_cpuset}")
expected_user = f"{expected_uid}:{expected_gid}"
if service.get("user") != expected_user:
    fail(f"service rtthread-repro user must be exactly {expected_user}")

if "privileged" in service:
    privileged = service["privileged"]
    if not isinstance(privileged, bool):
        fail("service rtthread-repro privileged must be boolean")
    if privileged:
        fail("service rtthread-repro must not be privileged")

if "network_mode" in service:
    network_mode = service["network_mode"]
    if not isinstance(network_mode, str):
        fail("service rtthread-repro network_mode must be a string")
    if network_mode == "host":
        fail("service rtthread-repro must not use host networking")

devices = service.get("devices", [])
if not isinstance(devices, list):
    fail("service rtthread-repro devices must be an array")
for device in devices:
    if not isinstance(device, dict):
        fail("service rtthread-repro device entries must be objects")
    for field in ("source", "target"):
        value = device.get(field)
        if not isinstance(value, str):
            fail(f"service rtthread-repro device {field} must be a string")
        if value == "/dev/kvm":
            fail(f"service rtthread-repro device {field} must not be /dev/kvm")
' "$expected_uid" "$expected_gid" "$expected_cpuset"
}

run_self_tests() {
    local sentinel_json
    local decoy_json
    local valid_preflight
    local spoofed_preflight
    local valid_preflight_file
    local spoofed_preflight_file
    local preflight_fixture_dir
    local valid_dockerfile
    local stage_bypass_dockerfile
    local shell_bypass_dockerfile
    local option_bypass_dockerfile
    local quoted_dockerfile
    local heredoc_dockerfile
    local captured_json
    local captured_warning
    local capture_stderr_file

    sentinel_json='{"services":{"rtthread-repro":{"cap_add":["SYS_NICE"],"cpuset":"5-7","user":"23456:23457"}}}'
    validate_compose_json 23456 23457 5-7 <<<"$sentinel_json" ||
        fail "self-test rejected target-service sentinel interpolation"

    decoy_json='{"services":{"rtthread-repro":{"cap_add":["SYS_NICE"],"cpuset":"0-3","user":"1000:1000"},"decoy":{"cpuset":"5-7","user":"23456:23457"}}}'
    if validate_compose_json 23456 23457 5-7 \
        <<<"$decoy_json" >/dev/null 2>&1; then
        fail "self-test accepted sentinel interpolation from another service"
    fi

    valid_dockerfile='ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4
ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4
FROM ${UV_IMAGE} AS uv
FROM ${BASE_IMAGE} AS qemu-builder
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu sysstat socat util-linux && rm -rf /var/lib/apt/lists/*
RUN command -v aarch64-linux-gnu-strip >/dev/null 2>&1
RUN command -v pidstat >/dev/null 2>&1
RUN command -v socat >/dev/null 2>&1
RUN command -v uclampset >/dev/null 2>&1'
    validate_dockerfile_contract <<<"$valid_dockerfile" ||
        fail "self-test rejected the planned Dockerfile instruction grammar"

    stage_bypass_dockerfile='ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4
ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4
FROM ${BASE_IMAGE} AS qemu-builder
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
RUN apt-get update && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu sysstat socat util-linux && rm -rf /var/lib/apt/lists/*
RUN command -v aarch64-linux-gnu-strip >/dev/null 2>&1
RUN command -v pidstat >/dev/null 2>&1
RUN command -v socat >/dev/null 2>&1
RUN command -v uclampset >/dev/null 2>&1
FROM ${UV_IMAGE} AS uv'
    if validate_dockerfile_contract <<<"$stage_bypass_dockerfile" \
        >/dev/null 2>&1; then
        fail "self-test accepted runtime checks outside the final BASE_IMAGE stage"
    fi

    shell_bypass_dockerfile="$(sed \
        '/^RUN apt-get update/i SHELL [\"/bin/true\"]' \
        <<<"$valid_dockerfile")"
    if validate_dockerfile_contract <<<"$shell_bypass_dockerfile" \
        >/dev/null 2>&1; then
        fail "self-test accepted a top-level SHELL instruction"
    fi

    option_bypass_dockerfile="${valid_dockerfile/--no-install-recommends /--no-install-recommends --download-only }"
    if validate_dockerfile_contract <<<"$option_bypass_dockerfile" \
        >/dev/null 2>&1; then
        fail "self-test accepted option-shaped apt package arguments"
    fi

    quoted_dockerfile='ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4
ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4
FROM ${UV_IMAGE} AS uv
FROM ${BASE_IMAGE} AS qemu-builder
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
FROM ${BASE_IMAGE}
RUN printf "%s\n" "
RUN apt-get update && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu sysstat socat util-linux && rm -rf /var/lib/apt/lists/*
RUN command -v aarch64-linux-gnu-strip >/dev/null 2>&1
"
RUN command -v pidstat >/dev/null 2>&1
RUN command -v socat >/dev/null 2>&1
RUN command -v uclampset >/dev/null 2>&1'
    if validate_dockerfile_contract <<<"$quoted_dockerfile" \
        >/dev/null 2>&1; then
        fail "self-test accepted exact instructions inside multiline quoted text"
    fi

    heredoc_dockerfile='ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4
ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4
FROM ${UV_IMAGE} AS uv
FROM ${BASE_IMAGE} AS qemu-builder
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
FROM ${BASE_IMAGE}
RUN cat<<EOF
RUN apt-get update && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu sysstat socat util-linux && rm -rf /var/lib/apt/lists/*
RUN command -v aarch64-linux-gnu-strip >/dev/null 2>&1
EOF
RUN command -v pidstat >/dev/null 2>&1
RUN command -v socat >/dev/null 2>&1
RUN command -v uclampset >/dev/null 2>&1'
    if validate_dockerfile_contract <<<"$heredoc_dockerfile" \
        >/dev/null 2>&1; then
        fail "self-test accepted exact instructions inside cat<<EOF"
    fi

    valid_preflight='#!/usr/bin/env bash
set -euo pipefail
check_tools() {
    command -v qemu-system-aarch64 >/dev/null 2>&1
    command -v uv >/dev/null 2>&1
    command -v uclampset >/dev/null 2>&1
    command -v pidstat >/dev/null 2>&1
    command -v socat >/dev/null 2>&1
    command -v aarch64-linux-gnu-strip >/dev/null 2>&1
}
if [[ "${1:-}" == "--check-tools" ]]; then
    check_tools
    exit 0
fi
check_tools'
    spoofed_preflight='#!/usr/bin/env bash
cat() { :; }
if [[ "${1:-}" == "--check-tools" ]]; then
    printf "%s\n" "
command -v qemu-system-aarch64 >/dev/null 2>&1
command -v uv >/dev/null 2>&1
"
    cat<<EOF
command -v pidstat >/dev/null 2>&1
command -v socat >/dev/null 2>&1
command -v aarch64-linux-gnu-strip >/dev/null 2>&1
EOF
    exit 0
fi
exit 0'
    preflight_fixture_dir="$(mktemp -d)"
    valid_preflight_file="$preflight_fixture_dir/valid-preflight.sh"
    spoofed_preflight_file="$preflight_fixture_dir/spoofed-preflight.sh"
    printf '%s\n' "$valid_preflight" >"$valid_preflight_file"
    printf '%s\n' "$spoofed_preflight" >"$spoofed_preflight_file"
    if ! validate_preflight_contract "$valid_preflight_file"; then
        rm -f -- "$valid_preflight_file" "$spoofed_preflight_file"
        rmdir "$preflight_fixture_dir"
        fail "self-test rejected behavioral --check-tools implementation"
    fi
    if validate_preflight_contract "$spoofed_preflight_file"; then
        rm -f -- "$valid_preflight_file" "$spoofed_preflight_file"
        rmdir "$preflight_fixture_dir"
        fail "self-test accepted quoted/heredoc preflight spoof"
    fi
    rm -f -- "$valid_preflight_file" "$spoofed_preflight_file"
    rmdir "$preflight_fixture_dir"

    fake_compose_render() {
        printf '%s\n' "$sentinel_json"
        printf '%s\n' 'warning: fixture warning' >&2
    }
    capture_stderr_file="$(mktemp)"
    captured_json="$(capture_rendered_stdout \
        "$capture_stderr_file" fake_compose_render)"
    captured_warning="$(<"$capture_stderr_file")"
    rm -f -- "$capture_stderr_file"
    validate_compose_json 23456 23457 5-7 <<<"$captured_json" ||
        fail "self-test allowed stderr to corrupt rendered JSON"
    [[ "$captured_warning" == 'warning: fixture warning' ]] ||
        fail "self-test did not capture Compose stderr separately"

    printf '%s\n' 'PASS: RT-Thread Docker reproduction self-tests'
}

if [[ "${1:-}" == "--validate-compose-json" ]]; then
    validate_compose_json "${2:-1000}" "${3:-1000}" "${4:-0-3}"
    exit 0
fi
if [[ "${1:-}" == "--self-test" ]]; then
    run_self_tests
    exit 0
fi

missing_file=0
for required_file in "$DOCKERFILE_REL" "$COMPOSE_REL" "$PREFLIGHT_REL"; do
    if [[ ! -f "$ROOT/$required_file" ]]; then
        printf 'FAIL: missing required Docker reproduction file: %s\n' \
            "$required_file" >&2
        missing_file=1
    fi
done
if ((missing_file != 0)); then
    exit 1
fi

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

validate_dockerfile_contract <"$DOCKERFILE"
validate_preflight_contract "$PREFLIGHT" ||
    fail "$PREFLIGHT_REL --check-tools must fail when any required tool is absent"

compose_stderr_file="$(mktemp)"
trap 'rm -f -- "$compose_stderr_file"' EXIT
if ! rendered_compose="$(
    capture_rendered_stdout \
        "$compose_stderr_file" \
        env \
        RT_REPRO_UID=23456 \
        RT_REPRO_GID=23457 \
        RT_REPRO_CPUSET=5-7 \
        docker compose \
            --project-directory "$ROOT" \
            -f "$COMPOSE_FILE" \
            config --format json
)"; then
    while IFS= read -r warning; do
        printf '%s\n' "$warning" >&2
    done <"$compose_stderr_file"
    fail "Docker Compose JSON rendering failed"
fi
while IFS= read -r warning; do
    printf '%s\n' "$warning" >&2
done <"$compose_stderr_file"
validate_compose_json 23456 23457 5-7 <<<"$rendered_compose"

printf '%s\n' 'PASS: RT-Thread Docker reproduction contract'
