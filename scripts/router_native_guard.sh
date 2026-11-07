#!/bin/sh
# Router-local guard. Never depends on SSH/client WAN staying connected.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=${FSS_GUARD_ROOT:-/jffs/configs/fss-native-v1}
now() { awk '{print int($1)}' /proc/uptime; }
boot() { cat /proc/sys/kernel/random/boot_id; }
verify() {
    local expected actual
    expected=$(awk 'NR==1 {print $1}' "$ROOT/baseline.sha256") || return 1
    actual=$(sha256sum "$ROOT/baseline.tgz") || return 1
    [ -n "$expected" ] && [ "$expected" = "${actual%% *}" ] &&
        tar -tzf "$ROOT/baseline.tgz" >/dev/null
}
restore() {
    verify || return 1
    /bin/sh /koolshare/ss/ssconfig.sh stop >> "$ROOT/rollback.log" 2>&1 || true
    while IFS= read -r path; do
        [ -z "$path" ] || rm -f "/$path" || return 1
    done < "$ROOT/absent"
    tar -xzf "$ROOT/baseline.tgz" -C / || return 1
    if [ -f "$ROOT/captured-payload.sha256" ]; then
        (cd / && sha256sum -c "$ROOT/captured-payload.sha256") >> "$ROOT/rollback.log" 2>&1 || return 1
    else
        while IFS= read -r path; do
            [ -e "/$path" ] || return 1
        done < "$ROOT/present"
    fi
    { dbus list ss; dbus list fss; } | cut -d= -f1 | grep -E '^(ss_|ssconf_|fss_)[a-zA-Z0-9_]+$' > "$ROOT/current.keys" || return 1
    while IFS= read -r key; do
        grep -Fxq "$key" "$ROOT/baseline.keys" || dbus remove "$key" || return 1
    done < "$ROOT/current.keys"
    tab=$(printf '\t')
    while IFS="$tab" read -r key encoded; do
        case "$key" in ss_*|ssconf_*|fss_*) ;; *) return 1;; esac
        value=$(printf '%s' "$encoded" | base64 -d) || return 1
        dbus set "$key=$value" || return 1
    done < "$ROOT/dbus.tsv"
    /bin/sh /jffs/scripts/airport-node-dns.sh >> "$ROOT/rollback.log" 2>&1 || return 1
    /bin/sh /koolshare/ss/ssconfig.sh restart >> "$ROOT/rollback.log" 2>&1 || return 1
    pidof xray >/dev/null && netstat -nltp 2>/dev/null | awk '
        $4=="127.0.0.1:23456" && $NF ~ /\/xray$/ {found=1} END {exit !found}
    ' || return 1

    jq -e '[.outbounds[]|select(.tag|startswith("proxy"))|.protocol]|index("vless")!=null' /koolshare/ss/xray.json >/dev/null || return 1
    [ ! -f "$ROOT/post-restore.sh" ] || /bin/sh "$ROOT/post-restore.sh" >> "$ROOT/rollback.log" 2>&1 || return 1
}
finish_guard() {
    local hook
    rm -f "$ROOT/pending" "$ROOT/rolling-back" || return 1
    if [ -f "$ROOT/guard-hook" ]; then
        read -r hook < "$ROOT/guard-hook" || return 1
        case "$hook" in /koolshare/init.d/S95fss-*-rollback.sh) rm -f "$hook";; *) return 1;; esac
    fi
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
        if [ ! -f "$ROOT/rolling-back" ] && [ "$(cat "$ROOT/boot")" != "$(boot)" ]; then
            boot > "$ROOT/boot"
            echo $(( $(now)+300 )) > "$ROOT/deadline.new"
            mv -f "$ROOT/deadline.new" "$ROOT/deadline"
            printf 'boot_guard_rearmed=%s\n' "$(date -Iseconds)" >> "$ROOT/audit"
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
verify) verify;;
*) exit 2;;
esac
