#!/bin/sh
set -e
camera-monitor-status > /tmp/fancyss-cm-preflight.status
findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS /mnt/camera-buffer
vcgencmd get_throttled
journalctl -k --since '-15 min' --no-pager | tail -30
for unit in camera-recorder mediamtx camera-live-relay; do echo "$unit"; systemctl show "$unit" -p MainPID -p InvocationID -p NRestarts --no-pager; done
for file in pending confirmed rolled-back; do if [ -f "/var/backups/camera-monitor/fancyss-direct-v1/$file" ]; then echo "$file"; fi; done
curl -fsS --max-time 15 http://127.0.0.1:8080/healthz | python3 -c 'import sys,json;x=json.load(sys.stdin);print("health_ok",x.get("ok"));
def walk(x,p=""):
 if isinstance(x,dict):
  for k,v in x.items():
   if k in ("last_verified_at","status","issues") and ("emergency" in p or "end_to_end" in p):print(p,k,v)
   elif isinstance(v,(dict,list)):walk(v,p+"/"+k)
 elif isinstance(x,list):
  for v in x:walk(v,p)
walk(x)'
