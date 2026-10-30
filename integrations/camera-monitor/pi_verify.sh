#!/bin/sh
# Narrow post-deploy checks. No root SQLite access and no secret values printed.
set -e
/bin/sh /var/backups/camera-monitor/fancyss-direct-v1-control-v4/guard.sh renew
chown root:camera-monitor /tmp/fancyss-cm-native-v1 /tmp/fancyss-cm-native-v1/probe_direct_download.py
chmod 750 /tmp/fancyss-cm-native-v1
chmod 640 /tmp/fancyss-cm-native-v1/probe_direct_download.py
systemctl is-active camera-uploader camera-viewing-uploader camera-web camera-recorder mediamtx camera-live-relay
systemd-run --unit=cm-fancyss-direct-v1-probe --wait --pipe --collect --uid=camera-monitor --gid=camera-monitor --property=RuntimeMaxSec=70 --property=EnvironmentFile=/etc/camera-monitor/graph.env --property=LoadCredentialEncrypted=camera-monitor-graph-token-cache:/etc/credstore.encrypted/camera-monitor-graph-token-cache.cred --setenv=CAMERA_MONITOR_CONFIG=/etc/camera-monitor/config.toml /opt/camera-monitor/venv/bin/python /tmp/fancyss-cm-native-v1/probe_direct_download.py
curl -fsS --max-time 15 http://127.0.0.1:8080/healthz | /opt/camera-monitor/venv/bin/python -c 'import sys,json;x=json.load(sys.stdin);print(json.dumps({"ok":x.get("ok"),"status":x.get("health",{}).get("status"),"issues":x.get("health",{}).get("issues")}))'
for unit in camera-recorder mediamtx camera-live-relay; do echo "$unit"; systemctl show "$unit" -p MainPID -p InvocationID -p NRestarts --no-pager; done
