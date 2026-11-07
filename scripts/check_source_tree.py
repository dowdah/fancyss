#!/usr/bin/env python3
"""Reject local work files and generated artifacts in the source repository."""
from pathlib import Path
import argparse
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOCAL_ROOTS = {".cache", "artifacts", "local-reports", "packages", "shadowsocks", "tmp_test_file"}
BINARY_MAGIC = (b"\x7fELF", b"MZ", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\x1f\x8b", b"PK\x03\x04", b"\xfd7zXZ\x00")


def local_path(name):
    return name.partition("/")[0] in LOCAL_ROOTS


def problem(name, data):
    if name.endswith((".tar.gz", ".tar.xz", ".zip", ".dat", ".gz", ".tar", ".xz", ".bz2", ".7z")):
        return "generated archive or data"
    if data.startswith(BINARY_MAGIC):
        return "compiled executable or binary archive"
    if len(data) > 10 * 1024 * 1024:
        return "file exceeds 10 MiB"
    return None


def check_history(revision_range):
    # A rename can reuse an old blob, and a later commit can remove its path.
    # Check each commit's destinations separately from the new Git objects.
    changed_paths = subprocess.check_output([
        "git", "log", "--root", "--format=", "--name-only", "-z", "--no-renames",
        "--diff-filter=AMT", "--diff-merges=first-parent", revision_range, "--",
    ], cwd=ROOT)
    failures = [f"{name}: local-only path in commit range"
                for name in sorted(set(os.fsdecode(changed_paths).split("\0"))) if local_path(name)]
    objects = subprocess.check_output(["git", "rev-list", "--objects", revision_range], cwd=ROOT, text=True)
    names = {}
    for entry in objects.splitlines():
        sha, _, name = entry.partition(" ")
        names[sha] = name
    if not names:
        return failures
    metadata = subprocess.check_output(
        ["git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        cwd=ROOT, input="\n".join(names) + "\n", text=True)
    process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for entry in metadata.splitlines():
            sha, kind, size = entry.split()
            if kind != "blob":
                continue
            name = names[sha]
            if int(size) > 10 * 1024 * 1024:
                failures.append(f"{name or sha}: new object exceeds 10 MiB")
                continue
            process.stdin.write((sha + "\n").encode())
            process.stdin.flush()
            header = process.stdout.readline().decode().split()
            data = process.stdout.read(int(header[2]))
            process.stdout.read(1)
            reason = problem(name, data)
            if reason:
                failures.append(f"{name or sha}: {reason}")
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait()
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--range", help="Also inspect added paths and new objects in this commit range")
    args = parser.parse_args()
    failures = []
    files = os.fsdecode(subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)).split("\0")
    for name in files:
        if local_path(name):
            failures.append(f"{name}: local-only path in index")
            continue
        path = ROOT / name
        if not name or not path.is_file():
            continue
        reason = problem(name, path.read_bytes())
        if reason:
            failures.append(f"{name}: {reason}")
    if args.range:
        failures.extend(check_history(args.range))
    if failures:
        raise SystemExit("\n".join(failures))
    print("Source tree contains no local-only paths, generated archives or compiled programs")


if __name__ == "__main__":
    main()
