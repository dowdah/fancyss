#!/usr/bin/env python3
"""Fetch and verify immutable build inputs without trusting archive paths."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_path(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts or str(path) != name:
        raise ValueError(f"Unsafe input path: {name!r}")
    return path


def obtain(asset, cache, offline=False):
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / asset["sha256"]
    if target.exists():
        if digest(target) != asset["sha256"]:
            raise ValueError(f"Corrupt cached input: {asset['name']}")
        return target
    if offline:
        raise FileNotFoundError(f"Input not cached: {asset['name']}")
    if not asset["url"].startswith("https://"):
        raise ValueError("Build inputs require HTTPS")
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
        temporary = Path(output.name)
        try:
            with urllib.request.urlopen(asset["url"], timeout=120) as response:
                shutil.copyfileobj(response, output)
            output.flush()
            if digest(temporary) != asset["sha256"]:
                raise ValueError(f"Checksum mismatch: {asset['name']}")
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def hydrate(lock, cache, destination, offline=False):
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()
    arch = {"aarch64": "arm64", "x86_64": "amd64"}.get(platform.machine(), platform.machine())
    host = f"{platform.system().lower()}-{arch}"
    for asset in lock["assets"]:
        if asset.get("host", host) != host:
            continue
        archive_path = obtain(asset, cache, offline)
        expected = {}
        for entry in asset["files"]:
            name = str(safe_path(entry["path"]))
            if name in seen:
                raise ValueError(f"Duplicate build input: {name}")
            seen.add(name)
            expected[name] = entry
        extracted = set()
        with tarfile.open(archive_path, "r:*") as archive:
            for member in archive:
                name = str(safe_path(member.name))
                if not member.isfile() or name not in expected or name in extracted:
                    raise ValueError(f"Unexpected archive member: {name}")
                entry = expected[name]
                if member.size != entry["bytes"]:
                    raise ValueError(f"Wrong input size: {name}")
                target = destination / name
                for parent in [target, *target.parents]:
                    if parent == destination.parent:
                        break
                    if parent.is_symlink():
                        raise ValueError(f"Symlink in input destination: {name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if digest(target) != entry["sha256"]:
                    target.unlink()
                    raise ValueError(f"Checksum mismatch: {name}")
                target.chmod(entry["mode"] & 0o755)
                extracted.add(name)
        if extracted != expected.keys():
            raise ValueError(f"Missing archive members: {sorted(expected.keys() - extracted)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--lock", type=Path, default=root / "build-inputs.lock.json")
    parser.add_argument("--cache", type=Path, default=root / ".cache/build-inputs")
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    hydrate(json.loads(args.lock.read_text()), args.cache, args.destination, args.offline)


if __name__ == "__main__":
    main()
