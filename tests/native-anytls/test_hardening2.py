"""Runtime receipts and ordered DNS decisions use credentials-free fixtures."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_airport_dns
from test_reliab2 import ROOT, function

RUNTIME = ROOT / "fancyss/scripts/ss_runtime_nodes.sh"
POLICY = ROOT / "fancyss/scripts/ss_shunt_dns_policy.sh"


class RunningManualDnsTests(unittest.TestCase):
    command = test_airport_dns.AirportDnsTests.command
    run_script = test_airport_dns.AirportDnsTests.run_script
    def setUp(self):
        test_airport_dns.AirportDnsTests.setUp(self)
        self.command("dbus", 'echo 1')
        self.env["AIRPORT_RUNTIME_HELPER"] = str(RUNTIME)
        self.env["FSS_ACTIVE_NODES_FILE"] = str(self.root / "active-nodes")
        self.env["FSS_RUNTIME_PROC"] = str(self.proc)
        (self.proc / "88").mkdir()
        (self.proc / "88/exe").symlink_to("/fixture/xray")
        (self.proc / "88/stat").write_text("88 (xray) " + " ".join(["S"] + ["0"] * 18 + ["77"]) + "\n")
        (self.root / "active-nodes").write_text("owner 88 77 /fixture/xray\nnode 9\n")
        (self.root / "suffixes").write_text("airport.invalid\n")
        (self.root / "manual.json").write_text('[{"id":"9","airport_identity":"manual","server":"manual.airport.invalid"}]')
        self.command("node-tool", '''case " $* " in
*" --source subscribe "*) cat "$FIXTURE_ROOT/nodes.json";;
*) cat "$FIXTURE_ROOT/manual.json";;
esac''')

    def test_periodic_sync_preserves_running_manual_node(self):
        ids = self.root / "ids"
        ids.write_text("9\n")
        for args in (("check", "--ids-file", str(ids)), ("sync",), ("sync",)):
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("manual.airport.invalid", self.rule.read_text())

    def test_pending_or_stale_owner_preserves_prior_rules(self):
        self.assertEqual(self.run_script("sync").returncode, 0)
        before = self.rule.read_text()
        for state in ("pending\n", "owner 88 78 /fixture/xray\nnode 9\n"):
            (self.root / "active-nodes").write_text(state)
            result = self.run_script("sync")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.rule.read_text(), before)
            self.assertIn("state=deferred", (self.root / "status").read_text())

    def test_stopped_owner_drops_manual_node(self):
        self.assertEqual(self.run_script("sync").returncode, 0)
        (self.root / "active-nodes").write_text("stopped\n")
        result = self.run_script("sync")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("manual.airport.invalid", self.rule.read_text())


class EffectiveReceiptTests(unittest.TestCase):
    def test_trimmed_anytls_does_not_require_a_helper(self):
        shunt = (ROOT / "fancyss/scripts/ss_node_shunt.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "meta").mkdir()
            (path / "meta/1.meta").write_text("node_type=4\n")
            (path / "proc/123").mkdir(parents=True)
            (path / "proc/123/stat").write_text("123 (xray) " + " ".join(["S"] + ["0"] * 18 + ["77"]) + "\n")
            (path / "core.json").write_text('{"outbounds":[{"tag":"proxy1"}]}')
            code = function(shunt, "fss_shunt_loaded_node_ids")
            code += function(shunt, "fss_shunt_anytls_runtime_snapshot").replace('"/proc/', f'"{path}/proc/')
            code += function(shunt, "fss_shunt_record_anytls_applied")
            code += f'''
FSS_SHUNT_CORE_CONFIG="{path}/core.json"
FSS_SHUNT_RUNTIME_ARTIFACT_DIR="{path}"
netstat() {{ echo "tcp 0 0 127.0.0.1:23456 0.0.0.0:* LISTEN 123/xray"; }}
fss_shunt_record_anytls_applied
'''
            result = subprocess.run(["/bin/sh", "-ec", code], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((path / "anytls.applied").read_text(), "xray 123 77\n")

    def test_expected_anytls_without_ready_helper_fails(self):
        shunt = (ROOT / "fancyss/scripts/ss_node_shunt.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "meta").mkdir()
            (path / "meta/1.meta").write_text("node_type=9\n")
            (path / "meta/1.transport").write_text("digest\n")
            (path / "proc/123").mkdir(parents=True)
            (path / "proc/123/stat").write_text("123 (xray) " + " ".join(["S"] + ["0"] * 18 + ["77"]) + "\n")
            (path / "core").write_text('{"outbounds":[{"tag":"proxy1"}]}')
            code = function(shunt, "fss_shunt_loaded_node_ids")
            code += function(shunt, "fss_shunt_anytls_runtime_snapshot").replace('"/proc/', f'"{path}/proc/')
            code += function(shunt, "fss_shunt_record_anytls_applied")
            code += f'''
FSS_SHUNT_CORE_CONFIG="{path}/core"
FSS_SHUNT_RUNTIME_ARTIFACT_DIR="{path}"
netstat() {{ echo "tcp 0 0 127.0.0.1:23456 0.0.0.0:* LISTEN 123/xray"; }}
fss_shunt_record_anytls_applied
'''
            result = subprocess.run(["/bin/sh", "-ec", code], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((path / "anytls.applied").exists())

    def test_rule_and_target_caps_remove_the_only_anytls_target(self):
        shunt = (ROOT / "fancyss/scripts/ss_node_shunt.sh").read_text()
        for total, max_rules, max_targets in ((17, 16, 100), (9, 16, 8)):
            with self.subTest(total=total), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                rules = [dict(id=str(i), source="custom", target_node_id=str(i)) for i in range(1, total + 1)]
                (path / "rules.json").write_text(json.dumps(rules))
                code = function(shunt, "fss_shunt_rebuild_proxy_domains") + function(shunt, "fss_shunt_prepare_runtime")
                code += f'''
work="{path}"
FSS_SHUNT_RUNTIME_RULE_DIR="$work/rules"
FSS_SHUNT_RUNTIME_PROXY_FILE="$work/proxy"
FSS_SHUNT_RUNTIME_TARGET_FILE="$work/targets"
FSS_SHUNT_RUNTIME_ACTIVE_FILE="$work/active"
FSS_SHUNT_MAX_RULES={max_rules}
FSS_SHUNT_MAX_TARGETS={max_targets}
fss_shunt_mode_selected() {{ :; }}
fss_shunt_rules_enabled() {{ :; }}
fss_shunt_runtime_key() {{ echo fixture; }}
fss_shunt_runtime_is_fresh() {{ return 1; }}
fss_shunt_cleanup_runtime() {{ :; }}
fss_shunt_rules_json() {{ cat "$work/rules.json"; }}
fss_shunt_write_rules_mirror() {{ :; }}
fss_pick_jq_bin() {{ echo jq; }}
fss_mktemp_dir() {{ mkdir "$work/temporary"; echo "$work/temporary"; }}
fss_shunt_target_is_special() {{ return 1; }}
fss_shunt_target_is_proxy_node() {{ :; }}
fss_shunt_materialize_rule_domains() {{ echo "domain:fixture.invalid" > "$4"; echo 1; }}
fss_shunt_write_runtime_meta() {{ :; }}
fss_shunt_prepare_runtime
'''
                result = subprocess.run(["bash", "-c", code], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                targets = (path / "targets").read_text().splitlines()
                self.assertNotIn(str(total), targets)
                self.assertEqual(len(targets), min(total, max_rules, max_targets))


class OrderedDnsTests(unittest.TestCase):
    def test_first_match_and_exact_names(self):
        rules = [
            dict(domain=["domain:early-proxy.invalid"], outboundTag="proxy1"),
            dict(domain=["domain:sub.early-proxy.invalid"], outboundTag="direct"),
            dict(domain=["full:exact.direct.invalid"], outboundTag="direct"),
            dict(domain=["domain:narrow.direct.invalid"], outboundTag="proxy1"),
            dict(domain=["domain:direct.invalid"], outboundTag="direct"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "core").write_text(json.dumps({"routing": {"rules": rules}}))
            result = subprocess.run(["/bin/sh", "-ec", f'. "{POLICY}"\nfss_shunt_write_aaaa_policy "{path}/core" "{path}/policy"'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            text = (path / "policy").read_text()
            self.assertIn("address /early-proxy.invalid/#6", text)
            self.assertNotIn("sub.early-proxy.invalid", text)
            self.assertIn("address /-.exact.direct.invalid/-6", text)
            self.assertIn("address /narrow.direct.invalid/#6", text)
            self.assertIn("address /direct.invalid/-6", text)


class SnapshotRotationTests(unittest.TestCase):
    def test_single_version_and_unfinished_guard(self):
        payload = ROOT / "scripts/router_native_v2_payload.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            stage = path / "stage"
            stage.mkdir()
            old = path / "jffs/configs/fss-anytls-hardening-release"
            old.mkdir(parents=True)
            (old / "guard.sh").touch()
            (old / "pending").touch()
            core = path / "koolshare/ss/ssconfig.sh"
            core.parent.mkdir(parents=True)
            core.write_text("production")
            command = f'. "{payload}"\nSTAGE="{stage}"\nnative_rotate_snapshots "{path}"'
            result = subprocess.run(["/bin/sh", "-ec", command], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(old.exists())
            (old / "pending").unlink()
            process = path / "proc/123"
            process.mkdir(parents=True)
            (process / "cmdline").write_bytes(b"/bin/sh\0/jffs/configs/fss-anytls-hardening-release/guard.sh\0watch\0")
            result = subprocess.run(["/bin/sh", "-ec", command], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(old.exists())
            (process / "cmdline").unlink()
            result = subprocess.run(["/bin/sh", "-ec", command], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(old.exists())
            current = path / "jffs/configs/fss-current-rollback"
            current.mkdir()
            (current / "guard.sh").touch()
            self.assertEqual(len(list((path / "jffs/configs").glob("fss-*"))), 1)
            self.assertEqual(core.read_text(), "production")
