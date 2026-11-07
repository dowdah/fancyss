#!/bin/sh
# Router-only, current TW node, at most 8 real resource fetches concurrently.
set -eu
umask 077
PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/tmp/fss-client-v2-test
HELPER=/tmp/fss-v2-helper.sh
cleanup_pool() {
 FSS_ANYTLS_BINARY=/koolshare/bin/anytls-zig /bin/sh "$HELPER" stop "$ROOT/old-pool.pid" "$ROOT/synthetic.pass" 127.0.0.1:19591
}
trap cleanup_pool EXIT
printf synthetic-only > "$ROOT/synthetic.pass"
FSS_ANYTLS_BINARY=/koolshare/bin/anytls-zig /bin/sh "$HELPER" start "$ROOT/old-pool.pid" "$ROOT/synthetic.pass" 127.0.0.1:19591 127.0.0.1:9 '' --insecure
printf 'old_pool '
/tmp/fss-pool-probe-v2 19591 32
for count in 32 128 256; do
 printf 'new_pool '
 /tmp/fss-pool-probe-v2 18082 "$count" & probe=$!
 while kill -0 "$probe" 2>/dev/null; do sed -n '/MemAvailable/p' /proc/meminfo >> "$ROOT/memory-samples"; sleep 1; done
 wait "$probe"
done
awk '/MemAvailable/{if (!min || $2<min) min=$2} END{print "min_mem_available_kib="min}' "$ROOT/memory-samples"
[ "$(awk '/MemAvailable/{if (!min || $2<min) min=$2} END{print min}' "$ROOT/memory-samples")" -ge 32768 ]
old_port=$(jq -r '.outbounds[]|select(.tag=="proxy654")|.settings.servers[0].port' /koolshare/ss/xray.json)
# Run alternating rounds to retain node fluctuations in the evidence.
for round in 1 2 3; do
 for pair in "old:$old_port" new:18082; do
  label=${pair%:*}; port=${pair#*:}
  pids=
  for slot in 1 2 3 4 5 6 7 8; do
   curl-fancyss -4 --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 20 -sS -o /dev/null -w "image round=$round engine=$label slot=$slot code=%{http_code} socks=%{time_connect} tls=%{time_appconnect} first=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" 'https://pbs.twimg.com/media/HVt0xNBbEAAp1Rr?format=jpg&name=large' > "$ROOT/image-$round-$label-$slot" 2>/dev/null &
   pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || true; done
  cat "$ROOT/image-$round-$label-"*
  printf 'fast_api round=%s engine=%s ' "$round" "$label"
  curl-fancyss -4 --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 15 -sS -o "$ROOT/api-$label.json" -w 'code=%{http_code} tls=%{time_appconnect} first=%{time_starttransfer} total=%{time_total}\n' -K /tmp/fss-slowdiag-20261028/fss-fast-api.conf 2>/dev/null || true
  if jq -e '.targets[0].url' "$ROOT/api-$label.json" >/dev/null 2>&1; then
   jq -r '.targets[0].url|sub("/speedtest";"/speedtest/range/0-1048575")|"url = \""+.+"\""' "$ROOT/api-$label.json" > "$ROOT/download-$label.conf"
   printf 'fast_1MiB round=%s engine=%s ' "$round" "$label"
   curl-fancyss -4 --noproxy '' --proxy "socks5h://127.0.0.1:$port" --cacert /etc/ssl/certs/ca-certificates.crt --connect-timeout 5 --max-time 15 --max-filesize 1048576 -sS -o /dev/null -w 'code=%{http_code} first=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n' -K "$ROOT/download-$label.conf" 2>/dev/null || true
  fi
 done
done
