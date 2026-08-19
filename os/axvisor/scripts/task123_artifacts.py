#!/usr/bin/env python3

"""Resolve Task 1/2/3 artifacts without using the network."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ARTIFACT_NAMES = (
    "qemu",
    "linux-kernel",
    "linux-initramfs",
    "model",
    "rootfs",
    "rtthread-normal",
    "rtthread-drop-status",
    "rtthread-delayed-server",
)
ARTIFACT_KEYS = {name: name.replace("-", "_") for name in ARTIFACT_NAMES}
ARTIFACT_LINE = re.compile(
    r"ARTIFACT name=([^ ]+) path=(.+) sha256=([0-9a-f]{64})"
)
GIT_OBJECT_ID = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
RTTHREAD_TREE_PATHS = ("bsp/qemu-virt64-aarch64", "components", "src")
FINGERPRINT_INPUTS = (
    Path("os/axvisor/configs/board/qemu-aarch64-three-guest-net.toml"),
    Path("os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml"),
    Path("os/axvisor/configs/vms/qemu/aarch64/linux-net-1.toml"),
    Path("os/axvisor/configs/vms/qemu/aarch64/linux-net-2.toml"),
    Path("os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"),
    Path("os/axvisor/guests/linux-net/init-linux-1"),
    Path("os/axvisor/guests/linux-net/init-linux-2"),
    Path("os/axvisor/guests/linux-net/init-task123"),
    Path("os/axvisor/guests/rt-benchmark"),
    Path("os/axvisor/guests/rt-ipc"),
    Path("os/axvisor/guests/task3/Makefile"),
    Path("os/axvisor/guests/task3/buildroot"),
    Path("os/axvisor/guests/task3/configs"),
    Path("os/axvisor/guests/task3/model"),
    Path("os/axvisor/guests/task3/patches"),
    Path("os/axvisor/guests/task3/scripts"),
    Path("os/axvisor/guests/task3/src"),
    Path("os/axvisor/patches/rtthread"),
    Path("os/axvisor/scripts/generate_linux_vmconfig.sh"),
    Path("os/axvisor/scripts/generate_rtthread_vmconfig.sh"),
    Path("os/axvisor/scripts/prepare_task123_artifacts.sh"),
    Path("os/axvisor/scripts/run_task123.sh"),
    Path("os/axvisor/scripts/setup_qemu_three_guest_net.sh"),
    Path("os/axvisor/scripts/task123_artifacts.py"),
)
FINGERPRINT_IGNORED_DIRECTORIES = {".git", "__pycache__", "build", "target"}


def sha256_file(path: Path) -> str:
    """Return the lowercase SHA-256 digest of a regular file."""
    try:
        if not path.is_file():
            raise ValueError(f"not a regular file: {path}")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as error:
        raise ValueError(f"cannot read file {path}: {error}") from error


def validate_candidate(path: Path, expected_sha256: str) -> bool:
    """Return whether path is a file with the expected lowercase digest."""
    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        return False
    try:
        return (
            path.is_file()
            and path.stat().st_size > 0
            and sha256_file(path) == expected_sha256
        )
    except (OSError, ValueError):
        return False


def parse_runner_manifest(path: Path) -> dict[str, object]:
    """Parse and validate a line-oriented Task 1/2/3 runner manifest."""
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ValueError(f"cannot read manifest {path}: {error}") from error

    result: dict[str, object] = {}
    artifacts: dict[str, object] = {}
    artifact_names: set[str] = set()
    for line_number, line in enumerate(contents.splitlines(), start=1):
        if line.startswith("ARTIFACT"):
            match = ARTIFACT_LINE.fullmatch(line)
            if match is None:
                raise ValueError(
                    f"malformed ARTIFACT line in {path}:{line_number}"
                )
            name, candidate_text, expected_sha256 = match.groups()
            if name in artifact_names:
                raise ValueError(
                    f"duplicate artifact name {name!r} in {path}:{line_number}"
                )
            artifact_names.add(name)
            if name not in ARTIFACT_KEYS:
                continue
            candidate = Path(candidate_text)
            if not candidate.is_absolute():
                candidate = path.parent / candidate
            artifacts[name] = {
                "path": str(candidate),
                "sha256": expected_sha256,
            }
            continue

        if not line or "=" not in line:
            raise ValueError(f"malformed manifest line in {path}:{line_number}")
        key, value = line.split("=", 1)
        if not key or any(character.isspace() for character in key):
            raise ValueError(f"malformed manifest key in {path}:{line_number}")
        if key in result or key == "artifacts":
            raise ValueError(f"duplicate manifest key {key!r} in {path}:{line_number}")
        result[key] = value

    result["artifacts"] = artifacts
    return result


def _manifest_candidates(
    manifests: list[Path], required_key: str, required_value: str
) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for manifest_path in sorted(manifests, key=lambda item: str(item.resolve())):
        try:
            manifest = parse_runner_manifest(manifest_path)
        except ValueError:
            continue
        if manifest.get(required_key) != required_value:
            continue
        artifacts = manifest.get("artifacts")
        if not isinstance(artifacts, dict):
            continue
        for name in ARTIFACT_NAMES:
            artifact = artifacts.get(name)
            if not isinstance(artifact, dict):
                continue
            candidate_text = artifact.get("path")
            expected_sha256 = artifact.get("sha256")
            if not isinstance(candidate_text, str) or not isinstance(
                expected_sha256, str
            ):
                continue
            try:
                candidate_path = Path(candidate_text).resolve(strict=True)
            except (OSError, RuntimeError, ValueError):
                continue
            if not validate_candidate(candidate_path, expected_sha256):
                continue
            candidate = {
                "name": name,
                "path": str(candidate_path),
                "sha256": expected_sha256,
            }
            candidates.append(candidate)
    return candidates


def find_accepted_evidence(evidence_root: Path) -> list[dict[str, object]]:
    """Return valid artifacts from PASS evidence manifests in stable order."""
    if not evidence_root.is_dir():
        return []
    try:
        manifests = list(evidence_root.rglob("manifest.txt"))
    except OSError:
        return []
    return _manifest_candidates(manifests, "result_gate", "PASS")


def _find_cached_artifacts(cache: Path) -> list[dict[str, object]]:
    artifacts_root = cache / "artifacts"
    if not artifacts_root.is_dir():
        return []
    try:
        manifests = list(artifacts_root.glob("*/manifest.txt"))
    except OSError:
        return []
    return _manifest_candidates(manifests, "cache_status", "VALID")


def _git(
    repository: Path, arguments: list[str], *, capture_output: bool = False
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["GIT_NO_LAZY_FETCH"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    try:
        return subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            env=environment,
        )
    except OSError as error:
        raise ValueError(f"cannot execute git: {error}") from error


def _valid_rtthread_repository(repository: Path, commit: str) -> bool:
    if not repository.is_dir() or GIT_OBJECT_ID.fullmatch(commit) is None:
        return False
    if _git(repository, ["cat-file", "-e", f"{commit}^{{commit}}"]).returncode != 0:
        return False
    for tree_path in RTTHREAD_TREE_PATHS:
        result = _git(
            repository,
            ["cat-file", "-t", f"{commit}:{tree_path}"],
            capture_output=True,
        )
        if result.returncode != 0 or result.stdout.strip() != "tree":
            return False
    return True


def _repository_candidates(search_root: Path) -> list[Path]:
    candidates: list[Path] = []
    if not search_root.is_dir():
        return candidates
    try:
        for directory, directory_names, file_names in os.walk(search_root):
            directory_names.sort()
            current = Path(directory)
            if ".git" in directory_names or ".git" in file_names:
                candidates.append(current)
                if ".git" in directory_names:
                    directory_names.remove(".git")
            if {"HEAD", "objects", "refs"}.issubset(
                set(file_names) | set(directory_names)
            ):
                candidates.append(current)
    except OSError:
        return []
    return sorted(set(candidates), key=lambda item: str(item.resolve()))


def find_local_rtthread_repository(root: Path, commit: str) -> Path | None:
    """Find a local Git object source for the pinned RT-Thread commit."""
    if GIT_OBJECT_ID.fullmatch(commit) is None:
        raise ValueError(f"invalid RT-Thread commit: {commit}")
    for candidate in _repository_candidates(root / "tmp"):
        if _valid_rtthread_repository(candidate, commit):
            return candidate.resolve()
    return None


def _fingerprint_file(digest: object, label: str, path: Path) -> None:
    file_digest = digest
    assert isinstance(file_digest, type(hashlib.sha256()))
    encoded_label = label.encode("utf-8")
    try:
        size = path.stat().st_size
        if not path.is_file():
            raise ValueError(f"fingerprint input is not a regular file: {path}")
        file_digest.update(len(encoded_label).to_bytes(8, "big"))
        file_digest.update(encoded_label)
        file_digest.update(size.to_bytes(8, "big"))
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                file_digest.update(chunk)
    except OSError as error:
        raise ValueError(f"cannot read fingerprint input {path}: {error}") from error


def _fingerprint_files(root: Path, directory: Path) -> list[Path]:
    files: list[Path] = []
    try:
        for current, directory_names, file_names in os.walk(directory):
            directory_names[:] = sorted(
                name
                for name in directory_names
                if name not in FINGERPRINT_IGNORED_DIRECTORIES
            )
            for file_name in sorted(file_names):
                if file_name.endswith((".pyc", ".pyo")):
                    continue
                candidate = Path(current) / file_name
                if candidate.is_file():
                    files.append(candidate)
    except OSError as error:
        raise ValueError(
            f"cannot scan fingerprint inputs under {directory}: {error}"
        ) from error
    return sorted(files, key=lambda item: item.relative_to(root).as_posix())


def compute_fingerprint(root: Path, lock_file: Path, components: list[str]) -> str:
    """Hash pinned inputs and ordered extension components for cache use."""
    try:
        resolved_root = root.resolve(strict=True)
        resolved_lock = lock_file.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"cannot resolve fingerprint input: {error}") from error
    if not resolved_root.is_dir():
        raise ValueError(f"root is not a directory: {root}")

    digest = hashlib.sha256(b"task123-artifacts-fingerprint-v1\0")
    try:
        lock_label = resolved_lock.relative_to(resolved_root).as_posix()
    except ValueError:
        lock_label = "lock-file"
    _fingerprint_file(digest, lock_label, resolved_lock)
    for relative in FINGERPRINT_INPUTS:
        candidate = resolved_root / relative
        if candidate.is_file() and candidate != resolved_lock:
            _fingerprint_file(digest, relative.as_posix(), candidate)
        elif candidate.is_dir():
            for item in _fingerprint_files(resolved_root, candidate):
                _fingerprint_file(
                    digest, item.relative_to(resolved_root).as_posix(), item
                )
    for index, component in enumerate(components):
        if not isinstance(component, str):
            raise ValueError("fingerprint components must be strings")
        encoded = component.encode("utf-8")
        digest.update(index.to_bytes(8, "big"))
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    return digest.hexdigest()


def _explicit_artifact(path_text: str, name: str) -> dict[str, str]:
    candidate = Path(path_text)
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"explicit {name} input does not exist: {candidate}") from error
    if not resolved.is_file():
        raise ValueError(f"explicit {name} input is not a regular file: {resolved}")
    try:
        if resolved.stat().st_size == 0:
            raise ValueError(f"explicit {name} input is empty: {resolved}")
    except OSError as error:
        raise ValueError(f"cannot inspect explicit {name} input: {error}") from error
    return {
        "origin": "explicit",
        "path": str(resolved),
        "sha256": sha256_file(resolved),
    }


def _first_by_name(candidates: list[dict[str, object]]) -> dict[str, dict[str, object]]:
    selected: dict[str, dict[str, object]] = {}
    for candidate in candidates:
        name = candidate.get("name")
        if isinstance(name, str) and name not in selected:
            selected[name] = candidate
    return selected


def _atomic_json(path: Path, data: dict[str, object]) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
        resolved_parent = parent.resolve(strict=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="ascii",
            dir=resolved_parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary = Path(output.name)
            json.dump(data, output, indent=2, sort_keys=True, ensure_ascii=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, resolved_parent / path.name)
    except OSError as error:
        if "temporary" in locals():
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
        raise ValueError(f"cannot write output {path}: {error}") from error


def _resolve(arguments: argparse.Namespace) -> None:
    root = Path(arguments.root)
    try:
        root = root.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"root does not exist: {root}") from error
    if not root.is_dir():
        raise ValueError(f"root is not a directory: {root}")

    cache_candidates = _first_by_name(_find_cached_artifacts(Path(arguments.cache)))
    evidence_candidates = _first_by_name(
        find_accepted_evidence(Path(arguments.evidence_root))
    )
    artifacts: dict[str, object] = {}
    missing: list[str] = []
    for name in ARTIFACT_NAMES:
        key = ARTIFACT_KEYS[name]
        explicit = getattr(arguments, key)
        if explicit is not None:
            artifacts[key] = _explicit_artifact(explicit, name)
            continue
        candidate = cache_candidates.get(name)
        origin = "cache"
        if candidate is None:
            candidate = evidence_candidates.get(name)
            origin = "evidence"
        if candidate is None:
            missing.append(key)
            continue
        artifacts[key] = {
            "origin": origin,
            "path": candidate["path"],
            "sha256": candidate["sha256"],
        }

    if arguments.rtthread_repository is not None:
        try:
            repository = Path(arguments.rtthread_repository).resolve(strict=True)
        except OSError as error:
            raise ValueError(
                "explicit RT-Thread repository does not exist: "
                f"{arguments.rtthread_repository}"
            ) from error
        if not _valid_rtthread_repository(repository, arguments.rtthread_commit):
            raise ValueError(
                f"explicit RT-Thread repository is invalid: {repository}"
            )
        repository_data: dict[str, str] | None = {
            "origin": "explicit",
            "path": str(repository),
        }
    else:
        repository = find_local_rtthread_repository(root, arguments.rtthread_commit)
        repository_data = (
            {"origin": "local_git", "path": str(repository)}
            if repository is not None
            else None
        )

    fingerprint = compute_fingerprint(
        root,
        Path(arguments.lock_file),
        [f"rtthread-commit={arguments.rtthread_commit}"],
    )
    _atomic_json(
        Path(arguments.output),
        {
            "schema": 1,
            "fingerprint": fingerprint,
            "artifacts": artifacts,
            "rtthread_repository": repository_data,
            "missing": missing,
        },
    )


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    resolve = subparsers.add_parser("resolve")
    for option in (
        "root",
        "cache",
        "evidence-root",
        "output",
        "lock-file",
        "rtthread-commit",
    ):
        resolve.add_argument(f"--{option}", required=True)
    for name in ARTIFACT_NAMES:
        resolve.add_argument(f"--{name}")
    resolve.add_argument("--rtthread-repository")
    resolve.set_defaults(handler=_resolve)
    return parser


def main() -> int:
    try:
        arguments = _parser().parse_args()
        arguments.handler(arguments)
    except ValueError as error:
        print(f"task123 artifacts: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
