# xray-xhttp

**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

 **xhttp+udp+cdn节点在软件（iOS）onexray和win11的v2rayN下，速度极快，快于histeria2(测试在Oracle 4ocpu+24运行)**
 
基于 Xray-core 的 **XHTTP + CDN 上下行分离**一键部署方案，默认开启 **xpadding**（ECH 可选），并在内核、Nginx、Xray 三层把**流控参数全部打开**，附带常驻管理命令 `xh`。

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
| 节点集（v4.0.0） | 默认 5 条，全部由 Xray 单核心提供：3 条 QUIC/h3（含 Hysteria2 obfs）+ 2 条 TCP 兜底。不再需要独立 hysteria 二进制 |
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
| 扩展 | `add-quic-h3`（3 条 XHTTP over h3）/ `add-quic`（Hysteria2）/ 上下行不同 CDN / 上行 IPv4 下行 IPv6 |

---

## 节点列表

v4.0.0 起默认输出**下表 5 条**，全部由 Xray 单核心提供——Hysteria2 改用 Xray 原生
inbound（v26.3.27+），不再需要独立的 hysteria 二进制。

**节点顺序即 HTTP/3 优先顺序**：前 3 条走 QUIC，后 2 条是 UDP 被封时的 TCP 兜底。
Mihomo 的策略组用 `include-all: true`，排序直接由此决定。

节点 1 经 CDN、server 是域名，在 v2rayN TUN 模式下需要把 CDN 域名加入直连列表，
否则会自环（见 `tasks/lessons.md` L15）。节点 2/3 直连裸 IP，只需为 VPS IP 加直连路由。
安装时生成的 `~/client-config-v2rayn-tun.txt` 已按本机实际值给出该清单。

名称为纯 ASCII + 主机名后缀（`<host>` = `hostname -s`）：

| # | 节点名 | 链路 | 传输 |
|---|---|---|---|
| 1 | `Vless-xhttp-tls-UDP-cdn-<host>` | 经 CDN，**UDP 443** | XHTTP + TLS，alpn h3，**实测最快** |
| 2 | `Vless-xhttp-h3-direct-<host>` | 直连 VPS，**UDP 443** | XHTTP + TLS，alpn h3，不经 CDN |
| 3 | `Hysteria2-obfs-<host>` | 直连 VPS，**UDP 8443** | Hysteria2 + Salamander 混淆 |
| 4 | `Vless-reality-vision-<host>` | 直连 VPS TCP 443 | Reality + Vision，UDP 被封时的兜底 |
| 5 | `Vless-xhttp-reality-<host>` | 直连 VPS TCP 443 | XHTTP + Reality，上下行不分离 |

节点 2/3 走裸 UDP 直连，需要在**云厂商安全组**放行 UDP 443 与 UDP 8443
（这一层在机器外面，脚本查不到也改不了）。Xray 版本低于 26.6.1 时这两条会被
自动禁用，只输出其余 3 条。

> **TUIC v5 未提供**：Xray-core 的 inbound 协议列表中没有 TUIC，在「仅用 Xray」的
> 前提下无法实现。节点 2（XHTTP over h3 直连）传输层同为 QUIC，是最接近的替代。

## 前置条件

运行脚本前需在 Cloudflare 完成（申请一个能托管到cloudflare 的[免费]域名：https://my.dnshe.com/index.php?m=domain_hub 或https://dash.domain.digitalplat.org/dashboard）：

1. Reality 域名 DNS → **仅 DNS**（灰色云朵）
2. CDN 域名 DNS → **代理开启**（橙色云朵）
3. SSL/TLS 加密 → **完全（严格）**
4. 网络 → **gRPC 已开启**
5. 缓存规则（建议）→ 将 XHTTP 路径设为绕过缓存，表达式在部署完成后由脚本给出
6. 如需 ECH → Edge Certificates 中先开启 ECH

每个入口域名使用独立的 `dist/<域名>/index.html` 作为回落页；可用 [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) 抓取网页后上传。

---

## 一键部署（推荐：带 xpadding 的 XHTTP）

> **版本要求**：Xray 内核 ≥ `26.6.1`，Mihomo 内核 ≥ `1.19.24`。
> Xray 的下限由两个直连 UDP 节点决定：Hysteria2 inbound 需 26.3.27+，finalmask 的 UDP listener 崩溃 bug（issue #6184）需 26.6.1+ 才修复。低于该版本时安装脚本会自动禁用这两条节点。
> xpadding 默认开启；ECH 可选，默认关闭。

Debian / Ubuntu：

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```


### 不带 xpadding 的普通版

> Mihomo 内核 ≥ `1.19.23` 即可。

```bash
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

脚本可重复执行，用于更新域名、回落网站等参数。

### 扩展：XHTTP over HTTP/3（3 条 h3 节点）

```bash
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/add-quic-h3.sh -o ~/add-quic-h3.sh && bash ~/add-quic-h3.sh
```

移植自上游 `add-quic.sh`，追加 `Vless-xhttp-tls-h3` /
`Vless-xhttp-split-h2up-h3down` / `Vless-xhttp-split-h3up-h2down` 三条。
三条的 `sni`/`host` 都用 CDN 域名，nginx 的 `listen ... quic` 插进 **CDN 域名的
server 块**并复用该块已有的 `location`——与 `add-quic.sh`（Hysteria2）插进
Reality 块的做法不同，两者用不同的配置标记，可同时安装。

## 扩展脚本

主脚本部署完成后按需追加，会复用已有 `UUID / Path / VLESS Encryption` 并更新客户端配置与订阅。

