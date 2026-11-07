#!/bin/sh
set -e
umask 077
ROOT=${FSS_GUARD_ROOT:-/var/backups/camera-monitor/fancyss-direct-v1-control-v4}
APP=${FSS_GUARD_APP:-/opt/camera-monitor/camera_monitor}
now() { awk '{print int($1)}' /proc/uptime; }
restore() {
    if [ -f "$ROOT/captured-payload.sha256" ]; then
        (cd "$ROOT" && sha256sum -c captured-payload.sha256) >> "$ROOT/rollback.log" 2>&1 || return 1
    else
        [ -s "$ROOT/graph.py" ] && [ -s "$ROOT/uploader.py" ] || return 1
    fi
    systemctl stop camera-uploader camera-viewing-uploader camera-web || return 1
    cp -p "$ROOT/graph.py" "$APP/graph.py" &&
        cp -p "$ROOT/uploader.py" "$APP/uploader.py" &&
        cmp -s "$ROOT/graph.py" "$APP/graph.py" &&
        cmp -s "$ROOT/uploader.py" "$APP/uploader.py" || return 1
    systemctl start camera-uploader camera-viewing-uploader camera-web || return 1
    for unit in camera-uploader camera-viewing-uploader camera-web; do
        systemctl is-active --quiet "$unit" || return 1
    done
}
finish_guard() {
    rm -f "$ROOT/pending" "$ROOT/rolling-back"
}
state_lock() {
    exec 9>"$ROOT/state.lock" && flock -x 9 || return 1
    trap 'flock -u 9 2>/dev/null || true' EXIT
}
rollback_locked() {
    local attempt=1
    : > "$ROOT/rolling-back" || return 1
    while [ "$attempt" -le 3 ]; do
        printf 'rollback_attempt=%s time=%s\n' "$attempt" "$(date -Iseconds)" >> "$ROOT/audit" || return 1
        if restore 8>&- 9>&-; then
            date -Iseconds > "$ROOT/rolled-back.new" &&
                mv -f "$ROOT/rolled-back.new" "$ROOT/rolled-back" || return 1
            finish_guard
            return
        fi
        printf 'rollback_failed=%s\n' "$attempt" >> "$ROOT/audit" || return 1
        attempt=$((attempt+1))
        [ "$attempt" -gt 3 ] || sleep 15
    done
    return 1
}

case "${1:-watch}" in
watch|start)
    [ -f "$ROOT/pending" ] || exit 0
    exec 8>"$ROOT/watch.lock"
    flock -n 8 || exit 0
    while :; do
        state_lock || exit 1
        [ -f "$ROOT/pending" ] || exit 0
        if [ -f "$ROOT/rolled-back" ] ||
            { [ -f "$ROOT/confirmed" ] && [ ! -f "$ROOT/rolling-back" ]; }; then
            finish_guard
            exit
        fi
        deadline=$(cat "$ROOT/deadline")
        if [ -f "$ROOT/rolling-back" ] || [ "$(now)" -ge "$deadline" ]; then
            if [ "${FSS_GUARD_VALIDATE_ONLY:-0}" = 1 ]; then
                echo guard_timeout_path_validated
                exit 0
            fi
            rollback_locked
            exit
        fi
        flock -u 9
        exec 9>&-
        sleep 5
    done
    ;;
renew|commit)
    state_lock || exit 1
    [ -f "$ROOT/pending" ] && [ ! -f "$ROOT/rolling-back" ] &&
        [ ! -f "$ROOT/confirmed" ] && [ ! -f "$ROOT/rolled-back" ] || exit 1
    if [ "$1" = renew ]; then
        echo $(( $(now)+300 )) > "$ROOT/deadline.new"
        mv -f "$ROOT/deadline.new" "$ROOT/deadline"
    else
        [ "$(now)" -lt "$(cat "$ROOT/deadline")" ] || exit 1
        date -Iseconds > "$ROOT/confirmed.new"
        mv -f "$ROOT/confirmed.new" "$ROOT/confirmed"
        finish_guard
    fi
    ;;
rollback|force-rollback)
    state_lock || exit 1
    if [ "$1" = rollback ]; then
        [ ! -f "$ROOT/rolled-back" ] || { finish_guard; exit; }
        [ -f "$ROOT/pending" ] && [ ! -f "$ROOT/confirmed" ] || exit 1
    else
        : > "$ROOT/rolling-back"
        : > "$ROOT/pending"
        rm -f "$ROOT/confirmed" "$ROOT/rolled-back"
    fi
    rollback_locked
    ;;
*) exit 2;;
esac
