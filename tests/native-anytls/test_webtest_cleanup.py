"""AnyTLS batch cleanup must stop every recorded instance and retain failures."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "fancyss/scripts/ss_webtest.sh"
POLICY = SCRIPT.with_name("ss_anytls_batch.sh")


def shell_functions(*names):
    source = SCRIPT.read_text()
    result = []
    for name in names:
        match = re.search(rf"(?m)^{name}\(\)\s*([{{(])", source)
        start = match.start()
        end = source.index("\n" + ("}" if match[1] == "{" else ")"), start) + 2
        result.append(source[start:end])
    return "\n".join(result) + "\n"


class WebtestCleanupTests(unittest.TestCase):
    def test_stop_replays_late_results_before_marking_unfinished_nodes(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "hooks_09").mkdir()
            (runtime / "hooks_09/3.status").write_text("configuration")
            (runtime / "webtest.state").write_text(
                "1>testing...\n2>queued...\n3>testing...\n4>waiting...\n5>tls_failed\n"
            )
            (runtime / "anytls-webtest.json").write_text('{"phase":"running","concurrency":2,"total":5}')
            program = POLICY.read_text().replace("/tmp/upload", "$TMP2")
            program += shell_functions(
                "wt_webtest_result_state", "wt_replay_batch_results", "wt_get_batch_state",
                "wt_mark_unfinished_batch_nodes", "wt_abort_batch_run", "wt_finish_batch_run", "wt_request_stop_batch",
            ).replace("/tmp/webtest.lock", "$TMP2/webtest.lock")
            program += r'''
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
WT_WEBTEST_STATE_LOCK="$TMP2/state.lock"
WT_WEBTEST_PID_FILE="$TMP2/batch.pid"
ps() { :; }
wt_pick_jq() { echo jq; }
wt_runtime_cleanup() {
    cat > "$TMP2/webtest_tool_09.stream.jsonl" <<'EVENTS'
{"id":"1","state":"ok","latency_ms":41.5}
{"id":"2","state":"stopped"}
{"id":"3","state":"failed"}
{"id":"4","state":"testing"}
{"id":"5","state":"failed"}
{"id":"4","state":
EVENTS
    [ "$1" = replay ] && wt_replay_batch_results
}
wt_set_batch_state() {
    awk -F '>' -v id="$1" -v state="$2" '$1==id {$0=id ">" state} 1' "$WT_WEBTEST_STATE_FILE" > "$TMP2/state.next"
    mv "$TMP2/state.next" "$WT_WEBTEST_STATE_FILE"
}
wt_emit_batch_state_diff() { :; }
wt_finalize_batch_output() { cp "$WT_WEBTEST_STATE_FILE" "$TMP2/final"; }
wt_request_stop_batch
'''
            subprocess.run(
                ["/bin/sh", "-c", program],
                env={**os.environ, "TMP2": str(runtime)}, check=True,
            )
            self.assertEqual((runtime / "final").read_text().splitlines(), [
                "1>41.5", "2>stopped", "3>configuration_failed", "4>stopped", "5>tls_failed",
            ])
            progress = json.loads((runtime / "anytls-webtest.json").read_text())
            self.assertEqual((progress["phase"], progress["completed"], progress["running"]), ("canceled", 3, 0))

    def test_automatic_anytls_jobs_keep_sampling_independent_of_history(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            targets = runtime / "targets"
            targets.write_text("1|1234|||1234|5000\n")
            program = shell_functions("wt_webtest_tool_build_targets_job") + r'''
wt_pick_jq() { echo jq; }
wt_webtest_group_label() { echo anytls; }
wt_get_previous_webtest_latency() { printf '%s' "$historical_latency"; }
ss_basic_furl=https://example.invalid/
WT_ANYTLS_AUTO_ACTIVE="$2"
historical_latency="$3"
wt_webtest_tool_build_targets_job "$1/targets" "$1/job.json" results events 2 09 legacy stream
'''
            jobs = []
            for automatic, previous in (("1", ""), ("1", "40"), ("0", "40")):
                subprocess.run(
                    ["/bin/sh", "-c", program, "fixture", str(runtime), automatic, previous], check=True
                )
                jobs.append(json.loads((runtime / "job.json").read_text()))
            for job in jobs[:2]:
                self.assertEqual((job["warmup"], job["attempts"]), (1, 2))
                self.assertNotIn("previous_latency_ms", job["groups"][0]["targets"][0])
            self.assertEqual(jobs[2]["groups"][0]["targets"][0]["previous_latency_ms"], 40)

    def test_auto_mode_low_memory_does_not_stop_an_xray_only_group(self):
        program = shell_functions("test_nodes") + r'''
dbus() { [ "$2" != ss_basic_row ] || echo 20; }
fss_get_current_node_id() { echo 1; }
detect_perf() { :; }
wt_probe_memory_pressure() { return 0; }
test_xray_group() { echo xray-ran; }
WT_GROUP_ORDER_PREPARED=1 WT_PREVIEW_READY=1
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
test_nodes
'''
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "nodes_file_name.txt").write_text("wt_test_05.txt\n")
            (runtime / "wt_xray_group.txt").write_text("1\n")
            result = subprocess.check_output(
                ["/bin/sh", "-c", program],
                env={**os.environ, "TMP2": str(runtime)}, text=True,
            )
            self.assertEqual(result.strip(), "xray-ran")

    def test_anytls_run_skips_a_bad_first_node_and_guards_only_capable_clients(self):
        program = shell_functions("wt_start_anytls_batch", "wt_wait_anytls_batch_ready", "test_13_at") + r'''
dbus() { echo auto; }
wt_pick_webtest_tool() { echo /bin/sh; }
wt_pick_jq() { echo jq; }
wt_set_batch_state_from_file() { :; }
wt_prepare_protocol_targets_workspace() {
    : > "$1"
    : > "$2"
    mkdir -p "$3"
}
wt_shell_quote() { printf "'%s'" "$1"; }
wt_anytls_hostport() { printf '%s:%s' "$1" "$2"; }
wt_get_reserved_port() { echo $((10000 + nu)); }
wt_node_get_plain() {
    case "$1:$2" in
    anytls_server:*) echo example.invalid ;;
    anytls_port:1) echo 65536 ;;
    anytls_port:2) echo 443 ;;
    anytls_pass:*) echo example-password ;;
    esac
}
wt_append_protocol_target_row() {
    printf '%s|%s|%s|%s|%s|%s\n' "$3" "$4" "$5" "$6" "$7" "$8" >> "$1"
    printf '%s\n' "$3" >> "$2"
}
fss_require_base_dns() { :; }
fss_airport_bootstrap_sync() { :; }
wt_stop_anytls_batch() { :; }
flock() { :; }
usleep() { sleep 0.01; }
fss_anytls_batch_finish() { :; }
fss_anytls_batch_begin() {
    printf 'auto-guard\n'
    ! grep -q 'example-password' "$3" || exit 9
    WT_ANYTLS_AUTO_LIMIT=2
}
wait_local_port() { exit 8; }
wt_try_webtest_tool_targets_batch() {
    if [ "$WT_ANYTLS_AUTO_ACTIVE" = 0 ]; then
        echo legacy-ran
        return
    fi
    first="$(awk -F '|' 'NR==1 {print $3}' "$1")"
    second="$(awk -F '|' 'NR==2 {print $3}' "$1")"
    if /bin/sh "$first"; then exit 6; fi
    /bin/sh "$second" || exit 7
    echo valid-node-ran
}
WT_SINGLE=0 WT_ANYTLS_THREADS=1
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
test_13_at "$TMP2/nodes" 09
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            client = root / "client"
            client.write_text(r'''#!/bin/sh
case "$1" in
    --capabilities) echo "$CLIENT_FEATURES" ;;
    --webtest-manifest)
        printf '%s' configuration > "$(jq -r '.nodes[0].status_file' "$2")"
        : > "$(jq -r '.ready_file' "$2")"
        ;;
esac
''')
            client.chmod(0o700)
            for index, features in enumerate(("webtest-manifest", "webtest-manifest webtest-ready-file")):
                runtime = root / str(index)
                runtime.mkdir()
                (runtime / "conf").mkdir()
                (runtime / "nodes").write_text("1\n2\n")
                result = subprocess.check_output(
                    ["/bin/sh", "-c", program],
                    env={**os.environ, "TMP2": str(runtime), "FSS_ANYTLS_BINARY": str(client),
                         "CLIENT_FEATURES": features}, text=True,
                )
                self.assertEqual(result.splitlines(), [
                    ["legacy-ran"], ["auto-guard", "valid-node-ran"],
                ][index])

    def test_failed_cleanup_replays_results_without_finalizing_and_can_retry(self):
        program = shell_functions(
            "wt_runtime_cleanup", "wt_abort_batch_run", "wt_finish_batch_run",
        ).replace("/tmp/webtest.lock", "$TMP2/webtest.lock")
        program += r'''
WT_WEBTEST_PID_FILE="$TMP2/runner.pid"
WT_WEBTEST_STATE_LOCK="$TMP2/state.lock"
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
WT_BATCH_FINALIZED=0
touch "$TMP2/webtest.lock" "$WT_WEBTEST_PID_FILE" "$WT_WEBTEST_STATE_LOCK"
echo memory_pressure > "$WT_WEBTEST_STOP_FLAG"
writers=1
helpers=1
ps() { :; }
killall() { :; }
find() { :; }
wt_stop_batch_result_writers() { return "$writers"; }
wt_stop_anytls_batch() { return "$helpers"; }
wt_replay_batch_results() { echo replay; }
wt_mark_unfinished_batch_nodes() { echo "mark=$1"; }
wt_finalize_batch_output() { echo finalize; }
still_retryable() {
    [ -f "$TMP2/webtest.lock" ] && [ -f "$WT_WEBTEST_PID_FILE" ] &&
        [ -f "$WT_WEBTEST_STATE_LOCK" ] && [ -f "$WT_WEBTEST_STOP_FLAG" ] &&
        [ "$WT_BATCH_FINALIZED" = 0 ]
}
if wt_abort_batch_run memory_pressure; then exit 3; fi
still_retryable || exit 4
writers=0
if wt_abort_batch_run memory_pressure; then exit 5; fi
still_retryable || exit 6
echo retry
helpers=0
wt_abort_batch_run memory_pressure || exit 7
[ ! -e "$TMP2/webtest.lock" ] && [ ! -e "$WT_WEBTEST_STOP_FLAG" ] && [ "$WT_BATCH_FINALIZED" = 1 ]
'''
        with tempfile.TemporaryDirectory() as directory:
            output = subprocess.check_output(
                ["/bin/sh", "-c", program], env={**os.environ, "TMP2": directory}, text=True,
            )
        self.assertEqual(output.splitlines(), ["replay", "retry", "replay", "mark=canceled", "finalize"])

    def test_anytls_group_failure_reaches_batch_runner(self):
        program = shell_functions("test_nodes") + r'''
dbus() { echo 20; }
fss_get_current_node_id() { echo 1; }
detect_perf() { :; }
test_13_at() { return 9; }
test_xray_group() { echo should-not-run; }
WT_GROUP_ORDER_PREPARED=1 WT_PREVIEW_READY=1
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
test_nodes
'''
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "nodes_file_name.txt").write_text("wt_test_09.txt\nwt_test_05.txt\n")
            (runtime / "wt_xray_group.txt").write_text("1\n")
            result = subprocess.run(
                ["/bin/sh", "-c", program], env={**os.environ, "TMP2": directory},
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout, "")

    def test_clear_removes_progress_only_after_successful_cleanup(self):
        program = shell_functions("clean_webtest").replace("/tmp/webtest.lock", "$TMP2/webtest.lock")
        program = program.replace("/tmp/upload", "$TMP2")
        program += r'''
WT_WEBTEST_FILE="$TMP2/latency.txt"
WT_WEBTEST_STREAM="$TMP2/latency.stream"
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
WT_WEBTEST_PID_FILE="$TMP2/runner.pid"
ps() { :; }
wt_runtime_cleanup() { return "$failure"; }
touch "$TMP2/anytls-webtest.json" "$TMP2/webtest.lock"
failure=1
if clean_webtest; then exit 3; fi
[ -f "$TMP2/anytls-webtest.json" ] && [ -f "$TMP2/webtest.lock" ] || exit 4
failure=0
clean_webtest || exit 5
[ ! -e "$TMP2/anytls-webtest.json" ] && [ ! -e "$TMP2/webtest.lock" ]
'''
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                ["/bin/sh", "-c", program], env={**os.environ, "TMP2": directory}, check=True,
            )

    @unittest.skipUnless(Path("/proc/self/stat").is_file(), "requires Linux process ownership checks")
    def test_restart_waits_for_pid_registration_and_client_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hooks = root / "hooks_09"
            hooks.mkdir()
            (hooks / "manifest.json").touch()
            programs = {
                "flock": "#!/usr/bin/env python3\nimport fcntl, sys\n"
                         "fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)\n",
                "mv": r'''#!/bin/sh
: > "$TMP2/registration-paused"
while [ ! -e "$TMP2/resume-registration" ]; do sleep 0.01; done
exec /bin/mv "$@"
''',
                "client": r'''#!/bin/sh
[ -e "$TMP2/hooks_09/.stopped" ] || exit 3
: > "$TMP2/client-saw-stop"
while [ ! -e "$TMP2/finish-client" ]; do sleep 0.01; done
''',
            }
            for name, contents in programs.items():
                path = root / name
                path.write_text(contents)
                path.chmod(0o700)
            program = shell_functions(
                "wt_start_anytls_batch", "wt_stop_anytls_batch", "wt_wait_pid_with_timeout",
            ) + r'''
WT_WEBTEST_STOP_FLAG="$TMP2/stop"
if [ "$1" = launch ]; then
    wt_start_anytls_batch "$TMP2/hooks_09" "$TMP2/client" "$TMP2/hooks_09/manifest.json" || exit 1
    wait "$batch_pid"
else
    wt_stop_anytls_batch && rm -rf "$TMP2/hooks_09"
fi
'''
            env = {**os.environ, "TMP2": str(root), "PATH": f"{root}:{os.environ['PATH']}"}

            def until_exists(path):
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(path.exists(), path.name)

            launcher = subprocess.Popen(["/bin/sh", "-c", program, "fixture", "launch"], env=env)
            cleaner = None
            try:
                until_exists(root / "registration-paused")
                self.assertFalse((hooks / "batch.pid").exists())
                launcher.kill()
                launcher.wait(timeout=3)
                cleaner = subprocess.Popen(["/bin/sh", "-c", program, "fixture", "clean"], env=env)
                until_exists(hooks / ".stopped")
                self.assertIsNone(cleaner.poll())
                (root / "resume-registration").touch()
                until_exists(root / "client-saw-stop")
                self.assertRegex((hooks / "batch.pid").read_text().strip(), r"^[1-9][0-9]*$")
                self.assertTrue((hooks / ".stopped").is_file())
                self.assertIsNone(cleaner.poll())
                (root / "finish-client").touch()
                self.assertEqual(cleaner.wait(timeout=7), 0)
                self.assertFalse(hooks.exists())
            finally:
                (root / "resume-registration").touch()
                (root / "finish-client").touch()
                if launcher.poll() is None:
                    launcher.wait(timeout=3)
                if cleaner is not None and cleaner.poll() is None:
                    cleaner.wait(timeout=7)

    @unittest.skipUnless(shutil.which("node"), "requires Node.js")
    def test_stale_progress_responses_do_not_repopulate_cleared_ui(self):
        page = SCRIPT.parent.parent / "webs/Module_shadowsocks.asp"
        source = page.read_text()
        functions = source[
            source.index("var anytlsWebtestProgressAt"):source.index("function is_latency_transient_state")
        ]
        run = r'''
const assert = require("node:assert/strict");
let text = "";
const requests = [];
function $() {
    return {length: 1, text(value) { text = value; }, empty() { text = ""; }};
}
$.ajax = function() {
    const callbacks = {};
    requests.push(callbacks);
    return {
        done(fn) { callbacks.done = fn; return this; },
        fail(fn) { callbacks.fail = fn; return this; }
    };
};
''' + functions + r'''
const old = {concurrency: 2, phase: "complete", completed: 10, total: 10, timeouts: 1};
refresh_anytls_webtest_progress(true);
requests[0].done(old);
assert.match(text, /超时 1/);
refresh_anytls_webtest_progress(true);
clear_anytls_webtest_progress();
requests[1].done(old);
assert.equal(text, "");
refresh_anytls_webtest_progress(true);
requests[2].done({...old, concurrency: 3, completed: 8});
requests[1].fail();
assert.match(text, /3 并发档/);
'''
        subprocess.run(["node"], input=run, text=True, check=True)

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
