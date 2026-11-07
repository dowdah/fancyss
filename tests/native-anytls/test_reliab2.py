"""Fault injection at the real shell lifecycle entry points."""
import pathlib
import json
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "fancyss/scripts"
CORE = (ROOT / "fancyss/ss/ssconfig.sh").read_text()
WRAPPER = (SCRIPTS / "ss_config.sh").read_text()
SUBSCRIBE = (SCRIPTS / "ss_node_subscribe.sh").read_text()
HELPER = (SCRIPTS / "ss_anytls_helper.sh").read_text()
DNS = (SCRIPTS / "ss_base_dns.sh").read_text()
SHUNT = (SCRIPTS / "ss_node_shunt.sh").read_text()


def function(source, name):
    return re.search(rf"^{name}\(\)\s*\{{\n.*?^\}}", source, re.M | re.S)[0] + "\n"


def branch(source, action):
    return re.search(rf"^{action}\)\n.*?^\t;;", source, re.M | re.S)[0]


class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = pathlib.Path(directory.name)
        self.variables = f'work={shlex.quote(directory.name)}\necho_date() {{ echo "$*"; }}\n'

    def shell(self, code):
        return subprocess.run(
            ["/bin/bash"], input=self.variables + code, text=True, capture_output=True,
            timeout=10,
        )

    def test_sigkill_waits_for_exit_or_preserves_pidfile(self):
        functions = "".join(function(HELPER, name) for name in (
            "stop_owned", "stop_process_exited", "wait_for_stop"
        ))
        for outcome in ("gone", "stuck", "reused", "unreadable", "malformed"):
            with self.subTest(outcome=outcome):
                result = self.shell(functions + f"outcome={outcome}\n" + r'''
proc="$work/proc"
pidfile="$work/instance.pid"
mkdir -p "$proc/123"
write_stat() {
    printf '123 (fake helper) D %s %s\n' "$(yes 0 | head -18 | tr '\n' ' ')" "$1" > "$proc/123/stat"
}
write_stat 42
printf '123 42\n' > "$pidfile"
case "$outcome" in
    reused) write_stat 99 ;;
    unreadable) rm "$proc/123/stat" ;;
    malformed) printf 'invalid\n' > "$pidfile" ;;
esac
owned() { instance_pid=123; instance_ticks=42; [ "$outcome" != unreadable ]; }
kill() {
    printf 'signal %s\n' "$*"
    if [ "$outcome" = gone ] && [ "$1" = -9 ]; then
        rm -rf "$proc/123"
    fi
    return 0
}
sleep() { :; }
stop_owned
rc=$?
[ ! -e "$pidfile" ] || echo retained
exit "$rc"
''')
                self.assertEqual(result.returncode, int(outcome in ("stuck", "unreadable", "malformed")), result)
                self.assertEqual("retained" in result.stdout, result.returncode == 1)
                self.assertEqual("signal -9" in result.stdout, outcome in ("gone", "stuck"))

    def test_perp_failure_and_failed_definition_removal_leave_helper_alone(self):
        result = self.shell(function(HELPER, "stop_instance") + '''
service_name=fixture
service_dir="$work/service"
mkdir "$service_dir"
perpctl() { return 1; }
rm() { return 1; }
stop_owned() { echo unexpected_stop; }
stop_instance
''')
        self.assertEqual(result.returncode, 1, result)
        self.assertNotIn("unexpected_stop", result.stdout)
        self.assertTrue((self.path / "service").is_dir())

    def test_apply_preserves_artifacts_when_stop_cannot_be_confirmed(self):
        result = self.shell(function(CORE, "apply_ss") + r'''
ss_basic_status=1
fss_runtime_nodes_mark() { :; }
proxy_is_listening() { :; }
fss_airport_bootstrap_sync_retry() { [ "$1:$2" = 2:3 ]; }
fss_get_current_node_id() { echo 12; }
shunt_hot_restart_eligible() { return 1; }
kill_process() { return 1; }
prepare_system() { rm "$work/artifact"; }
for name in fss_require_base_dns fss_require_shunt_lib ss_pre_stop stop_status \
    remove_ss_trigger_job remove_ss_reboot_job restore_conf restart_dnsmasq \
    flush_iptables flush_ipset kill_cron_job; do
    eval "$name() { :; }"
done
touch "$work/artifact"
apply_ss
''')
        self.assertEqual(result.returncode, 1, result)
        self.assertIn("ANYTLS_HELPER_STOP_FAILED", result.stdout)
        self.assertTrue((self.path / "artifact").is_file())

    def test_cold_recovery_retries_and_cancels(self):
        functions = "".join(function(CORE, name) for name in (
            "run_wan_start", "retry_cold_dns", "schedule_cold_dns_retry", "clear_cold_dns_retry"
        )) + function(DNS, "fss_airport_bootstrap_sync_retry")
        result = self.shell(functions + r'''
COLD_DNS_PENDING="$work/pending"
COLD_DNS_JOB=fixture
cat() {
    if [ "$1" = /proc/sys/kernel/random/boot_id ]; then echo fixture-boot; else command cat "$@"; fi
}
cru() {
    case "$1" in
        a) touch "$work/job" ;;
        d) rm -f "$work/job" ;;
    esac
}
sleep() { :; }
dbus() { echo "$enabled"; }
enabled=1
proxy_is_listening() { [ -f "$work/listener" ]; }
apply_ss() {
    if [ "$#" = 0 ]; then
        fss_airport_bootstrap_sync_retry 6 10 || return 75
    else
        fss_airport_bootstrap_sync_retry "$1" 10 || return 75
    fi
    touch "$work/listener"
    echo started >> "$work/events"
}
fss_airport_bootstrap_sync() {
    echo probe >> "$work/events"
    [ -f "$work/dns-ready" ]
}
run_wan_start
[ "$?" = 75 ] && [ -f "$work/job" ] && [ -f "$COLD_DNS_PENDING" ] || exit 10
[ "$(grep -c probe "$work/events")" = 6 ] || exit 11
retry_cold_dns
[ "$?" = 75 ] && [ -f "$work/job" ] || exit 12
touch "$work/dns-ready"
retry_cold_dns && retry_cold_dns || exit 13
[ "$(grep -c started "$work/events")" = 1 ] || exit 14
[ "$(grep -c probe "$work/events")" = 8 ] && [ ! -e "$work/job" ] || exit 15
schedule_cold_dns_retry
retry_cold_dns && [ ! -e "$COLD_DNS_PENDING" ] || exit 16
rm "$work/listener"
schedule_cold_dns_retry
clear_cold_dns_retry
retry_cold_dns && [ ! -e "$work/listener" ] || exit 17
schedule_cold_dns_retry
enabled=0
retry_cold_dns && [ ! -e "$COLD_DNS_PENDING" ] || exit 18
''')
        self.assertEqual(result.returncode, 0, result)

    def test_restart_and_subscription_loggers_return_failure(self):
        # Use actual case branches and actual wrappers. Only router operations are stubbed.
        core = self.variables + '''
set_lock() { :; }
unset_lock() { :; }
start_ws() { :; }
apply_ss() {
    echo native_restart
    if [ -f "$work/fail" ]; then echo preflight_failed; return 75; fi
}
clear_cold_dns_retry() { :; }
''' + "case restart in\n" + branch(CORE, "restart") + "\nesac\n"
        (self.path / "core").write_text(core)
        wrap = self.variables + '''
set_lock() { :; }
unset_lock() { :; }
pre_start() { :; }
''' + function(WRAPPER, "start_fancyss").replace("/bin/sh /koolshare/ss/ssconfig.sh", '/bin/bash "$work/core"')
        wrap += "case start in\n" + branch(WRAPPER, "start").replace("/tmp/upload/ss_log.txt", '"$work/plugin.log"') + "\nesac\n"
        (self.path / "wrapper").write_text(wrap)
        (self.path / "fail").touch()
        program = function(SHUNT, "fss_shunt_restart_after_subscription").replace(
            "/bin/sh /koolshare/scripts/ss_config.sh", '/bin/bash "$work/wrapper"'
        )
        result = self.shell(program + '''
set_lock() { :; }
unset_lock() { :; }
LOG_FILE="$work/sub.log"
WEB_ACTION=0
SUB_SELECTED_PROFILE_ID=fixture
start_node_subscribe() {
    fss_shunt_restart_after_subscription || return 1
    echo unexpected_success
}
case 3 in
''' + branch(SUBSCRIBE, "3") + "\nesac\n")
        self.assertEqual(result.returncode, 1, result)
        self.assertNotIn("unexpected_success", result.stdout)
        for name in ("plugin.log", "sub.log"):
            self.assertIn("preflight_failed", (self.path / name).read_text())
            self.assertTrue((self.path / name).read_text().endswith("XU6J03M6\n"))

        (self.path / "fail").unlink()
        (self.path / "meta").mkdir()
        (self.path / "meta/12.meta").write_text("node_type=9\nnode_rev=7\n")
        node = dict(type="9", anytls_server="a.invalid", anytls_port="443",
                    anytls_pass="synthetic", anytls_sni="", anytls_ai="1", _rev=7)
        (self.path / "built.json").write_text(json.dumps(node))
        reconcile = program + "".join(function(SHUNT, name) for name in (
            "fss_shunt_anytls_transport_digest", "fss_shunt_reconcile_anytls_subscription"
        )) + '''
dbus() { case "$2" in ss_basic_enable) echo 1;; ss_basic_mode) echo 7;; esac; }
fss_shunt_has_anytls() { :; }
fss_shunt_loaded_node_ids() { echo 12; }
fss_pick_node_tool() { echo fixture_tool; }
fixture_tool() { echo '[{}]'; }
fss_v2_get_node_json_by_id() { cat "$node_file"; }
fss_shunt_get_default_node_id() { echo 12; }
fss_shunt_get_effective_default_target() { echo 12; }
fss_shunt_rules_json_resolved() { echo '[]'; }
fss_get_node_field_plain() { echo 9; }
fss_shunt_log() { :; }
FSS_SHUNT_RUNTIME_ARTIFACT_DIR="$work"
node_file="$work/built.json"
fss_shunt_anytls_transport_digest 12 > "$work/meta/12.transport"
node_file="$work/next.json"
fss_shunt_reconcile_anytls_subscription
'''
        for field, value in (("_rev", 8), ("anytls_server", "b.invalid"),
                             ("anytls_port", "8443"), ("anytls_pass", "rotated"),
                             ("anytls_sni", "sni.invalid"), ("anytls_ai", "0")):
            with self.subTest(field=field):
                (self.path / "next.json").write_text(json.dumps(dict(node, **{field: value})))
                result = self.shell(reconcile)
                self.assertEqual(result.returncode, 0, result)
                self.assertEqual(result.stdout.count("native_restart"), int(field != "_rev"))

    def test_failed_fast_path_retains_saved_data_and_skips_full_write(self):
        fast = function(SUBSCRIBE, "sub_try_sync_single_source_fast_path")
        dispatch = function(SUBSCRIBE, "start_node_subscribe")
        dispatch = dispatch[dispatch.index('\tlocal ISNEW='):]
        result = self.shell(fast + "dispatch() {\n" + dispatch + '''
DIR="$work"
LOCAL_NODES_BAK="$work/backup"
SUB_STORAGE_SCHEMA=2
printf 'saved nodes\\n' > "$work/local_source_fixture.txt"
sub_get_single_changed_source_tag() { echo fixture; }
sub_find_local_source_file() { echo "$work/local_source_fixture.txt"; }
get_group_label_from_file() { echo fixture; }
get_sub_group_fallback_by_hash() { :; }
sub_capture_active_nodes() { :; }
sub_sync_single_source_schema2() { touch "$work/written"; }
sub_schedule_background_sync() { :; }
sub_after_nodes_written() { return 1; }
clear_nodes() { echo unexpected_full_write; }
dispatch
''')
        self.assertEqual(result.returncode, 1, result)
        self.assertTrue((self.path / "written").exists())
        self.assertEqual((self.path / "backup").read_text(), "saved nodes\n")
        self.assertNotIn("unexpected_full_write", result.stdout)
