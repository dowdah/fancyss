#!/bin/sh
# Bounded component deployment; no media restart, no root database access.
set -e
python3 /tmp/pi_deploy.py
/bin/sh /tmp/fancyss-cm-native-v1/pi_verify.sh
count=0
while [ "$count" -lt 18 ]; do
    [ ! -f /var/backups/camera-monitor/fancyss-direct-v1-control-v4/confirmed ] || exit 0
    /bin/sh /var/backups/camera-monitor/fancyss-direct-v1-control-v4/guard.sh renew
    if python3 /tmp/fancyss-cm-native-v1/pi_commit.py; then exit 0; fi
    count=$((count+1))
    sleep 20
done
/bin/sh /var/backups/camera-monitor/fancyss-direct-v1-control-v4/guard.sh rollback
exit 1
