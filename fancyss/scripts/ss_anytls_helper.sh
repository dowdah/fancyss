#!/bin/sh
# Shared lifecycle for generated native/shell AnyTLS artifacts. No node database.
umask 077
PATH=${FSS_ANYTLS_TEST_PATH:-/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin}
export PATH
action=$1
pidfile=$2
passfile=$3
listen=$4
server=$5
sni=$6
verify=$7
legacy_binary=/koolshare/bin/anytls-zig
if [ -n "${FSS_ANYTLS_BINARY:-}" ]; then
    binary="$FSS_ANYTLS_BINARY"
else
    case "$(uname -r)" in
    2.6.*) binary="$legacy_binary" ;;
    *) binary=/koolshare/bin/fss-anytls-client ;;
    esac
fi
proc=${FSS_PROC_ROOT:-/proc}

ticks() { sed 's/^.*) //' "$proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
owned() {
    read -r instance_pid instance_ticks 2>/dev/null < "$pidfile" || return 1
    case "$instance_pid:$instance_ticks" in *[!0-9:]*|:*|*:) return 1;; esac
    [ -n "$instance_ticks" ] && [ "$(ticks "$instance_pid")" = "$instance_ticks" ] || return 1
    instance_binary=$(readlink "$proc/$instance_pid/exe" 2>/dev/null)
    # hnd may relocate legacy cores to /data and install a symlink in bin.
    [ "$instance_binary" = "$(readlink -f "$binary")" ] ||
        [ "$instance_binary" = "$(readlink -f "$legacy_binary")" ] || return 1
    tr '\000' '\n' < "$proc/$instance_pid/cmdline" | grep -Fqx -- "$passfile" || return 1
    tr '\000' '\n' < "$proc/$instance_pid/cmdline" | grep -Fqx -- "$listen" || return 1
}
listening() {
    netstat -nlpt 2>/dev/null | awk -v address="$listen" -v owner="$instance_pid/" '$4==address && index($NF,owner)==1 {ok=1} END {exit !ok}'
}
stop_owned() {
    if [ -e "$pidfile" ]; then
        read -r stop_pid stop_ticks < "$pidfile" || return 1
        case "$stop_pid:$stop_ticks" in *[!0-9:]*|:*|*:|0:*) return 1;; esac
        if ! stop_process_exited; then
            owned && [ "$instance_pid:$instance_ticks" = "$stop_pid:$stop_ticks" ] || return 1
            kill "$stop_pid" 2>/dev/null || stop_process_exited || return 1
            if ! wait_for_stop; then
                owned && [ "$instance_pid:$instance_ticks" = "$stop_pid:$stop_ticks" ] || stop_process_exited || return 1
                if ! stop_process_exited; then
                    kill -9 "$stop_pid" 2>/dev/null || stop_process_exited || return 1
                    wait_for_stop || return 1
                fi
            fi
        fi
    fi
    rm -f "$pidfile"
}
stop_process_exited() {
    [ ! -d "$proc/$stop_pid" ] && return 0
    state_and_ticks=$(sed 's/^.*) //' "$proc/$stop_pid/stat" 2>/dev/null | awk '{print $1, $20}')
    set -- $state_and_ticks
    if [ "$#" != 2 ]; then
        [ ! -d "$proc/$stop_pid" ]
        return
    fi
    case "$2" in ''|*[!0-9]*) return 1;; esac
    [ "$2" != "$stop_ticks" ] || [ "$1" = Z ] || [ "$1" = X ]
}
wait_for_stop() {
    count=0
    while ! stop_process_exited; do
        [ "$count" -lt 5 ] || return 1
        sleep 1
        count=$((count+1))
    done
}
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
service_name=
case "$pidfile" in
 /tmp/fss_anytls_single.pid) service_name=fss-anytls-single;;
/tmp/fancyss_shunt/runtime_artifacts/nodes/*_anytls.pid)
    node=${pidfile##*/}; node=${node%_anytls.pid}
    case "$node" in ''|*[!0-9]*) exit 1;; esac
    service_name="fss-anytls-$node"
    ;;
esac
perp_base=${FSS_ANYTLS_PERP_BASE:-/koolshare/perp}
if [ -n "${FSS_ANYTLS_SERVICE_NAME:-}" ]; then
    case "$FSS_ANYTLS_SERVICE_NAME" in *[!a-zA-Z0-9_-]*|'') exit 2;; esac
    [ "$perp_base" != /koolshare/perp ] || exit 2
    service_name="$FSS_ANYTLS_SERVICE_NAME"
