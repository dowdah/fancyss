#!/bin/sh
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=/tmp/fss-tls-peak
router_ip="$(jq -er '.router_ip | select(type == "string" and test("^[0-9]+([.][0-9]+){3}$"))' "$ROOT/test-site.json")"
client_ip="$(jq -er '.client_ip | select(type == "string" and test("^[0-9]+([.][0-9]+){3}$"))' "$ROOT/test-site.json")"
node_id="$(jq -er '.node_id | tostring | select(test("^[0-9]+$"))' "$ROOT/test-site.json")"
expected_build="$(jq -er '.expected_build | select(type == "string" and length > 0)' "$ROOT/test-site.json")"
client_sha="$(jq -er '.client_sha256 | select(type == "string" and test("^[a-fA-F0-9]{64}$"))' "$ROOT/test-site.json")"
[ "$(dbus get fss_node_current)" = "$node_id" ]
[ "$(jq -r .build /koolshare/ss/fork-build.json)" = "$expected_build" ]
[ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 98304 ]
[ ! -f "$ROOT/setup.complete" ]
printf '%s  %s\n' "$client_sha" "$ROOT/client" | sha256sum -c - >/dev/null
jq -e '.user and .pass' "$ROOT/proxy-auth.json" >/dev/null
cleanup() { /bin/sh "$ROOT/router-cleanup.sh"; }
step=preflight
trap 'echo setup_exit_at=$step; cleanup' EXIT
iptables -N FSS_TLS_PEAK_TEST
iptables -A FSS_TLS_PEAK_TEST -s "$client_ip/32" -j ACCEPT
iptables -A FSS_TLS_PEAK_TEST -j DROP
iptables -I INPUT 1 -d "$router_ip/32" -p tcp --dport 30556 -j FSS_TLS_PEAK_TEST
cp /tmp/fancyss_shunt/runtime_artifacts/nodes/${node_id}_anytls.pass "$ROOT/password"
sed -e "s#/koolshare/scripts/ss_anytls_helper.sh#$ROOT/helper#" \
-e "s#/tmp/fancyss_shunt/runtime_artifacts/nodes/${node_id}_anytls.pid#$ROOT/client.pid#" \
-e "s#/tmp/fancyss_shunt/runtime_artifacts/nodes/${node_id}_anytls.pass#$ROOT/password#" \
-e 's/127.0.0.1:[0-9][0-9]*/127.0.0.1:18082/' \
"/tmp/fancyss_shunt/runtime_artifacts/nodes/${node_id}_start.sh" > "$ROOT/start.sh"
step=client
FSS_ANYTLS_BINARY="$ROOT/client" /bin/sh "$ROOT/start.sh"
step=source
set +e
. "$ROOT/shunt.sh"
set -e
type fss_shunt_apply_native_policy >/dev/null
step=json
jq --arg router_ip "$router_ip" --arg outbound "proxy$node_id" --slurpfile auth "$ROOT/proxy-auth.json" '
 .inbounds |= map(select(.tag=="socks-in" or .tag=="api-in") |
 if .tag=="socks-in" then .listen=$router_ip | .port=30556 | .settings={auth:"password",accounts:[$auth[0]],udp:false} else .listen="127.0.0.1"|.port=30585 end) |
 .routing.rules |= map(select(.outboundTag!="reject")) |
 (.outbounds[]|select(.tag==$outbound)|.settings.servers[0].port)=18082 |
 .log={access:"none",error:"none",loglevel:"warning"}
' /koolshare/ss/xray.json > "$ROOT/xray.json"
step=policy
fss_shunt_apply_native_policy "$ROOT/xray.json" "proxy$node_id"
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
