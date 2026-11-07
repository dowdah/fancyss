from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[2] / "scripts/check_source_tree.py"


class SourceTreeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.git("init", "-q")
        (self.root / "scripts").mkdir()
        self.checker = self.root / "scripts" / CHECKER.name
        shutil.copyfile(CHECKER, self.checker)

    def git(self, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=self.root, text=True).strip()

    def track(self, name, content="fixture"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        self.git("add", "-f", "--", name)
        return path

    def check(self, *args):
        return subprocess.run([sys.executable, str(self.checker), *args],
                              capture_output=True, text=True)

    def test_rejects_index_paths_even_when_file_is_missing(self):
        for directory in ("tmp_test_file", "artifacts", "local-reports", ".cache", "packages", "shadowsocks"):
            self.track(f"{directory}/sample.txt").unlink()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        for directory in ("tmp_test_file", "artifacts", "local-reports", ".cache", "packages", "shadowsocks"):
            self.assertIn(f"{directory}/sample.txt: local-only path in index", result.stderr)

    def test_rejects_added_and_renamed_paths_removed_later(self):
        self.track("tests/fixture.txt")
        self.git("commit", "-qm", "base")
        base = self.git("rev-parse", "HEAD")
        self.track("local-reports/new.txt", "new file")
        (self.root / "tmp_test_file").mkdir()
        self.git("mv", "tests/fixture.txt", "tmp_test_file/renamed.txt")
        self.git("commit", "-qm", "introduce local paths")
        self.git("rm", "-q", "local-reports/new.txt", "tmp_test_file/renamed.txt")
        self.git("commit", "-qm", "remove local paths")
        self.assertEqual(self.check().returncode, 0)
        result = self.check("--range", f"{base}..HEAD")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local-reports/new.txt: local-only path in commit range", result.stderr)
        self.assertIn("tmp_test_file/renamed.txt: local-only path in commit range", result.stderr)

    def test_accepts_component_metadata_and_nested_fixtures(self):
        self.track("binaries/example/v1/md5sum.txt")
        self.track("tests/fixtures/artifacts/sample.txt")
        self.git("commit", "-qm", "source files")
        result = self.check("--range", "HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)
