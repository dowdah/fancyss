#!/usr/bin/env python3
"""Write package identity and hashes before atomically publishing the matrix."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

packages, source = map(Path, sys.argv[1:])
entries = []
checksums = []
for package in sorted(packages.glob("*.tar.gz")):
    with package.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    checksums.append(f"{checksum}  {package.name}\n")
    entries.append(dict(name=package.name, sha256=checksum, bytes=package.stat().st_size))
if len(entries) != 21:
    raise SystemExit(f"Incomplete package matrix: {len(entries)} of 21 packages")
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
(packages / "SHA256SUMS").write_text("".join(checksums))
(packages / "release.json").write_text(json.dumps({
    "source_commit": commit,
    "inputs_sha256": hashlib.sha256((source / "build-inputs.lock.json").read_bytes()).hexdigest(),
    "packages": entries,
}, indent=2) + "\n")
