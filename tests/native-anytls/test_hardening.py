"""Release inputs and rollback are exercised entirely in temporary directories."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from test_reliab2 import ROOT, function

PAYLOAD = ROOT / "scripts/router_native_v2_payload.sh"
META = "shadowsocks/ss/fork-build.json"
CORE = "shadowsocks/ss/ssconfig.sh"
NEW = "shadowsocks/bin/fss-anytls-client"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class NativePayloadTests(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.work = Path(fixture.name)
        self.stage = self.work / "stage"
        self.stage.mkdir()
        self.verified = self.stage / "verified"
        self.snapshot = self.work / "snapshot"
        self.snapshot.mkdir()
        self.data = {CORE: b"new core", NEW: b"new client"}

    def shell(self, body):
        return subprocess.run(
            ["/bin/sh", "-ec", f'''
. "{PAYLOAD}"
STAGE="{self.stage}"
VERIFIED="{self.verified}"
ROOT="{self.snapshot}"
META="{META}"
{body}
'''], text=True, capture_output=True,
        )

    def archive(self, *, extra=None, duplicate=False, link=False, missing=False, duplicate_manifest=False):
        records = {name: sha(data) for name, data in self.data.items()}
        manifest = json.dumps({"files": records})
        if duplicate_manifest:
            manifest = manifest.replace('"files": {', f'"files": {{"{CORE}": "{records[CORE]}", ')
        members = [(META, manifest.encode()), *self.data.items()]
        if missing:
            members.pop()
        if extra:
            members.append((extra, b"extra"))
        if duplicate:
            members.append((CORE, self.data[CORE]))
        package = self.stage / "payload.tar.gz"
        with tarfile.open(package, "w:gz") as archive:
            for name, data in members:
                entry = tarfile.TarInfo(name)
                if name == NEW and link:
                    entry.type, entry.linkname = tarfile.SYMTYPE, "other"
                    archive.addfile(entry)
                else:
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
        return sha(package.read_bytes())

    def prepare(self):
        digest = self.archive()
        result = self.shell(f"native_stage_payload {digest}")
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copyfile(self.verified / "files", self.snapshot / "install-files")
        shutil.copyfile(self.verified / "hashes", self.snapshot / "install.sha256")
        (self.snapshot / "present").write_text("koolshare/ss/ssconfig.sh\n")
        (self.snapshot / "absent").write_text("koolshare/bin/fss-anytls-client\nkoolshare/ss/fork-build.json\n")

    def test_archive_rejects_untrusted_inputs(self):
        self.archive()
        self.assertNotEqual(self.shell("native_stage_payload " + "0" * 64).returncode, 0)
        for args in (
            {"extra": "shadowsocks/ss/extra"}, {"extra": "shadowsocks/ss/../extra"},
            {"extra": "/shadowsocks/ss/absolute"}, {"duplicate": True}, {"link": True},
            {"missing": True}, {"duplicate_manifest": True},
        ):
            with self.subTest(args=args):
                digest = self.archive(**args)
                result = self.shell(f"native_stage_payload {digest}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.verified.exists())

    def test_changes_after_snapshot_abort_before_stop(self):
        self.prepare()
        fake_stop = self.work / "stopped"
        apply = f'native_verify_prepared\ntouch "{fake_stop}"'
        extra = self.verified / "shadowsocks/ss/extra"
        core = self.verified / CORE
        for change, undo in (
            (lambda: extra.write_bytes(b"unlisted"), extra.unlink),
            (lambda: core.write_bytes(b"changed"), lambda: core.write_bytes(self.data[CORE])),
            (lambda: (self.snapshot / "absent").write_text(""), lambda: None),
        ):
            change()
            result = self.shell(apply)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertFalse(fake_stop.exists())
            undo()

    def test_secondary_jffs_target_is_verified_and_installed(self):
        secondary = "jffs/scripts/airport-node-dns.sh"
        self.data[secondary] = b"new airport runtime"
        self.prepare()
        with (self.snapshot / "absent").open("a") as stream:
            stream.write(secondary + "\n")
        live = self.work / "koolshare"
        jffs = self.work / "jffs"
        result = self.shell(f'native_verify_prepared\nnative_publish "{live}" "{jffs}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((jffs / "scripts/airport-node-dns.sh").read_bytes(), self.data[secondary])
        (self.verified / "jffs/scripts/unlisted").touch()
        self.assertNotEqual(self.shell("native_verify_prepared").returncode, 0)

    def test_install_then_restore_captured_state(self):
        self.prepare()
        live = self.work / "koolshare"
        (live / "ss").mkdir(parents=True)
        old_core = live / "ss/ssconfig.sh"
        old_core.write_bytes(b"old core")
        with tarfile.open(self.snapshot / "baseline.tgz", "w:gz") as archive:
            archive.add(old_core, "koolshare/ss/ssconfig.sh")
        (self.snapshot / "baseline.keys").write_text("fss_node_current\n")
        (self.snapshot / "dbus.tsv").write_text("fss_node_current\tNjY0\n")
        (self.snapshot / "current-node").write_text("664\n")
        (live / "ss/xray.json").write_text('{"outbounds":[{"tag":"proxy664","protocol":"socks"}]}')
        result = self.shell(f'native_verify_prepared\nnative_publish "{live}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(old_core.read_bytes(), self.data[CORE])
        self.assertTrue((live / "bin/fss-anytls-client").exists())
        guard = (ROOT / "scripts/router_native_v2_guard.sh").read_text()
        restore = function(guard, "restore")
        restore = restore.replace('"/$path"', f'"{self.work}/$path"').replace('-C / ', f'-C "{self.work}" ')
        restore = restore.replace("/bin/sh /koolshare/ss/ssconfig.sh", "fake_core")
        restore = restore.replace("/bin/sh /jffs/scripts/airport-node-dns.sh", "true")
        restore = restore.replace("/koolshare/ss/xray.json", f'"{live}/ss/xray.json"')
        result = self.shell(restore + '''
verify() { :; }
fake_core() { :; }
dbus() {
    case "$1:$2" in
        list:fss) echo fss_node_current=664 ;;
        get:fss_node_current) echo 664 ;;
    esac
}
pidof() { :; }
netstat() { echo "tcp 0 0 127.0.0.1:23456 0.0.0.0:* LISTEN 1/xray"; }
restore
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(old_core.read_bytes(), b"old core")
        self.assertFalse((live / "bin/fss-anytls-client").exists())
        self.assertFalse((live / "ss/fork-build.json").exists())


class AirportPreflightTests(unittest.TestCase):
    def test_missing_dependency_never_reaches_stop(self):
        installer = (ROOT / "fancyss/install.sh").read_text()
        self.assertLess(installer.index('preflight_anytls_and_airport_dns "${DIR}"'), installer.index("# stop first"))
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "scripts").mkdir()
            conf = package / "airport.conf"
            conf.touch()
            scripts = ("ss_airport_dns_install.sh", "airport-node-dns.sh",
                       "airport-node-dns-boot.sh", "airport-node-dns-status.sh")
            for name in scripts:
                path = package / "scripts" / name
                path.touch()
                path.chmod(0o755)
            for name in scripts:
                with self.subTest(name=name):
                    path = package / "scripts" / name
                    path.chmod(0o644)
                    command = function(installer, "preflight_anytls_and_airport_dns")
                    command += f'''
echo_date() {{ echo "$*"; }}
preflight_anytls_and_airport_dns "{package}" lite "{conf}" || exit 1
echo service_stopped
'''
                    result = subprocess.run(["/bin/sh", "-c", command], text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn(name, result.stdout)
                    self.assertNotIn("service_stopped", result.stdout)
                    path.chmod(0o755)
            result = subprocess.run(["/bin/sh", "-c", command], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("service_stopped", result.stdout)
