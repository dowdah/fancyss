#!/bin/sh
set -e
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/tmp/fancyss-native-v1-tests
OUT="$ROOT/native/runtime_artifacts"
meta_before=$(sha256sum /koolshare/configs/fancyss/node_json_cache.meta)
printf '654\n' > "$ROOT/native-ids"
"$ROOT/node-tool" runtime-artifact --profile shunt --effective --ids-file "$ROOT/native-ids" --output-dir "$OUT"
meta_after=$(sha256sum /koolshare/configs/fancyss/node_json_cache.meta)
[ "$meta_before" = "$meta_after" ] || exit 1
printf 'global_node_cache_unchanged=1\n'
sed -i "s#/koolshare/scripts/ss_anytls_helper.sh#$ROOT/ss_anytls_helper.sh#g" "$OUT/nodes/654_start.sh" "$OUT/nodes/654_stop.sh"
pass="$OUT/nodes/654_anytls.pass"
pidfile="$OUT/nodes/654_anytls.pid"
port=$(sed -n 's/^start_port=//p' "$OUT/meta/654.meta")
helper="$ROOT/ss_anytls_helper.sh"
trap '/bin/sh "$OUT/nodes/654_stop.sh" >/dev/null 2>&1' EXIT
/bin/sh "$OUT/nodes/654_start.sh"
pid1=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port")
/bin/sh "$OUT/nodes/654_start.sh"
pid2=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port")
[ "$pid1" = "$pid2" ] || exit 1
printf 'idempotent_start=1\n'
if /bin/sh "$helper" start "$ROOT/collision.pid" "$pass" "127.0.0.1:$port" invalid.example:443 '' --verify; then exit 1; fi
/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port" >/dev/null
printf 'port_collision_preserves_owner=1\n'
printf '%s 0\n' "$pid1" > "$ROOT/stale.pid"
/bin/sh "$helper" stop "$ROOT/stale.pid" "$pass" "127.0.0.1:$port"
/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port" >/dev/null
printf 'stale_pid_does_not_kill=1\n'
perpctl -b /koolshare/perp k fss-anytls-654 >/dev/null 2>&1
sleep 1
count=0
while ! pid3=$(/bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port"); do
    [ "$count" -lt 8 ] || exit 1
    sleep 1; count=$((count+1))
done
[ "$pid3" != "$pid1" ] || exit 1
printf 'supervisor_recovers_process=1\n'
/bin/sh "$OUT/nodes/654_stop.sh"
if /bin/sh "$helper" status "$pidfile" "$pass" "127.0.0.1:$port"; then exit 1; fi
printf 'owned_stop_cleans_instance=1\n'
