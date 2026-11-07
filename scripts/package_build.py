#!/usr/bin/env python3
"""Run the package matrix in an isolated source snapshot."""
import argparse
import fcntl
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fetch_build_inputs import hydrate


def copy_sources(root, stage):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    for name in sorted(set(names) - {""}):
        source = root / name
        if not source.is_file() and not source.is_symlink():
            continue
        destination = stage / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            destination.symlink_to(os.readlink(source))
        else:
            shutil.copy2(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    cache = Path(os.environ.get("FSS_CACHE_DIR", root / ".cache")).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    lock_directory = root / ".cache"
    lock_directory.mkdir(exist_ok=True)
    with (lock_directory / "package-build.lock").open("w") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("A package build is already running")
        lock = json.loads((root / "build-inputs.lock.json").read_text())
        with tempfile.TemporaryDirectory(prefix="package-", dir=cache) as temporary:
            stage = Path(temporary)
            copy_sources(root, stage)
            hydrate(lock, cache / "build-inputs", stage, args.offline)
            for name, module in lock["submodules"].items():
                if "version" in module:
                    version_file = stage / "tool" / name / "VERSION"
                    version_file.parent.mkdir(parents=True, exist_ok=True)
                    version_file.write_text(module["version"] + "\n")
            for name in lock["compressed_rules"]:
                source = stage / name.removesuffix(".gz")
                with source.open("rb") as stream, (stage / name).open("wb") as output:
                    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
                        shutil.copyfileobj(stream, compressed)
            geodata_cache = cache / "geodata"
            geodata_cache.mkdir(exist_ok=True)
            (stage / ".build_geodata").symlink_to(geodata_cache)
            env = dict(os.environ, FSS_INTERNAL_BUILD="1", FSS_SOURCE_ROOT=str(root),
                       FSS_PACKAGE_DEST=str(root / "packages"), FSS_OFFLINE=str(int(args.offline)),
                       GOCACHE=str(cache / "go-build"), GOMODCACHE=str(cache / "go-mod"),
                       GOTOOLCHAIN="local", FSS_UPX=os.environ.get("FSS_UPX", str(stage / ".build-tools/upx")))
            if args.offline:
                env.update(GOPROXY="off", GOSUMDB="off")
            subprocess.run(["bash", str(stage / "build.sh")], cwd=stage, env=env, check=True)


if __name__ == "__main__":
    main()
