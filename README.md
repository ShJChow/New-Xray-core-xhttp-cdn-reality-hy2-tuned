# xray-xhttp

**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

>  **已在 Oracle ARM (4 核 24G) / Debian 12 & 13 (推荐) / Ubuntu 22.04 & 24.04 深度测试与调优**

基于 Xray-core 的 **XHTTP + CDN + Reality + Hysteria2** 全能高可用部署方案。默认开启 **xpadding 流量填充混淆 / Hysteria2 Salamander 混淆 / 全套 8 条节点**，并在安装时自动应用**系统级与网络层流控调优（BBR + fq、64MB 缓冲区、1048576 句柄、全套安全加固）**，附带常驻管理工具 `xh`。

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
- [七、免责声明](#七免责声明)

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
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

按照终端提示依次输入：
1. **Reality / 直连域名**（如 `reality.example.com`）
2. **CDN 域名**（如 `cdn.example.com`）
3. 选择伪装站或默认设置即可全自动完成安装。

---

### 2. 零交互环境变量一键部署

适合重装系统或批量自动化部署：

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
AUTO=1 REALITY_DOMAIN=reality.example.com CDN_DOMAIN=cdn.example.com IP_CHOICE=1 FALLBACK_MODE=proxy REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu CDN_FALLBACK_ORIGIN=https://www.harvard.edu CDN_ECH=n bash ~/install.sh
```

#### 常用环境变量速查

| 环境变量 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `AUTO` | 设为 `1` 开启零交互全自动安装 | `0` |
| `REALITY_DOMAIN` | 直连 / Reality 域名（**必填**） | — |
| `CDN_DOMAIN` | CDN 代理域名（**必填**） | — |
| `IP_CHOICE` | `1` 为 IPv4，`2` 为 IPv6 | `1` |
| `FALLBACK_MODE` | `proxy`（反代真实大学网站）/ `static`（本地网页） | `proxy` |
| `FEATURE_AUTO_TUNING`| 自动开启系统与网络底层调优（BBR/64M缓冲/句柄） | `true` |
| `NODE_TAG` | 自定义节点名称后缀（如 `hk-oracle`） | `vps` |

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

安装完成后将提供 **8 条全协议节点**，客户端通过 `urltest` 自动分流调度：

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
| **1** | `VLESS-XHTTP-TLS-CF-h2` | XHTTP (TCP) | 经 CDN 443 | **隐藏真实 IP**，防封锁与救砖 |
| **2** | `VLESS-XHTTP-TLS-CF-h3` | XHTTP (QUIC) | 经 CDN 443 | 经 CDN 的 QUIC 备用链路 |
| **3** | `VLESS-XHTTP-TLS-QUIC` | XHTTP (QUIC) | 直连 UDP 8444 | 直连 QUIC，`mode=stream-up` |
| **4** | `VLESS-XHTTP-TLS-TCP` | XHTTP (TCP) | 直连 TCP 8445 | 直连 TCP，手机端低功耗首选 |
| **5** | `Hysteria2-QUIC-TLS` | Hysteria 2 | 直连 UDP 8443 | **Brutal 拥塞引擎**，弱网丢包杀手 |
| **6** | `VLESS-TCP-REALITY-Vision` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **7** | `VLESS-XHTTP-REALITY` | XHTTP-Reality | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |
| **8** | `VLESS-XHTTP-Reality-UP-CDN-Down` | 上下行分离 | 上行直连 / 下行 CDN | 兼顾极速上行握手与 CDN 下行大带宽 |

---

## 六、常见问题与排错

### 1. Reality 节点测速显示 `-1`（连不上）？
- **原因**：Reality 属于 4 层纯 TCP 握手伪装协议，**绝对不能开启 Cloudflare 小黄云代理**。
- **解决**：在 Cloudflare 控制台中确认 `reality.example.com` 为 **灰色云朵（仅 DNS）**，并且客户端填写的 `server` 必须是真实的 VPS IP 或灰云域名。

### 2. 直连 UDP / Hysteria 2 节点超时？
- **原因**：云服务商（如 Oracle Cloud、AWS、阿里云、腾讯云）默认带有外部**安全组防火墙**。
- **解决**：在云服务商控制台的安全组规则中，放行入站端口：
  - **UDP 8443** (Hysteria 2)
  - **UDP 8444** (XHTTP QUIC)
  - **TCP 8445** (XHTTP TCP)
  - **TCP 443** 与 **TCP 80**

### 3. 如何检测服务器内核配置冲突？
- 终端运行 `xh conflict`，脚本会自动检测 `/etc/sysctl.d/` 下所有第三方冲突文件并提示自愈修复。

---

## 七、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
