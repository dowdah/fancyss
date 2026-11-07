"""Exercise the routing, subscription and rollback failure paths without live services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_reliab2 import ROOT, SCRIPTS, SHUNT, SUBSCRIBE, function

HOT = (SCRIPTS / "ss_shunt_hot_reload.sh").read_text()


class HotRoutingTests(unittest.TestCase):
    def test_order_preserved_and_unknown_rules_rejected(self):
        def rule(tag, target, **match):
            return dict(type="field", ruleTag=tag, outboundTag=target, **match)

        rules = [
            dict(type="field", inboundTag=["api-in"], outboundTag="api"),
            rule("fss_recording_body", "direct", domain=["full:files.invalid"]),
            rule("fss_native_black_domain", "proxy12", domain=["domain:blocked.invalid"]),
            rule("fss_native_white_ip", "direct", ip=["192.0.2.0/24"]),
            rule("fss_user_domain", "proxy12", domain=["domain:user.invalid"]),
            rule("fss_default", "proxy12", network="tcp,udp"),
        ]
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "routes"
            for unsupported in (False, True):
                if unsupported:
                    rules.insert(-1, rule("fss_native_cn_domain", "direct", domain=["geosite:CN"]))
                config.write_text(json.dumps({"routing": {"rules": rules}}))
                result = subprocess.run(
                    ["/bin/sh", "-c", function(HOT, "hot_export_plan") + 'hot_export_plan "$1"', "test", str(config)],
                    text=True, capture_output=True,
                )
                if unsupported:
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual([line.split("|")[0] for line in result.stdout.splitlines()],
                                     [rule["ruleTag"] for rule in rules[1:]])

    def test_only_verified_generation_is_removed_after_staging(self):
        functions = "".join(function(HOT, name) for name in (
            "hot_apply_next_state", "hot_build_stage_state", "hot_make_stage_tag",
        ))
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "next").write_text("fss_recording_body|direct|||||append\nfss_default|12|||||append\n")
            (path / "last").write_text("fss_old|12|||||append\n")
            (path / "pid").write_text("fixture\n")
            for invalid in ("yes", "no"):
                result = subprocess.run(
                    ["/bin/sh", "-c", functions + r'''
HOT_NEXT_FILE=$1/next
HOT_LAST_FILE=$1/last
HOT_STAGE_FILE=$1/staged
HOT_PLAN_FILE=$1/plan
HOT_PROCESS_FILE=$1/pid
HOT_APPLIED_RULE_TS_FILE=$1/ts
hot_xray_process() { echo fixture; }
fss_shunt_loaded_node_ids() { :; }
fss_runtime_nodes_publish() { :; }
HOT_STATE_DIR=$1
hot_current_rule_ts() { echo 1; }
hot_verify_targets_loaded() { :; }
hot_verify_runtime_plan() { [ "$2" != yes ]; }
# Inject an unverified baseline before any API writes.
if [ "$2" = yes ]; then hot_verify_runtime_plan() { return 1; }; fi
hot_apply_rules_from_file() { cut -d '|' -f1 "$1"; }
hot_remove_rules_from_file() { printf 'removed=%s\n' "$(cut -d '|' -f1 "$1")"; }
hot_log() { :; }
hot_apply_next_state
''', "test", temp, invalid], text=True, capture_output=True,
                )
                if invalid == "yes":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                else:
                    self.assertEqual(result.returncode, 0, result)
                    staged = result.stdout.splitlines()
                    self.assertTrue(staged[0].startswith("fss_recording_body__"))
                    self.assertTrue(staged[1].startswith("fss_default__"))
                    self.assertEqual(staged[2], "removed=fss_old")


class PendingSubscriptionTests(unittest.TestCase):
    def test_failed_postwrite_retries_without_rewriting_nodes(self):
        functions = "".join(function(SUBSCRIBE, name) for name in (
            "sub_after_nodes_written", "sub_retry_anytls_pending", "sub_run_cache_postwrite_steps",
        ))
        functions = functions.replace(". /koolshare/scripts/ss_node_shunt.sh", ":")
        with tempfile.TemporaryDirectory() as temp:
            for path in ("fast", "full"):
                result = subprocess.run(
                    ["/bin/sh", "-c", functions + r'''
work=$1
dbus() {
    case "$1:$2" in
        get:ss_basic_enable) echo 1 ;;
        get:ss_basic_mode) echo 7 ;;
        get:fss_sub_anytls_pending) [ ! -e "$work/pending" ] || echo 1 ;;
        set:fss_sub_anytls_pending=1) touch "$work/pending" ;;
        remove:fss_sub_anytls_pending) rm -f "$work/pending" ;;
    esac
}
fss_shunt_has_anytls() { :; }
fss_shunt_loaded_node_ids() { echo 12; }
sub_run_reference_postwrite_steps() { echo "references:$1"; }
fss_airport_bootstrap_sync() { [ -f "$work/dns-ready" ]; }
fss_shunt_reconcile_anytls_subscription() { echo "reconcile:$1"; }
sub_should_refresh_runtime_caches() { return 1; }
echo_date() { :; }
rm -f "$work/dns-ready"
sub_after_nodes_written "$2" && exit 11
[ -e "$work/pending" ] || exit 12
sub_retry_anytls_pending && exit 13
touch "$work/dns-ready"
sub_retry_anytls_pending && sub_retry_anytls_pending || exit 14
[ ! -e "$work/pending" ]
''', "test", temp, path], text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result)
                self.assertEqual(result.stdout.splitlines(), [f"references:{path}", "reconcile:--retry-pending"])

    def test_pending_reconcile_checks_live_receipt_even_when_disk_digest_matches(self):
        functions = function(SHUNT, "fss_shunt_reconcile_anytls_subscription")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "meta").mkdir()
            (path / "meta/12.meta").write_text("node_type=9\nnode_rev=7\n")
            (path / "meta/12.transport").write_text("digest\n")
            (path / "anytls.applied").write_text("verified\n")
            for live in ("verified", "partial"):
                result = subprocess.run(
                    ["/bin/sh", "-c", functions + r'''
FSS_SHUNT_RUNTIME_ARTIFACT_DIR=$1
live_snapshot=$2
dbus() { case "$2" in ss_basic_enable) echo 1;; ss_basic_mode) echo 7;; esac; }
fss_shunt_has_anytls() { :; }
fss_shunt_loaded_node_ids() { echo 12; }
fss_pick_node_tool() { echo nodes; }
nodes() { echo '[{}]'; }
fss_v2_get_node_json_by_id() { echo '{"_rev":7}'; }
fss_shunt_anytls_transport_digest() { echo digest; }
fss_shunt_get_default_node_id() { echo 12; }
fss_shunt_get_effective_default_target() { echo 12; }
fss_shunt_rules_json_resolved() { echo '[]'; }
fss_get_node_field_plain() { echo 9; }
fss_shunt_log() { :; }
fss_shunt_anytls_runtime_snapshot() { echo "$live_snapshot"; }
fss_shunt_restart_after_subscription() { echo restarted; }
fss_shunt_reconcile_anytls_subscription --retry-pending
''', "test", temp, live], text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result)
                self.assertEqual(result.stdout.count("restarted"), int(live == "partial"))


class GuardTests(unittest.TestCase):
    def test_pi_restore_retries_failed_file_copy_and_service_start(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "app"
            app.mkdir()
            for filename in ("graph.py", "uploader.py"):
                (root / filename).write_text("baseline")
                (app / filename).write_text("replacement")
            (root / "pending").touch()
            commands = {
                "cp": '''
[ -f "$FSS_GUARD_ROOT/copied" ] || { touch "$FSS_GUARD_ROOT/copied"; exit 1; }
exec /bin/cp "$@"
''',
                "systemctl": '''
[ "$1" != start ] || [ -f "$FSS_GUARD_ROOT/started" ] || {
    touch "$FSS_GUARD_ROOT/started"
    exit 1
}
''',
                "flock": ":",
                "sleep": ":",
            }
            for name, body in commands.items():
                command = root / name
                command.write_text(f"#!/bin/sh\n{body}\n")
                command.chmod(0o700)
            env = dict(os.environ, FSS_GUARD_ROOT=temp, FSS_GUARD_APP=str(app),
                       PATH=temp + ":" + os.environ["PATH"])
            guard = ROOT / "integrations/camera-monitor/pi_guard.sh"
            result = subprocess.run(["/bin/sh", str(guard), "rollback"], env=env, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual((root / "audit").read_text().count("rollback_failed="), 2)
            self.assertEqual((app / "graph.py").read_text(), "baseline")
            self.assertEqual((app / "uploader.py").read_text(), "baseline")
            self.assertFalse((root / "pending").exists())

    def test_rollback_retries_and_excludes_concurrent_commit(self):
        sources = [
            ROOT / "integrations/camera-monitor/pi_guard.sh",
            ROOT / "scripts/router_native_guard.sh",
            ROOT / "scripts/router_native_v2_guard.sh",
        ]
        for source in sources:
            with self.subTest(guard=source.name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / "pending").touch()
                (root / "deadline").write_text("999999999\n")
                # Use the host's native file lock through Python when flock(1) is absent.
                flock = root / "flock"
                flock.write_text("""#!/usr/bin/env python3
