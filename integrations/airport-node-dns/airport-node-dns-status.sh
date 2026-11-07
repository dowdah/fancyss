#!/bin/sh

PATH=/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export LC_ALL=C

AIRDNS="/jffs/bin/airdns"
AIRDNS_CONF="/jffs/configs/airport-smartdns.conf"
AIRDNS_PID="/var/run/airport-smartdns.pid"

NODE_TOOL="/koolshare/bin/node-tool"
JQ="/koolshare/bin/jq"
DNSCLIENT="/koolshare/bin/dnsclient"

RULE_FILE="/jffs/configs/dnsmasq.d/airport-node-forward.conf"

MAIN_SCRIPT="/jffs/scripts/airport-node-dns.sh"
BOOT_SCRIPT="/jffs/scripts/airport-node-dns-boot.sh"
SERVICES_START="/jffs/scripts/services-start"

TMP_EXPECTED="/tmp/airport-status-expected.$$"
TMP_ACTUAL="/tmp/airport-status-actual.$$"
TMP_CRON="/tmp/airport-status-cron.$$"

FAIL=0
WARN=0

cleanup()
{
    rm -f \
        "$TMP_EXPECTED" \
        "$TMP_ACTUAL" \
        "$TMP_CRON"
}

trap cleanup 0 1 2 15

ok()
{
    printf '[ OK ] %s\n' "$*"
}

warn()
{
    printf '[WARN] %s\n' "$*"
    WARN=$((WARN + 1))
}

fail()
{
    printf '[FAIL] %s\n' "$*"
    FAIL=$((FAIL + 1))
}

section()
{
    printf '\n========== %s ==========\n' "$*"
}

read_system_log()
{
    if [ -x /usr/sbin/logread ]; then
        /usr/sbin/logread 2>/dev/null
        return
    fi

    if [ -x /sbin/logread ]; then
        /sbin/logread 2>/dev/null
        return
    fi

    if [ -x /usr/bin/logread ]; then
        /usr/bin/logread 2>/dev/null
        return
    fi

    if [ -x /bin/logread ]; then
        /bin/logread 2>/dev/null
        return
    fi

    if [ -f /tmp/syslog.log ]; then
        cat /tmp/syslog.log
        return
    fi

    if [ -f /var/log/messages ]; then
        cat /var/log/messages
        return
    fi
}

TEST_DOMAIN="$1"


section "文件状态"

if [ -x "$AIRDNS" ]; then
    ok "airdns二进制存在：$AIRDNS"
else
    fail "airdns二进制不存在：$AIRDNS"
fi

if [ -f "$AIRDNS_CONF" ]; then
    ok "airdns配置存在：$AIRDNS_CONF"
else
    fail "airdns配置不存在：$AIRDNS_CONF"
fi

if [ -x "$MAIN_SCRIPT" ]; then
    ok "管理脚本存在"
else
    fail "管理脚本不存在：$MAIN_SCRIPT"
fi

if [ -x "$BOOT_SCRIPT" ]; then
    ok "开机脚本存在"
else
    warn "开机脚本不存在：$BOOT_SCRIPT"
fi

if [ -f "$RULE_FILE" ]; then
    ok "dnsmasq节点规则存在"
else
    fail "dnsmasq节点规则不存在：$RULE_FILE"
fi


section "airdns进程"

PID=""

if [ -f "$AIRDNS_PID" ]; then
    PID="$(awk '{print $1}' "$AIRDNS_PID" 2>/dev/null)"

    if [ -n "$PID" ]; then
        ok "PID文件存在，记录PID=$PID"
    else
        warn "PID文件存在但内容为空"
    fi
else
    warn "PID文件不存在"
fi

if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    PROC_NAME="$(cat "/proc/$PID/comm" 2>/dev/null)"

    if [ "$PROC_NAME" = "airdns" ]; then
        ok "PID $PID 对应进程名为airdns"
    else
        fail "PID $PID 当前对应进程为：$PROC_NAME"
    fi
elif [ -n "$PID" ]; then
    fail "PID文件记录的进程 $PID 已不存在"
fi

REAL_PIDS="$(pidof airdns 2>/dev/null)"

if [ -n "$REAL_PIDS" ]; then
    ok "检测到airdns进程：$REAL_PIDS"
