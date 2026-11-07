"""Switch failures and package identities are tested without production traffic."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_hardening2
from test_reliab2 import ROOT, function

CORE = (ROOT / "fancyss/ss/ssconfig.sh").read_text()
DNS = (ROOT / "fancyss/scripts/ss_base_dns.sh").read_text()


class SwitchingDnsTests(test_hardening2.RunningManualDnsTests):
    def setUp(self):
        super().setUp()
        (self.root / "manual.json").write_text(json.dumps([
            dict(id="9", airport_identity="manual", server="manual.airport.invalid"),
            dict(id="10", airport_identity="manual", server="new.airport.invalid"),
        ]))
        self.command("node-tool", '''case " $* " in
*" --source subscribe "*) cat "$FIXTURE_ROOT/nodes.json";;
*) ids=$(printf '%s\\n' "$*" | sed 's/.*--ids //')
   jq --arg ids ",$ids," '[.[]|.id as $id|select($ids|contains(","+$id+","))]' "$FIXTURE_ROOT/manual.json";;
esac''')
        self.command("dnsclient", '''
echo "$*" >> "$FIXTURE_ROOT/queries"
case "$*" in *"$(cat "$FIXTURE_ROOT/fail-domain" 2>/dev/null || echo never.invalid)"*) exit 1;; esac
echo 192.0.2.20''')
        result = self.run_script("sync")
        self.assertEqual(result.returncode, 0, result.stderr)

    def apply(self, cleanup_fails=False):
        noops = """fss_require_base_dns fss_require_shunt_lib ss_pre_stop stop_status
