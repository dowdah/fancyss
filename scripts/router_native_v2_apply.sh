#!/bin/sh
# Stop the captured version before changing helper/backend identity.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=/jffs/configs/fss-native-v2
STAGE=/tmp/fancyss-native-v2-deploy
[ -f "$ROOT/baseline.tgz" ] && [ -f "$ROOT/guard-test.log" ] && [ ! -f "$ROOT/pending" ]
jq -r '.files|to_entries[]|"\(.value)  \(.key)"' "$STAGE/shadowsocks/ss/fork-build.json" > "$STAGE/payload.sha256"
(cd "$STAGE" && sha256sum -c payload.sha256) > "$ROOT/payload-check.log"
touch "$ROOT/pending"
/bin/sh "$ROOT/guard.sh" renew
cat > /koolshare/init.d/S96fss-native-guard.sh <<'HOOK'
#!/bin/sh
[ "$1" = start ] || exit 0
nohup /bin/sh /jffs/configs/fss-native-v2/guard.sh watch > /jffs/configs/fss-native-v2/watch.log 2>&1 </dev/null &
HOOK
chmod 755 /koolshare/init.d/S96fss-native-guard.sh
nohup /bin/sh "$ROOT/guard.sh" watch > "$ROOT/watch.log" 2>&1 </dev/null &
/bin/sh /koolshare/ss/ssconfig.sh stop >> "$ROOT/apply.log" 2>&1
# Invoke original generated stop scripts explicitly: some firmware PATHs have
# a hardware register utility named sh ahead of /bin/sh.
for stop in /tmp/fancyss_shunt/runtime_artifacts/nodes/*_stop.sh; do
 [ ! -f "$stop" ] || /bin/sh "$stop" >> "$ROOT/apply.log" 2>&1 || exit 1
done
# The old helper must have stopped its exact instance before installation.
if [ -s /tmp/fancyss_shunt/runtime_artifacts/nodes/654_anytls.pid ]; then echo old_instance_not_stopped; exit 1; fi
while IFS= read -r item; do
 case "$item" in shadowsocks/*) target="/koolshare/${item#shadowsocks/}";; *) exit 1;; esac
 [ -f "$STAGE/$item" ] || exit 1
 mkdir -p "${target%/*}"
 cp "$STAGE/$item" "${target}.native-new"
 case "$target" in *.sh|*/fss-anytls-client) chmod 755 "${target}.native-new";; *) chmod 644 "${target}.native-new";; esac
 mv "${target}.native-new" "$target"
done < "$STAGE/payload-files"
[ "$(df -k /jffs | awk 'END{print $4}')" -ge 2048 ] || { echo persistent_space_gate_failed; /bin/sh "$ROOT/guard.sh" rollback; exit 1; }
/bin/sh "$ROOT/guard.sh" renew
/bin/sh /koolshare/ss/ssconfig.sh restart >> "$ROOT/apply.log" 2>&1
[ "$(dbus get fss_node_current)" = "$(cat "$ROOT/current-node")" ]
/koolshare/bin/fss-anytls-client --version
/bin/sh "$ROOT/guard.sh" renew
echo native_v2_started_under_local_guard=1
