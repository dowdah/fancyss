#!/bin/sh
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=/tmp/fss-tls-peak
[ "$(dbus get fss_node_current)" = 654 ]
[ "$(jq -r .build /koolshare/ss/fork-build.json)" = 3.5.30-anytls-native.1 ]
[ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 98304 ]
[ ! -f "$ROOT/setup.complete" ]
printf '%s  %s\n' 11063b01b06df0294a121901baa71835d24f79c71c97858f18c60e02c11e1d94 "$ROOT/client" | sha256sum -c - >/dev/null
jq -e '.user and .pass' "$ROOT/proxy-auth.json" >/dev/null
cleanup() { /bin/sh "$ROOT/router-cleanup.sh"; }
step=preflight
trap 'echo setup_exit_at=$step; cleanup' EXIT
iptables -N FSS_TLS_PEAK_TEST
iptables -A FSS_TLS_PEAK_TEST -s 192.168.50.250/32 -j ACCEPT
iptables -A FSS_TLS_PEAK_TEST -j DROP
iptables -I INPUT 1 -d 192.168.50.1/32 -p tcp --dport 30556 -j FSS_TLS_PEAK_TEST
cp /tmp/fancyss_shunt/runtime_artifacts/nodes/654_anytls.pass "$ROOT/password"
sed -e "s#/koolshare/scripts/ss_anytls_helper.sh#$ROOT/helper#" \
-e "s#/tmp/fancyss_shunt/runtime_artifacts/nodes/654_anytls.pid#$ROOT/client.pid#" \
-e "s#/tmp/fancyss_shunt/runtime_artifacts/nodes/654_anytls.pass#$ROOT/password#" \
-e 's/127.0.0.1:[0-9][0-9]*/127.0.0.1:18082/' \
/tmp/fancyss_shunt/runtime_artifacts/nodes/654_start.sh > "$ROOT/start.sh"
step=client
FSS_ANYTLS_BINARY="$ROOT/client" /bin/sh "$ROOT/start.sh"
step=source
set +e
. "$ROOT/shunt.sh"
set -e
type fss_shunt_apply_native_policy >/dev/null
step=json
jq --slurpfile auth "$ROOT/proxy-auth.json" '
 .inbounds |= map(select(.tag=="socks-in" or .tag=="api-in") |
 if .tag=="socks-in" then .listen="192.168.50.1" | .port=30556 | .settings={auth:"password",accounts:[$auth[0]],udp:false} else .listen="127.0.0.1"|.port=30585 end) |
 .routing.rules |= map(select(.outboundTag!="reject")) |
 (.outbounds[]|select(.tag=="proxy654")|.settings.servers[0].port)=18082 |
 .log={access:"none",error:"none",loglevel:"warning"}
' /koolshare/ss/xray.json > "$ROOT/xray.json"
step=policy
fss_shunt_apply_native_policy "$ROOT/xray.json" proxy654
env "xray.location.asset=/koolshare/ss/rules_ng2/dat" /koolshare/bin/xray run -test -config "$ROOT/xray.json" > "$ROOT/config-check.log" 2>&1
[ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 81920 ]
step=xray
nohup env "xray.location.asset=/koolshare/ss/rules_ng2/dat" /koolshare/bin/xray run -config "$ROOT/xray.json" > "$ROOT/xray.log" 2>&1 </dev/null &
echo $! > "$ROOT/xray.pid"
sleep 2
kill -0 "$(cat "$ROOT/xray.pid")"
[ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 65536 ]
cat /proc/sys/kernel/random/boot_id > "$ROOT/boot-id"
date +%s > "$ROOT/run-id"
touch "$ROOT/setup.complete"
# Test-only expiry survives a disconnected development session.
nohup /bin/sh "$ROOT/expire.sh" "$(cat "$ROOT/run-id")" > "$ROOT/expiry.log" 2>&1 </dev/null &
trap - EXIT
echo isolated_authenticated_pi_only_proxy_ready=1
