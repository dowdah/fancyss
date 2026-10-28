#!/bin/sh
# Adopt the existing airport resolver without moving it into business DNS.
set -e
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
CONF=/jffs/configs/airport-smartdns.conf
[ -f "$CONF" ] || exit 0
ROOT=/koolshare/scripts
# Firmware BusyBox may omit mktemp. mkdir is atomic and rejects existing paths.
airport_tmpdir() {
    local prefix="$1" n=0 candidate=""
    while [ "$n" -lt 16 ]; do
        candidate="${prefix}.$$.${n}"
        if (umask 077; mkdir "$candidate") 2>/dev/null; then printf '%s\n' "$candidate"; return 0; fi
        n=$((n+1))
    done
    return 1
}
WORK=$(airport_tmpdir /tmp/fss_airport_install)
LOCK=/tmp/airport-node-dns.lock
held=0
cleanup() { rm -rf "$WORK"; if [ "$held" = 1 ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi; }
trap cleanup EXIT
count=0
while ! mkdir "$LOCK" 2>/dev/null; do
    [ "$count" -lt 20 ] || exit 1
    sleep 1; count=$((count+1))
done
held=1
birth=$(sed 's/^.*) //' /proc/$$/stat | awk '{print $20}')
printf '%s %s\n' "$$" "$birth" > "$LOCK/pid"
RULE=/jffs/configs/dnsmasq.d/airport-node-forward.conf
if [ ! -s /jffs/configs/airport-node-dns.identities ]; then
    node-tool list --format json --source subscribe --effective > "$WORK/nodes.json"
    sed -n 's#^server=/\([^/]*\)/127\.0\.0\.1#\1#p' "$RULE" | sed 's/#6053$//' | jq -Rsc 'split("\n")|map(select(length>0))' > "$WORK/domains.json"
    jq -r --slurpfile domains "$WORK/domains.json" '.[]|select(.server as $s|$domains[0]|index($s))|.airport_identity' "$WORK/nodes.json" | sort -u > "$WORK/identities"
    # Empty profile can still use an explicit provider suffix policy.
    [ -s "$WORK/identities" ] || printf '# explicit suffix policy only\n' > "$WORK/identities"
    mv "$WORK/identities" /jffs/configs/airport-node-dns.identities
fi
if grep -Fq '38.76.213.238:8080/dns-query' "$CONF"; then
    # Provider's authenticated DNS tutorial, verified on-router with system CA.
    if [ ! -f /jffs/configs/airport-node-dns.suffixes ]; then
        printf 'ctcxianyu.com\n525536.xyz\n' > /jffs/configs/airport-node-dns.suffixes
    fi
    if ! grep -Fq '149.104.6.147:8080/dns-query' "$CONF"; then
        cp "$CONF" "$WORK/conf"
        printf '\n# Provider backup DoH; certificate verification enabled.\nserver-https https://149.104.6.147:8080/dns-query\n' >> "$WORK/conf"
        cp "$WORK/conf" "${CONF}.new.$$"
        mv "${CONF}.new.$$" "$CONF"
        RESTART=1
    fi
fi
for name in airport-node-dns.sh airport-node-dns-boot.sh airport-node-dns-status.sh; do
    [ -f "$ROOT/$name" ] || exit 1
    cp "$ROOT/$name" "/jffs/scripts/.$name.new.$$"
    chmod 755 "/jffs/scripts/.$name.new.$$"
    mv "/jffs/scripts/.$name.new.$$" "/jffs/scripts/$name"
done
# An old airdns used SmartDNS's default PID path. Restart once to separate it
# before business SmartDNS is started. Check ownership before sending a signal.
PIDFILE=/var/run/airport-smartdns.pid
if [ -f "$PIDFILE" ]; then
    read -r pid birth < "$PIDFILE"
    case "$pid" in ''|*[!0-9]*) exit 1;; esac
    if [ "$(readlink /proc/$pid/exe 2>/dev/null)" = /jffs/bin/airdns ] &&
       tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fqx -- "$CONF"; then
        if [ "${RESTART:-0}" = 1 ] || ! tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fqx -- "${PIDFILE}.daemon"; then
            kill "$pid"
            count=0
            while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 8 ]; do sleep 1; count=$((count+1)); done
            kill -0 "$pid" 2>/dev/null && exit 1
            rm -f "$PIDFILE"
        fi
    fi
fi
rm -f "$LOCK/pid"; rmdir "$LOCK"; held=0
/bin/sh /jffs/scripts/airport-node-dns.sh sync --defer-reload