fi
case "$perp_base" in /*) ;; *) exit 2;; esac
service_dir="$perp_base/$service_name"

stop_instance() {
    if [ -n "$service_name" ] && [ -d "$service_dir" ]; then
        # Supervisor unreachable: drop the definition so it cannot respawn,
        # then stop the owned PID directly instead of leaving it running.
        if ! perpctl -b "$perp_base" X "$service_name" >/dev/null 2>&1; then
            rm -rf "$service_dir" && [ ! -e "$service_dir" ] || return 1
        fi
    fi
    stop_owned || return 1
    [ -z "$service_name" ] || rm -rf "$service_dir"
}
case "$action" in
start|stop)
    exec 8>"${pidfile}.lock" || exit 1
    # A stop racing a start (subscription restart vs. UI) waits for it rather
    # than failing; start itself is bounded (~12s), so 20s is ample.
    count=0
    until flock -n 8; do
        [ "$action" = stop ] && [ "$count" -lt 20 ] || { echo ANYTLS_INSTANCE_BUSY >&2; exit 1; }
        sleep 1; count=$((count+1))
    done
    ;;
esac

case "$action" in
version)
    exec "$binary" --version
    ;;
run)
    # Called by perp; exec preserves PID and /proc start identity.
    printf '%s %s\n' "$$" "$(ticks "$$")" > "$pidfile" || exit 1
    set -- "$binary" -server "$server" --password-file "$passfile" -l "$listen" "$verify"
    [ -z "$sni" ] || set -- "$@" -sni "$sni"
    [ "$binary" = "$legacy_binary" ] || set -- "$@" --router-egress
    exec "$@"
    ;;
start)
    [ -x "$binary" ] && [ -s "$passfile" ] || exit 1
    case "$listen" in 127.0.0.1:[0-9]*) ;; *) exit 1;; esac
    case "$verify" in --verify|--insecure) ;; *) exit 1;; esac
    if owned && listening && [ "$instance_binary" = "$(readlink -f "$binary")" ]; then exit 0; fi
    if [ "$binary" != "$legacy_binary" ] && ! "$binary" --check-router-egress; then
        echo ANYTLS_EGRESS_MARK_UNAVAILABLE >&2
        exit 1
    fi
    [ ! -s "$pidfile" ] || stop_instance || exit 1
    # Fail on occupied port; bind success must later belong to our exact PID.
    port=${listen##*:}
    netstat -nl 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {used=1} END {exit !used}' && exit 1
    chmod 600 "$passfile" || exit 1
    if [ -n "$service_name" ]; then
        mkdir -p "$service_dir" || exit 1
        {
            printf '#!/bin/sh\n[ "$1" = start ] || exit 0\nexec env -i PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin '
            printf 'FSS_ANYTLS_PERP_BASE='; quote "$perp_base"; printf ' '
            printf 'FSS_ANYTLS_SERVICE_NAME='; quote "${FSS_ANYTLS_SERVICE_NAME:-}"; printf ' '
            printf 'FSS_ANYTLS_BINARY='; quote "$binary"; printf ' /bin/sh '
            quote "$(readlink -f "$0")"; printf ' run '
            for arg in "$pidfile" "$passfile" "$listen" "$server" "$sni" "$verify"; do quote "$arg"; printf ' '; done
            printf '\n'
        } > "$service_dir/rc.main" || exit 1
        chmod 755 "$service_dir/rc.main"
        chmod 1755 "$service_dir"
        (
            perpctl -b "$perp_base" A "$service_name" || exit 1
            for attempt in 1 2 3; do perpctl -b "$perp_base" u "$service_name" && exit 0; sleep 1; done
            exit 1
        ) >/dev/null 2>&1 || { stop_instance; echo ANYTLS_SUPERVISOR_START_FAILED >&2; exit 1; }
    else
        /bin/sh "$0" run "$pidfile" "$passfile" "$listen" "$server" "$sni" "$verify" >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 1000>&- &
    fi
    count=0
    while [ "$count" -lt 8 ]; do
        if owned && listening; then exit 0; fi
        sleep 1; count=$((count+1))
    done
    stop_instance >/dev/null 2>&1
    exit 1
    ;;
stop)
    stop_instance
    ;;
status)
    owned && listening || exit 1
    printf '%s\n' "$instance_pid"
    ;;
engine)
    owned && listening || exit 1
    "$instance_binary" --version
    ;;
*) exit 2;;
esac
