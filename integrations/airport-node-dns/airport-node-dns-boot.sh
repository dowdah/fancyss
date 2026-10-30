#!/bin/sh

# 等待软件中心和fancyss文件准备完成
count=0

while [ "$count" -lt 36 ]; do
    if [ -x /koolshare/bin/node-tool ] &&
       [ -x /koolshare/bin/jq ] &&
       [ -f /jffs/configs/airport-smartdns.conf ]; then
        break
    fi

    sleep 5
    count=$((count + 1))
done

# 重建cron任务
cru d airport_node_dns >/dev/null 2>&1

cru a airport_node_dns \
    "*/10 * * * * /bin/sh /jffs/scripts/airport-node-dns.sh >/dev/null 2>&1"

# 启动airdns并同步节点域名
/bin/sh /jffs/scripts/airport-node-dns.sh >/dev/null 2>&1
