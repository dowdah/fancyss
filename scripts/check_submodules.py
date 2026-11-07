#!/usr/bin/env python3
"""Check that public submodule URLs provide the locked commits."""
import configparser
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    config = configparser.ConfigParser()
    config.read(ROOT / ".gitmodules")
    lock = json.loads((ROOT / "build-inputs.lock.json").read_text())
    for section in config.sections():
        path = config[section]["path"]
        url = config[section]["url"]
        if not url.startswith("https://github.com/"):
            raise SystemExit(f"Public HTTPS submodule URL required: {path}")
        name = Path(path).name
        revision = lock["submodules"][name]["commit"]
        actual = subprocess.check_output(["git", "ls-tree", "HEAD", path], cwd=ROOT, text=True).split()[2]
        if revision != actual:
            raise SystemExit(f"Lock does not match gitlink: {path}")
        cache = ROOT / ".cache/submodules" / name
        if not cache.exists():
            subprocess.run(["git", "init", "--bare", str(cache)], check=True, capture_output=True)
        exists = subprocess.run(["git", "--git-dir", str(cache), "cat-file", "-e", revision + "^{commit}"], capture_output=True)
        if exists.returncode:
            subprocess.run(["git", "--git-dir", str(cache), "fetch", "--depth=1", url, revision], check=True,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
        print(f"Verified {path} {revision}")


if __name__ == "__main__":
    main()
