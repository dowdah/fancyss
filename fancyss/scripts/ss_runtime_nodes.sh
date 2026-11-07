#!/bin/sh
# Runtime identities contain node IDs and process ownership only.
FSS_ACTIVE_NODES_FILE=${FSS_ACTIVE_NODES_FILE:-/tmp/fancyss_active_nodes}
FSS_RUNTIME_PROC=${FSS_RUNTIME_PROC:-/proc}

fss_runtime_ticks() {
    sed 's/^.*) //' "$FSS_RUNTIME_PROC/$1/stat" 2>/dev/null | awk '{print $20}'
}

fss_runtime_nodes_mark() {
    local state="$1" temp="$FSS_ACTIVE_NODES_FILE.new.$$"
    (umask 077; printf '%s\n' "$state" > "$temp") &&
        mv -f "$temp" "$FSS_ACTIVE_NODES_FILE"
}

fss_runtime_nodes_publish() {
    local pid="$1" ids="$2" tick binary temp="$FSS_ACTIVE_NODES_FILE.new.$$"
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    tick=$(fss_runtime_ticks "$pid") || return 1
    binary=$(readlink "$FSS_RUNTIME_PROC/$pid/exe") || return 1
    [ -n "$tick" ] && [ -n "$binary" ] || return 1
    (umask 077
        printf 'owner %s %s %s\n' "$pid" "$tick" "$binary" > "$temp"
        awk '/^[0-9]+$/ && !seen[$0]++ {print "node " $0}' "$ids" >> "$temp"
    ) && mv -f "$temp" "$FSS_ACTIVE_NODES_FILE"
}

fss_runtime_nodes_read() {
    local state pid tick binary actual
    read -r state pid tick binary < "$FSS_ACTIVE_NODES_FILE" || return 1
    [ "$state" != stopped ] || return 0
    [ "$state" = owner ] || return 1
    case "$pid:$tick" in *[!0-9:]*|:*|*:) return 1;; esac
    actual=$(fss_runtime_ticks "$pid") || return 1
    [ "$tick" = "$actual" ] &&
        [ "$binary" = "$(readlink "$FSS_RUNTIME_PROC/$pid/exe" 2>/dev/null)" ] || return 1
    awk '$1=="node" && $2~/^[0-9]+$/ && NF==2 {print $2}' "$FSS_ACTIVE_NODES_FILE"
}
