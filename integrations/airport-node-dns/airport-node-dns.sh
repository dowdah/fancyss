#!/bin/sh
# Airport bootstrap DNS. Kept independent from fancyss proxy/business DNS.
umask 077
PATH=${AIRPORT_TEST_PATH:-/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin}
export PATH LC_ALL=C
AIRDNS=${AIRPORT_AIRDNS:-/jffs/bin/airdns}
CONF=${AIRPORT_CONF:-/jffs/configs/airport-smartdns.conf}
PIDFILE=${AIRPORT_PIDFILE:-/var/run/airport-smartdns.pid}
RULE=${AIRPORT_RULE:-/jffs/configs/dnsmasq.d/airport-node-forward.conf}
SCOPE=${AIRPORT_SCOPE:-/jffs/configs/airport-node-dns.identities}
SUFFIXES=${AIRPORT_SUFFIXES:-/jffs/configs/airport-node-dns.suffixes}
NODE_TOOL=${AIRPORT_NODE_TOOL:-/koolshare/bin/node-tool}
JQ=${AIRPORT_JQ:-/koolshare/bin/jq}
PROC=${AIRPORT_PROC:-/proc}
LOCK=${AIRPORT_LOCK:-/tmp/airport-node-dns.lock}
STATUS=${AIRPORT_STATUS:-/tmp/airport-node-dns.state}
APPLIED="$STATUS.applied"
PENDING="$STATUS.pending"
DNSMASQ_CONF=${AIRPORT_DNSMASQ_CONF:-/etc/dnsmasq.conf}
DEFER=0
IDS=
RUNTIME_HELPER=${AIRPORT_RUNTIME_HELPER:-/koolshare/scripts/ss_runtime_nodes.sh}
ACTION=${1:-sync}
[ $# -eq 0 ] || shift
while [ $# -gt 0 ]; do
    case "$1" in
    --defer-reload) DEFER=1;;
    --ids-file) shift; IDS=$1; [ -r "$IDS" ] || exit 2;;
    *) exit 2;;
    esac
    shift
