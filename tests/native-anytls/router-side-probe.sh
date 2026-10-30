#!/bin/sh
# Runs only on the router. Uses selected IDs, no node scans, no production rules.
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/tmp/fancyss-native-v1-tests
. /koolshare/scripts/base.sh
. "$ROOT/ss_webtest_gen.sh"
set -e
mkdir -p "$ROOT/runtime_artifacts/nodes"
cleanup() {
    [ -z "${dns_pid:-}" ] || kill "$dns_pid" 2>/dev/null || true
    [ -z "${cold_pid:-}" ] || kill "$cold_pid" 2>/dev/null || true
    for stop in "$ROOT/runtime_artifacts/nodes/"*_stop.sh; do [ ! -f "$stop" ] || /bin/sh "$stop"; done
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Independent cold DoH instance; no production caches are flushed.
sed -e 's/127.0.0.1:6053/127.0.0.1:16053/g' -e 's/cache-size 512/cache-size 512/' -e 's/prefetch-domain yes/prefetch-domain no/' -e 's/serve-expired yes/serve-expired no/' -e "s#log-file .*#log-file $ROOT/cold.log#" /jffs/configs/airport-smartdns.conf > "$ROOT/cold.conf"
# Provider backup documented in the authenticated DNS tutorial (2026-07-18).
# Keep certificate verification enabled for this newly introduced upstream.
sed -i '\#^server-https #d' "$ROOT/cold.conf"
printf 'server-https https://149.104.6.147:8080/dns-query\n' >> "$ROOT/cold.conf"
/jffs/bin/airdns -f -p "$ROOT/cold.pid" -c "$ROOT/cold.conf" >"$ROOT/cold.stdout" 2>&1 &
cold_pid=$!
sleep 3
printf '== COLD AIRPORT DOH ==\n'
cold_answer=$(dnsclient -46 -p 16053 -t 5 -i 1 @127.0.0.1 us04.ctcxianyu.com 2>/dev/null | head -1)
[ -z "$cold_answer" ] && printf 'cold_doh=no_answer\n' || printf 'cold_doh=resolved answer=%s\n' "$cold_answer"
kill "$cold_pid" 2>/dev/null || true; wait "$cold_pid" 2>/dev/null || true; cold_pid=
for pair in 654:18541 640:18542; do
    id=${pair%:*}; port=${pair#*:}
    WT_GEN_OUT_FILE="$ROOT/runtime_artifacts/nodes/${id}_outbounds.json"
    WT_GEN_START_FILE="$ROOT/runtime_artifacts/nodes/${id}_start.sh"
    WT_GEN_STOP_FILE="$ROOT/runtime_artifacts/nodes/${id}_stop.sh"
    WT_PRESET_START_PORT=$port
    wt_gen_anytls_outbound "$id" "side"
    sed -i "s#/koolshare/scripts/ss_anytls_helper.sh#$ROOT/ss_anytls_helper.sh#g" "$WT_GEN_START_FILE" "$WT_GEN_STOP_FILE"
    printf '== NODE %s HELPER START ==\n' "$id"
    /bin/sh "$WT_GEN_START_FILE"
    /bin/sh "$ROOT/ss_anytls_helper.sh" status "$ROOT/runtime_artifacts/nodes/${id}_anytls.pid" "$ROOT/runtime_artifacts/nodes/${id}_anytls.pass" "127.0.0.1:$port"
    curl-fancyss --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 12 -s -o /dev/null -w 'https_code=%{http_code} total=%{time_total}\n' https://www.google.com/generate_204 || true
    curl-fancyss --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 12 -s -o /dev/null -w 'graph_unauth_code=%{http_code} total=%{time_total}\n' https://graph.microsoft.com/v1.0/me || true
    /koolshare/bin/curl-fancyss --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 12 -sS -H 'Accept: application/dns-json' -o "$ROOT/cf-$id.json" -w 'doh_via_anytls_http=%{http_code} total=%{time_total}\n' 'https://cloudflare-dns.com/dns-query?name=github.com&type=A' || true
    /koolshare/bin/jq '{Status,answer_count:(.Answer//[]|length)}' "$ROOT/cf-$id.json" 2>/dev/null || true
    # Test DoH using the already-shipped SmartDNS proxy support.
    cat > "$ROOT/business-dns.conf" <<-EOF
bind 127.0.0.1:17913
bind-tcp 127.0.0.1:17913
proxy-server socks5://127.0.0.1:$port -name fss_proxy
server-https https://cloudflare-dns.com/dns-query -host-ip 162.159.36.1 -proxy fss_proxy
server-https https://cloudflare-dns.com/dns-query -host-ip 162.159.46.1 -proxy fss_proxy
ca-file /etc/ssl/certs/ca-certificates.crt
log-level info
log-file $ROOT/business.log
cache-size 512
speed-check-mode none
EOF
    /koolshare/bin/smartdns -f -p "$ROOT/business.pid" -c "$ROOT/business-dns.conf" >"$ROOT/business.stdout" 2>&1 &
    dns_pid=$!
    sleep 1
    kill -0 "$dns_pid" || { echo dns_instance_start_failed; exit 1; }
    printf '== NODE %s BUSINESS DNS ==\n' "$id"
    for domain in github.com graph.microsoft.com www.youtube.com; do
        printf '%s\n' "$domain"
        answer=$(/koolshare/bin/dnsclient -4 -p 17913 -t 7 -i 1 @127.0.0.1 "$domain" 2>/dev/null | head -1)
        [ -z "$answer" ] && printf 'dns=no_answer\n' || printf 'dns=resolved answer=%s\n' "$answer"
    done
    kill "$dns_pid" 2>/dev/null || true; wait "$dns_pid" 2>/dev/null || true; dns_pid=
    /bin/sh "$WT_GEN_STOP_FILE"
    printf '== NODE %s CLEANUP ==\n' "$id"
    /bin/sh "$ROOT/ss_anytls_helper.sh" status "$ROOT/runtime_artifacts/nodes/${id}_anytls.pid" "$ROOT/runtime_artifacts/nodes/${id}_anytls.pass" "127.0.0.1:$port" && exit 1 || true
done