```bash
# Hysteria2 直连（同扩展的 XHTTP+TLS+H3 节点已知不通，见下）
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

> v2.0.1 起该扩展**默认只产出 `Hysteria2-direct`**。`Vless-xhttp-tls-h3-direct` 需 `FEATURE_XHTTP_H3_NODE=true` 才输出。
> **后者在 Shadowrocket 下实测不通**（与主脚本已默认停用的直连 h3 节点同因），
> 见 [docs/8 勘误](./docs/8.拓展-QUIC添加.md)。想要 Hysteria2 的照常运行本扩展，忽略 h3 那条即可。

### 非交互一键（脚本化重装）

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
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
| `FEATURE_H3_DIRECT` | `false` 关闭直连 h3 节点（UDP 443） | `true` |
| `FEATURE_HY2` | `false` 关闭 Hysteria2-obfs 节点（UDP 8443） | `true` |
| `H3_PORT` / `HY2_PORT` | 两条直连 UDP 节点的端口 | `443` / `8443` |
| `FEATURE_XHTTP_H3_NODE` | Hysteria2 扩展的开关：`true` 恢复 `Vless-xhttp-tls-h3-direct` 节点与配套 nginx quic 监听 | `false` |
| `FEATURE_KEEPALIVE` | `false` 不装保活 cron | `true` |
| `FEATURE_AUTOUPDATE` | `false` 不装自动更新 cron | `true` |

`AUTO=1` 且 `FALLBACK_MODE=static` 时会自动生成占位 `index.html` 并跳过人工确认，事后可自行替换。

---
 ### 1. 下载脚本
  curl -O https://raw.githubusercontent.com/ShJChow/Xray-core-xhttp-cdn-tuned/main/tools/ubuntu_vps_optimize.sh

  ### 2. 加执行权限
  chmod +x ubuntu_vps_optimize.sh

  ### 3. 先「只看不碰」——检测 + 打印计划，零修改
  sudo bash ubuntu_vps_optimize.sh --dry-run

  ### 4. 确认无误后正式跑
  sudo bash ubuntu_vps_optimize.sh

##  管理命令 `xh`

部署完成后即可使用，详见 [docs/11.管理命令.md](./docs/11.管理命令.md)。

```text
xh                     交互菜单
xh status              服务状态 / 监听端口 / 调优状态 / 版本
xh info                节点参数与客户端节点链接
xh sub                 订阅链接与二维码
xh log [xray|nginx]    跟踪日志
xh start|stop|restart  服务控制
xh update [--auto]     更新 Xray-core（自检失败自动回滚）
xh tuning [show|on|off] 查看 / 开启 / 回滚系统层调优
xh diag                节点连不上时的服务端侧自检
xh conflict            检测 /etc/sysctl.d/ 中会覆盖本项目参数的其它配置文件
xh keepalive [on|off]  保活开关
xh autoupdate [on|off] 内核自动更新开关
xh uninstall           卸载全部组件
```

---

## 流控调优


### `xh tuning on` 会做什么

BBR + fq、`rmem/wmem`（按内存分档 64/32/16 MB）、`tcp_fastopen=3`、`tcp_mtu_probing=1`、
`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat`、`somaxconn=65535`、UDP 缓冲（QUIC/H3）、
`limits.d` + systemd drop-in（`nofile=1048576`）。

全部写入独立文件 `/etc/sysctl.d/99-xray-xhttp.conf` 与
`/etc/security/limits.d/99-xray-xhttp.conf`，**不改动你原有的 `sysctl.conf`**，
也不改官方 Xray unit（用 drop-in，内核更新不会被覆盖）。

全部调优均为 **best-effort**：OpenVZ / LXC 等只读 sysctl 环境会逐项跳过并告警，
不会中断。回滚只需 `xh tuning off`。完整参数表见
[docs/10.流控调优.md](./docs/10.流控调优.md)。

> **未验证**：这些参数在你的机器上是否真的提升吞吐，本项目没有做过对照测量。
> 默认不开启正是因为如此——先把节点跑通，有需要再自行开启并对比。

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

 ## 在你 VPS 上依次执行就行：

  # 1. 下载脚本
  curl -O https://raw.githubusercontent.com/ShJChow/Xray-core-xhttp-cdn-tuned/main/tools/ubuntu_vps_optimize.sh

  # 2. 加执行权限
  chmod +x ubuntu_vps_optimize.sh

  # 3. 先「只看不碰」——检测 + 打印计划，零修改
  sudo bash ubuntu_vps_optimize.sh --dry-run

  # 4. 确认无误后正式跑
  sudo bash ubuntu_vps_optimize.sh

  三种模式：

  ┌────────────┬───────────────────────────────────────┐
  │    命令    │                 作用                  │
  ├────────────┼───────────────────────────────────────┤
  │ --dry-run  │ 只检测 + 打印将要改什么，不写任何文件 │
  ├────────────┼───────────────────────────────────────┤
  │ （无参数） │ 检测 → 备份 → 优化 → 验证             │
  ├────────────┼───────────────────────────────────────┤
  │ --rollback │ 完整回滚到运行前状态                  │
  └────────────┴───────────────────────────────────────┘

  跑完后重启服务生效：

  systemctl restart xray nginx docker
---

## 如有问题，清理后重跑

```bash
  pkill -9 -x xray; pkill -9 -f 'xray run'
  rm -f  /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f  /usr/local/bin/xray
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  systemctl daemon-reload && systemctl reset-failed

  pgrep -a xray || echo "✅ 干净"
  bash ~/install.sh
```

推送 `v*` tag 时 GitHub Actions 会自动构建并发布 Release。

---

## 致谢与许可

本项目以 [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config)（MIT）为基础衍生；
管理命令、非交互部署、保活自愈与内核自动更新等产品形态借鉴自 [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx)（GPL-3.0），相关代码为本项目自行实现，未复制其源码。

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
