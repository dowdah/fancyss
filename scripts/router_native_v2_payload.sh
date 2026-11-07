#!/bin/sh
# Shared payload contract for prepare/apply. The expected archive digest is
# supplied independently of the archive and its embedded manifest.
native_paths() {
    case "${1:-legacy}" in
    legacy) ROOT=/jffs/configs/fss-current-rollback; STAGE=/tmp/fancyss-native-v2-deploy ;;
    vowifi.2) ROOT=/jffs/configs/fss-current-rollback; STAGE=/tmp/fss-anytls-hardening-deploy ;;
    hardening.1) ROOT=/jffs/configs/fss-current-rollback; STAGE=/tmp/fss-anytls-hardening2-deploy ;;
    hardening.2) ROOT=/jffs/configs/fss-current-rollback; STAGE=/tmp/fss-anytls-hardening3-deploy ;;
    *) return 1 ;;
    esac
    VERIFIED="$STAGE/verified"
    META=shadowsocks/ss/fork-build.json
}

native_check_paths() {
    LC_ALL=C awk '
        $0=="jffs/scripts/airport-node-dns.sh" { if(seen[$0]++) bad=1; next }
        !/^shadowsocks\/(bin|scripts|ss|webs|res|init[.]d)\/[A-Za-z0-9_][A-Za-z0-9_.-]*$/ { bad=1 }
        seen[$0]++ { bad=1 }
        END { exit (NR == 0 || bad) }
    ' "$1"
}

native_target_path() {
    case "$1" in
    shadowsocks/*) printf 'koolshare/%s\n' "${1#shadowsocks/}" ;;
    jffs/scripts/airport-node-dns.sh) printf '%s\n' "$1" ;;
    *) return 1 ;;
    esac
}

# Retire only this project's known release snapshots after checking every
# candidate for an unfinished transaction. The optional prefix is for fixtures.
native_rotate_snapshots() (
    set -e
    prefix="${1:-}"
    : > "$STAGE/retired-snapshots"
    : > "$STAGE/active-guard-paths"
    for process in "$prefix"/proc/[0-9]*/cmdline; do
        [ -r "$process" ] || continue
        tr '\000' '\n' < "$process" 2>/dev/null |
            grep -E '^/(jffs/configs|data)/fss[^/]*/(guard|release)[.]sh$' >> "$STAGE/active-guard-paths" || true
    done
    for relative in \
        jffs/configs/fss-current-rollback \
        jffs/configs/fss-anytls-hardening-release \
        jffs/configs/fss-native-v1 jffs/configs/fss-native-v2 \
        jffs/configs/fss-native-v2-attempt1 jffs/configs/fss-native-v2-release-20261029 \
        jffs/configs/fss-vowifi-lan-release jffs/configs/fss-vowifi-release \
        data/fss-compat-release-20261030T1430 data/fss-egress-release-20261029T2230 \
        data/fss-native-cancel1-20261029T2009 data/fss-profile-20261029T2100 \
        data/fss-profile-20261029T2135 data/fss-reliab1-release-20261103 \
        data/fss-reliab2-release-20261104 data/fss-reliab3-release-20261104; do
        dir="$prefix/$relative"
        [ -d "$dir" ] || continue
        [ ! -L "$dir" ] || exit 1
        [ -f "$dir/guard.sh" ] || [ -f "$dir/release.sh" ] || [ -f "$dir/baseline.tgz" ] || exit 1
        [ ! -f "$dir/pending" ] && [ ! -f "$dir/rolling-back" ] || { echo unfinished_release >&2; exit 1; }
        if grep -Fxq "/$relative/guard.sh" "$STAGE/active-guard-paths" ||
            grep -Fxq "/$relative/release.sh" "$STAGE/active-guard-paths"; then
            echo active_release_guard >&2
            exit 1
        fi
        printf '%s\n' "$relative" >> "$STAGE/retired-snapshots"
    done
    while IFS= read -r relative; do
        for hook in "$prefix"/koolshare/init.d/S95fss-*-rollback.sh "$prefix"/koolshare/init.d/S96fss-native-guard.sh; do
            [ -f "$hook" ] || continue
            if grep -Fq "/$relative/" "$hook"; then rm -f "$hook"; fi
        done
        rm -rf "$prefix/$relative"
    done < "$STAGE/retired-snapshots"
)

native_hash() {
    local line
    line=$(sha256sum "$1") || return 1
    printf '%s\n' "${line%% *}"
}

native_stage_payload() (
    set -e
    expected="$1"
    printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$'
    mkdir -m 700 "$VERIFIED"
    trap 'rm -rf "$VERIFIED"' EXIT
    cd "$VERIFIED"
    cp "$STAGE/payload.tar.gz" archive.tgz
    [ "$(native_hash archive.tgz)" = "$expected" ]
    tar -tzf archive.tgz > members
    native_check_paths members
    tar -tvzf archive.tgz > types
    awk 'substr($1,1,1)!="-" { bad=1 } END { exit bad }' types
    tar -xzf archive.tgz
    jq -e '
        .files | type=="object" and length>0 and
        all(to_entries[]; .value | type=="string" and test("^[0-9a-f]{64}$"))
    ' "$META" >/dev/null
    jq -r '.files | keys[]' "$META" > declared
    jq --stream -r '
        select(length==2 and (.[0]|length)==2 and .[0][0]=="files") | .[0][1]
    ' "$META" > streamed
    LC_ALL=C sort streamed -o streamed
    cmp -s declared streamed
    printf '%s\n' "$META" >> declared
    native_check_paths declared
    LC_ALL=C sort declared > files
    LC_ALL=C sort members -o members
    cmp -s files members
    jq -r '.files | to_entries[] | "\(.value)  \(.key)"' "$META" > hashes
    sha256sum "$META" >> hashes
    sha256sum -c hashes
    rm -f archive.tgz members types declared streamed
    trap - EXIT
)

