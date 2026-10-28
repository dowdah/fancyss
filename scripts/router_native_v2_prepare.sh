#!/bin/sh
# Captures live state locally; no secrets are exported to the workstation.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=/jffs/configs/fss-native-v2
STAGE=/tmp/fancyss-native-v2-deploy
[ "$(dbus get ss_basic_mode)" = 7 ] || exit 1
[ "$(dbus get ss_basic_pkg_arch)" = hnd ] || exit 1
[ "$(dbus get ss_basic_pkg_type)" = full ] || exit 1
[ "$(dbus get fss_node_current)" = 654 ]
[ "$(jq -r .build /koolshare/ss/fork-build.json)" = 3.5.30-anytls-native.1 ]
jq -e '[.outbounds[]|select(.tag|startswith("proxy"))|.protocol]|index("socks")!=null' /koolshare/ss/xray.json >/dev/null
[ ! -e "$ROOT" ] || { echo baseline_directory_exists; exit 1; }
# Budget new persistent files, a conservative snapshot allowance and 2 MiB reserve.
free=$(df -k /jffs | awk 'END{print $4}')
need=$(du -k "$STAGE/shadowsocks/bin/fss-anytls-client" | awk '{print $1}')
[ "$free" -ge $((need+2048+512)) ] || { echo persistent_space_preflight_failed; exit 1; }
mkdir -m 700 "$ROOT"
dbus get fss_node_current > "$ROOT/current-node"
cp "$STAGE/guard.sh" "$ROOT/guard.sh"
chmod 700 "$ROOT/guard.sh"
: > "$ROOT/present"; : > "$ROOT/absent"
while IFS= read -r item; do
    case "$item" in shadowsocks/install.sh) continue;; shadowsocks/*) path="koolshare/${item#shadowsocks/}";; *) exit 1;; esac
    [ -f "$STAGE/$item" ] || continue
    if [ -e "/$path" ]; then echo "$path" >> "$ROOT/present"; else echo "$path" >> "$ROOT/absent"; fi
done < "$STAGE/payload-files"
for path in jffs/scripts/airport-node-dns.sh jffs/scripts/airport-node-dns-boot.sh jffs/scripts/airport-node-dns-status.sh jffs/configs/airport-smartdns.conf jffs/configs/dnsmasq.d/airport-node-forward.conf jffs/configs/airport-node-dns.identities jffs/configs/airport-node-dns.suffixes koolshare/init.d/S96fss-native-guard.sh koolshare/ss/xray.json koolshare/configs/fancyss/node_shunt_rules.json; do
    if [ -e "/$path" ]; then echo "$path" >> "$ROOT/present"; else echo "$path" >> "$ROOT/absent"; fi
done
sort -u "$ROOT/present" -o "$ROOT/present"; sort -u "$ROOT/absent" -o "$ROOT/absent"
tar -czf "$ROOT/baseline.tgz" -C / -T "$ROOT/present"
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
# Exercise the timeout branch without restoring or changing a live service.
mkdir -p "$STAGE/guard-test"
cp "$ROOT/boot" "$STAGE/guard-test/boot"
echo 0 > "$STAGE/guard-test/deadline"
touch "$STAGE/guard-test/pending"
FSS_GUARD_ROOT="$STAGE/guard-test" FSS_GUARD_VALIDATE_ONLY=1 /bin/sh "$ROOT/guard.sh" watch > "$ROOT/guard-test.log"
grep -q guard_timeout_path_validated "$ROOT/guard-test.log"
printf 'baseline_captured=1\nguard_timeout_validated=1\n'
