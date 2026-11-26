"""The automatic AnyTLS profile promotes and demotes only on verified evidence."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "fancyss/scripts/ss_anytls_batch.sh"


class AnyTLSBatchPolicyTests(unittest.TestCase):
    def run_trial(self, profile, reason="trial", minimum=60, timeouts=1, seconds=36, concurrency=3):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "profile"
            result.write_text(json.dumps(profile))
            events = root / "events"
            events.write_text("".join(
                json.dumps(dict(id=str(index), state="timeout" if index < timeouts else "ok")) + "\n"
                for index in range(4)
            ))
            program = r'''
. "$1"
WT_ANYTLS_AUTO_PROFILE="$2"
WT_ANYTLS_AUTO_PREVIOUS="$(cat "$2")"
WT_ANYTLS_AUTO_REASON="$4"
WT_ANYTLS_AUTO_MIN="$5"
WT_ANYTLS_AUTO_COUNT=4
WT_ANYTLS_AUTO_LIMIT="$7"
WT_ANYTLS_AUTO_START=0
fss_anytls_uptime() { printf '%s\n' "$elapsed"; }
fss_anytls_batch_state() { :; }
elapsed="$6"
fss_anytls_batch_finish "$3" 0
'''
            subprocess.run(
                ["/bin/sh", "-c", program, "fixture", str(SCRIPT), str(result), str(events),
                 reason, str(minimum), str(seconds), str(concurrency)],
                check=True,
            )
            return json.loads(result.read_text())

    def setUp(self):
        self.baseline = dict(key="fixture", level=2, samples=2, sum=80, timeouts=1,
                             trial_count=0, trial_sum=0, cooldown=0)

    def test_promotes_only_after_two_useful_trials(self):
        first = self.run_trial(self.baseline, timeouts=0)
        self.assertEqual(first["level"], 2)
        self.assertEqual(first["trial_count"], 1)
        second = self.run_trial(first, timeouts=0)
        self.assertEqual(second["level"], 3)
        self.assertEqual(second["samples"], 2)
        self.assertEqual(second["sum"], 72)
        self.assertEqual(second["timeouts"], 0)

    def test_low_memory_or_extra_timeouts_reject_trial(self):
        for result in (self.run_trial(self.baseline, minimum=55),
                       self.run_trial(self.baseline, timeouts=2)):
            self.assertEqual(result["level"], 2)
            self.assertEqual(result["trial_count"], 0)
            self.assertGreater(result["cooldown"], 0)

    def test_pressure_reduces_verified_limit(self):
        result = self.run_trial(self.baseline, reason="memory_pressure", minimum=47, concurrency=2)
        self.assertEqual(result["level"], 1)
        self.assertEqual(result["samples"], 0)

    def test_pressure_in_higher_trial_returns_to_previous_limit(self):
        result = self.run_trial(self.baseline, reason="memory_pressure", minimum=47)
        self.assertEqual(result["level"], 2)

    def test_manual_batch_only_tries_higher_with_headroom_and_no_shunt_update(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "configs/fancyss").mkdir(parents=True)
            targets = root / "targets"
            targets.write_text("1|10001\n2|10002\n3|10003\n4|10004\n")
            inputs = root / "probe-inputs"
            inputs.write_text("original settings")
            program = r'''
. "$1"
export KSROOT="$2" FSS_WEBTEST_MANUAL=1
nvram() { printf '%s\n' "$firmware"; }
wt_pick_webtest_tool() { echo /bin/sh; }
fss_anytls_mem_mib() { echo "$memory"; }
fss_anytls_uptime() { echo 100; }
fss_anytls_batch_state() { :; }
fss_anytls_batch_shunt_idle() { [ "$idle" = yes ]; }
begin() {
    fss_anytls_batch_begin "$1" /bin/sh "$2" || exit 1
    printf '%s:%s\n' "$WT_ANYTLS_AUTO_LIMIT" "$WT_ANYTLS_AUTO_REASON"
}
firmware=one memory=68 idle=yes
begin "$3" "$4"
printf '%s' "$WT_ANYTLS_AUTO_PREVIOUS" | jq '.level=2|.sum=80|.samples=2' > "$WT_ANYTLS_AUTO_PROFILE"
begin "$3" "$4"
idle=no
begin "$3" "$4"
idle=yes memory=55
begin "$3" "$4"
firmware=two memory=68
begin "$3" "$4"
firmware=one memory=68
printf '%s\n' '1|20001' '2|20002' '3|20003' '4|20004' > "$3"
begin "$3" "$4"
printf '%s' 'changed settings with the same node IDs' > "$4"
begin "$3" "$4"
'''
            output = subprocess.check_output(
                ["/bin/sh", "-c", program, "fixture", str(SCRIPT), str(root), str(targets), str(inputs)], text=True
            )
            self.assertEqual(output.splitlines(), [
                "1:", "3:trial", "2:shunt_busy", "2:low_headroom", "1:", "3:trial", "1:",
            ])