import fcntl, sys
flags = {'-x': fcntl.LOCK_EX, '-u': fcntl.LOCK_UN, '-n': fcntl.LOCK_EX | fcntl.LOCK_NB}
fcntl.flock(int(sys.argv[2]), flags[sys.argv[1]])
""")
                flock.chmod(0o700)
                script = source.read_text()
                if "\nPATH=" in script:
                    script = "\n".join(line for line in script.splitlines() if not line.startswith("PATH="))
                original = function(script, "restore")
                script = script.replace(original, r'''restore() {
    [ -f "$ROOT/pending" ] || return 1
    printf 'attempt\n' >> "$ROOT/attempts"
    n=$(wc -l < "$ROOT/attempts")
    if [ "$n" -lt 2 ]; then
        sleep 0.2
        return 1
    fi
    [ ! -f "$ROOT/fail-all" ]
}
''')
                guard = root / "guard.sh"
                guard.write_text(script)
                fast_sleep = root / "sleep"
                fast_sleep.write_text('#!/bin/sh\n[ "$1" = 15 ] || exec /bin/sleep "$@"\n')
                fast_sleep.chmod(0o700)
                env = dict(os.environ, FSS_GUARD_ROOT=temp, PATH=temp + ":" + os.environ["PATH"])
                (root / "fail-all").touch()
                failure = subprocess.run(["/bin/sh", str(guard), "rollback"], env=env, timeout=5)
                self.assertNotEqual(failure.returncode, 0)
                self.assertEqual(len((root / "attempts").read_text().splitlines()), 3)
                self.assertTrue((root / "pending").is_file())
                (root / "fail-all").unlink()
                (root / "attempts").unlink()
                rollback = subprocess.Popen(["/bin/sh", str(guard), "rollback"], env=env)
                for _ in range(40):
                    if (root / "attempts").exists():
                        break
                    time.sleep(0.01)
                confirm = subprocess.run(["/bin/sh", str(guard), "commit"], env=env, timeout=5)
                self.assertNotEqual(confirm.returncode, 0)
                self.assertEqual(rollback.wait(timeout=5), 0)
                self.assertEqual(len((root / "attempts").read_text().splitlines()), 2)
                self.assertFalse((root / "pending").exists())
                self.assertTrue((root / "rolled-back").is_file())