else
    fail "没有检测到airdns进程"
fi

AIRDNS_COUNT="$(printf '%s\n' "$REAL_PIDS" | awk '{print NF}')"

if [ -n "$REAL_PIDS" ] && [ "$AIRDNS_COUNT" -gt 1 ]; then
    warn "检测到多个airdns进程，数量=$AIRDNS_COUNT"
fi


section "监听端口"

PORT_LINE="$(
    netstat -nl 2>/dev/null |
    grep '127[.]0[.]0[.]1:6053' |
    head -n 1
)"

if [ -n "$PORT_LINE" ]; then
    ok "127.0.0.1:6053正在监听"
    printf '       %s\n' "$PORT_LINE"
else
    fail "127.0.0.1:6053没有监听"
fi


section "dnsmasq"

DNSMASQ_PIDS="$(pidof dnsmasq 2>/dev/null)"

if [ -n "$DNSMASQ_PIDS" ]; then
    ok "dnsmasq正在运行：$DNSMASQ_PIDS"
else
    fail "dnsmasq没有运行"
fi

if [ -f /etc/dnsmasq.conf ]; then

    if grep -q \
        '^[[:space:]]*conf-dir=/jffs/configs/dnsmasq.d' \
        /etc/dnsmasq.conf 2>/dev/null; then

        ok "dnsmasq已加载/jffs/configs/dnsmasq.d"
    else
        warn "/etc/dnsmasq.conf中未发现dnsmasq.d加载配置"
    fi
else
    warn "未找到/etc/dnsmasq.conf"
fi


section "cron定任务"

CRU=""
CRON_FOUND=0

for CANDIDATE in \
    /usr/sbin/cru \
    /sbin/cru \
    /usr/bin/cru \
    /bin/cru \
    /koolshare/bin/cru
do
    if [ -x "$CANDIDATE" ]; then
        CRU="$CANDIDATE"
        break
    fi
done

if [ -n "$CRU" ]; then

    "$CRU" l 2>/dev/null >"$TMP_CRON"

    CRON_LINE="$(
        grep 'airport_node_dns' "$TMP_CRON" |
        head -n 1
    )"

    if [ -z "$CRON_LINE" ]; then
        CRON_LINE="$(
            grep 'airport-node-dns[.]sh' "$TMP_CRON" |
            head -n 1
        )"
    fi

    if [ -n "$CRON_LINE" ]; then
        ok "定时任务已注册"
        printf '       cru路径：%s\n' "$CRU"
        printf '       %s\n' "$CRON_LINE"
        CRON_FOUND=1
    fi
fi


