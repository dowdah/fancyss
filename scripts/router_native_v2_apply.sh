#!/bin/sh
# Stop the captured version before changing helper/backend identity.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/router_native_v2_payload.sh"
release=${1:-legacy}
native_paths "$release"
[ "$#" -le 1 ]
exec 7>/var/lock/fss-native-deploy.lock
flock -n 7
[ -f "$ROOT/baseline.tgz" ] && [ -f "$ROOT/guard-test.log" ] &&
    [ ! -f "$ROOT/pending" ] && [ ! -f "$ROOT/confirmed" ] && [ ! -f "$ROOT/rolled-back" ] || exit 1
grep -q guard_timeout_path_validated "$ROOT/guard-test.log"
/bin/sh "$ROOT/guard.sh" verify
native_verify_prepared > "$ROOT/payload-check.log"
native_check_live_baseline "$release" "$VERIFIED/$META" /koolshare >> "$ROOT/payload-check.log"
[ "$(dbus get ss_basic_mode)" = 7 ]
[ "$(dbus get fss_node_current)" = "$(cat "$ROOT/current-node")" ]
if [ "$release" = legacy ]; then
    hook=/koolshare/init.d/S95fss-native-v2-rollback.sh
else
    hook=/koolshare/init.d/S95fss-current-rollback.sh
fi
[ ! -e "$hook" ] && [ ! -L "$hook" ] || exit 1
touch "$ROOT/pending"
/bin/sh "$ROOT/guard.sh" renew
cat > "$hook" <<HOOK
#!/bin/sh
[ "\$1" = start ] || exit 0
nohup /bin/sh "$ROOT/guard.sh" watch > "$ROOT/watch.log" 2>&1 </dev/null &
HOOK
chmod 755 "$hook"
printf '%s\n' "$hook" > "$ROOT/guard-hook"
rm -f "$ROOT/watch-ready"
nohup /bin/sh "$ROOT/guard.sh" watch 7>&- > "$ROOT/watch.log" 2>&1 </dev/null &
watcher=$!
for attempt in 1 2 3 4 5; do
    [ ! -f "$ROOT/watch-ready" ] || break
    kill -0 "$watcher"
    sleep 1
done
[ -f "$ROOT/watch-ready" ] && kill -0 "$watcher" || exit 1
applied=0
trap 'if [ "$applied" = 0 ]; then /bin/sh "$ROOT/guard.sh" rollback >> "$ROOT/apply.log" 2>&1 || true; fi' EXIT
/bin/sh /koolshare/ss/ssconfig.sh stop 7>&- >> "$ROOT/apply.log" 2>&1
# Invoke original generated stop scripts explicitly: some firmware PATHs have
# a hardware register utility named sh ahead of /bin/sh.
for stop in /tmp/fancyss_shunt/runtime_artifacts/nodes/*_stop.sh; do
 [ ! -f "$stop" ] || /bin/sh "$stop" 7>&- >> "$ROOT/apply.log" 2>&1 || exit 1
done
# The old helper must have stopped its exact instance before installation.
for pidfile in /tmp/fancyss_shunt/runtime_artifacts/nodes/*_anytls.pid /tmp/fss_anytls_single.pid; do
    [ ! -s "$pidfile" ] || { echo old_instance_not_stopped; exit 1; }
done
/bin/sh "$ROOT/guard.sh" renew
(
    exec 9>"$ROOT/state.lock"
    flock -x 9
    [ -f "$ROOT/pending" ] && [ ! -f "$ROOT/rolling-back" ] || exit 1
    native_publish /koolshare
)
[ "$(df -k /jffs | awk 'END{print $4}')" -ge 2048 ] || { echo persistent_space_gate_failed; exit 1; }
/bin/sh "$ROOT/guard.sh" renew
/bin/sh /koolshare/ss/ssconfig.sh restart 7>&- >> "$ROOT/apply.log" 2>&1
[ "$(dbus get fss_node_current)" = "$(cat "$ROOT/current-node")" ]
/koolshare/bin/fss-anytls-client --version
/bin/sh "$ROOT/guard.sh" renew
applied=1
echo native_v2_started_under_local_guard=1