native_check_live_baseline() {
    local release="$1" manifest="$2" live="$3"
    if [ "$release" = legacy ]; then
        [ "$(jq -r .build "$live/ss/fork-build.json")" = 3.5.30-anytls-native.1 ] &&
            [ "$(jq -r .build "$manifest")" = 3.5.30-anytls-native.2 ] &&
            [ "$(dbus get fss_node_current)" = 654 ]
        return
    fi
    if [ "$release" = hardening.1 ] || [ "$release" = hardening.2 ]; then
        local prefix=3.5.30-anytls-native.2-compat.1-reliab.3-vowifi.2 next=hardening.2
        [ "$release" != hardening.2 ] || next=hardening.3
        [ "$(jq -r .build "$live/ss/fork-build.json")" = "$prefix-$release" ] || return 1
        [ "$(jq -r .build "$manifest")" = "$prefix-$next" ] || return 1
        jq -r '.base_files|keys[]|"shadowsocks/"+.' "$manifest" > "$VERIFIED/base-paths" || return 1
        native_check_paths "$VERIFIED/base-paths" || return 1
        jq -e '.base_files|length>0 and all(to_entries[];.value|test("^[0-9a-f]{64}$"))' "$manifest" >/dev/null || return 1
        jq -r '.base_files|to_entries[]|"\(.value)  \(.key)"' "$manifest" > "$VERIFIED/base.sha256" || return 1
        (cd "$live" && sha256sum -c "$VERIFIED/base.sha256") || return 1
        jq -r '.base_absent[]|"shadowsocks/"+.' "$manifest" > "$VERIFIED/absent-paths" || return 1
        if [ -s "$VERIFIED/absent-paths" ]; then
            native_check_paths "$VERIFIED/absent-paths" || return 1
        fi
        while IFS= read -r absent; do
            [ ! -e "$live/${absent#shadowsocks/}" ] && [ ! -L "$live/${absent#shadowsocks/}" ] || return 1
        done < "$VERIFIED/absent-paths"
        expected=$(jq -er '.base_airport_script_sha256|select(test("^[0-9a-f]{64}$"))' "$manifest") || return 1
        [ "$(native_hash /jffs/scripts/airport-node-dns.sh)" = "$expected" ]
        return
    fi
    [ "$(jq -r .build "$live/ss/fork-build.json")" = 3.5.30-anytls-native.2-compat.1-reliab.3-vowifi.2 ] || return 1
    [ "$(jq -r .build "$manifest")" = 3.5.30-anytls-native.2-compat.1-reliab.3-vowifi.2-hardening.1 ] || return 1
    jq -e '
        .base_files | keys == ["bin/fss-anytls-client","scripts/ss_anytls_helper.sh","ss/fork-build.json","ss/ssconfig.sh"]
    ' "$manifest" >/dev/null || return 1
    jq -e '.base_files | all(to_entries[]; .value | type=="string" and test("^[0-9a-f]{64}$"))' "$manifest" >/dev/null || return 1
    jq -r '.base_files | to_entries[] | "\(.value)  \(.key)"' "$manifest" > "$VERIFIED/base.sha256" || return 1
    (cd "$live" && sha256sum -c "$VERIFIED/base.sha256")
}

native_verify_prepared() (
    set -e
    cd "$VERIFIED"
    native_check_paths "$ROOT/install-files"
    roots=shadowsocks
    [ ! -d jffs ] || roots="$roots jffs"
    find $roots ! -type d ! -type f -print > live-members
    [ ! -s live-members ]
    find $roots -type f -print > live-members
    LC_ALL=C sort live-members -o live-members
    cmp -s "$ROOT/install-files" live-members
    awk '{print $2}' "$ROOT/install.sha256" | LC_ALL=C sort > hashed-members
    cmp -s "$ROOT/install-files" hashed-members
    sha256sum -c "$ROOT/install.sha256"
    while IFS= read -r item; do
        path=$(native_target_path "$item")
        if grep -Fxq "$path" "$ROOT/present"; then
            if grep -Fxq "$path" "$ROOT/absent"; then exit 1; fi
        else
            grep -Fxq "$path" "$ROOT/absent"
        fi
    done < "$ROOT/install-files"
)

native_publish() (
    set -e
    live="$1"
    temp=
    trap '[ -z "$temp" ] || rm -f "$temp"' EXIT
    while read -r expected item; do
        case "$item" in
        shadowsocks/*) target="$live/${item#shadowsocks/}" ;;
        jffs/scripts/airport-node-dns.sh) target="${2:-/jffs}/scripts/airport-node-dns.sh" ;;
        *) exit 1 ;;
        esac
        next="$target.native-new.$$"
        [ ! -L "$target" ] && [ ! -L "${target%/*}" ] && [ ! -e "$next" ] && [ ! -L "$next" ] || exit 1
        mkdir -p "${target%/*}"
        temp="$next"
        cp "$VERIFIED/$item" "$temp"
        if [ "$(native_hash "$temp")" != "$expected" ]; then
            echo payload_changed_during_apply >&2
            exit 1
        fi
        case "$target" in *.sh|*/fss-anytls-client) chmod 755 "$temp";; *) chmod 644 "$temp";; esac
        mv "$temp" "$target"
        temp=
    done < "$ROOT/install.sha256"
)
