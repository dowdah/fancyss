"""Exercise the optional Wi-Fi Calling exception with the real rule helper."""
import pathlib
import subprocess
import tempfile
import unittest

from test_reliab2 import CORE, function


class VowifiBypassTests(unittest.TestCase):
    entry = "02:Ab:00:01:02:03 208.54.0.0/16"
    rule = (
        "-i br0 -p udp -m mac --mac-source 02:ab:00:01:02:03 -d 208.54.0.0/16 "
        "-m multiport --dports 500,4500 -m comment --comment fancyss-vowifi-bypass -j RETURN"
    )

    def run_helper(self, content, mode="7", install="ok", interface="br0"):
        with tempfile.TemporaryDirectory() as tmp:
            config = pathlib.Path(tmp) / "vowifi.conf"
            if content is not None:
                config.write_text(content)
            functions = "".join(function(CORE, name) for name in (
                "apply_vowifi_bypass", "append_if_not_exists", "append_if_not_exists_with_cmd",
            ))
            result = subprocess.run(
                ["/bin/sh", "-c", functions + r'''
ss_basic_mode=$2
echo_date() { printf 'log: %s\n' "$*"; }
nvram() { printf '%s\n' "$interface"; }
iptables() {
    local action="$3" args="$*"
    shift 4
    case "$action" in
        -C) [ "$installed" = "$*" ] ;;
        -A)
            printf '%s\n' "$args" >> "$calls"
            [ "$outcome" = ok ] || return 1
            installed=$*
            ;;
    esac
}
outcome=$3
interface=$4
calls=$1.calls
# Check the same generated rule twice, as during repeated rule loads.
apply_vowifi_bypass "$1"
apply_vowifi_bypass "$1"
if [ -f "$calls" ]; then cat "$calls"; fi
''', "test", str(config), mode, install, interface],
                text=True, capture_output=True, check=True,
            )
        return result.stdout.splitlines()

    def test_only_configured_device_network_and_ike_ports_bypass(self):
        self.assertEqual(self.run_helper(self.entry), [
            f"-t mangle -A SHADOWSOCKS {self.rule}",
        ])

    def test_lan_mode_uses_one_rule_for_all_devices_on_main_lan(self):
        self.assertEqual(self.run_helper("lan\n", interface="br2"), [
            "-t mangle -A SHADOWSOCKS -i br2 -p udp -m addrtype --dst-type UNICAST "
            "-m multiport --dports 500,4500 -m comment --comment fancyss-vowifi-bypass -j RETURN",
        ])

    def test_disabled_and_invalid_config(self):
        for config in (None, "", " \n\t\n"):
            self.assertEqual(self.run_helper(config), [])
        self.assertEqual(self.run_helper(self.entry, mode="2"), [])
        for config in (
            "bad " + self.entry.split()[1],
            self.entry.replace("02:Ab", "03:Ab"),
            self.entry.replace("/16", "/0"),
            self.entry.replace("/16", "/33"),
            self.entry.replace("208.", "999."),
            self.entry + " -j ACCEPT",
            self.entry + "\n" + self.entry,
            "lan\n" + self.entry,
            self.entry + "\nlan",
            "lan all",
        ):
            with self.subTest(config=config):
                output = self.run_helper(config)
                self.assertEqual(len(output), 2)
                self.assertTrue(all(line.startswith("log: ") for line in output))

    def test_install_failure_keeps_normal_routing(self):
        self.assertTrue(all(line.startswith("log: ") for line in
                            self.run_helper(self.entry, interface="br+")))
        output = self.run_helper(self.entry, install="fail")
        self.assertEqual(output.count(f"-t mangle -A SHADOWSOCKS {self.rule}"), 2)
        self.assertEqual(sum("安装失败" in line for line in output), 2)

    def test_shared_rule_build_precedes_acl_and_default_dispatch(self):
        build = function(CORE, "_start_iptables")
        self.assertLess(build.index("ensure_chain mangle SHADOWSOCKS"),
                        build.index("apply_vowifi_bypass "))
        self.assertLess(build.index("--match-set ignlist dst", build.index("ensure_chain mangle SHADOWSOCKS")),
                        build.index("apply_vowifi_bypass "))
        self.assertLess(build.index("apply_vowifi_bypass "), build.index("lan_access_control "))
        self.assertLess(build.index("apply_vowifi_bypass "), build.index("apply_acl_udp_rule "))
        self.assertIn("load_iptables", function(CORE, "apply_ss_by_nat"))
