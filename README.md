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
- [八、v4.9.0 握手提速与「全部采用最新特性」](#八v490-握手提速与全部采用最新特性)
- [九、v4.9.1 CDN 延迟归因与 ECN](#九v491-cdn-延迟归因与-ecn)
- [十、v4.9.2 换上 BBRv3 内核，与 tcp-brutal 的新内核 ABI 修复](#十v492-换上-bbrv3-内核与-tcp-brutal-的新内核-abi-修复)
- [十一、v4.9.4 BBRv3 上的 25 样本回归基线](#十一v494-bbrv3-上的-25-样本回归基线)
- [十二、v4.9.5 large 档 tcp_rmem/tcp_wmem 上限补齐到 64MB](#十二v495-large-档-tcp_rmemtcp_wmem-上限补齐到-64mb)
- [十三、v4.9.6 MTU 全线回到 1500](#十三v496-mtu-全线回到-1500)
- [十四、免责声明](#十四免责声明)

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
| `FEATURE_BRUTAL` | 拥塞控制 | `true` | 开启 TCP Brutal (HyNetworks/tcp-brutal) 极速拥塞控制。 |
| `BRUTAL_DEFAULT_MBPS` | 默认带宽 | `auto` (95% 本机速率) | TCP Brutal 默认全局下发速率（Mbps，留空或 `auto` 则自动探测本机/网卡最大速率并设为其 95%）。 |
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
xh brutal              # TCP Brutal 极速拥塞控制状态、开启/关闭与速率调节
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
- **③-a 节点 7 `Vless-xhttp-reality-up-cdn-down` 在 mihomo 上必然报 REALITY 认证失败**：这不是配置错误，是 mihomo 不支持「REALITY 父级 + `download-settings`」组合（实测 v1.19.30，详见第七节第 14 条）。自 v4.8.9 起该节点默认不再下发给 mihomo，Clash 系用户改用节点 6 即可。**v2rayN / Xray-core 客户端不受影响。**
- **③ 客户端内核对 XHTTP+Reality 及 ML-KEM-768 加密支持不足（节点 5 / 节点 6）**：`Vless-xhttp-reality` 节点采用了后量子加密算法，部分旧版 Clash/Mihomo/Shadowrocket 客户端内核不支持会导致握手 EOF。**建议：Clash 系客户端优先选用 `VLESS-TCP-REALITY-Vision` 标准节点；全协议节点推荐配合最新版 Xray-core (≥ 24.11 / 26.x) 客户端使用**。
- **④ SNI 误填为 CDN 域名**：Reality 的 SNI 必须填写直连域名（`REALITY_DOMAIN`），误填 CDN 域名会导致服务端报 `server name mismatch` 并拒绝连接。
- **⑤ 域名开启了 Cloudflare 代理（小黄云）**：Reality 是纯 TCP 直连伪装协议，`REALITY_DOMAIN` **必须在 Cloudflare 设置为仅 DNS（灰色云朵）**。

> **关于 `minClientVer`（v4.9.0 起已移除）**：本项目曾把 Reality 的 `minClientVer`
> 从 26.x 新默认值 `v26.3.27` 放宽到 `1.8.0` 以兼容 mihomo/sing-box 等非 Xray 内核。
> 自 v4.9.0 起该行**已删除**，改为采用当前 Xray 版本的默认最低客户端版本——
> 代价是 **mihomo / Clash 系客户端在两条 Reality 节点上会报 `REALITY authentication failed`**，
> 换来的是不再向更旧、非 Xray 的实现开放握手，`xray run -test` 那句
> 「会增加服务器 IP 被 GFW 封锁的可能性」的警告也随之消失。
> **要兼容 Clash 系客户端**：在 `/usr/local/etc/xray/config.json` 的 `realitySettings`
> 里把 `"minClientVer": "1.8.0"` 加回去（注意给上一行的 `shortIds` 数组补回逗号），
> 然后 `xray run -test -c /usr/local/etc/xray/config.json && systemctl restart xray`。

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

### 9.〔v4.9.0 变更〕移除 `minClientVer`，回到内核默认

v4.8.x 及之前，Reality 入站带 `"minClientVer": "1.8.0"`，`xray run -test` 会为此打印：

```
REALITY: Changing "minClientVer" will increase the likelihood of your server's IP being blocked by the GFW
```

自 v4.9.0 起该行已删除。删除后同一条命令改打印：

```
REALITY: The default minimal client version is Xray-core v26.3.27, other clients may be refused to connect
```

**验证命令**（在服务器上跑）：

```bash
grep -c minClientVer /usr/local/etc/xray/config.json   # 期望 0（注释里的说明不计，见下一条）
xray run -test -c /usr/local/etc/xray/config.json 2>&1 | grep REALITY
```

**这是一个真实的取舍，两边都要写清楚**：

| | `minClientVer: 1.8.0`（v4.8.x） | 删除（v4.9.0，当前） |
|---|---|---|
| Xray-core / v2rayN 客户端 | 可用 | 可用 |
| mihomo / Clash 系客户端 | 可用 | **握手报 `REALITY authentication failed`，两条 Reality 节点不可用** |
| 主动探测暴露面 | 向更旧、非 Xray 实现开放握手 | 回到内核默认 |
| `xray run -test` | 打印 GFW 封 IP 风险警告 | 无该警告 |

要改回兼容 Clash 系客户端，见第六节第 1 条末尾的还原步骤。

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

### 11.〔严重·定时炸弹〕证书续期后 `/etc/ssl/private/` 可能不会更新

本项目的 **xray 8446（h3-direct）**、**独立 hysteria 8443**、**nginx 8003（CDN 回源 + 伪装站）**
三者都直接读 `/etc/ssl/private/` 下的证书**副本**，而不是 acme.sh 自己的目录。
这份副本靠安装时配置的 `acme.sh --install-cert --key-file/--fullchain-file` 在每次续期后自动更新，
路径记在域名配置的 `Le_RealKeyPath` / `Le_RealFullChainPath` 里。

**这两个值一旦被清空，就是一颗一个月后引爆的定时炸弹。**

真实事故：同机另一套脚本执行 `acme.sh --install-cert` 时**只传了 `--reloadcmd`**。
acme.sh 的 `--install-cert` 会**重写整组部署配置** —— 只给 reloadcmd 时，
`Le_RealKeyPath` / `Le_RealFullChainPath` / `Le_RealCertPath` 会被一并清空。之后：

```
续期日   acme 照常续期到 ~/.acme.sh/，reloadcmd 照常重启 nginx/xray
         → 但它们重新加载的还是那份从未被更新过的旧文件
旧证书
到期日   h3-direct / hy2 / 全部 CDN 节点同时失效
```

**隐蔽性极高**：续期成功、服务重启成功、日志无任何异常，问题要到一个月后才发作。
REALITY 节点不受影响（用自签公钥，不读这份证书），所以表现是「一部分节点突然全断，另一部分好好的」。

**本版新增 `xh diag` 三项证书续期自检**：

```
[OK]   acme 证书落地路径已配置（/etc/ssl/private/fullchain.cer）
[OK]   已部署证书与 acme 源一致
[OK]   acme reloadcmd 覆盖了全部读证书的服务
```

分别检查：落地路径是否配置且指向本项目实际使用的位置；已部署副本与 acme 源的**叶证书指纹**
是否一致（不一致 = 续期后没落地）；`reloadcmd` 是否覆盖了所有读这份证书的服务
（nginx / xray，以及本机确实在跑独立 hysteria 时的 `hysteria-server`）。

路径被清空时的输出，附带可直接粘贴的修复命令：

```
[!!]   acme 未配置证书落地路径（Le_RealFullChainPath/Le_RealKeyPath 为空）
       — 续期后 /etc/ssl/private/ 不会更新，旧证书到期时 h3-direct/hy2/CDN 节点会同时失效。
       修复: acme.sh --install-cert -d <域名> --ecc \
             --key-file /etc/ssl/private/private.key \
             --fullchain-file /etc/ssl/private/fullchain.cer \
             --reloadcmd '<原有 reloadcmd>'
```

**同时修复安装脚本的 `reloadcmd` 漏掉独立 hysteria**：本项目默认由 Xray 原生提供 Hysteria2
（安装时会停用 `hysteria-server`），此时无需重启它；但装在已有独立 hysteria 的机器上时，
8443 由该二进制提供服务、同样读 `/etc/ssl/private/`，续期后不重启会一直用旧证书。
现改为**有条件重启**（`is-active` 判断），避免在没有该服务的机器上让整条 reloadcmd 返回非零。

> **手工自查**（不装本版也能用）：
> ```bash
> ym=<你的 Reality 域名>
> grep -E "Le_Real(Key|FullChain)Path" ~/.acme.sh/${ym}_ecc/${ym}.conf
> # 两者都应非空且指向 /etc/ssl/private/
> ```

### 12. 两个不要碰的地方

- **不要给 REALITY 回落限速**（`limitFallback*`）。理由见本节第 2 条：
  在本架构里回落是全部 CDN 节点的生产通路。
- **不要给 REALITY 开 `xver`**（PROXY protocol）。443 回落到的是 nginx 8003，
  而模板里 8003 的 `listen` 没有 `proxy_protocol` 参数；开了 `xver` 而不同步改
  nginx，nginx 会把 PROXY 头当成 HTTP 请求，同样打掉全部 CDN 节点。

### 13. 关于本机回环测速的口径（重要）

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

### 14.〔严重·客户端兼容〕节点 7 上下行分离在 mihomo 上 100% 连不上

**现象**：`Vless-xhttp-reality-up-cdn-down` 在 v2rayN / Xray-core 上完全正常，
在 Clash 系（mihomo）上却每次都失败，mihomo 日志：

```
[TCP] dial Vless-xhttp-reality-up-cdn-down-... --> www.gstatic.com:80
      error: 192.9.145.231:443 connect error: REALITY authentication failed
```

注意报错地址是 **`:443`——上行那条直连腿**，不是 CDN 下行腿。也就是说
加了 `download-settings` 之后，连原本好好的 REALITY 握手都一起废了。

**Xray-core 侧对照（同一条分享链接原样还原成 Xray JSON）**：

| 指标 | 结果 |
| :--- | ---: |
| `generate_204` 握手 | 72 ms |
| cachefly 100MB × 3 | 90.4 / 103.3 / 112.2 MB/s（723–898 Mbps） |
| 日志报错 | 无 |

**mihomo v1.19.30 逐项二分**（每个变体只改一处，其余完全相同）：

| 变体 | 结果 |
| :--- | :--- |
| A 原样下发 | **FAIL** REALITY authentication failed |
| B 删掉 `download-settings` | **PASS**（即退化成节点 6） |
| C `download-settings.servername` 改成 REALITY 域名 | FAIL |
| D `download-settings` 去掉 `client-fingerprint` | FAIL |
| E `download-settings` 补上父级的 `reality-opts` | FAIL |
| F 父级 `encryption` 换成 `none`（排除后量子加密嫌疑） | FAIL |
| G `download-settings` 去掉 `alpn` | FAIL |

**关键对照——换个非 REALITY 的父级**：

| 变体 | 结果 |
| :--- | :--- |
| H `h3-direct`（QUIC/TLS 父级）+ CDN 下行 | FAIL（context deadline exceeded） |
| I `h2-cdn`（TCP/TLS 父级）+ CDN 下行 | **PASS** |
| J `h3-direct` 原样（对照组） | PASS |

**根因**：mihomo 支持 `xhttp-opts.download-settings` 本身（变体 I 通过），
但**不能与 REALITY 父级并用**——变体 F 证明与后量子加密无关，
变体 C/D/E/G 证明不是 `download-settings` 内部字段填错。
这是 mihomo 侧的实现限制，服务端无从修复。

**修复方式**：新增 `FEATURE_UP_CDN_DOWN_MIHOMO`，**默认 `false`**，
mihomo 配置里不再下发这条节点（沿用既有的 `#<<FEATURE_X ... #>>FEATURE_X`
裁剪机制，`mihomo-nodes.yaml` 与 `mihomo-full.yaml` 一起处理）。
留着它不是"多一个选择"，而是一条**永远连不上的死节点**，
还会被 `include-all: true` 的择优组反复探测拖慢切换。
Clash 系用户本来就有节点 6（REALITY 直连）与节点 1（CDN），功能不缺。

**v2rayN / Xray-core 的 URI 订阅不受影响，始终包含该节点。**
确有需要（例如自建 mihomo 打了补丁）时 `FEATURE_UP_CDN_DOWN_MIHOMO=true` 打开。

**修复后实测**（mihomo v1.19.30 逐节点起独立 mixed 入口）：

```
Vless-xhttp-h2-cdn           PASS
Vless-xhttp-h3-cdn           PASS
Vless-xhttp-h3-direct        PASS
Hysteria2-obfs               PASS
Vless-reality-vision         PASS
Vless-xhttp-reality          PASS
mihomo 日志 error 计数：0
```

### 15.〔客户端兼容矩阵〕七条节点各自需要什么内核

上一条引出的普遍问题：**同一份订阅发给不同内核，能用的节点并不一样**。
下表是实测（Xray-core 26.7.28 / mihomo v1.19.30）与协议支持面的汇总：

| # | 节点 | Xray-core | mihomo | sing-box / Shadowrocket / NekoBox |
| :--- | :--- | :---: | :---: | :---: |
| 1 | `Vless-xhttp-h2-cdn` | ✅ | ✅ | ❌ 无 XHTTP |
| 2 | `Vless-xhttp-h3-cdn` | ✅ | ✅ | ❌ 无 XHTTP |
| 3 | `Vless-xhttp-h3-direct` | ✅ | ✅ | ❌ 无 XHTTP |
| 4 | `Hysteria2-obfs` | ✅ | ✅ | ✅ |
| 5 | `Vless-reality-vision` | ✅ | ✅ | ✅ |
| 6 | `Vless-xhttp-reality` | ✅ | ✅ | ❌ 无 XHTTP |
| 7 | `Vless-xhttp-reality-up-cdn-down` | ✅ | ❌ **REALITY + download-settings 冲突** | ❌ 无 downloadSettings |

怎么用这张表：

- **只有节点 4（Hysteria2）与节点 5（Reality-Vision）是全内核通吃的。**
  给 sing-box / Shadowrocket / NekoBox 用户就发这两条，其余 XHTTP 节点它们的内核根本不认。
- **Clash 系（mihomo）能用 1–6，唯独 7 不行**，这正是 v4.8.9 默认不下发的原因。
- **想要全部 7 条，客户端必须是 Xray-core 内核**（v2rayN、onexray 等，建议 ≥ 26.x）。
- 表里的 ❌「无 XHTTP」是内核层面不实现该传输，不是配置问题，**服务端改不了**。


### 16.〔静默失效〕`xh tuning on` 的 systemd drop-in 有两处不生效

一次例行体检里发现，`xh tuning on` 写出的 drop-in **两条路径都没真正生效**，
且都不报错——机器看起来"已调优"，实际参数从未加载。

**A. `GOMAXPROCS` 落盘的是未展开的字面量**

drop-in 实际内容：

```ini
Environment="GOMAXPROCS=${CPU_CORES}"     # ← 字面量，不是核心数
```

根因是生成它的 heredoc 用了**带引号的定界符**，引号会关闭变量展开：

```bash
cat > "${dir}/${dropin}" <<'DROPINEOF'    # ← 'DROPINEOF' 带引号 = 不展开
```

这个 bug 一直没被发现，是因为**后果恰好与预期重合**：Go 运行时解析不了非法的
`GOMAXPROCS` 就直接忽略它，回退到 `NumCPU()`，而这正是本来想设的值。
但它掩盖了同一份文件里 `GOGC` / `GODEBUG` 是否生效的问题，见 B。

**B. 写完 drop-in 只做了 `daemon-reload`，从不重启服务**

`daemon-reload` 只让 systemd 重读单元文件；`LimitNOFILE` 与 `Environment`
是 fork/exec 时读取一次的量，**对已在运行的进程一律不生效**。
于是 drop-in 写入后，在下一次服务重启之前完全是摆设。

实测：本机 drop-in 写于 `12:29`，而 `hysteria-server` 进程启动于 `11:08`——
中间没有重启，进程环境里 `GOGC` / `GOMAXPROCS` / `GODEBUG` 一个都没有。

**验证方法**（对着**运行中**的进程查，不要查文件）：

```bash
# 1. 看落盘的 drop-in 里是不是字面量
grep GOMAXPROCS /etc/systemd/system/hysteria-server.service.d/10-xray-xhttp.conf

# 2. 看运行中进程真正拿到的环境（空 = 未生效）
PID=$(systemctl show hysteria-server -p MainPID --value)
tr '\0' '\n' < /proc/$PID/environ | grep -E 'GOGC|GOMAXPROCS|GODEBUG'
grep 'Max open files' /proc/$PID/limits
```

修复前后对比：

```
修复前： tr ... | grep -E 'GOGC|GOMAXPROCS|GODEBUG'   →  （空）
修复后： GOGC=200 / GOMAXPROCS=4 / GODEBUG=madvdontneed=1
        Max open files  1048576  1048576
```

**修复**：

1. 生成 drop-in 的 heredoc 去掉定界符引号（该块内无其他 `$`，展开是安全的）：
   `<<'DROPINEOF'` → `<<DROPINEOF`。
2. 写完 drop-in 后**显式提示需要重启**，而不是静默 `daemon-reload` 了事：

   ```
   [!] 上述 drop-in 对已运行的进程不生效，需重启后才应用：
       systemctl restart xray nginx hysteria-server sing-box
   ```

**为什么不在脚本里直接重启**：`xh tuning on` 可能在任意时刻被执行，
自动重启会无预警掐断全部在线连接。句柄上限和 GC 参数都不是救火项，
晚几小时到下次维护窗口才生效并无损失，**由用户挑时机**比脚本自作主张更合适。


### 17.〔架构〕BBR 与 Brutal 如何共存，以及一条路由锁如何毁掉它

常见疑问："能不能 BBR 和 Brutal 一起用？"

先说硬约束：**一条 TCP 连接只能用一种拥塞控制**，两者无法在同一条流上混合。
所谓共存只能是**按连接分流**——本项目与 sbbox 同机共存时，实际结构是这样的：

| 节点 / 入站 | CC 来源 | 实际用的 |
| :--- | :--- | :--- |
| Xray 三个入站（xhttp / reality） | `sockopt.tcpcongestion=brutal` | **Brutal** |
| sing-box vless-reality | 未设，跟内核默认 | **BBR** |
| sing-box naive | 未设，跟内核默认 | **BBR** |
| Hysteria2 | QUIC 用户态自带 brutal | 用户态，**不碰内核 TCP CC** |
| TUIC | `congestion_control: bbr` | QUIC 用户态 BBR |

TCP 侧靠 `sockopt` 逐 socket 指定、内核默认 `bbr` 兜底；QUIC 侧（hy2 / tuic）在用户态
自己实现拥塞控制，**与内核 TCP CC 完全无关**。所以"要极速切 Brutal 节点、要稳切 BBR 节点"
这套分工是天然成立的，不需要额外配置。

**毁掉它的是路由级 `congctl lock`。** `brutalctl add <prefix> <rate>` 除了设速率，
还会装一条路由：

```
120.235.161.48 via 10.0.0.1 dev enp0s6 proto 233 congctl lock brutal
```

路由锁按**目的地**生效，优先级压过入站的 sockopt 分工。后果是发往该 IP 的**所有** TCP
连接都被拽进 brutal 定速——包括本该走 BBR 的 sing-box 入站，**以及 SSH 会话本身**：

```
10.0.0.239:22 ←→ 120.235.161.48:14773   brutal  pacing_rate 3800000000bps
```

分流方案就此被抹平成"全 brutal 定速"，正是使用者想避免的结果。

**实测数据（Brutal 速率超配的代价）**

该 /32 被锁到 3800 Mbps（按服务器 4 Gbps 出口的 95% 推算），而客户端是家宽。
同一台机器上按 CC 汇总在线连接：

```
  bbr     连接 72   发送     40.5 MB  重传     0.0 MB (0.0%)
  brutal  连接 29   发送   1255.7 MB  重传   359.1 MB (28.6%)
```

单看那条 sing-box naive 连接更直观：

```
bytes_sent:    1,200,745,235
bytes_retrans:   358,902,006   →  29.9%
pacing_rate:   3,800,000,000 bps   (3800 Mbps)
delivery_rate:    71,902,448 bps   (~72 Mbps)
```

**实际投递约 72 Mbps，却按 3800 Mbps 定速发包，近三成流量在重传。**
Brutal 是无视丢包的定速算法，速率超过链路真实容量时不会退让，只会持续自我洪泛。
`0.0.0.0/0` 的默认值取"服务器出口的 95%"，那是**服务器**的出口能力，
**不是客户端线路的承受能力**——两者可以差一到两个数量级。

**修复与验证**

```bash
brutalctl del 120.235.161.48/32     # 移除 /32 速率组与随附的路由锁
```

删除后恢复按入站分流。注意 **CC 在连接建立时确定，存量连接不会改变**，
需客户端重连才切换。复核：

```bash
ss -tin state established dst <客户端IP> | grep -oE '\b(bbr|brutal)\b' | sort | uniq -c
# 预期：sing-box 的 reality / naive 连接为 bbr，Xray 的 443 连接仍为 brutal
```

`xh brutal show` 已内置这两项自检：存在路由级 `congctl lock` 时单独告警，
并按 CC 汇总在线连接的发送量与重传率。**判据：brutal 重传率显著高于 bbr
即说明速率超配，应下调而不是继续加码。**

**给 Brutal 定速率的正确口径**：以**客户端实测下行**的 90% 为准，而不是服务器出口带宽。
测速要在客户端做；服务器上经公网 IP 回环测出来的数字不作数（见第 13 条）。

---

## 八、v4.9.0 握手提速与「全部采用最新特性」

本节记录 v4.9.0 这一轮改动。目标只有两个：**每条节点的握手少花一个 RTT / 少传一批字节**，
以及**把所有向后兼容的下限一律提到最新**。同样每条都有实测数据，包括「测了但不采纳」的。

改完在同机跑了完整的 13 节点回归（`run_test.py`，覆盖本项目 7 条 + sbbox 5 条 + 1 条自研），
**13/13 全通过**：

```
Xray     n0-h2-cdn                 PASS   396.0ms   TCP/H2 + Cloudflare CDN
Xray     n1-h3-cdn                 PASS   158.3ms   QUIC/H3 + Cloudflare CDN
Xray     n2-h3-direct              PASS    13.0ms   QUIC/H3 + VLESS Direct
Xray     n3-hy2-obfs               PASS    27.5ms   Hysteria 2 + Salamander
Xray     n4-reality-vision         PASS     6.3ms   VLESS + Reality + Vision
Xray     n5-reality-xhttp          PASS    84.5ms   VLESS + Reality + XHTTP
Xray     n6-reality-up-cdn-down    PASS   107.7ms   Reality Up + CDN Down
sbbox    tuic / hysteria2 / naive-h3 / naive-h2 / vless-reality   全部 PASS
```

> CDN 两条的百来毫秒是 Cloudflare 边缘路径，不是服务端——口径见第七节第 13 条。

---

### 1.〔握手提速〕裁掉证书链尾部的根证书

**现象**：Let's Encrypt 签发的 `fullchain.cer` 是 **4 张**证书：

```
leaf(reality.cch.us.kg) → YE2(中间) → Root YE(由 ISRG Root X2 交叉签名) → ISRG Root X2(由 X1 交叉签名)
```

**根因**：根证书本来就该由客户端信任库提供，服务端在**每一次** TLS 握手里都把它重传一遍。
对 QUIC 尤其贵——客户端地址被验证前服务端受 **3 倍放大限制**，首包群越大越容易多吃一个 RTT，
这直接落在 `h3-direct`、`Hysteria2-obfs`、`CDN-H3` 三条节点上。

**判据不能用「自签根」**：链尾那张是**交叉签名**的（ISRG Root X2 由 X1 签发），
`subject != issuer`，按自签去找一张都裁不掉。本项目改成直接测我们真正要的性质——
**从尾部逐张试删，每删一张就拿系统信任库验一次，验得过才落实，验不过立即停手**。

**验证命令**：

```bash
# 裁剪前后各跑一次，看服务端出向字节数
tcpdump -i lo -n -w /tmp/h.pcap 'tcp port 8003' & sleep 1
openssl s_client -connect 127.0.0.1:8003 -servername "$(xh info | grep -o 'reality[^ ]*' | head -1)" -tls1_3 </dev/null >/dev/null 2>&1
sleep 1; kill %1
tcpdump -r /tmp/h.pcap -n 'src port 8003' | awk '{for(i=1;i<=NF;i++) if($i=="length"){gsub(":","",$(i+1)); s+=$(i+1)}} END{print "server->client bytes:",s}'

# 链长与体积
grep -c BEGIN /etc/ssl/private/fullchain.cer   # 4 → 3
wc -c < /etc/ssl/private/fullchain.cer         # 4841 → 3243
```

**实测前后对照**：

| | 裁剪前 | 裁剪后 | 差 |
|---|---|---|---|
| 链长 | 4 张 | 3 张 | −1 |
| `fullchain.cer` | 4841 B | 3243 B | −1598 B |
| 单条 TLS 1.3 握手服务端出向字节 | 5509 B | 4364 B | **−1145 B** |
| `openssl verify`（系统信任库） | OK | OK | 无差异 |

**为什么停在 3 张而不是 2 张**：只留 `leaf + YE2` 时验证直接失败——

```
$ openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted YE2.pem leaf.pem
error 20 at 1 depth lookup: unable to get local issuer certificate
```

`Root YE` 还没进主流信任库，砍掉它就没人能建链了。脚本自己会停在这里，不需要写死张数。

**修复方式**：`/usr/local/sbin/xh-trim-chain`（源码 `tools/xh-trim-chain.sh`，安装时由
`07-acme-cert.sh` 落地），并把它加到 acme.sh 的 `reloadcmd` **最前面**——
续期时 acme.sh 会把完整 4 张链重新写回 `/etc/ssl/private/fullchain.cer`，
**裁剪结果不会自己留下来，必须每次续期后重跑**。失败只 `|| true` 记一笔，绝不阻断续期。

> **踩过的坑（已修）**：这个脚本的第一版在 POSIX sh 里没有局部变量，
> `chain_ok()` 里复用了外层游标 `keep`，函数每调一次就把外层游标改掉，
> **结果验证失败也照样把链砍短了一张**（实测把 3 张砍成 2 张，客户端直接验不过）。
> 现在函数内部一律用 `_ck` / `_ci`。回归用例：原始 4 张链 → 3 张、已裁剪的 3 张链 → 不动、
> 幂等重跑 → 不动、单张自签证书 → 不动。

---

### 2.〔降延迟〕Xray 内置 DNS 按实测延迟重排

**现象**：`dns.servers` 第一位是 `8.8.8.8`。

**根因**：`freedom` 出站的 `targetStrategy: UseIPv4` 会让**每个新域名**都走一次内置 DNS，
第一位是谁直接决定每条新连接的额外延迟。

**验证命令**（随机不存在的子域，避开各级缓存）：

```bash
for s in 1.1.1.1 8.8.8.8 9.9.9.9; do
  printf "%-10s " $s
  for i in 1 2 3; do dig +tries=1 +time=2 @$s r$RANDOM$i.example.com A | grep 'Query time'; done
done
```

**实测（本机 Oracle ARM）**：

| 解析器 | 冷域名查询耗时 |
|---|---|
| **1.1.1.1** | **7 / 4 / 4 ms** |
| 8.8.8.8 | 17 / 14 / 13 ms |
| 9.9.9.9 | 16 / 14 / 14 ms |

**修复方式**：`servers` 改为 `1.1.1.1 → 8.8.8.8 → localhost`。每条新连接省约 **10ms**。

---

### 3.〔最新特性〕TLS 下限一律提到 1.3

三处 `tlsSettings.minVersion` 与 nginx 的 `ssl_protocols` 全部改为只谈 TLS 1.3。

**注意：不能靠「删掉 `minVersion` 这行」来要最新特性**——删掉后 Xray 会退回它自己的
默认下限（更低），方向正好相反。要最新就得**显式写死 `"1.3"`**。

nginx 侧连带两处清理：

- `ssl_ciphers` 在 TLSv1.3 下**不生效**（那是 1.2 及以下的旋钮），换成
  `ssl_conf_command Ciphersuites ...`；`ssl_prefer_server_ciphers` 同理已无作用，删除。
- `ssl_stapling` 改为显式 `off`：Let's Encrypt 自 2025 年起不再提供 OCSP，
  本项目签发的证书里**没有 OCSP responder URL**，开着只会每次启动/重载打两条 warn。

**验证命令**：

```bash
openssl x509 -in /etc/ssl/private/fullchain.cer -noout -ocsp_uri   # 输出为空 = 无 OCSP
openssl s_client -connect 127.0.0.1:8003 -servername <你的直连域名> -tls1_2 </dev/null 2>&1 | grep -i alert
# 期望：tlsv1 alert protocol version（1.2 被拒）
openssl s_client -connect 127.0.0.1:8003 -servername <你的直连域名> -tls1_3 </dev/null 2>&1 | grep 'Verify return'
# 期望：Verify return code: 0 (ok)
```

**实测**：改前 `nginx -t` 每次两条
`"ssl_stapling" ignored, no OCSP responder URL in the certificate`，改后无告警；
TLS 1.2 连接被 alert 70 拒绝，TLS 1.3 正常，13 节点回归全过。

---

### 4.〔实测后不采纳〕给 Reality 入站开 TCP Fast Open

**没有改动。** Reality 入站的 `sockopt` 至今**不含** `tcpFastOpen`，这是 v4.7.x 起
有意为之：部分运营商 / 移动网络会丢弃带数据的 SYN 包，表现为
`failed to read client hello`。省下的那一个 RTT 换不来这种概率性的连不上。
（XHTTP 入站与 `freedom` 出站的 TFO 照常开启，它们不面对这条路径。）

---

### 5.〔实测后不采纳〕把 sbbox 的 Reality 握手目标从 `gateway.icloud.com` 改到本机

sbbox 那套的 Reality `handshake.server` 是远端的 `gateway.icloud.com:443`，
本项目用的是 `127.0.0.1:8003`。原以为远端目标会给每次握手加一整个 RTT，实测不成立：

```
$ curl -s -o /dev/null -w "connect=%{time_connect} appconnect=%{time_appconnect}\n" https://gateway.icloud.com/
connect=0.001609 appconnect=0.013412
connect=0.001563 appconnect=0.012547
```

TCP 连接建立只要 **1.6ms**（Apple 边缘就在同区），换成本机也省不出可测的差值，
反而要动客户端 SNI 和订阅。**未改动。**

---

## 九、v4.9.1 CDN 延迟归因与 ECN

### 1.〔提速〕CDN 两条节点的延迟主因是 packet-up 的最小 POST 间隔，不是 Cloudflare

**现象**：`Vless-xhttp-h2-cdn` / `h3-cdn` 的延迟常年是直连节点的 3~8 倍，
很容易归咎于「Cloudflare 边缘路径慢」。

**排查过程里两次走错，都记下来**：

1. 先怀疑 VPS 到边缘的距离。实测 `ping` 边缘 IP **0.85ms**，`cf-ray` 显示落在
   **SJC**，与 VPS 同区——不是距离问题。
2. 再拿 `curl https://cdn.<域名>/` 分层测，量到「源站 11~35ms」。**这个数是错的**：
   nginx 的 `location /` 是伪装反代，打的是 stanford.edu，量的是伪装站的响应时间，
   跟隧道路径毫无关系。**测 CDN 节点必须打隧道路径，不能打 `/`。**

**根因**：CDN 节点必须走 `packet-up`（`stream-up` 经 Cloudflare 会让 CDN-TLS 吞吐
掉到 0、CDN-H3 超时，见第七节）。packet-up 把上行切成一串 POST，两次 POST 之间有
一个最小间隔 `scMinPostsIntervalMs`，本项目此前显式写死 **30ms**。这个间隔就是延迟主项。

**验证命令**（同一条 CDN 出站，只改这一个字段）：

```bash
# 分别用 scMinPostsIntervalMs = 默认 / 10 / 1 建三条 socks 入站，各打 9 次
curl -s -o /dev/null -w '%{time_total}\n' --socks5-hostname 127.0.0.1:<port> \
  http://www.gstatic.com/generate_204
# 订阅里当前下发的值：
grep -o 'scMinPostsIntervalMs%22%3A[0-9]*' /usr/local/nginx/html/sub/*/v2rayn-raw.txt | sort -u
```

**实测前后对照**（经 Cloudflare，各 9 个样本）：

| `scMinPostsIntervalMs` | 中位 | p95 | 20MB 下载吞吐 |
|---|---|---|---|
| 内置默认（≈30ms，旧） | 21.7ms | 45.6ms | 328~509 Mbps |
| **10ms（现默认）** | **12.2ms** | 70.0ms | 414~546 Mbps |
| 1ms | 10.3ms | 38.8ms | 371~520 Mbps |

**吞吐三档无差别**——这一项是纯延迟收益，不用拿吞吐换。

**取 10 而不是 1**：30→10 已经拿到大头（−9.5ms），10→1 只再省 1.9ms，
不值得为此把打给 CDN 的请求速率再抬一个数量级（请求数是 CDN 侧最容易做特征的维度）。
需要时可覆盖：`XHTTP_SC_MIN_POSTS_MS=30 bash install.sh`。

**全量回归前后**（13 节点，各 9 样本中位）：

| 节点 | 改前 | 改后 |
|---|---|---|
| n0-h2-cdn | 24.9ms | **11.9ms** |
| n1-h3-cdn | 15.4ms | **10.6ms** |

> **顺带修了测试口径**：`run_test.py` 自己拼的 CDN 出站原本**不带**
> `scMinPostsIntervalMs`，量到的是 Xray 内置默认而不是订阅真正下发的值，
> 跟用户实际体验对不上。现已同步。

---

### 2.〔已开启，但当前内核上无提速〕`tcp_ecn` 2 → 1

**改动**：`net.ipv4.tcp_ecn` 从 `2`（只被动应答）改为 `1`（主动发起协商）。

**验证命令**（关键是**按对端 IP 过滤**，否则会把自己作为服务端回的 SYN-ACK
误判成「对端接受」——我第一次就是这么误判的）：

```bash
IP=$(getent ahostsv4 speed.cloudflare.com | awk 'NR==1{print $1}')
tcpdump -i <网卡> -n "host $IP and tcp port 443 and tcp[tcpflags] & tcp-syn != 0" -w /tmp/e.pcap &
curl -s -o /dev/null --resolve "speed.cloudflare.com:443:$IP" https://speed.cloudflare.com/
tcpdump -r /tmp/e.pcap -n | grep 'Flags \[S'
# 我方 SYN 应为 [SEW]；对端 SYN-ACK 带 E（[S.E]）= 接受，不带 = 拒绝
```

**实测 7 个对端**：Cloudflare / GitHub / Bing / Microsoft / 1.1.1.1 / 9.9.9.9 **接受**，
Google（gstatic）**拒绝**；**无一例连接失败**。

**但必须说清楚：它在当前内核上不提速。** 本机 `tcp_congestion_control=bbr`，
而这个 `bbr` 是 **BBRv1**（见下一条），BBRv1 的控制环路**不消费 ECN 标记**。
A/B 实测（12 轮交错，`speed.cloudflare.com`）：

| | 首字节中位 | 吞吐中位 |
|---|---|---|
| `tcp_ecn=2` | 44.8ms | 1212 Mbps |
| `tcp_ecn=1` | 47.5ms | 1373 Mbps |

差异完全落在 CF 边缘本身的波动里（两组各有 4/12 次传输直接失败），**无可测差异**——
这正是理论预期。设成 1 是无成本的前置条件：等换上 ECN 敏感的拥塞控制再补就晚了。

---

### 3.〔查明·当前做不到〕内核里的 `bbr` 是 BBRv1，不是 BBRv3

BBRv3 相对 v1 的四项改动（ECN/丢包进入控制环路、ProbeBW 改为
DOWN/CRUISE/REFILL/UP 的轮次推进、15% Headroom、平滑的 ProbeRTT）
**在本机内核上一项都不存在**，也没有任何 sysctl 能把 v1 变成 v3。

**判据**：

```bash
grep -i ' bbr' /proc/kallsyms | awk '{print $3}'
# 出现 bbr_lt_bw_sampling → v1 专属（v3 已移除）；无任何 v3 状态机符号
ss -tin | grep -o 'bbr:([^)]*)'
# bbr:(bw:...,mrtt:...,pacing_gain:...,cwnd_gain:...) → v1 的 info 字段布局
ls /sys/module/tcp_bbr/parameters/   # 空
```

**为什么暂时换不上**：本机是 **arm64**。archive 里所有 `linux-image-*` 都是同一套
Ubuntu 7.0.0 内核，带的都是这份 BBRv1；XanMod 一类的预编译 BBRv3 内核只出 x86_64。

> ⚠️ **这段结论在 v4.9.2 被证伪**：`byJoey/Actions-bbr-v3` **有 arm64 构建**
> （`arm64-*` tag 一直都在，是我漏查了）。v4.9.2 已实际换上，见第十节。

剩下两条路，都需要单独决策，本版**未执行**：

- **DKMS 外挂 `tcp_bbr3` 模块**：本机 `tcp_brutal` 就是这么装的（`dkms status`
  显示已为两个内核版本各编译一份），工具链齐全、可回退，是风险最低的一条。
- **自编 BBRv3 内核**：Oracle VPS 无带外控制台，自编内核启动失败等于失联。

## 十、v4.9.2 换上 BBRv3 内核，与 tcp-brutal 的新内核 ABI 修复

### 1.〔更正〕arm64 有预编译的 BBRv3 内核

v4.9.1 写的「预编译 BBRv3 内核只出 x86_64，没有 arm64 构建」**是错的**。
`byJoey/Actions-bbr-v3` 的 release 里 `arm64-*` tag 一直都有，是漏查了。
本机已换到 `7.2.3-joeyblog-bbrv3`，原厂 `-oracle` 内核保留在 `/boot` 作回退。

### 2.〔严重·会静默降级〕tcp-brutal 在内核 7.1+ 上编译失败

**这一条与是否升级 BBRv3 无关，任何人把机器升到 7.1 以上都会踩到。**

**现象**：`dkms` 编译 tcp-brutal 报

```
error: 'struct tcp_congestion_ops' has no member named 'min_tso_segs'; did you mean 'tso_segs'?
```

**根因**：内核改了拥塞控制的回调签名，上游 tcp-brutal 至今未适配：

```c
旧 (≤7.0): u32 (*min_tso_segs)(struct sock *sk);
新 (7.1+): u32 (*tso_segs)(struct sock *sk, unsigned int mss_now);
```

**为什么危险**：本项目的 `sockopt` 里写着 `"tcpcongestion":"brutal"`。模块编不出来
时安装流程只是 `|| true` 过去，**brutal 静默不可用**，你要到转发出问题才会发现。

**验证命令**：

```bash
sysctl -n net.ipv4.tcp_available_congestion_control   # 期望含 brutal
lsmod | grep brutal
dkms status | grep tcp-brutal                          # 应为每个内核各一份 installed
tail -20 /var/lib/dkms/tcp-brutal/*/build/make.log     # 失败时看这里
```

**修复方式**（v4.9.2 起自动执行）：安装流程改成先 `dkms ldtarball` 把源码摊到
`/usr/src`，打完补丁再 `dkms install`——原来的 `dkms install <tarball>` 是
「解包+编译」一步走，中间插不进补丁。补丁给回调加了条件编译，
**判别式直接 grep 目标内核的 `include/net/tcp.h`**，不用 `LINUX_VERSION_CODE`
猜版本边界（猜错会在别人的内核上静默走错分支）。

写这个探测踩了三个坑，都写进注释了：

1. Makefile 会被读**两次**——外层 make 有 `KERNEL_DIR`，内核 kbuild 重读时只有
   `srctree`。只看 `KERNEL_DIR` 的话，真正编译那一遍路径为空，宏静默不定义。
2. `$(shell ...)` 里不能用反斜杠续行。
3. **make 匹配 `$(shell ...)` 的右括号时不认引号**——grep 模式里写
   `'tso_segs)(struct sock...'` 会让 `$(shell)` 提前闭合，报
   `/bin/sh: Syntax error: Unterminated quoted string`。判别式因此改用无括号的
   `tso_segs.*mss_now`（旧内核 0 命中、新内核 1 命中）。

**实测**：补丁后的源码对 `7.2.3-joeyblog-bbrv3` 与 `7.0.0-1010-oracle` **都能编出
`brutal.ko`**，两个内核下 `brutal` 均在可用 CC 列表里。补丁函数幂等，重复执行不会二次插入。

### 3.〔方法〕远程 VPS 换内核的四层防宕机

无带外控制台的云主机换内核，四层缺一不可：

| 故障 | 兜底 | 结果 |
|---|---|---|
| 内核 panic | `panic=10` | 10 秒自动重启 |
| **initramfs 找不到根盘** | **`rd.shell=0 rd.emergency=reboot`** | 立即重启，而不是掉进 emergency shell 挂死 |
| 能开机但网络不通 | systemd 死人开关（12 分钟未确认则重启） | 自动重启 |
| 启动项本身 | `GRUB_DEFAULT=saved` + `grub-set-default 旧内核` + `grub-reboot 新内核` | 新内核只试一次 |

第二层最容易漏：**`panic=10` 管不了 dracut 的 emergency shell**，那才是「开不了机又连不上」的典型形态。

**踩过的坑**：保护措施必须在**装内核之前**就位。内核包的 postinst 会自己跑
`update-grub`，若此时 `GRUB_DEFAULT=0` 仍在，默认启动项立刻变成新内核；
我把保护排在装包之后，dkms 一失败脚本就中止，机器一度处于
「下次重启进未验证内核且无任何回退」的状态。

**换内核前必查**（本机根盘是 virtio_scsi，`cmdline` 里的 `netroot=iscsi` 是
Oracle 镜像样板参数，不代表真走 iSCSI）：

```bash
mokutil --sb-state                     # Secure Boot 开着就装不了未签名内核
iscsiadm -m session; ls /sys/firmware/ibft   # 确认根盘到底走不走 iSCSI
# 拿新内核的 config 和「当前能开机的内核」逐项比对开机关键项
for c in CONFIG_ACPI CONFIG_EFI CONFIG_SCSI_VIRTIO CONFIG_VIRTIO_NET \
         CONFIG_ARM64_4K_PAGES CONFIG_SERIAL_AMBA_PL011_CONSOLE; do
  echo "$c: $(grep -E "^$c=" /boot/config-旧) vs $(grep -E "^$c=" /boot/config-新)"
done
```

本机 19 项全部一致（含 arm64 最容易翻车的页大小 4K），这是敢按下重启的依据。

### 4.〔适配〕`xh` 状态输出新增 BBR 版本识别

BBR 有 v1 / v3 两代，`sysctl net.ipv4.tcp_congestion_control` **两代都叫 `bbr`**，
只看名字分不出来 —— 这正是 v4.9.1 里我误判的起点。`xh` 的状态输出现在多一行：

```
  net.ipv4.tcp_congestion_control  bbr
    └─ BBR 版本                     v3
```

判据按可靠性排序，拿不到就报 `unknown`、不猜：

1. `/proc/kallsyms` 里有 `bbr_start_bw_probe_down` / `bbr_is_inflight_too_high` /
   `bbr_skb_marked_lost` → v3；有 `bbr_lt_bw_sampling` → v1（该符号 v3 已删除）
2. 兜底看 `ss -tin` 的 **`pacing_gain`**：v1 STARTUP 是 `2.88672`，v3 是 `2.77344`，
   且只在拿不到 kallsyms 时才用，命中不了就报 `unknown`

> **v4.9.3 更正**：v4.9.2 曾把 `cwnd_gain`（v1=2.88672、v3=2）写成版本指纹，**这是错的**。
> **BBRv1 进入 PROBE_BW 后 `cwnd_gain` 同样是 2** —— 它区分的是连接所处的状态，
> 不是 BBR 版本，拿它判长连接会给出错误答案。当时本机 42 条连接恰好全在 STARTUP
> 期，才没暴露这个问题。判版本请以 kallsyms 符号为准。

### 5.〔实测〕BBRv3 上线后的回归与 ECN 复测

13 节点全量回归 **13/13 PASS**。BBRv3 已确认接管：`bbr_lt_bw_sampling`（v1 专属）
为 0，`bbr_start_bw_probe_down` / `bbr_skb_marked_lost` / `bbr_is_inflight_too_high`
均在。**最快的版本指纹是 `ss -tin | grep -o 'bbr:([^)]*)'`**：

```
v1: bbr:(bw:...,mrtt:...,pacing_gain:2.88672,cwnd_gain:2.88672)
v3: bbr:(bw:...,mrtt:...,pacing_gain:2.77344,cwnd_gain:2)
```

`cwnd_gain` 由 2.88672 变成 2，正是 v3 把 cwnd_gain 与 pacing_gain 解耦的 Headroom 改动。

**ECN 复测：依然没有收益，但原因和 v4.9.1 说的不一样。** v4.9.1 归因为
「BBRv1 不消费 ECN 标记」——那句没错，但不是全部原因。换上会消费 ECN 的 BBRv3 后
仍无差异，真正的原因是**路径上压根没有标记**：

```bash
nstat -az | grep -iE 'DeliveredCE|InCEPkts'   # 自开机以来全为 0
ss -tin | grep delivered_ce                    # 无该字段
```

BBRv3 下 A/B（各 12 轮交错，cachefly 10MB + gstatic/generate_204）：
首字节中位 1.9ms vs 1.9ms，吞吐中位 2700 vs 2576 Mbps，差异都在噪声内。
**判断 ECN 有没有用，要先量 CE 计数，而不是直接跑吞吐 A/B。**
`tcp_ecn=1` 予以保留（零成本，路径上将来出现 L4S/AQM 时能立刻吃到）。

> **测量口径警告**：`speed.cloudflare.com` 会对频繁测速返回 **HTTP 429**，
> 此时 `%{speed_download}` 变成 0 而 **curl 退出码仍是 0**，极易被误读成
> 「吞吐掉到 0 的严重回归」——我就这么误判过一次。做吞吐基准要用 cachefly
> 一类不限流的源，并显式检查 `http_code` 与 `size_download`。
> v4.9.1 那组 BBRv1 的吞吐数字（1212/1373 Mbps）就掺了 429，不可与本节数字直接相比。

---

## 十一、v4.9.4 BBRv3 上的 25 样本回归基线

换到 `7.2.3-joeyblog-bbrv3` 后的完整回归，**每条节点 25 个样本**（`SAMPLES=25 python3 run_test.py`）。
这组数字同时作为后续比对的基线 —— 以后改动前后对比，请对齐样本量再比。

```
每条 25 个样本（已预热）；抖动 = max ÷ 中位。基线是同一目标不走代理的耗时。
Core     Node Tag                  Port    Status          中位      p95      抖动
直连     (no-proxy baseline)       -       BASE         1.8ms    3.4ms    2.1x
Xray     n0-h2-cdn                 10800   PASS        15.8ms   43.0ms    8.2x
Xray     n1-h3-cdn                 10801   PASS        12.7ms   31.0ms    2.8x
Xray     n2-h3-direct              10802   PASS         3.8ms   12.5ms    3.7x
Xray     n3-hy2-obfs               10803   PASS         3.0ms    5.9ms    3.0x
Xray     n4-reality-vision         10804   PASS         6.7ms   10.7ms    1.6x
Xray     n5-reality-xhttp          10805   PASS         3.1ms    8.0ms    2.6x
Xray     n6-reality-up-cdn-down    10806   PASS         3.8ms    7.9ms    2.1x
sbbox    tuic                      11801   PASS         2.6ms    6.6ms    2.9x
sbbox    hysteria2                 11802   PASS         2.9ms    6.8ms    4.5x
sbbox    naive-h3                  11803   PASS         2.6ms    6.8ms   16.5x
sbbox    naive-h2                  11804   PASS         3.9ms    7.2ms    2.7x
sbbox    vless-reality             11805   PASS         7.3ms   15.9ms    8.1x
Overall Result: 13/13 nodes passed verification (ALL PASS)
```

### 1.〔读法〕抖动倍率会随样本量变大，它不代表变差了

**抖动 = max ÷ 中位。样本越多越容易抓到极端值，所以这一列必然随 n 增大而增大。**
判断稳定性要看 **p95**，不要看抖动倍率。同一台机器同一配置，把样本量从 9 提到 25：

| 节点 | n=9 的 p95 / 抖动 | n=25 的 p95 / 抖动 |
|---|---|---|
| tuic | 447.5ms / **153.7x** | 6.6ms / **2.9x** |
| naive-h3 | 40.4ms / 12.2x | 6.8ms / 16.5x |
| 直连基线 | 18.3ms / 9.6x | 3.4ms / 2.1x |

`tuic` 在 n=9 时那个 153.7x 完全是单枪离群，样本量一上来就消失了；
`naive-h3` 的倍率反而从 12.2x 涨到 16.5x，但 p95 从 40.4ms 降到 6.8ms —— 
**倍率涨了而实际表现更稳**，这正说明倍率不能单独用来判断好坏。

### 2.〔读法〕先看直连基线再看节点

表里第一行是**不走代理**打同一目标的耗时。本轮基线 p95 3.4ms、抖动 2.1x，
说明这一轮路径本身很稳，因此 `n0-h2-cdn` 的 p95 43ms 是 Cloudflare 边缘路径
（见第九节），`naive-h3` / `vless-reality` 的高倍率是零星单次毛刺，
都不是服务端问题。基线自己抖起来的时候（上一轮 n=9 基线 p95 就有 18.3ms），
超出基线的部分才算节点的。

### 3.〔结论〕换内核无回归

中位延迟与 BBRv1 时期在同一量级，两轮之间也高度一致
（tuic 2.9→2.6、naive-h3 3.3→2.6、n1-h3-cdn 12.9→12.7、n4 6.2→6.7），说明已收敛。
CDN 两条维持在 12.7 / 15.8ms —— 这是 v4.9.1 把 `scMinPostsIntervalMs`
从 30ms 降到 10ms 的收益（改之前是 21.7ms 量级），换内核没有把它吃掉。

> **范围提醒**：13 条节点里多数是 QUIC（hy2 / tuic / naive-h3 / xhttp-h3），
> 拥塞控制在**用户态**；Xray 隧道 socket 又写死了 `tcpcongestion: brutal`。
> BBRv3 实际只作用于出站 TCP 直连与 naive-h2 那部分，**不要把整表的表现都归给它**。

---

## 十二、v4.9.5 large 档 tcp_rmem/tcp_wmem 上限补齐到 64MB

`docs/10.流控调优.md` 从一开始就写着 large 档的 `tcp_rmem` 上限是 **64MB**，
但 `src/06-tuning-lib.sh` 里 large 档的 `TCP_MEM_MAX` 一直是 `33554432`（32MB）——
**是代码没跟上文档**，不是文档写错。v4.9.5 把 large 档（内存 ≥ 16GB）补齐：

```diff
-TUNE_TIER="large";  SOCK_MEM_MAX=67108864; TCP_MEM_MAX=33554432; ...
+TUNE_TIER="large";  SOCK_MEM_MAX=67108864; TCP_MEM_MAX=67108864; ...
```

medium / entry / small 三档**不变**（它们的 `TCP_MEM_MAX` 本来就是各自 `SOCK_MEM_MAX` 的一半以下，
在小内存机上把单条连接的缓冲上限提到和全局 `rmem_max` 齐平并不安全）。

验证：

```bash
xh tuning on
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
# 期望：4096  131072  67108864
```

**未采纳的两项**（来自社区流传的 "BBR Blast Smooth" 一键脚本）：

| 该脚本的做法 | 为什么不采纳 |
| --- | --- |
| `net.ipv4.tcp_fin_timeout=8` | 本项目用 `15`。有 CDN 回源的部署里，8 秒的 FIN_WAIT2 会在回源侧长连接被中间设备静默半关时提前放走 socket，换来的内存节省在 24GB 机器上没有意义。 |
| 把参数 `>>` 追加进 `/etc/sysctl.conf` | ① Ubuntu 24.04+ 默认**没有** `/etc/sysctl.conf`，脚本会新建它；systemd-sysctl 把 `/etc/sysctl.conf` 排在 `/etc/sysctl.d/*.conf` **之后**应用，于是它会静默盖掉 `xh tuning` 与 `sbbox tune` 的值，而 `xh tuning off` 只删自己的文件、**回滚不掉**。② `>>` 追加意味着重复执行会堆叠多份。本项目所有参数只写 `/etc/sysctl.d/99-xray-xhttp.conf` 一个文件，整文件覆盖、整文件删除。 |

该脚本其余 10 项参数（`fq`/`bbr`、`rmem_max`/`wmem_max=64M`、`tcp_tw_reuse`、`tcp_no_metrics_save`
以及内核本就默认开启的 `tcp_window_scaling`/`tcp_timestamps`/`tcp_sack`）本项目**均已包含**。

---

## 十三、v4.9.6 MTU 全线回到 1500

服务器物理网卡与客户端 TUN 虚拟网卡的 MTU 都统一为 **1500**。

**服务器侧**：此前 `xh tuning on` 会无条件把默认网卡压到 1480
（v4.9.5 起改为"仅当当前 MTU < 1480 才设"，见 `src/06-tuning-lib.sh`）。
若你的机器已被压过，用下面的方法验证链路能否跑满 1500 再改回：

```bash
DEV=$(ip route show default | awk '{print $5;exit}')
GW=$(ip route show default | awk '{print $3;exit}')
ip link set dev "$DEV" mtu 1500
ping -c2 -M do -s 1472 "$GW" && ping -c2 -M do -s 1472 1.1.1.1   # 1500 字节不分片
# 任一不通就 ip link set dev "$DEV" mtu 1480 回退
```

**持久化不在本项目手里**：MTU 若写死在 `/etc/netplan/*.yaml` 里，
`ip link set` 只影响当前运行时，重启会被 netplan 改回去。检查：

```bash
grep -rn mtu /etc/netplan/
```

注意 `50-cloud-init.yaml` 由 cloud-init 在开机时重写，要覆盖它得靠序号更大的
文件（如 `99-custom-mtu.yaml`，netplan 按文件名排序，后者胜）。

**客户端侧**：`templates/mihomo-full.yaml.tmpl` 的 `tun.mtu` 由 1480 改为 1500。

> **这一项有取舍，请按自己的网络判断。** TUN 是虚拟网卡，它的包还要再被
> VLESS / Hysteria 封装一层才出物理网卡，1480 那 20 字节余量正是为了避免
> 封装后超过物理 MTU 触发分片。**在 PPPoE（MTU 1492）、部分移动网络等
> 物理 MTU 本就小于 1500 的链路上，1500 可能导致大包丢失、网页加载卡半截。**
> 若遇到这类现象，把客户端配置里的 `tun.mtu` 改回 1480 即可，与服务端无关。

---

## 十四、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
