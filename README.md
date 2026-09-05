# xray-xhttp
小白请使用ai agent，把本项目发给agent配置。
**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

>  **已在 Oracle ARM (4 核 24G) / Debian 12 & 13 (推荐) / Ubuntu 22.04 & 24.04 深度测试与调优**

基于 Xray-core 的 **XHTTP + CDN + Reality + Hysteria2** 全能高可用部署方案。默认开启 **xpadding 流量填充混淆 / Hysteria2 Salamander 混淆 / 全套 6 条节点**，并在安装时自动应用**系统级与网络层流控调优（BBR + fq、64MB 缓冲区、1048576 句柄、全套安全加固）**，附带常驻管理工具 `xh`。

支持 V2rayN / Clash Verge Rev / Mihomo Party / Sing-box / Shadowrocket / Loon / Surge / onexray 等全平台客户端。

---

## 目录

- [一、前置准备材料（域名、Cloudflare 与证书）](#一前置准备材料)
  - [1. 域名解析配置](#1-域名解析配置)
  - [2. Cloudflare 控制台设置](#2-cloudflare-控制台设置)
  - [3. SSL 证书申请详细步骤（acme-yg）](#3-ssl-证书申请详细步骤)
- [二、一键部署](#二一键部署)
  - [1. 交互式一键部署](#1-交互式一键部署)
  - [2. 零交互环境变量一键部署](#2-零交互环境变量一键部署)
- [三、常驻管理命令 `xh`](#三常驻管理命令-xh)
- [四、全平台千兆客户端调优指南](#四全平台千兆客户端调优指南)
  - [Windows 10 / 11](#1-windows-10--11-管理员-powershell)
  - [macOS](#2-macos)
  - [Linux](#3-linux-客户端)
- [五、节点拓扑与双轨架构](#五节点拓扑与双轨架构)
- [六、常见问题与排错](#六常见问题与排错)
- [七、v4.8.x 实测诊断与修复记录](#七v48x-实测诊断与修复记录)
- [八、免责声明](#八免责声明)

---

## 一、前置准备材料

在运行部署脚本前，请准备好 **2 个解析到本机 VPS IP 的子域名**（推荐托管在 Cloudflare）：
- **域名 1（直连 / Reality 域名）**：例如 `reality.example.com`
- **域名 2（CDN 域名）**：例如 `cdn.example.com`

>  **免费域名获取参考**：[DNSHE](https://my.dnshe.com) 或 [DigitalPlat](https://dash.domain.digitalplat.org)

---

### 1. 域名解析配置

在 Cloudflare DNS 控制台中添加两条 `A` 记录指向你的 VPS 公网 IP：

| 记录类型 | 域名名称 | 目标 IP | Cloudflare 代理状态（云朵颜色） | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| **A 记录** | `reality.example.com` | `你的 VPS IP` |  **仅 DNS（灰色云朵）** | 用于证书申请与 Reality/Hy2 直连 |
| **A 记录** | `cdn.example.com` | `你的 VPS IP` |  **已代理（橙色小黄云）** | 用于 XHTTP CDN 节点隐藏真实 IP |

---

### 2. Cloudflare 控制台设置

在 Cloudflare 仪表盘中开启以下开关：

1. **SSL/TLS** ➡️ **概述**：加密模式选择 **完全（严格）/ Full (strict)**；
2. **SSL/TLS** ➡️ **边缘证书**：最低 TLS 版本选择 **TLS 1.2**；
3. **网络（Network）**：
   -  开启 **gRPC**
   -  开启 **WebSockets**
   -  开启 **HTTP/3 (with QUIC)**
   -  开启 **0-RTT 连接恢复**
4. **规则（Rules）** ➡️ **Cache Rules（可选优化）**：
   - 对你的 XHTTP 路径设置 **Bypass Cache**（绕过缓存，避免流式响应被分块缓冲）。

---

### 3. SSL 证书申请详细步骤

本方案在安装时会自动使用 acme.sh 申请证书。如果你之前证书申请失败，或希望提前使用著名的 **`acme-yg` 一键脚本** 申请好证书，请按以下步骤操作：

#### 步骤 1：释放 80 端口（如果已有服务在运行）
```bash
systemctl stop nginx xray 2>/dev/null || true
```

#### 步骤 2：执行 acme-yg 证书申请脚本
```bash
bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
```

#### 步骤 3：交互式菜单详细选型与操作
1. **进入菜单**：输入 `1` 选择 **【ACME 申请证书】**；
2. **选择申请模式**：
   - **推荐方式 A（80 端口模式）**：输入 `1`（Standalone 模式，需确保 80 端口未被占用且域名 1 已灰云直连解析到本机 IP）；
   - **推荐方式 B（Cloudflare API 模式）**：输入 `2`（无需停用 80 端口，输入 CF Global API Key 或 Token 即可全自动签发）；
3. **输入主域名与次域名（双域名 SAN 证书）**：
   - **主域名**：输入你的直连域名（如 `reality.example.com`）
   - **泛域名 / 附加域名**：输入你的 CDN 域名（如 `cdn.example.com`）
4. **安装并输出证书路径**：
   申请成功后，证书会自动保存在 `/root/ygkkkca/` 目录下。

#### 步骤 4：将证书部署到标准路径（一键复制）
```bash
mkdir -p /etc/ssl/private
cp -f /root/ygkkkca/reality.example.com/fullchain.cer /etc/ssl/private/fullchain.cer
cp -f /root/ygkkkca/reality.example.com/private.key /etc/ssl/private/private.key
chmod 600 /etc/ssl/private/*.key
```

---

## 二、一键部署

### 1. 交互式一键部署

登录 VPS 终端（Root 权限）：

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

按照终端提示依次输入：
1. **Reality / 直连域名**（如 `reality.example.com`）
2. **CDN 域名**（如 `cdn.example.com`）
3. 选择伪装站或默认设置即可全自动完成安装。

---

### 2. 零交互环境变量一键部署

适合重装系统、自动化脚本或批量部署。遵循 **Karpathy 工程准则**（*Think Before Coding · Simplicity First · Surgical Changes*）设计：

#### 方案 A：标准生产推荐模板（推荐直接复制修改域名）
```bash
sudo -i

AUTO=1 \
REALITY_DOMAIN="reality.example.com" \
CDN_DOMAIN="cdn.example.com" \
IP_CHOICE=1 \
FALLBACK_MODE="proxy" \
REALITY_FALLBACK_ORIGIN="https://www.sjsu.edu" \
CDN_FALLBACK_ORIGIN="https://www.stanford.edu" \
FEATURE_AUTO_TUNING=true \
FEATURE_XPADDING=true \
FEATURE_CDN_ECH=false \
FEATURE_H3_DIRECT=true \
FEATURE_H2_DIRECT=false \
FEATURE_HY2=true \
FEATURE_AUTOUPDATE=true \
FEATURE_KEEPALIVE=true \
NODE_TAG="oracle-vps" \
bash -c "$(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh)"
```

#### 方案 B：极简极速模板（仅配置必填项）
```bash
sudo -i

AUTO=1 \
REALITY_DOMAIN="reality.example.com" \
CDN_DOMAIN="cdn.example.com" \
bash -c "$(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh)"
```

#### 方案 C：自定义端口与路径模板（密码由脚本全自动生成 SHA256 高熵密钥，无需手动指定）
```bash
sudo -i

AUTO=1 \
REALITY_DOMAIN="reality.example.com" \
CDN_DOMAIN="cdn.example.com" \
H3_PORT=8446 \
H2_PORT=8445 \
HY2_PORT=8443 \
XHTTP_PATH="/$(openssl rand -hex 4)" \
NODE_TAG="node-01" \
bash -c "$(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh)"
```

#### 全量环境变量配置矩阵速查表

| 环境变量 | 适用类型 | 默认值 | 说明与工程建议 |
| :--- | :---: | :---: | :--- |
| `AUTO` | 基础控制 | `0` | 设为 `1` 开启零交互全自动无人值守安装。 |
| `REALITY_DOMAIN` | 核心必填 | — | **直连 / Reality 域名**。Cloudflare 中设为 **仅 DNS（灰色云朵）**。 |
| `CDN_DOMAIN` | 核心必填 | — | **CDN 代理域名**。Cloudflare 中设为 **已代理（橙色小黄云）**。 |
| `IP_CHOICE` | 网络协议 | `1` | `1` 优先 IPv4，`2` 优先 IPv6。 |
| `NODE_TAG` | 节点标识 | `vps` | 节点名称后缀（如 `hk-oracle`、`us-lax`），便于客户端策略组区分。 |
| `FALLBACK_MODE` | 伪装模式 | `proxy` | `proxy`（反代真实高校网站）或 `static`（本地网页）。 |
| `REALITY_FALLBACK_ORIGIN` | 伪装源站 | `https://www.sjsu.edu` | Reality 握手失败/主动探测回落的合法目标网站。 |
| `CDN_FALLBACK_ORIGIN` | 伪装源站 | `https://www.stanford.edu`| CDN 路径未匹配时的伪装目标网站。 |
| `FEATURE_AUTO_TUNING` | 系统优化 | `true` | 自动开启 BBR+fq、64MB Socket 缓冲区、1048576 句柄等系统级调优。 |
| `FEATURE_XPADDING` | 流量混淆 | `true` | 启用 XHTTP 流量填充混淆（`xPaddingObfsMode`），破坏 CDN 侧长度指纹。 |
| `FEATURE_CDN_ECH` | 实验特性 | `false` | Cloudflare ECH 加密 SNI 开关。未在 CF 控制台开启 ECH 时务必保持 `false`。 |
| `FEATURE_H3_DIRECT` | 协议开关 | `true` | 开启直连 HTTP/3 (QUIC) 节点（监听 UDP `H3_PORT`）。 |
| `FEATURE_H2_DIRECT` | 协议开关 | `false` | 开启直连 HTTP/2 (TCP) 节点（监听 TCP `H2_PORT`，默认关闭保持 7 节点）。 |
| `FEATURE_HY2` | 协议开关 | `true` | 开启原生 Hysteria2 + Salamander 混淆节点（监听 UDP `HY2_PORT`）。 |
| `FEATURE_AUTOUPDATE` | 运维管理 | `true` | 开启每周定期自动升级 Xray-core（自检不通过自动回滚）。 |
| `FEATURE_KEEPALIVE` | 进程自愈 | `true` | 开启服务守护进程保活与自动拉起。 |
| `H3_PORT` | 端口定义 | `8446` | HTTP/3 直连 UDP 端口（需云防火墙开放）。 |
| `H2_PORT` | 端口定义 | `8445` | HTTP/2 直连 TCP 端口（需云防火墙开放）。 |
| `HY2_PORT` | 端口定义 | `8443` | Hysteria2 直连 UDP 端口（需云防火墙开放）。 |
| `XHTTP_PATH` | 路由路径 | 随机生成 | XHTTP 请求匹配路径（如 `/4ac061df`）。 |
| `HY2_PASSWORD` | 认证密码 | 自动生成 (SHA256 hex) | Hysteria2 节点连接密码（未指定时自动生成 32 字节 / 64 字符 SHA256 高熵密钥）。 |
| `OBFS_PASSWORD` | 混淆密码 | 自动生成 (SHA256 hex) | Salamander 混淆密码（未指定时自动生成 32 字节 / 64 字符 SHA256 高熵密钥）。 |

---

## 三、常驻管理命令 `xh`

部署完成后，系统已常驻快捷管理工具 `xh`，随时在终端输入即可调出交互菜单：

```bash
xh                     # 进入交互式管理主菜单
xh status              # 查看服务运行状态、监听端口与调优状态
xh info                # 查看节点参数与客户端链接
xh sub                 # 查看/输出订阅链接与订阅二维码
xh resub               # 修改配置后一键重新生成全量订阅
xh tuning [win|mac|sb] # 查看对应系统的客户端千兆调优代码
xh conflict            # sysctl 内核参数冲突检测与一键自愈
xh log [xray|nginx]    # 实时查看服务运行与连接日志
xh update [--auto]     # 一键升级 Xray-core（失败自动回滚）
xh start | stop | restart # 启停与重启服务
```

---

## 四、全平台千兆客户端调优指南

针对 **1000 兆（Gigabit）宽带**，客户端操作系统的默认 TCP 缓冲区会锁死跨国高 BDP 链路的单流下载速度。执行以下调优可跑满千兆线速：

### 1. Windows 10 / 11（管理员 PowerShell）

以管理员身份打开 PowerShell 执行一键联网优化：
```powershell
irm https://reality.example.com/sub/<你的Token>/win.ps1 | iex
```
*(或直接在服务器运行 `xh tuning win` 获取本地离线调优脚本)*

### 2. macOS

打开终端执行一键命令扩容 Socket 接收窗口至 32MB：
```bash
sudo sysctl -w kern.ipc.maxsockbuf=33554432
sudo sysctl -w net.inet.tcp.recvspace=4194304
sudo sysctl -w net.inet.tcp.sendspace=4194304
sudo sysctl -w net.inet.tcp.autorcvbuf=1
sudo sysctl -w net.inet.tcp.autorcvbufmax=33554432
sudo sysctl -w net.inet.tcp.autosndbuf=1
sudo sysctl -w net.inet.tcp.autosndbufmax=33554432
sudo sysctl -w net.inet.tcp.fastopen=3
sudo sysctl -w net.inet.tcp.rfc1323=1
sudo sysctl -w net.inet.tcp.win_scale_factor=8
```

### 3. Linux 客户端

```bash
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.ipv4.tcp_rmem="4096 262144 67108864"
sudo sysctl -w net.ipv4.tcp_wmem="4096 262144 67108864"
sudo sysctl -w net.ipv4.tcp_adv_win_scale=1
sudo sysctl -w net.ipv4.tcp_fastopen=3
```

---

## 五、节点拓扑与双轨架构

安装完成后将提供 **6 条核心全协议节点**，客户端通过 `urltest` 自动分流调度：

```mermaid
flowchart TD
    Client[客户端设备] --> Router{分流调度 / URL-Test}
    
    subgraph 场景 B：极致性能（日常主力 90% 流量）
        Router -->|直连极低延迟| Reality[VLESS-Reality-Vision<br>TCP 443 Splice 零拷贝]
        Router -->|抗丢包大带宽| Hy2[Hysteria 2 / TUIC v5<br>UDP 8443 Brutal 引擎]
        Reality --> VPS[VPS 源站真实 IP]
        Hy2 --> VPS
    end
    
    subgraph 场景 A：安全容灾（备用 / 救砖）
        Router -->|防封锁 / 隐匿源站| XHTTP[VLESS-XHTTP<br>TCP/UDP 443 xmux 多路复用]
        XHTTP --> CF[Cloudflare CDN 优选边缘]
        CF -->|HTTP/2 流式回源| Nginx[Nginx grpc_pass<br>零缓冲直通]
        Nginx --> XrayInbound[Xray 本地 8001 入站]
    end
```

| # | 节点名称 | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-TLS-CF-h3` | XHTTP (QUIC) | 经 CDN 443 | **隐藏真实 IP**，防封锁与救砖 |
| **2** | `VLESS-XHTTP-TLS-QUIC` | XHTTP (QUIC) | 直连 UDP 8446 | 直连 QUIC，`mode=stream-up` |
| **3** | `Hysteria2-QUIC-TLS` | Hysteria 2 | 直连 UDP 8443 | **Brutal 拥塞引擎**，弱网丢包杀手 |
| **4** | `VLESS-TCP-REALITY-Vision` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **5** | `VLESS-XHTTP-REALITY` | XHTTP-Reality | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |
| **6** | `VLESS-XHTTP-Reality-UP-CDN-Down` | 上下行分离 | 上行直连 / 下行 CDN | 兼顾极速上行握手与 CDN 下行大带宽 |

### 六条核心节点实测吞吐

在服务端本机为每条节点单独起一个 SOCKS 入口，**9 轮交替轮询**采样：每轮先测一次不走代理的直连基线，再依次测 6 条核心节点，因此同一轮内所有条目共享同样的上游状态。下载取 `cachefly.cachefly.net/50mb.test`，握手取 `www.gstatic.com/generate_204`。表中为 **9 次采样的中位数（最小–最大）**。

| # | 节点 | 链路 | 下载 MB/s 中位（范围） | 握手 ms 中位（范围） |
| :--- | :--- | :--- | ---: | ---: |
| — | *直连基线（不走代理）* | — | *681.6（277.8–714.2）* | *23（21–26）* |
| **1** | `VLESS-XHTTP-TLS-CF-h3` | 经 CDN 443/UDP | 57.8（35.3–80.2） | 217（88–643） |
| **2** | `VLESS-XHTTP-TLS-QUIC` | 直连 8446/UDP | 59.3（45.2–67.1） | 25（23–36） |
| **3** | `Hysteria2-QUIC-TLS` | 直连 8443/UDP | 32.2（28.8–43.6） | 26（23–66） |
| **4** | `VLESS-TCP-REALITY-Vision` | 直连 443/TCP | **374.1（285.2–432.2）** | 26（25–33） |
| **5** | `VLESS-XHTTP-REALITY` | 直连 443/TCP | 97.5（91.0–134.4） | 25（23–65） |
| **6** | `VLESS-XHTTP-Reality-UP-CDN-Down` | 上行直连 / 下行 CDN | 99.6（88.9–111.1） | 25（24–30） |

怎么读这张表：

- **测的是服务端侧的协议栈开销，不是你的实际网速。** 客户端跑在 VPS 本机、经公网 IP 回环，不含最后一公里。直连基线 681.6 MB/s 说明上游几乎不构成瓶颈，因此各节点的差距基本可归因于协议栈本身——但这也意味着**表里没有任何一个数字是你在真实跨境链路上能跑到的**。
- **必须看范围，不能只看中位数。** 早期用单次采样、且测速源本身抖动到数倍时，节点间的排名完全是噪声。换成快速稳定的源并取 9 次中位数后结论才立得住；即便如此，1 号 CDN 节点的握手仍在 79–821 ms 之间大幅波动——那是 Cloudflare 选边缘的结果，不是服务端的抖动。
- **4 号 Reality-Vision 一骑绝尘（374 MB/s，约为直连基线的 55%）**，与 `xtls-rprx-vision` 走 Splice 零拷贝、数据不经用户态搬运的设计相符，是全部核心节点里唯一达到这个量级的。
- **3 号 Hysteria 2 是最慢也最稳的一档**（32.2 MB/s，波动最小）。瓶颈在协议自身的拥塞控制与用户态包处理，而非链路——同机直连有 681 MB/s 可作对照。它的价值在弱网丢包场景，本测试环境（零丢包）恰好是它最不占优的场景。
- **5 与 6 中位数几乎相同**（97.5 / 99.6）。上下行分离的收益在本机回环里体现不出来——下行走 CDN 那半段在这里没有任何优势，要在真实跨境链路上才有意义。

复现方法与自检命令见 `xh diag`；若某条节点在客户端不通而本机自测正常，问题在该设备到 VPS 的网络路径，而非服务端配置。


---

## 六、常见问题与排错

### 1. Reality 三条节点全都不通 / 提示认证失败？
Reality 节点的认证在服务端会被记录为 `authentication failed or validation criteria not met`，常见原因及排查方法如下：
- **① 客户端系统时间偏差 > 30 秒（最常见）**：Reality 握手带有时间戳防重放校验。若手机/电脑系统时间与标准网络时间相差 30 秒以上，服务端会直接拒绝连接。**解决方法：在客户端设备设置中开启「自动从网络同步时间」**。
- **② 客户端 Public Key (公钥) 或 ShortId 不匹配**：若服务端重新生成过配置，旧节点链接中的公钥失效。**解决方法：在 VPS 运行 `xh info` 或 `xh sub`，重新复制/导入最新节点链接**。
- **③ 客户端内核对 XHTTP+Reality 及 ML-KEM-768 加密支持不足（节点 5 / 节点 6）**：`Vless-xhttp-reality` 节点采用了后量子加密算法，部分旧版 Clash/Mihomo/Shadowrocket 客户端内核不支持会导致握手 EOF。**建议：Clash 系客户端优先选用 `VLESS-TCP-REALITY-Vision` 标准节点；全协议节点推荐配合最新版 Xray-core (≥ 24.11 / 26.x) 客户端使用**。
- **④ SNI 误填为 CDN 域名**：Reality 的 SNI 必须填写直连域名（`REALITY_DOMAIN`），误填 CDN 域名会导致服务端报 `server name mismatch` 并拒绝连接。
- **⑤ 域名开启了 Cloudflare 代理（小黄云）**：Reality 是纯 TCP 直连伪装协议，`REALITY_DOMAIN` **必须在 Cloudflare 设置为仅 DNS（灰色云朵）**。

> **关于 `minClientVer` 的提示**：为兼容 mihomo/sing-box 等非 Xray 内核，本项目把 Reality
> 的 `minClientVer` 从 26.x 新默认值 `v26.3.27` 放宽到了 `1.8.0`。这是一个真实的权衡：
> 执行 `xray run -test` 时内核会警告此举「会增加服务器 IP 被 GFW 封锁的可能性」，因为
> 放宽后 Reality 对更旧、非 Xray 的客户端也开放握手，扩大了主动探测的暴露面。若你主要
> 使用 v2rayN（Xray 内核），删掉这一行更安全；若要兼容 Clash 系客户端，则需要保留。

### 2. 直连 UDP / Hysteria 2 节点超时？
- **原因**：云服务商（如 Oracle Cloud、AWS、阿里云、腾讯云）默认带有外部**安全组防火墙**。
- **解决**：在云服务商控制台的安全组规则中，放行入站端口：
  - **UDP 8443** (Hysteria 2)
  - **UDP 8446** (XHTTP QUIC)
  - **TCP 8445** (XHTTP TCP，仅当开启 `FEATURE_H2_DIRECT=true` 时需要)
  - **TCP 443** 与 **TCP 80**

### 3. 如何检测服务器内核配置冲突？
- 终端运行 `xh conflict`，脚本会自动检测 `/etc/sysctl.d/` 下所有第三方冲突文件并提示自愈修复。

---

## 七、v4.8.x 实测诊断与修复记录

本节记录一次在 **Oracle ARM (4 核 24G) / Ubuntu 26.04 / kernel 7.0** 上、对同机共存的
xray-xhttp 与 sbbox 两套节点做的完整诊断。**每一条都有实测数据支撑，包括三条"测了但不采纳"的结论。**

### 1.〔严重〕端口跳跃段会劫持同机其他 UDP 服务端口

**现象**：同机另一套脚本的 Hysteria2 节点，链接里的基础端口 `44116` 完全连不上（客户端报
`connect error: timeout: no recent network activity`），但同一节点的跳跃段端口能正常连；
**被劫持方的服务端日志里没有任何记录**，常规排查手段全部失效。

**根因**：端口跳跃依赖 nat 表的**端口段**规则。本项目节点链接里建议的跳跃段是
`mport=${HY2_PORT},40000-50000`，对应规则为

```
-A PREROUTING -p udp --dport 40000:50000 -j REDIRECT --to-ports 8443
```

这条规则按**范围**匹配，会把落在 40000-50000 内的**任何**本机 UDP 端口一并改写。
另一套脚本随机分到的基础端口 44116 正好落在段内，于是所有直连 44116 的包被投递给
本项目的 8443 实例；两边 obfs 密码不同，握手包被当作垃圾**静默丢弃**——既不报错也不落日志。

**验证方法**（用另一实例的凭据去连被劫持的端口，若能连通即证明劫持成立）：

```bash
# 用 8443 实例的密码连 44116 —— 若返回 200，说明包确实被改写投递到了 8443
hysteria client -c <(printf 'server: <IP>:44116\nauth: <8443实例的密码>\nobfs: {type: salamander, salamander: {password: <8443实例的obfs>}}\ntls: {sni: <域名>}\nsocks5: {listen: 127.0.0.1:10871}\n') &
curl -s --socks5-hostname 127.0.0.1:10871 -o /dev/null -w '%{http_code}\n' https://www.cloudflare.com/cdn-cgi/trace
```

实测结果：返回 `200`，且 **8443 实例**的日志出现 `client connected`，被劫持的 44116 实例日志为空 —— 劫持确认。

**修复**：新增 `xh diag` 中的 **UDP 端口段劫持检测**（`cmd_portconflict`），自动列出被劫持的服务端口并给出修复命令：

```bash
xh diag        # 输出示例：
#   [!!]   UDP 44116 落在端口段 40000-50000 内（该段被导向 8443）
#          修复：iptables -t nat -I PREROUTING 1 -p udp --dport 44116 -j RETURN
```

修复原理是在所有端口段规则**之前**插一条 `RETURN` 例外，使直连基础端口的包不被改写。
该检测只统计**真实服务端口**（在 INPUT 链有显式单端口 ACCEPT 规则的），不会把代理进程的
临时出站 UDP socket 误报进来；已插入 RETURN 例外的端口不再重复报警。

> **同机共存多套代理脚本时，这是最容易踩且最难排查的一类故障。** 任何使用端口跳跃的脚本都有这个问题。

### 2.〔实测后撤回〕REALITY 回落限速（`limitFallback*`）——**会掐断全部 CDN 节点**

v4.8.0 / v4.8.1 引入了这项，理由是「未通过 Reality 认证的连接会回落到伪装站，
不限速等于给主动探测者提供免费高速代理」。**这个理由在本项目的架构下是错的，
该配置会让所有经 CDN 的节点瘫痪。v4.8.2 已移除。**

原因在于本项目的端口分工：

| 端口 | 归属 |
| :--- | :--- |
| 443 | **Xray 的 REALITY 入站** |
| 8003 | nginx（REALITY 的 `target`，同时承载 `/path` → `grpc_pass` → Xray 8001） |

Cloudflare 回源走的是源站 **443**，而 CF 不是 REALITY 客户端 —— 于是它的 TLS 握手
认证失败，被 REALITY **回落**到 `127.0.0.1:8003` 的 nginx，再由 nginx 的
`grpc_pass` 转给 Xray 8001。也就是说：

> **在这套架构里，REALITY 的「回落」不是探测诱饵，而是全部 CDN 节点的生产数据通路。**
> 探测流量与合法 CDN 回源流量在这一层完全同形，无法区分。

给回落限速 = 给所有 CDN 节点限速。按 `afterBytes: 10MB / bytesPerSec: 1MB/s` 计算，
一个 100MB 下载需要约 90 秒，客户端普遍会先超时。

实测（同一台机器，`cachefly` 100MB，各 3 次，丢弃重启后的首次请求）：

| 配置 | 成功 | 吞吐 |
| :--- | :--- | ---: |
| 不带 `limitFallback`（基线） | 3/3 | 808 Mbps |
| **带 `limitFallback`** | **0/3** | **0（超时）** |
| 仅 `targetStrategy` + `finalRules` | 3/3 | 正常（无辜） |

移除后全部 7 条节点复测：

| 节点 | 吞吐 |
| :--- | ---: |
| `Vless-xhttp-h2-cdn` | 909 Mbps |
| `Vless-xhttp-h3-cdn` | 654 Mbps |
| `Vless-reality-vision` | 2837 Mbps |
| `Vless-xhttp-reality` | 755 Mbps |
| `Vless-xhttp-reality-up-cdn-down` | 832 Mbps |

**排查经验**：症状是 CDN 节点「能连上、握手正常、小请求返回 200，但大文件传 0 字节」，
nginx 报 `upstream rejected request with error 5`。若你自建的架构也是「REALITY 占 443 +
CDN 回源到 443」，就不要给回落加任何限速。

### 3. 直连 h3 / h2 入站启用 `rejectUnknownSni`

此前 8446 / 8445 入站接受任意 SNI，可被当作任意 SNI 的 TLS 前置来探测。现改为只接受证书覆盖的域名，
未知 SNI 直接拒绝握手，行为更接近真实站点。

### 4. `freedom` 出站新增 `finalRules` 私有地址兜底

`routing.domainStrategy` 为 `AsIs` 时，路由层的 `ip: geoip:private` 规则拿不到域名的解析结果。
新增的 `finalRules` 在**解析成 IP 之后**再判一次，与路由规则互补：

```json
"targetStrategy": "UseIPv4",
"finalRules": [ { "action": "block", "ip": ["geoip:private"] } ]
```

> 实测本项目 Reality 节点在**加固前**就已能拦住 `http://127.0.0.1.nip.io/`（返回被阻断），
> 该项属于纵深防御加固，而非修复已存在的漏洞。（同机 sbbox 侧则确实存在此绕过，见该项目 README。）

### 5. 日志级别 `info` → `warning`

`info` 会为每条连接落一行、且包含目标域名，实测 24 小时约 2260 行——既是磁盘噪音，也等于在服务器上留了一份用户访问记录。

### 6.〔修正误报〕`xh diag` 对独立 hysteria 二进制的判断

旧逻辑只要发现 `/etc/hysteria/config.yaml` 存在就报 `[!!]`，并建议
`systemctl disable --now hysteria-server`。**这个建议在部分机器上会直接打掉一条正在用的节点。**

原因：本项目的 Hysteria2 可由 Xray 原生 inbound（`"protocol": "hysteria"`）提供，但该 inbound
在安装时**未取得 acme 证书就会被自动跳过**（见 `src/09-server-config.sh` 中 `FEATURE_HY2=false` 的回退分支）。
此时 hy2 节点其实由独立 hysteria 二进制唯一提供，停掉它节点立刻失效。

新逻辑先看 xray 配置里到底有没有原生 hy2 inbound，再决定怎么报：

| xray 原生 hy2 | 独立二进制端口 | 判定 |
| :--- | :--- | :--- |
| 无 | 任意 | `[OK]` 独立二进制是唯一提供者，**明确提示不要停用** |
| 有，同端口 | 与之相同 | `[!!]` 真冲突，二选一 |
| 有，不同端口 | 与之不同 | `[OK]` 冗余但不冲突 |

### 7.〔实测后不采纳〕REALITY 后量子签名 `mldsa65Seed`

Xray 26.7.28 的 REALITY 支持 ML-DSA-65 后量子签名（`xray mldsa65` 生成密钥对）。**实测在本环境下会直接破坏 REALITY 握手**：

| 服务端 `mldsa65Seed` | 客户端 `mldsa65Verify` | 节点连通性 |
| :--- | :--- | :--- |
| 未设置 | 未设置 | ✅ 200 |
| **已设置** | 未设置 | ❌ 000（TLS 阶段 connection reset） |
| **已设置** | **已设置** | ❌ 000 |
| 未设置 + 仅 `limitFallback` | — | ✅ 200 |

二分定位确认元凶是 `mldsa65Seed`（`limitFallback` 无影响）。配置本身能通过 `xray run -test` 校验，
故判断为 26.7.28（预发布版）自身问题。**本版不启用**，待上游稳定后再评估。

### 8.〔实测后不采纳〕把 MTU 从 9000 降到 1500

Oracle Cloud 的 VNIC 默认 MTU 9000，而到公网的实际 PMTU 是 1500（`ping -M do -s 8972` 失败、`-s 1472` 成功），
一度怀疑会造成额外重传。**实测恰好相反**（Reality 节点，取 3 次最好值）：

| MTU | 吞吐 |
| :--- | ---: |
| **9000（默认）** | **3755 Mbps** |
| 1500 | 2991 Mbps |

对端通告的 MSS（通常 1460）本来就会把实际分段限制住，巨帧 MTU 在此几乎不生效；反而是本机内部路径受益。**保持 9000 不动。**

### 9. `minClientVer` 的既有权衡（未改动）

`xray run -test` 会为 `"minClientVer": "1.8.0"` 打印警告：

```
REALITY: Changing "minClientVer" will increase the likelihood of your server's IP being blocked by the GFW
```

这是上游明确的取舍提示：放宽后 Reality 对更旧、非 Xray 的客户端也开放握手，主动探测的暴露面变大。
本项目为兼容 Clash / mihomo / sing-box 三种内核而保留该设置；**若你只用 v2rayN（Xray 内核），删掉这行更安全。**

### 10.〔实测后不采纳〕REALITY 节点的进一步提速

对 `Vless-reality-vision` 做了一轮定向测量，结论是**它已经没有可调空间**，
本版未对该节点做任何性能改动。数据如下。

**单流已与直连持平**（`cachefly` 100MB）：

| 路径 | 单流吞吐 |
| :--- | ---: |
| 不走代理（直连） | 2267 Mbps |
| **经 REALITY-Vision** | **2204 Mbps** |

差距约 3%，与 `xtls-rprx-vision` 走 splice 零拷贝、数据不经用户态搬运的设计相符。

**并发上限是测试拓扑的限制，不是协议的。** 同时观测应用层吞吐与网卡实际吞吐：

| 场景 | 应用层 | 网卡实际 | 倍率 |
| :--- | ---: | ---: | ---: |
| 直连 ×4 | — | 7826 Mbps | — |
| REALITY ×4 | 2727 Mbps | 5009 Mbps | 1.8× |
| REALITY ×8 | 2686 Mbps | 6700 Mbps | 2.5× |

经代理时每个字节要多次穿过同一张网卡（客户端→服务端走公网 IP 发夹进出、
服务端→外网再一进一出）。REALITY ×8 时网卡已跑到 6700 Mbps，占观测上限
7826 Mbps 的 **86%** —— 瓶颈是这张网卡，不是 REALITY。真实远端客户端不存在这段发夹。

**CPU 也不是瓶颈**：持续加压时四个核分别为 36.3% / 31.7% / 28.9% / 28.0%，
分布均匀且远未饱和。

**`policy.bufferSize` 实测无效**（reality 单流，各取 3 次最好值）：

| bufferSize | 吞吐 |
| :--- | ---: |
| 512 | 3377 Mbps |
| 2048 | 3799 Mbps |
| 4096（默认） | 3234 Mbps |
| 8192 | 3549 Mbps |

**非单调、无规律，是运行间噪声而非效应**，因此保持默认 4096 不动。
（注意这组数字整体高于上面的单流表——同一配置不同时段可差 50%，
这也说明单次测量在本环境下不足以支撑结论。）

### 11. 两个不要碰的地方

- **不要给 REALITY 回落限速**（`limitFallback*`）。理由见本节第 2 条：
  在本架构里回落是全部 CDN 节点的生产通路。
- **不要给 REALITY 开 `xver`**（PROXY protocol）。443 回落到的是 nginx 8003，
  而模板里 8003 的 `listen` 没有 `proxy_protocol` 参数；开了 `xver` 而不同步改
  nginx，nginx 会把 PROXY 头当成 HTTP 请求，同样打掉全部 CDN 节点。

### 12. 关于本机回环测速的口径（重要）

在服务端本机经公网 IP 回环测速时，**UDP 会额外经过云厂商的发夹（hairpin）路径，吞吐大约减半**，
而 TCP 不受同等影响。实测裸 UDP：

| 路径 | 裸 UDP 吞吐 |
| :--- | ---: |
| 纯 loopback（127.0.0.1） | 1189 Mbps |
| 经公网 IP 发夹 | 603 Mbps |

同一 Hysteria2 实例：loopback 593 Mbps vs 发夹 312 Mbps；TUIC：1490 vs 748 Mbps。
**因此本机自测出的 QUIC 类节点数字系统性偏低，不能据此判断"UDP 节点比 TCP 节点慢"**——
要比较协议本身，必须固定在同一条路径上比。

---

## 八、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
