#!/bin/sh
set -e
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=${FSS_ARTIFACT_TEST_ROOT:-/tmp/fancyss-native-v1-tests}
NODE_ID=${FSS_TEST_NODE_ID:-654}
case "$NODE_ID" in ''|*[!0-9]*) exit 2;; esac
PERP_BASE="$ROOT/perp"
export FSS_ANYTLS_PERP_BASE="$PERP_BASE" FSS_ANYTLS_SERVICE_NAME=fss-test-anytls-$NODE_ID
[ ! -e "$PERP_BASE" ] || exit 1
mkdir -m 700 "$PERP_BASE"
production_before=$(pidof fss-anytls-client || true)
perpd -a 7 "$PERP_BASE" > "$ROOT/perpd.log" 2>&1 &
supervisor=$!
cleanup() {
    /bin/sh "$OUT/nodes/${NODE_ID}_stop.sh" >/dev/null 2>&1 || true
    kill "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
}
trap cleanup EXIT
OUT="$ROOT/native/runtime_artifacts"
meta_before=$(sha256sum /koolshare/configs/fancyss/node_json_cache.meta)
printf '%s\n' "$NODE_ID" > "$ROOT/native-ids"
"$ROOT/node-tool" runtime-artifact --profile shunt --effective --ids-file "$ROOT/native-ids" --output-dir "$OUT"
meta_after=$(sha256sum /koolshare/configs/fancyss/node_json_cache.meta)
[ "$meta_before" = "$meta_after" ] || exit 1
printf 'global_node_cache_unchanged=1\n'
sed -i "s#/koolshare/scripts/ss_anytls_helper.sh#$ROOT/ss_anytls_helper.sh#g" "$OUT/nodes/${NODE_ID}_start.sh" "$OUT/nodes/${NODE_ID}_stop.sh"
pass="$OUT/nodes/${NODE_ID}_anytls.pass"
pidfile="$OUT/nodes/${NODE_ID}_anytls.pid"
port=$(sed -n 's/^start_port=//p' "$OUT/meta/${NODE_ID}.meta")
helper="$ROOT/ss_anytls_helper.sh"
test_port=23943
if netstat -nl 2>/dev/null | awk -v p=":$test_port" '$4~p"$"{used=1}END{exit !used}'; then exit 1; fi
for file in "$OUT/nodes/${NODE_ID}_start.sh" "$OUT/nodes/${NODE_ID}_stop.sh" "$OUT/nodes/${NODE_ID}_outbounds.json"; do
    [ ! -f "$file" ] || sed -i "s/127.0.0.1:$port/127.0.0.1:$test_port/g;s/\"port\":$port/\"port\":$test_port/g" "$file"
done
port=$test_port

/bin/sh "$OUT/nodes/${NODE_ID}_start.sh"
pid1=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port")
/bin/sh "$OUT/nodes/${NODE_ID}_start.sh"
pid2=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port")
[ "$pid1" = "$pid2" ] || exit 1
printf 'idempotent_start=1\n'
if FSS_ANYTLS_SERVICE_NAME= /bin/sh "$helper" start "$ROOT/collision.pid" "$pass" "127.0.0.1:$port" invalid.example:443 '' --verify; then exit 1; fi
/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port" >/dev/null
printf 'port_collision_preserves_owner=1\n'
printf '%s 0\n' "$pid1" > "$ROOT/stale.pid"
FSS_ANYTLS_SERVICE_NAME= /bin/sh "$helper" stop "$ROOT/stale.pid" "$pass" "127.0.0.1:$port"
/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port" >/dev/null
printf 'stale_pid_does_not_kill=1\n'
perpctl -b "$PERP_BASE" k "$FSS_ANYTLS_SERVICE_NAME" >/dev/null 2>&1
sleep 1
count=0
while ! pid3=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port"); do
    [ "$count" -lt 8 ] || exit 1
    sleep 1; count=$((count+1))
done
[ "$pid3" != "$pid1" ] || exit 1
printf 'supervisor_recovers_process=1\n'
/bin/sh "$OUT/nodes/${NODE_ID}_stop.sh"
if /bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port"; then exit 1; fi
printf 'owned_stop_cleans_instance=1\n'

[ "$(pidof fss-anytls-client || true)" = "$production_before" ]
