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
- [七、版本迭代与核心调优演进记录 (v4.8 - v4.9.34)](#七版本迭代与核心调优演进记录-v48---v4934)
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

针对千兆宽带跨境高 BDP 链路，可按需对客户端系统进行网络调优：

- **Windows 10 / 11（管理员 PowerShell）**：
  ```powershell
  irm https://reality.example.com/sub/<你的Token>/win.ps1 | iex  # 或在服务端运行 xh tuning win
  ```
- **macOS（终端扩容 Socket 接收窗口至 32MB）**：
  ```bash
  sudo sysctl -w kern.ipc.maxsockbuf=33554432 net.inet.tcp.recvspace=4194304 net.inet.tcp.autorcvbuf=1 net.inet.tcp.autorcvbufmax=33554432 net.inet.tcp.fastopen=3
  ```
- **Linux 客户端**：
  ```bash
  sudo sysctl -w net.core.rmem_max=67108864 net.ipv4.tcp_rmem="4096 262144 67108864" net.ipv4.tcp_fastopen=3
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

| # | 节点名称（v4.9.38） | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H2` | XHTTP (h2) + vlessenc | 经 CDN TCP 443 | **TCP 稳健回源**，UDP 封锁时的 CDN 逃生通道 |
| **2** | `VLESS-XHTTP-CDN-H3` | XHTTP (QUIC) + vlessenc | 经 CDN UDP 443 | **隐藏真实 IP**，防封锁与救砖 |
| **3** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | 直连 UDP 8443 | 直连 QUIC，`mode=stream-up` |
| **4** | `Hysteria2-H3-Direct` | Hysteria 2 | 直连 UDP 443 | 标准 HTTP/3 形态，实测下行最快（v4.9.26） |
| **5** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **6** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |
| **7** | `VLESS-Reality-Up-CDN-Down` | 上下行分离 + vlessenc | 上行 Reality 直连 / 下行 CDN（h2） | 0-RTT 直连上行 + CDN 满速下行防封 |

> 默认关闭、按需开启：`VLESS-CDN-Up-Reality-Down`（`FEATURE_CDN_UP_REALITY_DOWN`）、`VLESS-XHTTP-Direct-H2`（`FEATURE_H2_DIRECT`）、`Hysteria2-Obfs-Direct`（`FEATURE_HY2_OBFS`）。

---

## 六、常见问题与排错

| 故障现象 | 核心排查原因 | 快速解决指引 |
| :--- | :--- | :--- |
| **Reality 节点连接失败** | 客户端与网络时间偏差 > 30 秒 | 开启客户端系统「自动从网络同步时间」（防重放） |
| **Mihomo 上下行分离报错** | Mihomo 浅拷贝继承父级 Reality 配置 | 在 `download-settings` 声明 `reality-opts: { public-key: "" }` |
| **直连 UDP / Hysteria 2 超时** | 云服务商外部安全组拦截 | 云控制台安全组放行 UDP 443 / 8443 / 8446 与 TCP 443 / 8445 |
| **内核参数冲突 / 被篡改** | `/etc/sysctl.d/` 存在外部冲突脚本 | 运行 `xh conflict` 自动检测并一键自愈修复 |

---

## 七、版本迭代与核心调优演进记录 (v4.8 - v4.9.38)

本项目经跨洋高延迟弱网环境（160ms+ / 1% 丢包）实测迭代，核心演进总结如下：

| 演进领域 | 涉及版本 | 核心技术方案与调优结论 |
| :--- | :--- | :--- |
| **官方正式版铁律** | v4.9.8–v4.9.18 | 严格锁定 `releases/latest`（当前 v26.3.27），避开测试版后量子握手（MLKEM768）断连陷阱；深度适配主流客户端订阅语法 |
| **双轨分离拓扑** | v4.9.19–v4.9.29 | 落地 Reality-Up-CDN-Down（0-RTT 直连上行+CDN 满速下行）与 CDN-Up-Reality-Down；攻克 Mihomo 继承 bug；8001 启用 vlessenc 防 CDN 窥探 |
| **网络流控极限调优** | v4.8.x–v4.9.30 | 协同 BBRv3 与 TCP Brutal（锁定 3800 Mbps）；实测维持 **64MB** Socket 缓冲上限；多队列 RPS/RFS 软中断均衡；支持 TLS 1.3、TFO 与 ECH/ECN |
| **全链路安全防洪** | v4.9.17–v4.9.33 | 默认关闭高风险大范围端口跳跃，收敛为单端口 Hy2（UDP 443）；Netfilter hashlimit 令牌桶防伪造洪泛；`fs.suid_dumpable=0` 防内存转储；保留端口防短连接碰撞 |
| **节点变慢复盘** | v4.9.34 | netns 160ms/1% 丢包、300↓/50↑ 全节点复测：服务端未退化（Vision 124↓ vs 9-23 的 119）；443 入站 brutal vs bbr 120/112、146/142 重叠 → 维持 brutal；经 CF 上行 h2 恒 10 Mbps、h3 34 Mbps → `CDN-Up-Reality-Down` 上行腿恢复 h3；`tools/xray_rtt_bench.py` 修复 CDN 节点被改写为本机地址（绕过 CF、CDN-H3 撞 Hy2 UDP 443 全部无效） |
| **精简拓扑与默认下线** | v4.9.35 | 默认安装精简剔除 `VLESS-XHTTP-CDN-H2`（上行 10M 硬上限）与 `VLESS-Reality-Up-CDN-Down`，聚焦 6 条核心主力节点；支持通过环境变量按需开启 |
| **拓扑置换与分离优化** | v4.9.36 | 将分离节点置换为 `VLESS-Reality-Up-CDN-Down`（Reality 直连上行 + CDN H2 满速下行），替代原 CDN-Up-Reality-Down 维持 6 大主力架构；修复无 xpadding 模式下 extra downloadSettings 缺失缺陷 |
| **凭据注入加固与 Hy2 修复** | v4.9.37 | 补齐客户端配置生成模块中的 `rawurlencode` 函数与 `HY2_PASSWORD` 兜底机制，根治独立生成或订阅更新时 Hysteria 2 节点因认证密码缺失导致的连接被拒或客户端静默剔除缺陷 |
| **CDN-H2 默认恢复** | v4.9.38 | 恢复默认开启 `VLESS-XHTTP-CDN-H2` 节点（共 7 条核心主力节点），保障晚高峰或运营商封锁 UDP 443 时 CDN TCP 兜底通道开箱即用 |

---

## 八、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
