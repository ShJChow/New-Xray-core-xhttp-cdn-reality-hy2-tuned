# xray-xhttp
 **xhttp+udp+cdn节点在软件（iOS）onexray下，速度极快，快于histeria2(测试在Oracle 4ocpu+24运行)**
 
443 端口基于 Xray-core 的 **XHTTP + CDN 上下行分离**一键部署方案，默认开启 **xpadding**（ECH 可选），并在内核、Nginx、Xray 三层把**流控参数全部打开**，附带常驻管理命令 `xh`。

支持 V2rayN / Shadowrocket / Mihomo / onexray 客户端，支持 IPv4 与 IPv6。

> **原理阅读**：XHTTP、上下行分离及其抗审查优势 — <https://habr.com/en/articles/990208/>
>
> **注意**：本方案使用 VLESS Encryption，客户端（V2rayN、Mihomo）需更新到支持 `vlessenc` / `xhttp` 的版本。
>
> **注意**：V2rayN v7.19.5+ 在 TUN 模式下链路可能不稳定，需启用旧版 TUN 保护选项（[PR #9005](https://github.com/2dust/v2rayN/pull/9005)）。
安装所有节点和扩展histeria2节点后，运行 **xh tuning on**
---

## 特性

| 能力 | 说明 |
|---|---|
| 5 种节点模式 | 2 条 TCP 直连兜底 + 1 条 XHTTP over HTTP/3（UDP 443）+ 2 条上下行分离，见下方节点表 |
| xpadding | 默认开启，`xPaddingObfsMode` + 自定义 Header 与参数名，绕过 CDN 侧的 XHTTP 特征检测 |
| ECH | 可选，加密 TLS 握手中的 SNI |
| VLESS Encryption | 默认开启（ML-KEM-768），防止 CDN 中间人解密流量 |
| **流控全开** | BBR + fq、TFO、MTU 探测、句柄 1048576、Xray `sockopt` 与 `policy.bufferSize`、Nginx gRPC 长连接超时 |
| **机型自适应** | 按内存自动分三档（≥16G / ≥4G / <4G）伸缩缓冲区与队列；ARM64 显式设置 `bufferSize`（默认仅 4 KB） |
| flow / Vision | 节点 1 用 `xtls-rprx-vision`（唯一能走 Splice 的节点）；其余节点是 XHTTP，按协议不能带 flow。`VISION_UDP443=1` 可切到 `-udp443` |
| **管理命令 `xh`** | 状态 / 节点信息 / 订阅 / 日志 / 更新内核 / 调优开关 / 保活 / 卸载 |
| **非交互一键** | 环境变量驱动，`AUTO=1` 零交互重装 |
| **保活自愈** | cron 每 5 分钟健康检查 + 开机自启 |
| **内核自动更新** | 每周更新 Xray-core，配置自检失败自动回滚 |
| 扩展 | 上下行不同 CDN / 上行 IPv4 下行 IPv6 / Hysteria2（同扩展的 XHTTP-H3 节点已知不通，见 docs/8 勘误） |

---

## 节点列表

脚本生成 5 条节点，名称为纯 ASCII + 主机名后缀（`<host>` = `hostname -s`）：

| # | 节点名 | 链路 | 传输 |
|---|---|---|---|
| 1 | `Vless-reality-vision-<host>` | 直连 VPS TCP 443 | Reality + Vision，**唯一支持 Splice，速度最快**；UDP 被封时的兜底 |
| 2 | `Vless-xhttp-reality-<host>` | 直连 VPS TCP 443 | XHTTP + Reality，上下行不分离 |
| 3 | `Vless-xhttp-tls-UDP-cdn-<host>` | 经 CDN，**UDP 443** | XHTTP + TLS，**alpn h3** |
| 4 | `Vless-xhttp-split-cdnup-realitydown-<host>` | 上行经 CDN / 下行直连 VPS | 上下行分离，`downloadSettings`，alpn h2 |
| 5 | `Vless-xhttp-split-realityup-cdndown-<host>` | 上行直连 VPS / 下行经 CDN | 上下行分离，`downloadSettings`，alpn h2 |

- 节点 1、2 走 TCP，是 UDP 被封时的兜底。
- 节点 3 是本项目相对上游的主要改动：CDN 侧只保留 UDP（HTTP/3）版本。
- 节点 4、5 是 v1.2.7 恢复的**上下行分离**节点：上行防封锁走 CDN、下行拿速度走直连（或反向）。二者依赖 Xray 的 `downloadSettings` 字段。

> **节点 4/5 的客户端支持性未验证**：`downloadSettings` 是 Xray-core 特有字段。**Shadowrocket 能否解析未经实测**——推荐用 mihomo / onexray 使用这两条。若 SR 中显示异常，改用节点 1–3。

> **关于 Vision**：`xtls-rprx-vision` 要求 TCP+TLS/REALITY 的 raw 传输，只有节点 1 满足。节点 2–5 是 XHTTP 传输，按 Xray 设计**不能带 flow**——给它们加 Vision 只会连接失败。详见 [docs/10 第 4 节](./docs/10.流控调优.md)。

### UDP（HTTP/3）节点

- **节点 3** 由 Cloudflare 边缘终结 h3，回源仍是 TCP，**服务端零改动**（需 CF 区域已开启 HTTP/3，默认开启）。
- **`alpn` 必须恰好只有 `h3`**，Xray 与 Mihomo 才会走 HTTP/3（`decideHTTPVersion` 与 `transport/xhttp/client.go` 都要求 `len(alpn)==1`）。手工改配置时不要额外加 `h2`。

#### 直连 h3 节点（`Vless-xhttp-tls-UDP-direct`）—— v1.2.7 起默认停用

用户在 Shadowrocket 下实测，直连 VPS 的两条 h3 节点（本脚本的 `Vless-xhttp-tls-UDP-direct` 与 `add-quic.sh` 的 `Vless-xhttp-tls-h3-direct`）**均不通**。因此 `FEATURE_H3_DIRECT` 默认值自 v1.2.7 改为 `false`：

- 客户端不再生成该节点链接与 mihomo 块，**不留死链接**；
- Nginx 不再监听 `UDP 443 quic`——这原本是配置里唯一有 SSL 库依赖的指令（`http3` 需要支持 QUIC 的 TLS 库，标准 OpenSSL 未必满足），曾在部分环境下导致 nginx 启动失败，默认关闭一并规避；
- 代码路径完整保留，想自行验证的用 `FEATURE_H3_DIRECT=true bash ~/install-xpadding.sh` 重跑。此时需防火墙放行 **UDP 443**，Oracle 要在 VCN 安全列表和实例 iptables 两层都放行，见 [docs/12](./docs/12.机型调优-OracleARM.md#3-oracle-特有443-端口要放行两层)。

> **历史**：v1.2.0 及之前该节点的 SNI 写的是 CDN 域名，而 QUIC 监听与 `location` 分处两个 `server_name`，TLS 握手会落到回落网站上——v1.2.1 已修复该错配，但客户端侧仍不通，故 v1.2.7 直接默认停用。

### 订阅在 Shadowrocket / onexray 里拉不到节点

脚本同时生成 **base64** 和 **明文**两份节点订阅（`xh sub` 会列出两个链接）：

```text
https://<Reality域名>/sub/<token>/v2rayn.txt        # base64
https://<Reality域名>/sub/<token>/v2rayn-raw.txt    # 明文，每行一条
```

部分 iOS 客户端对 base64 订阅更挑剔，**先换明文订阅试一次**。

若仍是空的，用这一步区分（10 秒，结论互斥）：

> **在出问题的那台设备上，用浏览器直接打开订阅链接。**
>
> - **打得开、能看到内容** → 网络与证书都没问题，是客户端的解析问题。改用明文订阅；仍不行就手动复制单条节点导入，看是哪一条被拒。
> - **打不开 / 报证书错误** → 该设备到 VPS 的网络或证书信任问题，与本项目配置无关。

节点本身的兼容性：节点 2–5 使用 **VLESS Encryption**（`encryption=` 为 ML-KEM-768 长串）与 **XHTTP**，都是较新的特性。客户端不支持时通常表现为**跳过这几条**，而不是整个订阅为空——所以"一条都没有"基本可以排除节点格式问题。

### UDP 节点连不上怎么办

```bash
xh diag     # 服务端侧自检：quic 监听 / nginx -t / UDP 443 / 防火墙，并给出客户端自测步骤
```

**UDP 节点（节点 3）不通、而 TCP 节点正常**，先分清是不是 TUN 模式导致的：

#### 情况 A：只在开启 TUN 时不通（v1.2.3 已修）

TUN 用 `auto-route` 把默认路由指向自己，客户端**自己**发往节点服务器的包会被自家 TUN 再次捕获，按 rules 兜到 `MATCH,漏网之鱼` → 又送回代理 → 自环。TCP 不受影响是因为 dialer 绑定物理接口的保护在 TCP 路径上更完整，QUIC 是无连接 UDP，同样的保护在多数平台兜不住。

`client-config-mihomo-full.yaml` 现在自带三道防线（越靠前越根本）：

| # | 位置 | 作用 |
|---|---|---|
| ① | `tun.route-exclude-address` | 让发往 VPS 的包**根本不进 TUN** |
| ② | `rules` 第一条 `IP-CIDR,<VPS_IP>/32,全局直连` | 万一进了 TUN，第一条就放出去 |
| ③ | `sniffer.skip-dst-address` | 即使被捞到，也不许改写目标地址 |

外加 `dns.fake-ip-filter` 补上两个域名——节点 3 的 `server` 是 CDN 域名，被 fake-ip 解析成 `198.18.x.x` 同样连不上。

> **纯节点订阅（`mihomo-nodes.yaml`）不含这些**——它只有 `proxies` 段。用纯节点导入自己配置的话，请手动把上面三条抄进去。
>
> **v2rayN 用户**：v2rayN 的 TUN 由客户端自己实现，我们改不到。v7.19.5+ 需启用旧版 TUN 保护选项（[PR #9005](https://github.com/2dust/v2rayN/pull/9005)）；或在设置里把 VPS IP 加入直连/绕过列表。

#### 情况 B：不开 TUN 也不通

那就是客户端侧网络封锁了 UDP 443（QUIC）——节点 3 根本不经过本项目的任何服务端配置，服务端改不了。此时请改用节点 1 / 2 / 4 / 5（全部走 TCP）。

> `add-quic.sh` 换非 443 UDP 端口这条路**不再推荐**：它产出的 `Vless-xhttp-tls-h3-direct` 同样在 Shadowrocket 下实测不通（见 [docs/8 勘误](./docs/8.拓展-QUIC添加.md)），该扩展现在只有 Hysteria2 那条节点可用。

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
curl -fsSL https://github.com/ShJChow26/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

Alpine Linux：

```sh
doas -s
apk add --no-cache bash curl
curl -fsSL https://github.com/ShJChow26/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

### 不带 xpadding 的普通版

> Mihomo 内核 ≥ `1.19.23` 即可。

```bash
curl -fsSL https://github.com/ShJChow26/xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

脚本可重复执行，用于更新域名、回落网站等参数。

## 扩展脚本

主脚本部署完成后按需追加，会复用已有 `UUID / Path / VLESS Encryption` 并更新客户端配置与订阅。

```bash
# Hysteria2 直连（同扩展的 XHTTP+TLS+H3 节点已知不通，见下）
curl -fsSL https://github.com/ShJChow26/xhttp-cdn-tuned/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

> 该扩展产出两条节点：`Hysteria2-direct` 与 `Vless-xhttp-tls-h3-direct`。
> **后者在 Shadowrocket 下实测不通**（与主脚本已默认停用的直连 h3 节点同因），
> 见 [docs/8 勘误](./docs/8.拓展-QUIC添加.md)。想要 Hysteria2 的照常运行本扩展，忽略 h3 那条即可。

### 非交互一键（脚本化重装）

```bash
sudo -i
curl -fsSL https://github.com/ShJChow26/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu \
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
| `FALLBACK_MODE` | `static`（本地页面）/ `proxy`（反代） | `proxy` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | `proxy` 模式下的回落站 | sjsu / harvard |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | xpadding 字段 | `Referer` / `x_padding` |
| `CDN_ECH` | `y` 开启 ECH | `n` |
| `VISION_UDP443` | `1` 时节点 1 的 flow 用 `xtls-rprx-vision-udp443`（需客户端支持） | `0` |
| `FEATURE_H3_DIRECT` | `true` 启用直连 VPS 的 h3 节点（`Vless-xhttp-tls-UDP-direct`）与对应 Nginx `443 quic` 监听。v1.2.7 起默认关闭：Shadowrocket 下实测不通 | `false` |
| `FEATURE_TUNING` | `false` 关闭全部调优（含 Xray 侧 bufferSize / sockopt） | `true` |
| `FEATURE_SYSCTL` | **系统层**调优（内核参数 / 句柄 / systemd drop-in），默认关闭，节点验证无误后再开 | `false` |
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
xh tuning [show|on|off] 查看 / 开启 / 回滚系统层调优
xh diag                UDP / HTTP3 节点连不上时的服务端侧自检
xh conflict            检测 /etc/sysctl.d/ 中会覆盖本项目参数的其它配置文件
xh keepalive [on|off]  保活开关
xh autoupdate [on|off] 内核自动更新开关
xh uninstall           卸载全部组件
```

---

## 流控调优

完整参数表、探测降级逻辑与回滚方式见 [docs/10.流控调优.md](./docs/10.流控调优.md)。要点：

- **内核**：BBR + fq、`rmem/wmem`（按内存分档 64/32/16 MB）、`tcp_fastopen=3`、`tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat`、`somaxconn=65535`、UDP 缓冲（QUIC/H3）等，全部写入独立文件 `/etc/sysctl.d/99-xray-xhttp.conf`，**不改动你原有的 `sysctl.conf`**。
- **Xray policy**：`bufferSize` 按档位取 512/256/64 KB。**ARM64（Oracle Ampere A1）默认只有 4 KB**，amd64 是 512 KB —— 不显式设置会形成巨大差异，详见 [docs/12](./docs/12.机型调优-OracleARM.md)。
- **句柄**：`limits.d` + systemd drop-in（不改官方 Xray unit，内核更新不会被覆盖），`nofile=1048576`。
- **Xray**：入站与 freedom 出站注入 `sockopt`（`tcpFastOpen` / `tcpcongestion: bbr` / keepalive / `tcpUserTimeout`）。`tcpcongestion` **仅在探测到 BBR 时写入**，否则省略以免 Xray 启动失败。
- **Nginx**：`listen backlog=65535`（默认仅 511，而全部 CDN 流量都经此进入，是全链路唯一的浅队列）、`access_log off`（XHTTP 高频 POST 且 URL 带上千字符 x_padding，写盘既费 IO 又把 padding 明文落盘）、`resolver` 按出网协议族关掉 IPv6/IPv4 解析（避免回落站每次先失败一次）、`worker_rlimit_nofile`、`worker_connections 65535`，以及把 XHTTP 的 `grpc_read_timeout` / `grpc_send_timeout` 从默认 60s 放大到 `1h`（空闲超过该超时后 Nginx 会关闭到 Xray 的上游连接，放大可减少重连；未做定量实测）。
- **客户端**：xpadding 版自动带 `xmux`（`maxConcurrency 32-64`、`hMaxReusableSecs 3600-6000`）。

**v1.2.2 起系统层与 Xray 层分开**：

| 层 | 开关 | 默认 | 内容 |
|---|---|---|---|
| 系统层 | `FEATURE_SYSCTL` | **`false`** | `sysctl.d` 内核参数、`limits.d`、systemd drop-in —— 唯一改动宿主机全局状态、也是最容易在 OpenVZ / LXC 上出问题的一段 |
| Xray 层 | `FEATURE_TUNING` | `true` | `policy.bufferSize`、入站/出站 `sockopt` —— 只写本项目的配置文件，无失败风险 |

先把节点跑通、确认无误，再用 `xh tuning on`（会给出带 `FEATURE_SYSCTL=true` 的现成重装命令）打开系统层。ARM64 的 `bufferSize` 属于 Xray 层，默认就已生效，不会因为系统层关闭而丢失。

全部调优均为 **best-effort**：OpenVZ / LXC 等只读 sysctl 环境会逐项跳过并告警，不会中断部署。回滚只需 `xh tuning off`。

---

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
12. [12.机型调优-OracleARM.md](./docs/12.机型调优-OracleARM.md)
13. [客户端模板.txt](./客户端模板.txt) / [客户端模板-mihomo.yaml](./客户端模板-mihomo.yaml)

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
