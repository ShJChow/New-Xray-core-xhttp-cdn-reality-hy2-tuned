# xray-xhttp

443 端口上基于 Xray-core 的 **XHTTP + CDN 上下行分离**一键部署方案，默认开启 **xpadding**（ECH 可选），并在内核、Nginx、Xray 三层把**流控参数全部打开**，附带常驻管理命令 `xh`。

支持 V2rayN / Shadowrocket / Mihomo 客户端，支持 IPv4 与 IPv6。

> **原理阅读**：XHTTP、上下行分离及其抗审查优势 — <https://habr.com/en/articles/990208/>
>
> **注意**：本方案使用 VLESS Encryption，客户端（V2rayN、Mihomo）需更新到支持 `vlessenc` / `xhttp` 的版本。
>
> **注意**：V2rayN v7.19.5+ 在 TUN 模式下链路可能不稳定，需启用旧版 TUN 保护选项（[PR #9005](https://github.com/2dust/v2rayN/pull/9005)）。

---

## 特性

| 能力 | 说明 |
|---|---|
| 5 种节点模式 | Reality Vision 直连 / XHTTP+Reality 不分离 / 上行 CDN 下行 Reality / 双向 CDN / 上行 Reality 下行 CDN |
| xpadding | 默认开启，`xPaddingObfsMode` + 自定义 Header 与参数名，绕过 CDN 侧的 XHTTP 特征检测 |
| ECH | 可选，加密 TLS 握手中的 SNI |
| VLESS Encryption | 默认开启（ML-KEM-768），防止 CDN 中间人解密流量 |
| **流控全开** | BBR + fq、16MB 收发缓冲、TFO、MTU 探测、句柄 1048576、Xray `sockopt`、Nginx gRPC 长连接超时修复 |
| **管理命令 `xh`** | 状态 / 节点信息 / 订阅 / 日志 / 更新内核 / 调优开关 / 保活 / 卸载 |
| **非交互一键** | 环境变量驱动，`AUTO=1` 零交互重装 |
| **保活自愈** | cron 每 5 分钟健康检查 + 开机自启 |
| **内核自动更新** | 每周更新 Xray-core，配置自检失败自动回滚 |
| 扩展 | 上下行不同 CDN / 上行 IPv4 下行 IPv6 / XHTTP-H3 与 Hysteria2 |

---

## 前置条件

运行脚本前需在 Cloudflare 完成：

1. Reality 域名 DNS → **仅 DNS**（灰色云朵）
2. CDN 域名 DNS → **代理开启**（橙色云朵）
3. SSL/TLS 加密 → **完全（严格）**
4. 网络 → **gRPC 已开启**
5. 缓存规则（建议）→ 将 XHTTP 路径设为绕过缓存，表达式在部署完成后由脚本给出
6. 如需 ECH → Edge Certificates 中先开启 ECH

每个入口域名使用独立的 `dist/<域名>/index.html` 作为回落页；可用 [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) 抓取网页后上传。

---

## 一键部署（推荐：带 xpadding 的 XHTTP）

> **版本要求**：Xray 内核 ≥ `26.2.6`，Mihomo 内核 ≥ `1.19.24`。
> xpadding 默认开启；ECH 可选，默认关闭。

Debian / Ubuntu：

```bash
sudo -i
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

Alpine Linux：

```sh
doas -s
apk add --no-cache bash curl
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

### 不带 xpadding 的普通版

> Mihomo 内核 ≥ `1.19.23` 即可。

```bash
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

脚本可重复执行，用于更新域名、回落网站等参数。

### 非交互一键（脚本化重装）

```bash
sudo -i
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.stanford.edu \
CDN_FALLBACK_ORIGIN=https://www.harvard.edu \
CDN_ECH=n \
bash ~/install-xpadding.sh
```

可用环境变量：

| 变量 | 说明 | 默认 |
|---|---|---|
| `AUTO` | `1` 表示零交互 | `0` |
| `REALITY_DOMAIN` / `CDN_DOMAIN` | 两个域名，**必填** | — |
| `IP_CHOICE` | `1`=IPv4，`2`=IPv6 | `1` |
| `FALLBACK_MODE` | `static`（本地页面）/ `proxy`（反代） | `static` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | `proxy` 模式下的回落站 | stanford / harvard |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | xpadding 字段 | `Referer` / `x_padding` |
| `CDN_ECH` | `y` 开启 ECH | `n` |
| `FEATURE_TUNING` | `false` 关闭全部流控调优 | `true` |
| `FEATURE_KEEPALIVE` | `false` 不装保活 cron | `true` |
| `FEATURE_AUTOUPDATE` | `false` 不装自动更新 cron | `true` |

`AUTO=1` 且 `FALLBACK_MODE=static` 时会自动生成占位 `index.html` 并跳过人工确认，事后可自行替换。

---

## 管理命令 `xh`

部署完成后即可使用，详见 [docs/11.管理命令.md](./docs/11.管理命令.md)。

```text
xh                     交互菜单
xh status              服务状态 / 监听端口 / 流控参数 / 版本
xh info                节点参数与客户端节点链接
xh sub                 订阅链接与二维码
xh log [xray|nginx]    跟踪日志
xh start|stop|restart  服务控制
xh update [--auto]     更新 Xray-core（自检失败自动回滚）
xh tuning [show|off]   查看 / 回滚流控调优
xh keepalive [on|off]  保活开关
xh autoupdate [on|off] 内核自动更新开关
xh uninstall           卸载全部组件
```

---

## 流控调优

完整参数表、探测降级逻辑与回滚方式见 [docs/10.流控调优.md](./docs/10.流控调优.md)。要点：

- **内核**：BBR + fq、`rmem/wmem` 16MB、`tcp_fastopen=3`、`tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat`、`somaxconn=65535`、UDP 缓冲（QUIC/H3）等，全部写入独立文件 `/etc/sysctl.d/99-xray-xhttp.conf`，**不改动你原有的 `sysctl.conf`**。
- **句柄**：`limits.d` + systemd drop-in（不改官方 Xray unit，内核更新不会被覆盖），`nofile=1048576`。
- **Xray**：入站与 freedom 出站注入 `sockopt`（`tcpFastOpen` / `tcpcongestion: bbr` / keepalive / `tcpUserTimeout`）。`tcpcongestion` **仅在探测到 BBR 时写入**，否则省略以免 Xray 启动失败。
- **Nginx**：`worker_rlimit_nofile`、`worker_connections 65535`，以及把 XHTTP 的 `grpc_read_timeout` / `grpc_send_timeout` 放大到 `1h`（默认 60s 会直接切断 XHTTP 长连接）。
- **客户端**：xpadding 版自动带 `xmux`（`maxConcurrency 16-32`、`hMaxReusableSecs 1800-3000`）。

全部调优均为 **best-effort**：OpenVZ / LXC 等只读 sysctl 环境会逐项跳过并告警，不会中断部署。回滚只需 `xh tuning off`。

---

## 扩展脚本

主脚本部署完成后按需追加，会复用已有 `UUID / Path / VLESS Encryption` 并更新客户端配置与订阅。

```bash
# 上行 CDN-A | 下行 CDN-B
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/add-dual-cdn.sh -o ~/add-dual-cdn.sh && bash ~/add-dual-cdn.sh

# 上行 IPv4 | 下行 IPv6（需 VPS 同时拥有 v4/v6）
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/add-dual-ip.sh -o ~/add-dual-ip.sh && bash ~/add-dual-ip.sh

# VLESS+XHTTP+TLS(H3) | Hysteria2 直连
curl -fsSL https://github.com/ShJChow26/xray-xhttp/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

---

## 手动部署

不想跑脚本可按顺序阅读 `docs/`：

1. [1.环境配置.md](./docs/1.环境配置.md)
2. [2.文件配置.md](./docs/2.文件配置.md)
3. [3.xpadding配置.md](./docs/3.xpadding配置.md)
4. [4.ECH配置.md](./docs/4.ECH配置.md)
5. [5.流程图.md](./docs/5.流程图.md)
6. [6.拓展-上下行不同CDN.md](./docs/6.拓展-上下行不同CDN.md)
7. [7.拓展-上下行IPv4IPv6.md](./docs/7.拓展-上下行IPv4IPv6.md)
8. [8.拓展-QUIC添加.md](./docs/8.拓展-QUIC添加.md)
9. [9.卸载.md](./docs/9.卸载.md)
10. [10.流控调优.md](./docs/10.流控调优.md)
11. [11.管理命令.md](./docs/11.管理命令.md)
12. [客户端模板.txt](./客户端模板.txt) / [客户端模板-mihomo.yaml](./客户端模板-mihomo.yaml)

---

## 输出文件

- `~/client-config.txt`：V2RayN / Shadowrocket 节点
- `~/client-config-mihomo-full.yaml`：Mihomo 完整分流配置
- `~/client-config-mihomo-nodes.yaml`：Mihomo 纯节点配置
- `~/subscription-links.txt`、`~/subscription-*.png`：订阅链接与二维码
- `/etc/xhttp-cdn/node.env`：节点参数（0600，`xh` 读取）

已有 Mihomo 配置的用户建议使用 `mihomo-nodes.yaml`。

---

## 本地构建

```bash
bash .github/scripts/build-install.sh    # dist/install.sh, dist/install-xpadding.sh
bash .github/scripts/build-dual-cdn.sh   # dist/add-dual-cdn.sh
bash .github/scripts/build-dual-ip.sh    # dist/add-dual-ip.sh
bash .github/scripts/build-quic.sh       # dist/add-quic.sh
```

推送 `v*` tag 时 GitHub Actions 会自动构建并发布 Release。

---

## 致谢与许可

本项目以 [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config)（MIT）为基础衍生；
管理命令、非交互部署、保活自愈与内核自动更新等产品形态借鉴自 [ShJChow26/argosbx](https://github.com/ShJChow26/argosbx)，相关代码为本项目自行实现。

详见 [NOTICE.md](./NOTICE.md)。许可证：[MIT](./LICENSE)。

## 参考资料

- Xray 小白搭建教程：<https://xtls.github.io/document/level-0/ch07-xray-server.html>
- XHTTP: Beyond REALITY：<https://github.com/XTLS/Xray-core/discussions/4113>
- XHTTP + CDN 上下行分离讨论：<https://github.com/XTLS/Xray-core/discussions/4118>
- Xray SockoptObject 文档：<https://xtls.github.io/config/transports/sockopt.html>
- Xray-core v26.2.6（xpadding）：<https://github.com/XTLS/Xray-core/releases/tag/v26.2.6>
- xpadding leak 讨论：<https://github.com/XTLS/Xray-core/issues/4346>、<https://github.com/XTLS/BBS/issues/25>
- Mihomo XHTTP 讨论：<https://github.com/MetaCubeX/mihomo/discussions/2669>
- Mihomo 文档（Transport）：<https://wiki.metacubex.one/config/proxies/transport/>
- Cloudflare ECH：<https://developers.cloudflare.com/ssl/edge-certificates/ech/>
