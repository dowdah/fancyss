#!/bin/sh
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=/tmp/fss-tls-peak
# Signal only the exact test command/config, never pidof/killall.
for kind in xray observer; do
 pid=$(cat "$ROOT/$kind.pid" 2>/dev/null)
 case "$pid" in ''|*[!0-9]*) continue;; esac
 if [ "$kind" = xray ]; then needle="$ROOT/xray.json"; else needle="$ROOT/sampler"; fi
 if [ -r "/proc/$pid/cmdline" ] && tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq "$needle"; then kill "$pid" 2>/dev/null; fi
done
FSS_ANYTLS_BINARY="$ROOT/client" /bin/sh "$ROOT/helper" stop "$ROOT/client.pid" "$ROOT/password" 127.0.0.1:18082 >/dev/null 2>&1 || true
iptables -D INPUT -d 192.168.50.1/32 -p tcp --dport 30556 -j FSS_TLS_PEAK_TEST 2>/dev/null || true
iptables -F FSS_TLS_PEAK_TEST 2>/dev/null || true
iptables -X FSS_TLS_PEAK_TEST 2>/dev/null || true
rm -f "$ROOT/setup.complete" "$ROOT/password" "$ROOT/proxy-auth.json" "$ROOT/xray.json"
echo isolated_test_cleaned=1
