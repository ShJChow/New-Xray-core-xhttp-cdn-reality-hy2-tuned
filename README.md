# xray-xhttp
小白请使用ai agent，把本项目发给agent配置。
**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

>  **已在 Oracle ARM (4 核 24G) 和系统 Ubuntu  26.04.01 深度测试与调优**。本协议专门应对规避AI封号。

基于 Xray-core 的 **XHTTP + CDN + Reality + Hysteria2** 全能高可用部署方案。默认开启 **xpadding 流量填充混淆 / Hysteria2 Salamander 混淆 / 全套 8 条核心节点**，并在安装时自动应用**系统级与网络层流控调优（BBR + fq、64MB 缓冲区、1048576 句柄、全套安全加固）**，附带常驻管理工具**xh**。

支持 V2rayN / Clash Verge Rev / Mihomo Party / Sing-box / Shadowrocket / Loon / Surge / onexray 等全平台客户端。**如果你的节点客户端内核没有更新，部分最新协议节点不可用**，比如H3.

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
- [七、版本迭代与核心调优演进记录 (v4.8 - v4.9.33)](#七版本迭代与核心调优演进记录-v48---v4933)
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
   - **推荐方式 B（Cloudflare API 模式）**：输入 `2`（无需停用 80 端口，输入 CF Global API Key 或 Token 即可全自动签发）；**最佳推荐**。
3. **输入主域名与次域名（双域名 SAN 证书）**：
   - **主域名**：输入你的直连域名（如 `reality.example.com`）
   - **泛域名 / 附加域名**：输入你的 CDN 域名（如 `cdn.example.com`）
4. **安装并输出证书路径**：
   申请成功后，证书会自动保存在 `/root/ygkkkca/` 目录下。

#### 步骤 4：将证书部署到标准路径（一键复制），如果没有自动签发，ssh重连一次主机即可。
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

> [!TIP]
> **现代参数传参建议**：推荐优先使用下方 **「方案 A-1 现代位置参数单行版」**（形如 `sudo bash <(curl -fsSL ...) key=val`）。参数直接作为 CLI 位置参数传入脚本内部解析为环境变量，无需提前 `sudo -i`，100% 免疫终端换行/软回车断行、Windows CRLF、尾部空格及 `sudo: AUTO=1: command not found` 报错。且脚本内部已内置最佳优化生产默认值，只需填写必选域名。

#### 方案 A-1：现代位置参数单行版（强烈推荐：100% 免疫终端换行与转义报错）
```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) AUTO=1 REALITY_DOMAIN="reality.example.com" CDN_DOMAIN="cdn.example.com" NODE_TAG="oracle-vps"
```
> 如需覆盖更多自定义项，直接在末尾空格追加即可（如 `IP_CHOICE=1`、`CDN_FALLBACK_ORIGIN="https://www.harvard.edu"`）。脚本内部默认值已涵盖 `FALLBACK_MODE=proxy`、`FEATURE_AUTO_TUNING=true`、`FEATURE_XPADDING=true`、`FEATURE_H3_DIRECT=true`、`FEATURE_HY2=true` 等优化配置，绝大多数场景无需重复传入。

#### 方案 A-2：Heredoc 结构化批处理版（多环境变量批量定义）
```bash
sudo -i

bash << 'EOF'
export AUTO=1
export REALITY_DOMAIN="reality.example.com"
export CDN_DOMAIN="cdn.example.com"
export NODE_TAG="oracle-vps"
export CDN_FALLBACK_ORIGIN="https://www.harvard.edu"
bash -c "$(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh)"
EOF
```

#### 方案 A-3：标准多行参数模板
```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) \
  AUTO=1 \
  REALITY_DOMAIN="reality.example.com" \
  CDN_DOMAIN="cdn.example.com" \
  NODE_TAG="oracle-vps"
```

#### 方案 B：极简极速模板（仅配置必填域名）
```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) AUTO=1 REALITY_DOMAIN="reality.example.com" CDN_DOMAIN="cdn.example.com"
```

#### 方案 C：自定义端口与路径模板（密码由脚本全自动生成 SHA256 高熵密钥，无需手动指定）
```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) \
  AUTO=1 \
  REALITY_DOMAIN="reality.example.com" \
  CDN_DOMAIN="cdn.example.com" \
  H3_PORT=8446 \
  H2_PORT=8445 \
  HY2_PORT=8443 \
  XHTTP_PATH="/$(openssl rand -hex 4)" \
  NODE_TAG="node-01"
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
| `CDN_FALLBACK_ORIGIN` | 伪装源站 | `https://www.harvard.edu`| CDN 路径未匹配时的伪装目标网站。 |
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
| `REALITY_MIN_CLIENT_VER` | 客户端兼容 | `1.8.0` | Reality 最低客户端版本控制（别名：`MINVERSION` / `MIN_CLIENT_VER`）。设为 `1.8.0` 兼容 mihomo / Clash Meta / sing-box；设为 `default` 或 `none` 回到 Xray 内核默认版本（严格模式）。 |
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
xh info                # 查看节点参数与客户端链接（含 minClientVer 状态）
xh sub                 # 查看/输出订阅链接与订阅二维码
xh resub               # 修改配置后一键重新生成全量订阅
xh minversion [on|off|<ver>] # Reality 最低版本控制（默认 1.8.0 兼容 mihomo/Clash）
xh ech [show|on|off]   # Cloudflare CDN ECH (加密 SNI) 开关与订阅同步
xh ecn [show|on|off]   # TCP ECN (显式拥塞通知) 开关与状态查看
xh cdnh2 [show|on|off] # CDN TCP(h2) 备用节点开关与订阅同步
xh brutal              # TCP Brutal 极速拥塞控制状态、开启/关闭与速率调节
xh tuning [win|mac|sb] # 查看对应系统的客户端千兆调优代码
xh conflict            # sysctl 内核参数冲突检测与一键自愈
xh log [xray|nginx]    # 实时查看服务运行与连接日志
xh update [--auto]     # 一键升级 Xray-core（失败自动回滚）
xh start | stop | restart # 启停与重启服务
```

---

## 四、全平台千兆客户端调优指南（慎用）

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

| # | 节点名称（v4.9.29） | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H3` | XHTTP (QUIC) + vlessenc | 经 CDN 443 | **隐藏真实 IP**，防封锁与救砖 |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | 直连 UDP 8446 | 直连 QUIC，`mode=stream-up` |
| **3** | `Hysteria2-H3-Direct` | Hysteria 2 | 直连 UDP 443 | 标准 HTTP/3 形态，实测下行最快（v4.9.26） |
| **4** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **5** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |
| **6** | `VLESS-Reality-Up-CDN-Down` | 上下行分离 + vlessenc | 上行 Reality 直连 / 下行 CDN | 上行不经 CDN，下行隐藏源站 |
| **7** | `VLESS-CDN-Up-Reality-Down` | 上下行分离 + vlessenc | 上行 CDN / 下行 Reality 直连 | v4.9.29 新增，见第二十九节 |

> 默认关闭、可按开关恢复：`VLESS-XHTTP-CDN-H2`（`FEATURE_CDN_H2`）、`VLESS-XHTTP-Direct-H2`（`FEATURE_H2_DIRECT`）、`Hysteria2-Obfs-Direct`（UDP 8443，`FEATURE_HY2_OBFS`）。
> 下面的吞吐表是 v4.9.x 早期的历史测量，节点名为当时的旧名。

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

## 六、常见问题与排错-开发者查看指引

### 1. Reality 三条节点全都不通 / 提示认证失败？
Reality 节点的认证在服务端会被记录为 `authentication failed or validation criteria not met`，常见原因及排查方法如下：
- **① 客户端系统时间偏差 > 30 秒（最常见）**：Reality 握手带有时间戳防重放校验。若手机/电脑系统时间与标准网络时间相差 30 秒以上，服务端会直接拒绝连接。**解决方法：在客户端设备设置中开启「自动从网络同步时间」**。
- **③-a 节点 7 `Vless-xhttp-reality-up-cdn-down` 在 mihomo 上报 REALITY 认证失败？（v4.9.19 已彻底攻克并修复）**：
  - **技术根因**：Mihomo 内核（`adapter/outbound/vless.go`）在处理 `download-settings` 时，默认将父级的 `v.realityConfig` 继承给下行连接。导致连接 CDN 域名（Cloudflare 443）时，强行发起了 REALITY 握手，因 Cloudflare 证书与 REALITY 密钥不匹配报错 `REALITY authentication failed`。
  - **解决方案**：在 `download-settings` 中显式配置 `reality-opts: { public-key: "" }`，使得 `Parse()` 返回 nil，彻底覆写清空继承的 REALITY 配置，下行恢复标准 TLS；同时按 Mihomo 规范扁平化 path/host/reuse-settings 结构。自 v4.9.19 起该节点已在 Mihomo 配置中**默认开启并 100% 跑通**！
- **③ 客户端内核对 XHTTP+Reality 及 ML-KEM-768 加密支持不足（节点 5 / 节点 6）**：`Vless-xhttp-reality` 节点采用了后量子加密算法，部分旧版 Clash/Mihomo/Shadowrocket 客户端内核不支持会导致握手 EOF。**建议：Clash 系客户端优先选用 `VLESS-TCP-REALITY-Vision` 标准节点；全协议节点推荐配合最新版 Xray-core (≥ 24.11 / 26.x) 客户端使用**。
- **④ SNI 误填为 CDN 域名**：Reality 的 SNI 必须填写直连域名（`REALITY_DOMAIN`），误填 CDN 域名会导致服务端报 `server name mismatch` 并拒绝连接。
- **⑤ 域名开启了 Cloudflare 代理（小黄云）**：Reality 是纯 TCP 直连伪装协议，`REALITY_DOMAIN` **必须在 Cloudflare 设置为仅 DNS（灰色云朵）**。

> **关于 `minClientVer`（v4.9.8 起支持原生配置与一键管理）**：
> Reality 默认配置最低客户端版本为 `1.8.0`，全面兼容 mihomo、Clash Meta、sing-box 等非 Xray 官方客户端。
> - **切换为严格模式**（仅限同代官方 Xray 内核）：执行 `xh minversion off` 即可移除 `minClientVer` 回到内核默认。
> - **切回兼容模式**：执行 `xh minversion on`（或 `xh minversion 1.8.0`），自动写入并热重启服务。
> - **安装期控制**：可通过环境变量 `REALITY_MIN_CLIENT_VER=1.8.0` 或 `REALITY_MIN_CLIENT_VER=default`（别名：`MINVERSION`）指定。

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

## 七、版本迭代与核心调优演进记录 (v4.8 - v4.9.33)

本项目在经历数十轮真实跨洋高延迟（160ms+ / 1% 丢包）生产环境实测与架构重构后，沉淀并收敛为现役的高性能代理矩阵。以下为核心技术演进与调优总结：

### 1. 官方正式版锁定铁律与客户端生态兼容（v4.9.8 – v4.9.18）
- **内核版本铁律**：严格锁定 Xray-core 官方最新正式版（`releases/latest`，当前 v26.3.27），严禁使用预发布/测试版（prerelease）。杜绝了测试版强制实验性后量子密钥（`X25519MLKEM768`）导致的第三方客户端大面积断连（`reality verification failed`）。
- **生态全兼容保障**：针对 Shadowrocket、sing-box、Clash Meta / Mihomo 等不同内核与客户端做深度适配，过滤不兼容语法（如 extra 范围参数、非标准 ECH 等），下发纯净且合规的专属订阅。

### 2. 双轨分离拓扑与协议矩阵规范化（v4.9.19 – v4.9.29）
- **上下行分离架构（双向互补）**：
  - **Reality-Up-CDN-Down**：直连 Reality 443 上行（0-RTT 极速握手）+ Cloudflare CDN 满速下行，突破跨洋单流下行瓶颈。
  - **CDN-Up-Reality-Down**：针对本地 UDP 443 QoS 严苛环境，上行经 Cloudflare CDN（标准 TCP/h2），下行直连 Reality 443 回程。
- **Mihomo 继承陷阱攻克**：彻底解决 MetaCubeX/Mihomo 在 `download-settings` 浅拷贝父级 `realityConfig` 的底层 bug，通过显式声明 `reality-opts: { public-key: "" }` 清空继承，实现下行退回标准 TLS 1.3 握手。
- **VLESS 加密（vlessenc）防窥探**：在 8001 XHTTP 源站入站开启 `vlessenc` 解密，阻断 Cloudflare CDN 边缘节点在解开外层 TLS 后窥视明文流量。
- **本质语义规范命名**：全面废弃带有平台词缀的冗余命名，统一采用 `[协议]-[传输/伪装]-[拓扑]` 语义结构（如 `VLESS-Reality-Vision-Direct`、`VLESS-XHTTP-CDN-H3` 等）。

### 3. 网络传输层极限流控与高阶特性优化（v4.8.x – v4.9.30）
- **BBRv3 原生内核协同**：全面迁移并加固 `7.2.7-joeyblog-bbrv3` 原生内核与最新 TCP Brutal 满速锁定（3800 Mbps），修复高版本 Linux 内核 ABI 崩溃与符号兼容问题。
- **系统缓冲与队列调优**：
  - TCP 缓冲区上限严格锁定 **64MB**（`tcp_rmem/wmem` max 67108864），经 160ms/1% 丢包实测，高丢包限速线路下吞吐收益显著高于 32MB，且无额外 bufferbloat。
  - 网卡 MTU 维持原生 1480；默认路由锁定 `initcwnd 32 initrwnd 32`；网卡队列 `txqueuelen 10000`。
- **多核软中断负载均衡**：虚拟网卡多队列激活 RPS/RFS（`rps_cpus = f`），规避单核软中断瓶颈。
- **现代 TLS 1.3 与协议特性**：全直连节点强制收敛至 TLS 1.3 现代密码套件；支持 TCP Fast Open (0-RTT) 与 MPTCP 多路径无缝切换；原生支持 Cloudflare CDN ECH (加密 SNI) 与 TCP ECN 协商。

### 4. 全链路安全防御与防信息泄露加固（v4.9.17 – v4.9.33）
- **端口跳跃默认关闭与收敛**：移除全网扫描与 conntrack 表耗尽风险极高的大范围 UDP 端口跳跃；Xray 侧 Hysteria2 节点全面聚焦单端口 `Hysteria2-H3-Direct`（UDP 443，标准 HTTP/3 形态）。
- **Netfilter 令牌桶 QDoS 防洪**：部署 iptables/ip6tables 连接追踪与 hashlimit 令牌桶限速（50/s burst 100），置顶 `lo` 与 `ESTABLISHED` 放行，在系统入栈最前端丢弃伪造握手洪泛。
- **特权进程防内存转储**：配置 `fs.suid_dumpable = 0` 与 `kernel.core_pattern = core`，阻断进程异常崩溃时内存私钥/凭据转储落盘。
- **阻断 ICMP 路由重定向**：网卡级配置 `send_redirects = 0`，阻断恶意中间人路由投毒。
- **本地保留端口防碰撞**：sysctl 全局保留关键代理与测试端口（`8001,8003,8443,8445,8446,10489,10800-10809,11801-11806,18793,23106,27295,28443`），防止出向短连接随机碰撞导致服务启动绑定失败。

---

## 八、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
