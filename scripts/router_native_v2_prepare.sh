#!/bin/sh
# Captures live state locally; no secrets are exported to the workstation.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/router_native_v2_payload.sh"
release=${2:-legacy}
native_paths "$release"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || exit 1
[ "$(dbus get ss_basic_mode)" = 7 ]
[ "$(dbus get ss_basic_pkg_arch)" = hnd ]
[ "$(dbus get ss_basic_pkg_type)" = full ]
jq -e '[.outbounds[]|select(.tag|startswith("proxy"))|.protocol]|index("socks")!=null' /koolshare/ss/xray.json >/dev/null

exec 7>/var/lock/fss-native-deploy.lock
flock -n 7
native_stage_payload "$1"
trap '[ -d "$ROOT" ] || rm -rf "$VERIFIED"' EXIT
native_check_live_baseline "$release" "$VERIFIED/$META" /koolshare
native_rotate_snapshots
# Require room to capture the snapshot before making any persistent changes.
free=$(df -k /jffs | awk 'END{print $4}')
need=$(du -sk "$VERIFIED" | awk '{print $1}')
old_kb=0
if [ -f /koolshare/bin/fss-anytls-client ]; then
    old_kb=$(du -k /koolshare/bin/fss-anytls-client | awk '{print $1}')
fi
[ "$free" -ge $((need+2048)) ] || { echo persistent_space_preflight_failed; exit 1; }
mkdir -m 700 "$ROOT"
dbus get fss_node_current > "$ROOT/current-node"
cp "$SCRIPT_DIR/router_native_v2_guard.sh" "$ROOT/guard.sh"
cp "$VERIFIED/files" "$ROOT/install-files"
cp "$VERIFIED/hashes" "$ROOT/install.sha256"
chmod 700 "$ROOT/guard.sh"
: > "$ROOT/present"; : > "$ROOT/absent"
while IFS= read -r item; do
    path=$(native_target_path "$item")
    [ ! -L "/$path" ] && [ ! -L "/${path%/*}" ] || exit 1
    if [ -e "/$path" ]; then
        [ -f "/$path" ]
        echo "$path" >> "$ROOT/present"
    else
        echo "$path" >> "$ROOT/absent"
    fi
done < "$ROOT/install-files"
for path in jffs/scripts/airport-node-dns.sh jffs/scripts/airport-node-dns-boot.sh jffs/scripts/airport-node-dns-status.sh jffs/configs/airport-smartdns.conf jffs/configs/dnsmasq.d/airport-node-forward.conf jffs/configs/airport-node-dns.identities jffs/configs/airport-node-dns.suffixes koolshare/init.d/S96fss-native-guard.sh koolshare/ss/xray.json koolshare/configs/fancyss/node_shunt_rules.json; do
    if [ -e "/$path" ]; then echo "$path" >> "$ROOT/present"; else echo "$path" >> "$ROOT/absent"; fi
done
sort -u "$ROOT/present" -o "$ROOT/present"; sort -u "$ROOT/absent" -o "$ROOT/absent"
tar -czf "$ROOT/baseline.tgz" -C / -T "$ROOT/present"
(cd / && while IFS= read -r path; do sha256sum "$path" || exit 1; done < "$ROOT/present") > "$ROOT/captured-payload.sha256"
{ dbus list ss; dbus list fss; } | cut -d= -f1 | grep -E '^(ss_|ssconf_|fss_)[a-zA-Z0-9_]+$' | sort -u > "$ROOT/baseline.keys"
# Each value is encoded separately; restoration never exports a large node
# database into the process environment (which would exceed ARM ARG_MAX).
while IFS= read -r key; do
    encoded=$(dbus get "$key" | base64 | tr -d '\r\n')
    printf '%s\t%s\n' "$key" "$encoded"
done < "$ROOT/baseline.keys" > "$ROOT/dbus.tsv"
cat /proc/sys/kernel/random/boot_id > "$ROOT/boot"
awk '{print int($1)+300}' /proc/uptime > "$ROOT/deadline"
sha256sum "$ROOT/baseline.tgz" > "$ROOT/baseline.sha256"
chmod 600 "$ROOT/"*
chmod 700 "$ROOT/guard.sh"
# Measure free space after writing the compressed snapshot and private settings.
# The temporary copy can coexist with the old file; keep at least 2 MiB after
# the atomic replacements. Only credit the old binary, which dominates size.
free=$(df -k /jffs | awk 'END{print $4}')
growth=$((need-old_kb))
[ "$growth" -ge 0 ] || growth=0
echo "flash_after_snapshot_kib=$free staged_kib=$need growth_budget_kib=$growth"
[ "$free" -ge $((need+256)) ] &&
    [ "$free" -ge $((growth+2048)) ] || { echo persistent_space_post_snapshot_failed; exit 1; }
# Exercise the timeout branch without restoring or changing a live service.
mkdir -p "$STAGE/guard-test"
cp "$ROOT/boot" "$STAGE/guard-test/boot"
echo 0 > "$STAGE/guard-test/deadline"
touch "$STAGE/guard-test/pending"
FSS_GUARD_ROOT="$STAGE/guard-test" FSS_GUARD_VALIDATE_ONLY=1 /bin/sh "$ROOT/guard.sh" watch > "$ROOT/guard-test.log"
grep -q guard_timeout_path_validated "$ROOT/guard-test.log"
printf 'baseline_captured=1\nguard_timeout_validated=1\n'
