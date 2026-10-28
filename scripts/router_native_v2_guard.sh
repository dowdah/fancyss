#!/bin/sh
# Router-local guard. Never depends on SSH/client WAN staying connected.
set -e
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/koolshare/bin
export PATH
ROOT=${FSS_GUARD_ROOT:-/jffs/configs/fss-native-v2}
now() { awk '{print int($1)}' /proc/uptime; }
boot() { cat /proc/sys/kernel/random/boot_id; }
restore() {
    [ "${FSS_GUARD_VALIDATE_ONLY:-0}" != 1 ] || { echo guard_timeout_path_validated; return 0; }
    mkdir "$ROOT/restore.lock" 2>/dev/null || exit 1
    trap 'rmdir "$ROOT/restore.lock" 2>/dev/null' EXIT
    rm -f "$ROOT/pending"
    printf 'rollback_started=%s\n' "$(date -Iseconds)" >> "$ROOT/audit"
    /bin/sh /koolshare/ss/ssconfig.sh stop >> "$ROOT/rollback.log" 2>&1 || true
    # Remove only files absent in the captured baseline.
    while IFS= read -r path; do [ -z "$path" ] || rm -f "/$path"; done < "$ROOT/absent"
    tar -xzf "$ROOT/baseline.tgz" -C /
    { dbus list ss; dbus list fss; } | cut -d= -f1 | grep -E '^(ss_|ssconf_|fss_)[a-zA-Z0-9_]+$' > "$ROOT/current.keys"
    while IFS= read -r key; do
        grep -Fxq "$key" "$ROOT/baseline.keys" || dbus remove "$key"
    done < "$ROOT/current.keys"
    tab=$(printf '\t')
    while IFS="$tab" read -r key encoded; do
        case "$key" in ss_*|ssconf_*|fss_*) ;; *) exit 1;; esac
        value=$(printf '%s' "$encoded" | base64 -d)
        dbus set "$key=$value"
    done < "$ROOT/dbus.tsv"
    # Airport DNS is an independently accepted component. The fork baseline
    # already includes the verified backup upstream; keep its owned process.
    /bin/sh /jffs/scripts/airport-node-dns.sh >> "$ROOT/rollback.log" 2>&1 || true
    /bin/sh /koolshare/ss/ssconfig.sh restart >> "$ROOT/rollback.log" 2>&1
    [ "$(dbus get fss_node_current)" = "$(cat "$ROOT/current-node")" ]
    jq -e '[.outbounds[]|select(.tag|startswith("proxy"))|.protocol]|index("socks")!=null' /koolshare/ss/xray.json >/dev/null
    printf 'rollback_complete=%s\n' "$(date -Iseconds)" >> "$ROOT/audit"
}
case "${1:-watch}" in
watch|start)
    [ -f "$ROOT/pending" ] || exit 0
    # Only one detached watcher, including after a boot hook races a command.
    exec 8>"$ROOT/watch.lock"
    flock -n 8 || exit 0
    while [ -f "$ROOT/pending" ]; do
        previous=$(cat "$ROOT/boot")
        if [ "$previous" != "$(boot)" ]; then
            boot > "$ROOT/boot"
            echo $(( $(now)+300 )) > "$ROOT/deadline"
            printf 'boot_guard_rearmed=%s\n' "$(date -Iseconds)" >> "$ROOT/audit"
        fi
        deadline=$(cat "$ROOT/deadline")
        if [ "$(now)" -ge "$deadline" ]; then restore; exit; fi
        sleep 5
    done
    ;;
renew)
    [ -f "$ROOT/pending" ] || exit 1
    echo $(( $(now)+300 )) > "$ROOT/deadline.new"
    mv "$ROOT/deadline.new" "$ROOT/deadline"
    ;;
commit)
    rm -f "$ROOT/pending"
    printf 'confirmed=%s\n' "$(date -Iseconds)" >> "$ROOT/audit"
    ;;
rollback) restore;;
*) exit 2;;
esac
