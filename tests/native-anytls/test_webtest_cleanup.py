"""AnyTLS batch cleanup must stop every recorded instance and retain failures."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "fancyss/scripts/ss_webtest.sh"
POLICY = SCRIPT.with_name("ss_anytls_batch.sh")


def shell_functions(*names):
    source = SCRIPT.read_text()
    result = []
    for name in names:
        start = re.search(rf"(?m)^{name}\(\)\s*\{{", source).start()
        end = source.index("\n}", start) + 2
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
                "wt_mark_unfinished_batch_nodes", "wt_request_stop_batch",
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
        program = shell_functions("wt_wait_anytls_batch_ready", "test_13_at") + r'''
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
usleep() { sleep 0.01; }
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
