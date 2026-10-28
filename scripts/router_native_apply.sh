#!/bin/sh
# Apply the exact delta only after a local baseline and timeout test exist.
set -e
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/jffs/configs/fss-native-v1
STAGE=/tmp/fancyss-native-v1-deploy
[ -f "$ROOT/baseline.tgz" ] && [ -f "$ROOT/guard-test.log" ]
[ ! -f "$ROOT/pending" ]
# Every payload file must match the locally built manifest before mutation.
jq -r '.files|to_entries[]|"\(.value)  \(.key)"' "$STAGE/shadowsocks/ss/fork-build.json" > "$STAGE/payload.sha256"
(cd "$STAGE" && sha256sum -c payload.sha256) > "$ROOT/payload-check.log"
touch "$ROOT/pending"
/bin/sh "$ROOT/guard.sh" renew
cat > /koolshare/init.d/S96fss-native-guard.sh <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
nohup /bin/sh /jffs/configs/fss-native-v1/guard.sh watch > /jffs/configs/fss-native-v1/watch.log 2>&1 </dev/null &
EOF
chmod 755 /koolshare/init.d/S96fss-native-guard.sh
nohup /bin/sh "$ROOT/guard.sh" watch > "$ROOT/watch.log" 2>&1 </dev/null &
while IFS= read -r item; do
    case "$item" in shadowsocks/install.sh) continue;; shadowsocks/*) target="/koolshare/${item#shadowsocks/}";; *) exit 1;; esac
    [ -f "$STAGE/$item" ] || continue
    mkdir -p "${target%/*}"
    cp "$STAGE/$item" "${target}.native-new"
    chmod --reference="$STAGE/$item" "${target}.native-new" 2>/dev/null || {
        case "$target" in *.sh|*/node-tool) chmod 755 "${target}.native-new";; *) chmod 644 "${target}.native-new";; esac
    }
    mv "${target}.native-new" "$target"
done < "$STAGE/payload-files"
/bin/sh /koolshare/scripts/ss_airport_dns_install.sh >> "$ROOT/apply.log" 2>&1
# Normal native SmartDNS policy with two validated DoH bootstrap addresses.
dbus set ss_basic_dns_plan=2
dbus set ss_basic_smrt=2
dbus set "ss_basic_smrt_gfw_dns=$(cat "$STAGE/business-doh-value")"
black=$(dbus get ss_wan_black_domain | base64 -d)
if ! printf '%s\n' "$black" | grep -Fxq login.live.com; then
    dbus set "ss_wan_black_domain=$(printf '%s\nlogin.live.com\n' "$black" | base64 | tr -d '\r\n')"
fi
dbus set ss_basic_shunt_audit=1
/bin/sh "$ROOT/guard.sh" renew
/bin/sh /koolshare/ss/ssconfig.sh restart >> "$ROOT/apply.log" 2>&1
jq -e '[.outbounds[]|select(.tag|startswith("proxy"))|.protocol]|index("vless")!=null' /koolshare/ss/xray.json >/dev/null
/bin/sh "$ROOT/guard.sh" renew
echo fork_applied_under_vless=1