if [ "$CRON_FOUND" -eq 0 ]; then

    for CRON_FILE in \
        /var/spool/cron/crontabs/* \
        /var/spool/cron/* \
        /tmp/cron.d/* \
        /etc/crontabs/* \
        /etc/cron.d/*
    do
        [ -f "$CRON_FILE" ] || continue

        CRON_LINE="$(
            grep 'airport-node-dns[.]sh' \
                "$CRON_FILE" 2>/dev/null |
            head -n 1
        )"

        if [ -n "$CRON_LINE" ]; then
            ok "定时任务存在于cron配置文件"
            printf '       文件：%s\n' "$CRON_FILE"
            printf '       %s\n' "$CRON_LINE"
            CRON_FOUND=1
            break
        fi
    done
fi


CROND_PIDS="$(pidof crond 2>/dev/null)"

if [ -n "$CROND_PIDS" ]; then
    ok "crond后台服务正在运行：$CROND_PIDS"
else
    warn "没有通过pidof检测到crond进程"
fi


LAST_CRON_LOG="$(
    read_system_log |
    grep 'airport-node-dns' |
    grep '规则' |
    tail -n 1
)"

if [ -n "$LAST_CRON_LOG" ]; then

    ok "检测到airport-node-dns最近实际执行记录"
    printf '       %s\n' "$LAST_CRON_LOG"

    if [ "$CRON_FOUND" -eq 0 ]; then
        ok "虽然无法直接枚举cron任务，但定时执行功能实际正常"
        CRON_FOUND=1
    fi
fi

if [ "$CRON_FOUND" -eq 0 ]; then
    fail "没有找到定时任务，也没有检测到近执行记录"
fi


section "开机启动"

if [ -f "$SERVICES_START" ]; then

    if grep -q \
        'airport-node-dns-boot[.]sh' \
        "$SERVICES_START" 2>/dev/null; then

        ok "services-start已包含机场DNS启动项"
    else
        warn "services-start中没有找到airport-node-dns-boot.sh"
    fi
else
    warn "/jffs/scripts/services-start不存在"
fi


section "订阅节点与dnsmasq规则"

EXPECTED_COUNT=""
ACTUAL_COUNT=""

if [ -x "$NODE_TOOL" ] && [ -x "$JQ" ]; then

    "$NODE_TOOL" list \
        --format json \
        --source subscribe \
        --effective 2>/dev/null |
    "$JQ" -r '.[] | (.server // empty)' 2>/dev/null |
    awk '
    {
        value = $0

        gsub(/\r/, "", value)
        gsub(/^[ \t]+/, "", value)
        gsub(/[ \t]+$/, "", value)
        sub(/\.$/, "", value)

        value = tolower(value)

        if (value == "")
            next

        if (value ~ /:/)
            next

        if (value ~ /^([0-9]+\.){3}[0-9]+$/)
            next

        if (value !~ /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/)
            next

        if (value !~ /\./)
            next

        print value
    }
    ' |
    sort -u >"$TMP_EXPECTED"

    EXPECTED_COUNT="$(
        wc -l <"$TMP_EXPECTED" |
        tr -d ' '
    )"

    ok "当前有效订阅中发现 $EXPECTED_COUNT 个域名节点"
else
    warn "node-tool或jq不存在，无法读取当前订阅节点"
fi


if [ -f "$RULE_FILE" ]; then

    sed -n \
        's|^[[:space:]]*server=/\([^/]*\)/127[.]0[.]0[.]1#6053[[:space:]]*$|\1|p' \
        "$RULE_FILE" |
    tr 'A-Z' 'a-z' |
    sort -u >"$TMP_ACTUAL"

    ACTUAL_COUNT="$(
        wc -l <"$TMP_ACTUAL" |
        tr -d ' '
    )"

    ok "dnsmasq规则中发现 $ACTUAL_COUNT 个节点域名"
fi


if [ -n "$EXPECTED_COUNT" ] &&
   [ -n "$ACTUAL_COUNT" ]; then

    if cmp -s "$TMP_EXPECTED" "$TMP_ACTUAL"; then

        ok "订阅节点域名与dnsmasq规则完全一致"

    else

        warn "订阅节点域名与dnsmasq规则不一致"

        printf '\n只存在订阅中的域名：\n'

        comm -23 \
            "$TMP_EXPECTED" \
            "$TMP_ACTUAL" |
        head -n 20

        printf '\n只存在于dnsmasq规则中的域名：\n'

        comm -13 \
            "$TMP_EXPECTED" \
            "$TMP_ACTUAL" |
        head -n 20
    fi
fi


if [ -z "$TEST_DOMAIN" ]; then

    if [ -s "$TMP_ACTUAL" ]; then
        TEST_DOMAIN="$(head -n 1 "$TMP_ACTUAL")"

    elif [ -s "$TMP_EXPECTED" ]; then
        TEST_DOMAIN="$(head -n 1 "$TMP_EXPECTED")"
    fi
fi


section "实际DNS解析测试"

if [ -z "$TEST_DOMAIN" ]; then

    warn "没有可用于测试的节点域名"

else

    printf '测试域名：%s\n' "$TEST_DOMAIN"


    #
    # 1. 直接查询airdns
    #
    if [ -x "$DNSCLIENT" ]; then

        AIRDNS_OUTPUT="$(
            "$DNSCLIENT" \
                -46 \
                -p 6053 \
                -t 5 \
                -i 1 \
                @127.0.0.1 \
                "$TEST_DOMAIN" 2>/dev/null
        )"

        AIRDNS_RESULT="$(
            printf '%s\n' "$AIRDNS_OUTPUT" |
            grep -E '^[0-9][0-9.]*$' |
            head -n 1
        )"

        if [ -n "$AIRDNS_RESULT" ]; then
            ok "airdns直接解析成功：$TEST_DOMAIN -> $AIRDNS_RESULT"
        else
            fail "airdns直接解析失败：$TEST_DOMAIN"

            if [ -n "$AIRDNS_OUTPUT" ]; then
                printf '%s\n' "$AIRDNS_OUTPUT" |
                sed 's/^/       /'
            fi
        fi

    else
        warn "dnsclient不存在，无法直接测试airdns"
    fi


    #
    # 2. 通过系统dnsmasq查询
    #
    NSLOOKUP_OUTPUT="$(
        nslookup "$TEST_DOMAIN" 127.0.0.1 2>&1
    )"

    #
    # BusyBox兼容写法。
    #
    # nslookup通常输出：
    #
    # Address 1: 127.0.0.1 localhost.localdomain
    # Address 1: 31.25.88.214
    #
    # 提取所有IPv4，然后排除DNS服务器自身的127.0.0.1。
    #
    DNSMASQ_RESULT="$(
        printf '%s\n' "$NSLOOKUP_OUTPUT" |
        sed -n \
            's/^[[:space:]]*Address [0-9][0-9]*:[[:space:]]*\([0-9][0-9.]*\).*$/\1/p' |
        grep -v '^127[.]0[.]0[.]1$' |
        head -n 1
    )"

    if [ -n "$DNSMASQ_RESULT" ]; then

        ok "dnsmasq完整链路解析成功：$TEST_DOMAIN -> $DNSMASQ_RESULT"

        #
        # 如果直接airdns和dnsmasq结果不同，只提示。
        # CDN或多A记录时这并不一定是故障。
        #
        if [ -n "$AIRDNS_RESULT" ] &&
           [ "$AIRDNS_RESULT" != "$DNSMASQ_RESULT" ]; then

            warn "airdns与dnsmasq返回IP不同，可能由多A记录或缓存导致"
            printf '       airdns：%s\n' "$AIRDNS_RESULT"
            printf '       dnsmasq：%s\n' "$DNSMASQ_RESULT"
        fi

    else

        fail "dnsmasq完整链路解析失败：$TEST_DOMAIN"

        printf '%s\n' "$NSLOOKUP_OUTPUT" |
        sed 's/^/       /'
    fi
fi


section "SmartDNS配置"

if [ -f "$AIRDNS_CONF" ]; then

    BIND_LINE="$(
        grep \
            '^[[:space:]]*bind[[:space:]].*127[.]0[.]0[.]1:6053' \
            "$AIRDNS_CONF" |
        head -n 1
    )"

    if [ -n "$BIND_LINE" ]; then
        ok "airdns配置监听6053端口"
    else
        warn "配置中没有找到127.0.0.1:6053监听项"
    fi


    HTTPS_LINE="$(
        grep \
            '^[[:space:]]*server-https[[:space:]]' \
            "$AIRDNS_CONF" |
        head -n 1
    )"

    if [ -n "$HTTPS_LINE" ]; then
        ok "检测到DoH上游配置"
        printf '       %s\n' "$HTTPS_LINE"
    else
        fail "没有检测到server-https DoH上游"
    fi
fi


section "最近同步日志"

SYNC_LOG="$(
    read_system_log |
    grep 'airport-node-dns' |
    tail -n 10
)"

if [ -n "$SYNC_LOG" ]; then
    printf '%s\n' "$SYNC_LOG"
else
    printf '没有找到airport-node-dns系统日志\n'
fi


section "最近airdns日志"

if [ -f /tmp/airport-smartdns.log ]; then

    tail -n 10 /tmp/airport-smartdns.log

elif [ -f /tmp/airport-smartdns.stdout ]; then

    tail -n 10 /tmp/airport-smartdns.stdout

else

    printf '没有找到airdns日志文件\n'
fi


section "总结"

if [ "$FAIL" -eq 0 ] &&
   [ "$WARN" -eq 0 ]; then

    printf '状态：完全正常\n'
    printf '失败：0\n'
    printf '警告：0\n'
    exit 0
fi

if [ "$FAIL" -eq 0 ]; then

    printf '状态：核心功能正常，但存在非致命警告\n'
    printf '失败：0\n'
    printf '警告：%s\n' "$WARN"
    exit 0
fi

printf '状态：存在故障\n'
printf '失败：%s\n' "$FAIL"
printf '警告：%s\n' "$WARN"

exit 1