done
# Firmware BusyBox may omit mktemp. mkdir is atomic and rejects existing paths.
airport_tmpdir() {
    local prefix="$1" n=0 candidate=""
    while [ "$n" -lt 16 ]; do
        candidate="${prefix}.$$.${n}"
        if (umask 077; mkdir "$candidate") 2>/dev/null; then printf '%s\n' "$candidate"; return 0; fi
        n=$((n+1))
    done
    return 1
}
log() { logger -t airport-node-dns "$*"; printf 'airport-node-dns: %s\n' "$*" >&2; }
fail() { log "$1"; printf 'state=failed\nreason=%s\n' "$1" > "$STATUS"; exit 1; }
ticks() { sed 's/^.*) //' "$PROC/$1/stat" 2>/dev/null | awk '{print $20}'; }
owned() {
    read -r pid birth < "$PIDFILE" 2>/dev/null || return 1
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    [ "$(readlink "$PROC/$pid/exe" 2>/dev/null)" = "$AIRDNS" ] || return 1
    [ -z "$birth" ] || [ "$(ticks "$pid")" = "$birth" ] || return 1
    tr '\000' '\n' < "$PROC/$pid/cmdline" | grep -Fqx -- "$CONF" || return 1
}
ports_owned() {
    owned || return 1
    netstat -nlptu 2>/dev/null | awk -v owner="$pid/" '$4=="127.0.0.1:6053" && index($NF,owner)==1 {if($1 ~ /^tcp/)t=1;if($1 ~ /^udp/)u=1} END {exit !(t&&u)}'
}
ensure() {
    if ports_owned; then return 0; fi
    # No adoption by process name and no competing instance on an occupied port.
    netstat -nlupt 2>/dev/null | awk '$4 ~ /:6053$/ {found=1} END {exit !found}' && fail AIRPORT_DNS_PORT_OWNER
    [ -x "$AIRDNS" ] && [ -s "$CONF" ] || fail AIRPORT_DNS_INSTALL_MISSING
    "$AIRDNS" -f -p "${PIDFILE}.daemon" -c "$CONF" >> /tmp/airport-smartdns.stdout 2>&1 &
    pid=$!
    printf '%s %s\n' "$pid" "$(ticks "$pid")" > "$PIDFILE"
    count=0
    while [ "$count" -lt 6 ]; do ports_owned && return 0; sleep 1; count=$((count+1)); done
    owned && kill "$pid" 2>/dev/null
    fail AIRPORT_DNS_START_FAILED
}
release() {
    [ -z "${WORK:-}" ] || rm -rf "$WORK"
    [ -z "${NEW:-}" ] || rm -f "$NEW"
    [ -z "${RULE_WORK:-}" ] || rmdir "$RULE_WORK" 2>/dev/null
    if [ "${HELD:-0}" = 1 ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi
}
lock() {
    count=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        read -r owner birth < "$LOCK/pid" 2>/dev/null || owner=
        if [ -n "$owner" ] && [ -n "$birth" ] && [ "$(ticks "$owner")" != "$birth" ]; then
            rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null
        fi
        [ "$count" -lt 20 ] || fail AIRPORT_DNS_LOCK_BUSY
        sleep 1; count=$((count+1))
    done
    HELD=1
    printf '%s %s\n' "$$" "$(ticks "$$")" > "$LOCK/pid"
}
# Normalized node-tool list contains metadata only; never dump raw node records.
collect() {
    "$NODE_TOOL" list --format json --source subscribe --effective > "$WORK/sub.json" 2>/dev/null || fail AIRPORT_DNS_NODE_READ
    "$JQ" -e 'type=="array"' "$WORK/sub.json" >/dev/null || fail AIRPORT_DNS_NODE_FORMAT
    [ -s "$SCOPE" ] || fail AIRPORT_DNS_SCOPE_MISSING
    "$JQ" -Rsc 'split("\n")|map(select(length>0 and (startswith("#")|not)))' "$SCOPE" > "$WORK/scope.json" || fail AIRPORT_DNS_SCOPE_INVALID
    if [ -f "$SUFFIXES" ]; then cat "$SUFFIXES"; fi | "$JQ" -Rsc 'split("\n")|map(select(length>0 and (startswith("#")|not)))' > "$WORK/suffixes.json"
    filter='[.[] | select(. as $n | (($scope[0]|index($n.airport_identity)) != null) or any($suffixes[0][]; . as $d | ($n.server == $d or ($n.server|endswith("."+$d)))))]'
    "$JQ" --slurpfile scope "$WORK/scope.json" --slurpfile suffixes "$WORK/suffixes.json" "$filter" "$WORK/sub.json" > "$WORK/all.json" || fail AIRPORT_DNS_NODE_FORMAT
    : > "$WORK/active-ids"
    if [ "$(dbus get ss_basic_enable 2>/dev/null)" = 1 ]; then
        if [ -f "$RUNTIME_HELPER" ]; then
            . "$RUNTIME_HELPER"
            if ! fss_runtime_nodes_read > "$WORK/active-ids"; then
                if [ -z "$IDS" ]; then COLLECT_DEFERRED=1; return 0; fi
                : > "$WORK/active-ids"
            fi
        elif [ -z "$IDS" ]; then
            COLLECT_DEFERRED=1
            return 0
        fi
    fi
    [ -z "$IDS" ] || cat "$IDS" >> "$WORK/active-ids"
    ids=$(awk '/^[0-9]+$/ && !seen[$0]++ {printf "%s%s",sep,$0;sep=","}' "$WORK/active-ids")
    if [ -n "$ids" ]; then
        "$NODE_TOOL" list --format json --effective --ids "$ids" > "$WORK/targets.json" 2>/dev/null || fail AIRPORT_DNS_TARGET_READ
        "$JQ" --slurpfile scope "$WORK/scope.json" --slurpfile suffixes "$WORK/suffixes.json" "$filter" "$WORK/targets.json" > "$WORK/scoped-targets.json" || fail AIRPORT_DNS_TARGET_FORMAT
        "$JQ" -s 'add|unique_by(.id)' "$WORK/all.json" "$WORK/scoped-targets.json" > "$WORK/merged.json" || fail AIRPORT_DNS_TARGET_FORMAT
        mv "$WORK/merged.json" "$WORK/all.json"
    fi
    "$JQ" -r '.[].server//empty' "$WORK/all.json" | awk '
    {v=tolower($0);sub(/\.$/,"",v); if(v!~/^[0-9.]+$/ && v!~/:/ && v~/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/ && v~/\./)print v}' | sort -u > "$WORK/domains"
}
dnsmasq_listener() {
    netstat -nlpu 2>/dev/null | awk '$4 ~ /:53$/ && $NF ~ /^[0-9]+\/dnsmasq$/ {split($NF,a,"/"); print a[1]; exit}'
}
reload_dnsmasq() {
    local before after pid attempts=0
    pid=$(dnsmasq_listener)
    before="$pid:$(ticks "$pid")"
    dnsmasq --test >/dev/null 2>&1 || return 1
    service restart_dnsmasq >/dev/null 2>&1 || return 1
    while [ "$attempts" -lt 10 ]; do
        pid=$(dnsmasq_listener)
        after=$(ticks "$pid")
        if [ -n "$pid" ] && [ -n "$after" ] && [ "$pid:$after" != "$before" ]; then
            awk -v dir="${RULE%/*}" -v file="$RULE" '
                $0 == "conf-file=" file { found=1 }
                /^conf-dir=/ { sub(/^conf-dir=/,""); sub(/,.*/,""); sub(/\/$/,""); if ($0==dir) found=1 }
                END { exit !found }
            ' "$DNSMASQ_CONF"
            return
        fi
        sleep 1
        attempts=$((attempts+1))
    done
    return 1
}
sync_rules() {
    collect
    [ "${COLLECT_DEFERRED:-0}" != 1 ] || return 0
    mkdir -p "${RULE%/*}" || fail AIRPORT_DNS_RULE_DIR
    RULE_WORK=$(airport_tmpdir "${RULE%/*}/.airport-node-forward") || fail AIRPORT_DNS_TEMP
    NEW="$RULE_WORK/rules.conf"
    {
        printf '# Managed by airport-node-dns.sh (fancyss native integration)\n'
        while IFS= read -r domain; do printf 'server=/%s/127.0.0.1#6053\n' "$domain"; done < "$WORK/domains"
    } > "$NEW" || fail AIRPORT_DNS_RULE_WRITE
    sed -n '/^server=/p' "$RULE" 2>/dev/null > "$WORK/old"
    sed -n '/^server=/p' "$NEW" > "$WORK/next"
    CHANGED=0
    if [ ! -f "$RULE" ] || ! cmp -s "$WORK/old" "$WORK/next"; then
        CHANGED=1
        [ ! -f "$RULE" ] || cp "$RULE" "$WORK/old.conf" || fail AIRPORT_DNS_RULE_BACKUP
    fi
    if [ "$CHANGED" = 0 ] && [ ! -e "$PENDING" ] && cmp -s "$RULE" "$APPLIED"; then
        return 0
    fi
    : > "$PENDING" || fail AIRPORT_DNS_PENDING_WRITE
    if [ "$CHANGED" = 1 ]; then
        chmod 644 "$NEW" && mv -f "$NEW" "$RULE" || fail AIRPORT_DNS_RULE_COMMIT
    fi
    [ "$DEFER" = 0 ] || return 0
    if ! reload_dnsmasq; then
        local backup="$APPLIED"
        [ -f "$backup" ] || backup="$WORK/old.conf"
        if [ -f "$backup" ]; then
            cp "$backup" "$NEW" && chmod 644 "$NEW" && mv -f "$NEW" "$RULE" &&
                reload_dnsmasq || log AIRPORT_DNS_RESTORE_FAILED
        elif [ "$CHANGED" = 1 ]; then
            rm -f "$RULE" && reload_dnsmasq || log AIRPORT_DNS_RESTORE_FAILED
        fi
        fail AIRPORT_DNS_RELOAD_FAILED
    fi
    cp "$RULE" "$APPLIED.new" && mv -f "$APPLIED.new" "$APPLIED" &&
        rm -f "$PENDING" || fail AIRPORT_DNS_APPLIED_WRITE
}
# A single 2s probe turns one lost DoH packet into a refused start; retry briefly.
resolve() {
    tries=0
    while [ "$tries" -lt 3 ]; do
        answer=$(dnsclient -46 -p "$2" -t 2 -i 1 @127.0.0.1 "$1" 2>/dev/null | head -1)
        [ -z "$answer" ] || return 0
        tries=$((tries+1))
        [ "$tries" -ge 3 ] || sleep 1
    done
    return 1
}
check_targets() {
    [ -n "$IDS" ] || return 0
    [ -f "$WORK/scoped-targets.json" ] || return 0
    # Retain old owners' forwarding, but only probe the requested new targets.
    # An unavailable old node must not prevent switching to a healthy one.
    "$JQ" -Rsc 'split("\n")|map(select(test("^[0-9]+$")))' "$IDS" > "$WORK/check-ids.json" || fail AIRPORT_DNS_TARGET_FORMAT
    "$JQ" -r --slurpfile ids "$WORK/check-ids.json" \
        '.[]|select((.id|tostring) as $id|$ids[0]|index($id)!=null)|.server//empty' \
        "$WORK/scoped-targets.json" | sort -u > "$WORK/check-domains"
    while IFS= read -r domain; do
        case "$domain" in ''|*[!0-9.]* ) ;; *) continue;; esac
        case "$domain" in *:*) continue;; esac
        grep -Fqx "server=/$domain/127.0.0.1#6053" "$RULE" || fail AIRPORT_DNS_RULE_MISSING
        # A successful cache answer is usable, but not reported as fresh DoH proof.
        resolve "$domain" 6053 || fail AIRPORT_DNS_NO_ANSWER
        if [ "$DEFER" = 0 ]; then
            resolve "$domain" 53 || fail AIRPORT_DNS_SYSTEM_NO_ANSWER
        fi
    done < "$WORK/check-domains"
}
trap release EXIT
trap 'exit 1' HUP INT TERM
lock
WORK=$(airport_tmpdir /tmp/airport-node-dns) || fail AIRPORT_DNS_TEMP
case "$ACTION" in
ensure) ensure;;
sync|check)
    ensure
    sync_rules
    check_targets
    ;;
*) exit 2;;
esac
state=ready
[ ! -e "$PENDING" ] && [ "${COLLECT_DEFERRED:-0}" != 1 ] || state=deferred
printf 'state=%s\nanswer_freshness=unknown\nrules_changed=%s\n' "$state" "${CHANGED:-0}" > "$STATUS"
