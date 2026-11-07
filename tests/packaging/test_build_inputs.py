import hashlib
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import fetch_build_inputs as inputs
from verify_packages import verify_package


class InputsTests(unittest.TestCase):
    def fixture(self, root, name="bin/program"):
        data = b"fixture executable"
        archive = root / "input.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            item = tarfile.TarInfo(name)
            item.mode = 0o755
            item.size = len(data)
            tar.addfile(item, io.BytesIO(data))
        asset = dict(name=archive.name, url="https://example.invalid/input", sha256=inputs.digest(archive),
                     files=[dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), mode=0o755)])
        return archive, asset

    def test_download_then_offline_hydration_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, asset = self.fixture(root)
            with patch.object(inputs.urllib.request, "urlopen", return_value=io.BytesIO(archive.read_bytes())):
                inputs.hydrate(dict(assets=[asset]), root / "cache", root / "online")
            inputs.hydrate(dict(assets=[asset]), root / "cache", root / "offline", True)
            self.assertEqual((root / "online/bin/program").read_bytes(), (root / "offline/bin/program").read_bytes())
            self.assertEqual((root / "offline/bin/program").stat().st_mode & 0o777, 0o755)

    def test_missing_offline_input_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, asset = self.fixture(root)
            with self.assertRaises(FileNotFoundError):
                inputs.hydrate(dict(assets=[asset]), root / "cache", root / "output", True)

    def test_corrupt_download_not_cached(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, asset = self.fixture(root)
            with patch.object(inputs.urllib.request, "urlopen", return_value=io.BytesIO(b"corrupt")):
                with self.assertRaises(ValueError):
                    inputs.obtain(asset, root / "cache")
            self.assertEqual(list((root / "cache").iterdir()), [])

    def test_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, asset = self.fixture(root, "../outside")
            cache = root / "cache"
            cache.mkdir()
            (cache / asset["sha256"]).write_bytes(archive.read_bytes())
            with self.assertRaises(ValueError):
                inputs.hydrate(dict(assets=[asset]), cache, root / "output", True)
            self.assertFalse((root / "outside").exists())

    def test_corrupt_cached_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, asset = self.fixture(root)
            cache = root / "cache"
            cache.mkdir()
            (cache / asset["sha256"]).write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                inputs.obtain(asset, cache, True)

    def test_interrupted_download_leaves_no_cache(self):
        class BrokenResponse(io.BytesIO):
            def read(self, size=-1):
                raise ConnectionError("download interrupted")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, asset = self.fixture(root)
            with patch.object(inputs.urllib.request, "urlopen", return_value=BrokenResponse()):
                with self.assertRaises(ConnectionError):
                    inputs.obtain(asset, root / "cache")
            self.assertEqual(list((root / "cache").iterdir()), [])

    def test_missing_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, asset = self.fixture(root)
            cache = root / "cache"
            cache.mkdir()
            (cache / asset["sha256"]).write_bytes(archive.read_bytes())
            asset["files"].append(dict(path="bin/missing", bytes=0, sha256=hashlib.sha256(b"").hexdigest(), mode=0o644))
            with self.assertRaises(ValueError):
                inputs.hydrate(dict(assets=[asset]), cache, root / "output", True)

    def test_partial_matrix_cannot_replace_existing_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packages = root / "packages"
            packages.mkdir()
            (packages / "old-success").write_text("keep")
            result = subprocess.run([sys.executable, str(ROOT / "scripts/write_release_metadata.py"),
                                     str(packages), str(ROOT)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((packages / "old-success").read_text(), "keep")

    def test_archive_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, asset = self.fixture(root)
            with tarfile.open(archive, "w:gz") as tar:
                entry = tarfile.TarInfo("bin/program")
                entry.type = tarfile.SYMTYPE
                entry.linkname = "../../outside"
                tar.addfile(entry)
            asset["sha256"] = inputs.digest(archive)
            cache = root / "cache"
            cache.mkdir()
            (cache / asset["sha256"]).write_bytes(archive.read_bytes())
            with self.assertRaises(ValueError):
                inputs.hydrate(dict(assets=[asset]), cache, root / "output", True)

    def test_concurrent_build_with_different_cache_is_rejected(self):
        cache = ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        with (cache / "package-build.lock").open("w") as lock_file, tempfile.TemporaryDirectory() as alternate:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/package_build.py"), "--offline"],
                env=dict(os.environ, FSS_CACHE_DIR=alternate), capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already running", result.stderr)

    def test_failed_staged_build_preserves_sources_and_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            for name in ("package_build.py", "fetch_build_inputs.py"):
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text(".cache/\npackages/\n")
            (root / "build-inputs.lock.json").write_text(json.dumps(dict(assets=[], submodules={}, compressed_rules=[])))
            (root / "build.sh").write_text("printf changed > source-marker\nexit 7\n")
            (root / "source-marker").write_text("original")
            (root / "packages").mkdir()
            (root / "packages" / "old-success").write_text("keep")
            result = subprocess.run([sys.executable, str(root / "scripts/package_build.py"), "--offline"],
                env={k: v for k, v in os.environ.items() if k != "FSS_CACHE_DIR"}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "source-marker").read_text(), "original")
            self.assertEqual((root / "packages/old-success").read_text(), "keep")
            self.assertEqual(list((root / ".cache").glob("package-*/")), [])

    def test_wrong_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "fancyss_hnd_full.tar.gz"
            header = bytearray(20)
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, 62)  # x86_64 in an ARM package
            with tarfile.open(path, "w:gz") as package:
                member = tarfile.TarInfo("shadowsocks/bin/fss-anytls-client")
                member.mode = 0o755
                member.size = len(header)
                package.addfile(member, io.BytesIO(header))
            entry = dict(name=path.name, sha256=inputs.digest(path))
            with self.assertRaisesRegex(SystemExit, "Wrong architecture"):
                verify_package(root, entry, "test")

    def test_published_directory_is_readable_by_the_uploading_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "private-stage"
            stage.mkdir(mode=0o700)
            (stage / "package.tar.gz").write_bytes(b"package")
            output = root / "packages"
            result = subprocess.run(["bash", "-ec", 'source "$1"; PACKAGES_DIR="$2"; FSS_PACKAGE_DEST="$3"; publish_packages',
                                     "publish-test", str(ROOT / "build.sh"), str(stage), str(output)],
                                     capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.stat().st_mode & 0o777, 0o755)
            self.assertEqual((output / "package.tar.gz").read_bytes(), b"package")


if __name__ == "__main__":
    unittest.main()
