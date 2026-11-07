# Wi-Fi Calling 直连

Xray 分流模式下，如果默认节点使用 AnyTLS，未命中其他规则的 Wi-Fi Calling
握手可能被 UDP 拒绝规则拦截。

在路由器上将 `/jffs/configs/fancyss-vowifi-bypass.conf` 的内容设为一行 `lan`，
然后重启 fancyss。主 LAN 上的设备共用一条例外，发往外部 IPv4 单播目的地的
UDP 500 和 4500 会绕过 fancyss，由路由器正常转发。本机地址及已在 fancyss
忽略列表中的目的地按既有规则处理。使用同样端口的 IPsec VPN 也会走这条例外。

已有部署也可以继续使用单设备格式，在一行内填写 Wi-Fi MAC 和 IPv4 CIDR，
用空白分隔。下例使用示例 MAC 和 T-Mobile 网段。

```text
02:00:00:00:00:01 208.54.0.0/16
```

查看规则是否命中时，可在路由器
上运行 `iptables -t mangle -nvxL SHADOWSOCKS`，查找 `fancyss-vowifi-bypass`
的包计数。在手机上开启飞行模式，再单独打开 Wi-Fi，检查运营商标识并试拨普通电话。

清空或删除配置文件并重启 fancyss 即可关闭。文件默认不存在。无效配置或规则安装
失败会记录到 fancyss 启动日志，并继续使用常规分流规则。
