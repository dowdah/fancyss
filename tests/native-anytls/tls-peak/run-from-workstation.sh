#!/bin/bash
# Management transport only; every HTTPS load connection originates on the Pi.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=${FSS_TLS_REPORT_DIR:?set a private report directory}
mkdir -p "$OUT"
router_host=${FSS_TLS_ROUTER:?set the authorized router SSH host}
pi_host=${FSS_TLS_PI:?set the authorized Pi SSH host}
jump=()
[ -z "${FSS_TLS_JUMP_HOST:-}" ] || jump=(-o "ProxyJump=$FSS_TLS_JUMP_HOST")
router=(ssh "${jump[@]}" -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p"${FSS_TLS_ROUTER_PORT:-2333}" "$router_host")
pi=(ssh "${jump[@]}" -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$pi_host")
cleanup(){ "${router[@]}" '/bin/sh /tmp/fss-tls-peak/router-cleanup.sh' >> "$OUT/cleanup.txt" 2>&1 || true; [ -z "${observer:-}" ] || kill "$observer" 2>/dev/null || true; }
trap cleanup EXIT
"${router[@]}" 'read client ticks < /tmp/fss-tls-peak/client.pid; xray=$(cat /tmp/fss-tls-peak/xray.pid); echo $$ > /tmp/fss-tls-peak/observer.pid; exec /tmp/fss-tls-peak/sampler "$client" "$xray"' > "$OUT/memory.csv" 2> "$OUT/kernel-and-guard.log" &
observer=$!
sleep 1
kill -0 "$observer"
for n in 1 16 32 64 128; do
 "${pi[@]}" "python3 /tmp/driver.py --credentials-file /tmp/fss-tls-proxy-auth.json --connections $n --hold 30" > "$OUT/stage-$n.jsonl" 2> "$OUT/stage-$n.stderr"
 echo "stage_$n=complete"
 kill -0 "$observer"
 "${router[@]}" 'read pid ticks < /tmp/fss-tls-peak/client.pid; netstat -ntp 2>/dev/null | awk -v pid="$pid/" '\''$6=="ESTABLISHED" && index($NF,pid)==1 {if($4 !~ /^127\./)wan++;else local++} END{print "wan_tls="wan+0,"local_tcp="local+0}'\''' >> "$OUT/socket-counts.txt"
 sleep 3
done
for i in 1 2 3; do sleep 25; done
"${router[@]}" 'cat /proc/sys/kernel/random/boot_id; cat /tmp/fss-tls-peak/boot-id; /koolshare/bin/jq -r .build /koolshare/ss/fork-build.json; sed -n "/MemAvailable/p" /proc/meminfo' > "$OUT/post-test-state.txt"
echo complete=1
