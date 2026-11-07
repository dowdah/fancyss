# fancyss · AnyTLS 独立维护版

面向带软件中心的 ASUSWRT / Merlin 及兼容固件的路由器透明代理插件。由 `dowdah` 独立维护，基于 [hq450/fancyss](https://github.com/hq450/fancyss) 3.5.30，重点维护 AnyTLS 集成和离线打包。

**目前仅公开源码，暂未提供本维护版的公开安装包。** 已有本维护版离线包的用户，可按[选包说明](#机型与包型)核对设备平台和包型，再到软件中心[离线安装或升级](#安装与升级)。

## 本维护版的改动

- **AnyTLS 集成**。由插件管理 AnyTLS 客户端，配合 Xray 节点分流，改进服务重启、节点切换和路由回环处理。
- **可选的 Wi-Fi Calling 直连**。在 Xray 分流模式下，可为使用 AnyTLS 默认节点时的 Wi-Fi Calling 流量配置直连规则。

插件也支持 SS、SSR、VMess、VLESS、Trojan、Hysteria2、自定义 Xray/V2Ray JSON，以及 `full` 包中的 NaïveProxy 和 TUIC。节点可手动添加、通过 URI 导入或在线订阅，支持 DNS 分流、访问控制和延迟检测。

## 机型与包型

先在[上游 3.5.30 机型与固件参考](https://github.com/hq450/fancyss/blob/b19e82cb6a05e08990a96905353921819d44d134/README.md#支持机型固件)中按路由器型号和固件确认平台，再选包型。当前构建覆盖七个平台，实机兼容性按设备和固件分别验证。

| 平台 | 安装包前缀 |
| --- | --- |
| `arm` | `fancyss_arm` |
| `hnd` | `fancyss_hnd` |
| `hnd_v8` | `fancyss_hnd_v8` |
| `qca` | `fancyss_qca` |
| `mtk` | `fancyss_mtk` |
| `ipq32` | `fancyss_ipq32` |
| `ipq64` | `fancyss_ipq64` |

- **`full`**：使用 AnyTLS、NaïveProxy 或 TUIC 时选此包型。
- **`lite`**：无需上述协议时可选，节省 JFFS 空间。

## 安装与升级

1. 用对应的 SHA-256 校验清单核对已有离线包，确认平台和包型。
2. 在路由器软件中心选择**离线安装**或**手动安装**，上传匹配的本维护版安装包。升级插件或切换包型时也走这个入口。

带本维护版标记的安装会拦截上游插件自更新。节点订阅和规则更新仍通过插件内各自的入口操作。 [上游离线包](https://github.com/hq450/fancyss_history_package)属于上游版本，安装后会覆盖本维护版的 AnyTLS 改动。

## 使用指南

- [Wi-Fi Calling 直连](doc/guides/wifi-calling.md)
- [TUIC 配置指南](doc/tuic_usage_on_fancyss.md)（`full`）
- [NaïveProxy 配置实践](doc/naive_usage_on_fancyss.md)（`full`）

## 开发

Linux 环境具备完整的构建输入、规则编译器和 Go 模块缓存时，可以运行 `bash build.sh --offline`。缺少缓存的环境需等待替代构建输入。 [源码开发与发布说明](doc/source-only-development.md)

## 来源与许可证

原项目由 hq450 和上游贡献者开发。本维护版在上游 3.5.30 基础上修改了 AnyTLS 集成、Wi-Fi Calling 直连和打包流程。README 更新于 2026-11-07。

本仓库按 [GNU GPL v3](LICENSE) 发布其覆盖的代码。第三方组件适用各自的许可证。 [AnyTLS 客户端第三方声明](tool/fss-anytls-client/NOTICE)
