#!/usr/bin/env python3
"""Check every platform package before a release draft is created."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import sys
import tarfile

PLATFORMS = ("hnd", "hnd_v8", "qca", "arm", "mtk", "ipq32", "ipq64")


def verify_package(root, entry, source_commit):
    path = root / entry["name"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit(f"Package checksum mismatch: {path.name}")
    platform = next(name for name in sorted(PLATFORMS, key=len, reverse=True) if path.name.startswith(f"fancyss_{name}_"))
    machine = 183 if platform in ("hnd_v8", "mtk", "ipq64") else 40
    with tarfile.open(path) as package:
        names = set()
        for member in package:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or name.parts[0] != "shadowsocks":
                raise SystemExit(f"Unsafe package member: {member.name}")
            if member.name in names:
                raise SystemExit(f"Duplicate package member: {member.name}")
            names.add(member.name)
            if member.isfile() and member.name.startswith("shadowsocks/bin/"):
                with package.extractfile(member) as stream:
                    header = stream.read(20)
                if header.startswith(b"\x7fELF"):
                    actual = struct.unpack_from("<H" if header[5] == 1 else ">H", header, 18)[0]
                    # This existing HND v8 utility uses its supported 32-bit userland.
                    expected_machine = 40 if (platform, member.name) == ("hnd_v8", "shadowsocks/bin/dnsclient") else machine
                    if actual != expected_machine or member.mode & 0o111 == 0:
                        raise SystemExit(f"Wrong architecture or mode: {path.name}:{member.name}")
        required = {"shadowsocks/install.sh", "shadowsocks/ss/fork-build.json", "shadowsocks/scripts/airport-node-dns.sh"}
        if "_full" in path.name:
            required.add("shadowsocks/bin/fss-anytls-client")
        if not required <= names:
            raise SystemExit(f"Missing required files: {path.name}: {required - names}")
        meta = json.load(package.extractfile("shadowsocks/ss/fork-build.json"))
        if meta["source_commit"] != source_commit:
            raise SystemExit(f"Wrong package source: {path.name}")
        kind = "full" if "_full" in path.name else "lite"
        release_type = "debug" if "_debug" in path.name else "release"
        if meta["platform"] != f"{platform}/{kind}" or meta["release_type"] != release_type:
            raise SystemExit(f"Wrong package identity: {path.name}")
        if package.extractfile("shadowsocks/.valid").read().strip().decode() != platform:
            raise SystemExit(f"Wrong firmware platform: {path.name}")
    print(f"Verified {path.name}")


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "packages")
    expected = {f"fancyss_{platform}_{kind}.tar.gz" for platform in PLATFORMS for kind in ("full", "lite", "full_debug")}
    manifest = json.loads((root / "release.json").read_text())
    if {entry["name"] for entry in manifest["packages"]} != expected:
        raise SystemExit("Incomplete release matrix")
    for entry in manifest["packages"]:
        verify_package(root, entry, manifest["source_commit"])


if __name__ == "__main__":
    main()
