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
binary=${FSS_ANYTLS_BINARY:-/koolshare/bin/fss-anytls-client}
proc=${FSS_PROC_ROOT:-/proc}

ticks() { sed 's/^.*) //' "$proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
owned() {
    read -r instance_pid instance_ticks 2>/dev/null < "$pidfile" || return 1
    case "$instance_pid:$instance_ticks" in *[!0-9:]*|:*|*:) return 1;; esac
    [ -n "$instance_ticks" ] && [ "$(ticks "$instance_pid")" = "$instance_ticks" ] || return 1
    instance_binary=$(readlink "$proc/$instance_pid/exe" 2>/dev/null)
    case "$instance_binary" in
        /koolshare/bin/anytls-zig|/koolshare/bin/fss-anytls-client) ;;
        *) [ "$instance_binary" = "$(readlink -f "$binary")" ] || return 1;;
    esac
    tr '\000' '\n' < "$proc/$instance_pid/cmdline" | grep -Fqx -- "$passfile" || return 1
    tr '\000' '\n' < "$proc/$instance_pid/cmdline" | grep -Fqx -- "$listen" || return 1
}
listening() {
    netstat -nlpt 2>/dev/null | awk -v address="$listen" -v owner="$instance_pid/" '$4==address && index($NF,owner)==1 {ok=1} END {exit !ok}'
}
stop_owned() {
    if owned; then
        kill "$instance_pid" 2>/dev/null || return 1
        count=0
        while owned && [ "$count" -lt 5 ]; do sleep 1; count=$((count+1)); done
        if owned; then kill -9 "$instance_pid" 2>/dev/null || return 1; fi
    fi
    rm -f "$pidfile"
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
service_dir="/koolshare/perp/$service_name"

stop_instance() {
    if [ -n "$service_name" ] && [ -d "$service_dir" ]; then
        perpctl -b /koolshare/perp X "$service_name" >/dev/null 2>&1 || return 1
    fi
    stop_owned || return 1
    [ -z "$service_name" ] || rm -rf "$service_dir"
}
case "$action" in
start|stop)
    exec 8>"${pidfile}.lock" || exit 1
    flock -n 8 || { echo ANYTLS_INSTANCE_BUSY >&2; exit 1; }
    ;;
esac

case "$action" in
run)
    # Called by perp; exec preserves PID and /proc start identity.
    printf '%s %s\n' "$$" "$(ticks "$$")" > "$pidfile" || exit 1
    set -- "$binary" -server "$server" --password-file "$passfile" -l "$listen" "$verify"
    [ -z "$sni" ] || set -- "$@" -sni "$sni"
    exec "$@"
    ;;
start)
    [ -x "$binary" ] && [ -s "$passfile" ] || exit 1
    case "$listen" in 127.0.0.1:[0-9]*) ;; *) exit 1;; esac
    case "$verify" in --verify|--insecure) ;; *) exit 1;; esac
    if owned && listening && [ "$instance_binary" = "$(readlink -f "$binary")" ]; then exit 0; fi
    [ ! -s "$pidfile" ] || stop_instance || exit 1
    # Fail on occupied port; bind success must later belong to our exact PID.
    port=${listen##*:}
    netstat -nl 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {used=1} END {exit !used}' && exit 1
    chmod 600 "$passfile" || exit 1
    if [ -n "$service_name" ]; then
        mkdir -p "$service_dir" || exit 1
        {
            printf '#!/bin/sh\n[ "$1" = start ] || exit 0\nexec env -i PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/sh '
            quote "$(readlink -f "$0")"; printf ' run '
            for arg in "$pidfile" "$passfile" "$listen" "$server" "$sni" "$verify"; do quote "$arg"; printf ' '; done
            printf '\n'
        } > "$service_dir/rc.main" || exit 1
        chmod 755 "$service_dir/rc.main"
        chmod 1755 "$service_dir"
        (
            perpctl -b /koolshare/perp A "$service_name" || exit 1
            for attempt in 1 2 3; do perpctl -b /koolshare/perp u "$service_name" && exit 0; sleep 1; done
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
