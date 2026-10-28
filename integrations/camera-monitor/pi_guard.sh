#!/bin/sh
set -e
ROOT=/var/backups/camera-monitor/fancyss-direct-v1-control-v4
case "${1:-watch}" in
watch)
    while [ -f "$ROOT/pending" ]; do
        deadline=$(cat "$ROOT/deadline")
        now=$(awk '{print int($1)}' /proc/uptime)
        if [ "$now" -ge "$deadline" ]; then /bin/sh "$0" rollback; exit; fi
        sleep 5
    done
    ;;
renew) echo $(( $(awk '{print int($1)}' /proc/uptime)+300 )) > "$ROOT/deadline";;
commit) rm -f "$ROOT/pending"; date -Iseconds > "$ROOT/confirmed";;
rollback|force-rollback)
    if [ "$1" = rollback ] && [ -f "$ROOT/confirmed" ]; then echo component_already_confirmed; exit 0; fi
    rm -f "$ROOT/pending"
    systemctl stop camera-uploader camera-viewing-uploader camera-web
    cp -p "$ROOT/graph.py" /opt/camera-monitor/camera_monitor/graph.py
    cp -p "$ROOT/uploader.py" /opt/camera-monitor/camera_monitor/uploader.py
    systemctl start camera-uploader camera-viewing-uploader camera-web
    date -Iseconds > "$ROOT/rolled-back"
    ;;
*) exit 2;;
esac