remove_ss_trigger_job remove_ss_reboot_job restore_conf restart_dnsmasq flush_iptables
flush_ipset kill_cron_job prepare_system resolv_server_ip load_module creat_ipset
create_dnsmasq_conf add_white_black creat_vmess_json start_xray start_dns_x
get_proxy_server_ip load_iptables auto_start write_cron_job set_ss_reboot_job
write_numbers finish_start ss_post_start check_status""".split()
        code = f'. "{ROOT}/fancyss/scripts/ss_runtime_nodes.sh"\n'
        code += function(DNS, "fss_airport_bootstrap_sync_retry") + function(CORE, "apply_ss")
        code += "\n".join(f"{name}() {{ :; }}" for name in noops)
        code += f'''
fss_get_current_node_id() {{ echo 10; }}
proxy_is_listening() {{ return 0; }}
shunt_hot_restart_eligible() {{ return 1; }}
should_bootstrap_dns_before_proxy() {{ return 1; }}
echo_date() {{ echo "$*"; }}
netstat() {{ echo "tcp 0 0 127.0.0.1:23456 0.0.0.0:* LISTEN 88/xray"; }}
kill_process() {{ grep -qx pending "$FSS_ACTIVE_NODES_FILE" || return 1; touch "$FIXTURE_ROOT/stopped"; }}
fss_airport_bootstrap_sync() {{
    if [ "$#" = 0 ] && [ "{int(cleanup_fails)}" = 1 ]; then return 1; fi
    /bin/sh "{ROOT}/integrations/airport-node-dns/airport-node-dns.sh" sync "$@"
}}
ss_basic_mode=1
ss_basic_type=3
ss_basic_status=1
apply_ss
'''
        return subprocess.run(["bash", "-c", code], env=dict(self.env, PATH=self.env["AIRPORT_TEST_PATH"]),
                              capture_output=True, text=True)

    def test_failed_target_keeps_owner_and_dns_through_periodic_sync(self):
        before = (self.root / "active-nodes").read_bytes()
        (self.root / "fail-domain").write_text("new.airport.invalid")
        result = self.apply()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual((self.root / "active-nodes").read_bytes(), before)
        self.assertFalse((self.root / "stopped").exists())
        self.assertIn("manual.airport.invalid", self.rule.read_text())
        self.assertEqual(self.run_script("sync").returncode, 0)
        self.assertIn("manual.airport.invalid", self.rule.read_text())
        self.assertIn("state=ready", (self.root / "status").read_text())

    def test_unavailable_old_node_does_not_block_new_target_and_is_pruned(self):
        (self.root / "fail-domain").write_text("manual.airport.invalid")
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue((self.root / "stopped").exists())
        self.assertIn("node 10", (self.root / "active-nodes").read_text())
        self.assertNotIn("manual.airport.invalid", self.rule.read_text())
        self.assertIn("new.airport.invalid", self.rule.read_text())
        self.assertNotIn("manual.airport.invalid", (self.root / "queries").read_text())

    def test_subscription_still_retains_old_domain_after_success(self):
        nodes = json.loads(self.nodes.read_text())
        nodes.append(dict(id="11", airport_identity="airport-a", server="manual.airport.invalid"))
        self.nodes.write_text(json.dumps(nodes))
        self.assertEqual(self.apply().returncode, 0)
        self.assertIn("manual.airport.invalid", self.rule.read_text())

    def test_cleanup_failure_is_nonfatal_and_periodic_sync_retries(self):
        result = self.apply(cleanup_fails=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AIRPORT_DNS_CLEANUP_DEFERRED", result.stdout)
        self.assertIn("node 10", (self.root / "active-nodes").read_text())
        self.assertIn("manual.airport.invalid", self.rule.read_text())
        self.assertEqual(self.run_script("sync").returncode, 0)
        self.assertNotIn("manual.airport.invalid", self.rule.read_text())

    def test_failed_cold_start_does_not_publish_pending_owner(self):
        (self.root / "active-nodes").unlink()
        (self.root / "fail-domain").write_text("new.airport.invalid")
        result = self.apply()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((self.root / "active-nodes").exists())
        self.assertFalse((self.root / "stopped").exists())


class PackageIdentityTests(unittest.TestCase):
    def test_manifest_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            (stage / "ss").mkdir()
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            builds = set()
            for arch in ("arm", "hnd", "hnd_v8", "qca", "mtk", "ipq32", "ipq64"):
                for pkgtype in ("full", "lite"):
                    for release in ("release", "debug"):
                        result = subprocess.run(["bash", "-ec", f'source "{ROOT}/build.sh"; write_fork_manifest "$1" "$2" "$3" "$4"',
                                                 "fixture", arch, pkgtype, release, str(stage)], cwd=ROOT, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        meta = json.loads((stage / "ss/fork-build.json").read_text())
                        self.assertEqual(meta["source_commit"], commit)
                        self.assertEqual(meta["platform"], f"{arch}/{pkgtype}")
                        self.assertEqual(meta["package_type"], pkgtype)
                        self.assertEqual(meta["release_type"], release)
                        self.assertIn(commit[:12], meta["build"])
                        self.assertNotIn(meta["build"], builds)
                        builds.add(meta["build"])

    def test_updater_blocks_before_download_and_keeps_unmarked_path(self):
        updater = (ROOT / "fancyss/scripts/ss_update.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            # Mock the first network call and stop there: never install an upstream package.
            code = function(updater, "update_ss").replace("/koolshare/ss/fork-build.json", str(path / "fork-build.json"))
            code = code.replace("/tmp/version.json.js", str(path / "version.json.js"))
            code += f'''
echo_date() {{ :; }}
SOCKS5_OPEN=
netstat() {{ :; }}
ln() {{ :; }}
run() {{ touch "{path}/download"; exit 42; }}
update_ss
'''
            (path / "fork-build.json").write_text("{}")
            blocked = subprocess.run(["bash", "-c", code], capture_output=True)
            self.assertEqual(blocked.returncode, 1)
            self.assertFalse((path / "download").exists())
            (path / "fork-build.json").unlink()
            allowed = subprocess.run(["bash", "-c", code], capture_output=True)
            self.assertEqual(allowed.returncode, 42, allowed.stderr)
            self.assertTrue((path / "download").exists())


class ReleaseBaselineTests(unittest.TestCase):
    def test_third_release_baseline_rejects_wrong_version_or_changed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            live = path / "live"
            (live / "ss").mkdir(parents=True)
            (live / "scripts").mkdir()
            (live / "bin").mkdir()
            (path / "verified").mkdir()
            prefix = "3.5.30-anytls-native.2-compat.1-reliab.3-vowifi.2-"
            import hashlib
            sha = lambda data: hashlib.sha256(data).hexdigest()
            old = json.dumps(dict(build=prefix + "hardening.2")).encode()
            files = {"ss/fork-build.json": old, "ss/ssconfig.sh": b"core",
                     "scripts/airport-node-dns.sh": b"airport", "bin/fss-anytls-client": b"client"}
            for name, data in files.items():
                (live / name).write_bytes(data)
            (path / "airport").write_bytes(b"airport")
            manifest = path / "candidate.json"
            manifest.write_text(json.dumps(dict(build=prefix + "hardening.3", base_absent=[],
                base_files={name: sha(data) for name, data in files.items()},
                base_airport_script_sha256=sha(b"airport"))))
            payload = (ROOT / "scripts/router_native_v2_payload.sh").read_text()
            check = function(payload, "native_check_live_baseline").replace("/jffs/scripts/airport-node-dns.sh", str(path / "airport"))
            code = f'''. "{ROOT}/scripts/router_native_v2_payload.sh"
{check}
VERIFIED="{path}/verified"
native_paths hardening.2 || exit 1
VERIFIED="{path}/verified"
native_check_live_baseline hardening.2 "{manifest}" "{live}"
'''
            def run():
                return subprocess.run(["/bin/sh", "-ec", code], capture_output=True, text=True)
            good = run()
            self.assertEqual(good.returncode, 0, good.stderr)
            for name in ("ss/fork-build.json", "ss/ssconfig.sh", "scripts/airport-node-dns.sh", "bin/fss-anytls-client"):
                (live / name).write_bytes(b"changed")
                self.assertNotEqual(run().returncode, 0, name)
                (live / name).write_bytes(files[name])
            (path / "airport").write_bytes(b"changed")
            self.assertNotEqual(run().returncode, 0)
            (path / "airport").write_bytes(b"airport")
            data = json.loads(manifest.read_text())
            data["build"] = prefix + "hardening.2"
            manifest.write_text(json.dumps(data))
            self.assertNotEqual(run().returncode, 0)
