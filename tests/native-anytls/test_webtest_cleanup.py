"""AnyTLS batch cleanup must stop every recorded instance and retain failures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "fancyss/scripts/ss_webtest.sh"


class WebtestCleanupTests(unittest.TestCase):
    def test_cleanup_uses_owned_stop_hooks_and_reports_failure(self):
        source = SCRIPT.read_text()
        start = source.index("wt_stop_anytls_batch() (")
        end = source.index("\nwt_runtime_cleanup()", start)
        program = source[start:end] + """
flock() { [ "$*" = "-x 9" ] && [ -f "$TMP2/hooks_09/.stopped" ]; }
echo_date() { printf '%s\n' "$*"; }
wt_stop_anytls_batch
"""
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            hooks = runtime / "hooks_09"
            pids = runtime / "pids"
            hooks.mkdir()
            pids.mkdir()
            for node in (1, 2, 4):
                (pids / f"anytls_{node}.pid").touch()
            (hooks / "1.stop.sh").write_text('rm "$TMP2/pids/anytls_1.pid"\n')
            (hooks / "2.stop.sh").write_text("exit 1\n")
            (hooks / "3.stop.sh").write_text('touch "$TMP2/unstarted_hook_called"\n')
            (hooks / "4.stop.sh").write_text('rm "$TMP2/pids/anytls_4.pid"\n')

            result = subprocess.run(
                ["/bin/sh", "-c", program],
                env={**os.environ, "TMP2": str(runtime)},
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual([path.name for path in pids.iterdir()], ["anytls_2.pid"])
            self.assertFalse((runtime / "unstarted_hook_called").exists())


if __name__ == "__main__":
    unittest.main()
