#!/bin/sh
# One-time independent adoption, under the existing VLESS configuration.
set -e
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
STAGE=/tmp/fancyss-airport-native-v1
BACKUP=/jffs/configs/fss-airport-native-v1
[ ! -e "$BACKUP" ] || { echo airport_backup_exists; exit 1; }
mkdir -m700 "$BACKUP"
for path in jffs/scripts/airport-node-dns.sh jffs/scripts/airport-node-dns-boot.sh jffs/scripts/airport-node-dns-status.sh jffs/configs/airport-smartdns.conf jffs/configs/dnsmasq.d/airport-node-forward.conf jffs/configs/airport-node-dns.identities jffs/configs/airport-node-dns.suffixes koolshare/scripts/airport-node-dns.sh koolshare/scripts/airport-node-dns-boot.sh koolshare/scripts/airport-node-dns-status.sh koolshare/scripts/ss_airport_dns_install.sh; do
    if [ -e "/$path" ]; then echo "$path" >> "$BACKUP/present"; else echo "$path" >> "$BACKUP/absent"; fi
done
tar -czf "$BACKUP/original.tgz" -C / -T "$BACKUP/present"
# Independent fresh instance proves backup works before replacing the cached one.
sed -e 's/127.0.0.1:6053/127.0.0.1:16053/g' -e 's/prefetch-domain yes/prefetch-domain no/' -e 's/serve-expired yes/serve-expired no/' -e "s#log-file .*#log-file $STAGE/cold.log#" -e '\#^server-https #d' /jffs/configs/airport-smartdns.conf > "$STAGE/cold.conf"
printf 'server-https https://149.104.6.147:8080/dns-query\n' >> "$STAGE/cold.conf"
/jffs/bin/airdns -f -p "$STAGE/cold.pid" -c "$STAGE/cold.conf" > "$STAGE/cold.stdout" 2>&1 &
cold=$!
trap 'kill "$cold" 2>/dev/null || true' EXIT
sleep 2
answer=$(dnsclient -4 -p16053 -t6 -i1 @127.0.0.1 us04.ctcxianyu.com 2>/dev/null | head -1)
[ -n "$answer" ] || { echo cold_backup_failed; exit 1; }
kill "$cold"; wait "$cold" 2>/dev/null || true
trap - EXIT
for name in airport-node-dns.sh airport-node-dns-boot.sh airport-node-dns-status.sh ss_airport_dns_install.sh; do
    cp "$STAGE/$name" "/koolshare/scripts/.$name.new.$$"
    chmod 755 "/koolshare/scripts/.$name.new.$$"
    mv "/koolshare/scripts/.$name.new.$$" "/koolshare/scripts/$name"
done
/bin/sh /koolshare/scripts/ss_airport_dns_install.sh > "$BACKUP/install.log" 2>&1
printf '640\n654\n' > "$STAGE/ids"
/bin/sh /jffs/scripts/airport-node-dns.sh check --ids-file "$STAGE/ids" > "$BACKUP/check.log" 2>&1
for domain in us04.ctcxianyu.com; do
    answer=$(dnsclient -4 -p6053 -t6 -i1 @127.0.0.1 "$domain" 2>/dev/null | head -1)
    [ -n "$answer" ] || exit 1
    printf 'airport_answer domain=%s address=%s\n' "$domain" "$answer"
done
grep -q '149.104.6.147:8080/dns-query' /jffs/configs/airport-smartdns.conf
[ "$(pidof airdns | wc -w)" = 1 ]
date -Iseconds > "$BACKUP/confirmed"
echo airport_component_confirmed=1
