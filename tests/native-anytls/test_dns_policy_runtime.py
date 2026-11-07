"""Run the shipped SmartDNS with a deterministic, private UDP upstream."""
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

from test_reliab2 import ROOT

BINARY = os.environ.get("FSS_SMARTDNS_BINARY")


@unittest.skipUnless(BINARY, "set FSS_SMARTDNS_BINARY for isolated Linux DNS integration")
class SmartDnsWireTests(unittest.TestCase):
    def test_ordered_direct_aaaa_and_proxy_suppression(self):
        self.run_fixture([
            dict(domain=["domain:early.invalid"], outboundTag="proxy1"),
            dict(domain=["domain:sub.early.invalid"], outboundTag="direct"),
            dict(domain=["full:exact.invalid"], outboundTag="direct"),
            dict(domain=["domain:narrow.direct.invalid"], outboundTag="proxy1"),
            dict(domain=["domain:direct.invalid"], outboundTag="direct"),
        ], [
            ("exact.invalid", True), ("child.exact.invalid", False),
            ("direct.invalid", True), ("child.direct.invalid", True),
            ("narrow.direct.invalid", False), ("sub.early.invalid", False),
        ])

    def test_keyword_conflict_keeps_conservative_suffix_policy(self):
        self.run_fixture([
            dict(domain=["keyword:force-proxy"], outboundTag="proxy1"),
            dict(domain=["full:force-proxy.invalid"], outboundTag="direct"),
            dict(domain=["keyword:keep-aaaa"], outboundTag="direct"),
            dict(domain=["full:keep-aaaa.invalid"], outboundTag="proxy1"),
            dict(domain=["domain:direct.invalid"], outboundTag="direct"),
        ], [
            ("force-proxy.invalid", False), ("keep-aaaa.invalid", True),
            ("direct.invalid", True), ("child.direct.invalid", False),
        ])

    def run_fixture(self, rules, cases):
        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        upstream.bind(("127.0.0.1", 0))
        upstream.settimeout(0.2)
        done = threading.Event()

        def serve():
            while not done.is_set():
                try:
                    packet, address = upstream.recvfrom(2048)
                except socket.timeout:
                    continue
                end = 12
                while packet[end]:
                    end += packet[end] + 1
                end += 5
                qtype = struct.unpack("!H", packet[end - 4:end - 2])[0]
                data = (ipaddress.IPv6Address("2001:db8::42").packed if qtype == 28
                        else ipaddress.IPv4Address("192.0.2.42").packed)
                header = packet[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
                answer = b"\xc0\x0c" + struct.pack("!HHIH", qtype, 1, 30, len(data)) + data
                upstream.sendto(header + packet[12:end] + answer, address)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
            probe.close()
            (path / "core").write_text(json.dumps({"routing": {"rules": rules}}))
            script = ROOT / "fancyss/scripts/ss_shunt_dns_policy.sh"
            subprocess.run(["/bin/sh", "-ec", f'. "{script}"\nfss_shunt_write_aaaa_policy "{path}/core" "{path}/policy"'], check=True)
            (path / "conf").write_text(
                f"bind 127.0.0.1:{port}\nserver 127.0.0.1:{upstream.getsockname()[1]}\n"
                f"speed-check-mode none\nforce-AAAA-SOA yes\nconf-file {path}/policy\n"
                f"log-file {path}/log\ncache-size 0\n"
            )
            process = subprocess.Popen([BINARY, "-f", "-p", str(path / "pid"), "-c", str(path / "conf")],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        self.fail((path / "log").read_text() if (path / "log").exists() else "SmartDNS exited")
                    if (path / "pid").exists():
                        break
                    time.sleep(0.02)
                for domain, expect in cases:
                    with self.subTest(domain=domain):
                        encoded = b"".join(bytes([len(label)]) + label.encode() for label in domain.split(".")) + b"\0"
                        packet = struct.pack("!HHHHHH", 1234, 0x0100, 1, 0, 0, 0) + encoded + struct.pack("!HH", 28, 1)
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                            client.settimeout(2)
                            for attempt in range(3):
                                client.sendto(packet, ("127.0.0.1", port))
                                try:
                                    response = client.recv(2048)
                                    break
                                except socket.timeout:
                                    if attempt == 2:
                                        raise
                        answers = struct.unpack("!H", response[6:8])[0]
                        self.assertEqual(answers > 0, expect)
            finally:
                process.terminate()
                process.wait(timeout=5)
                done.set()
                thread.join(timeout=1)
                upstream.close()
