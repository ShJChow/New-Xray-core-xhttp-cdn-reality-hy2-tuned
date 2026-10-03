# xray-xhttp
小白请使用ai agent，把本项目发给agent配置。
**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

>  **已在 Oracle ARM (4 核 24G) 和系统 Ubuntu  26.04.01 深度测试与调优**。本协议专门应对规避AI封号，使用AI,客户端建议打开Tun模式。

基于 Xray-core 的 **XHTTP + CDN + Reality + Hysteria2** 全能高可用部署方案。默认开启 **xpadding 流量填充混淆 / Hysteria2 Salamander 混淆 / 全套 8 条核心节点**，并在安装时自动应用**系统级与网络层流控调优（BBR + fq、64MB 缓冲区、1048576 句柄、全套安全加固）**，附带常驻管理工具**xh**。集成 TCP Brutal 极速拥塞控制算法

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
- [四、节点拓扑与双轨架构](#四节点拓扑与双轨架构)
- [五、常见问题与排错](#五常见问题与排错)
- [六、版本迭代与核心调优演进记录 (v4.8 - v4.9.51)](#六版本迭代与核心调优演进记录-v48---v4951)
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

#### 方案 A：现代位置参数单行版（强烈推荐：100% 免疫终端换行与转义报错）
```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) AUTO=1 REALITY_DOMAIN="reality.example.com" CDN_DOMAIN="cdn.example.com" NODE_TAG="oracle-vps"
```
> 如需覆盖更多自定义项，直接在末尾空格追加即可（如 `IP_CHOICE=1`、`CDN_FALLBACK_ORIGIN="https://www.harvard.edu"`）。
>
> **CDN 域名开 Cloudflare 代理（橙云）时强烈建议追加 `CF_Token="<API Token>"`**（权限：Zone.Zone 读 + Zone.DNS 编辑）：证书改用 DNS-01 签发与续期，不占 80 端口、续期不停 nginx。不传则为 standalone（HTTP-01），CDN 走代理后 60 天续期必败；已安装的机器执行 `CF_Token=<API Token> xh cert dnscf` 切换，`xh cert show` / `xh diag` 可查看续期方式。脚本内部默认值已涵盖 `FALLBACK_MODE=proxy`、`FEATURE_AUTO_TUNING=true`、`FEATURE_XPADDING=true`、`FEATURE_H3_DIRECT=true`、`FEATURE_HY2=true` 等优化配置，绝大多数场景无需重复传入。


#### 方案 B：自定义端口与路径模板（密码由脚本全自动生成 SHA256 高熵密钥，无需手动指定）
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
xh cdnh3 [show|on|off] # CDN QUIC(h3) 默认节点开关与订阅同步
xh h2direct [show|on|off]   # 备用节点 XHTTP-Direct-H2（TCP 直连）
xh hy2obfs [show|on|off]    # 备用节点 Hysteria2-Obfs（UDP salamander 混淆）
xh split [show|reality-up on|off|cdn-up on|off]  # 备用节点 上下行分离两条
xh block [show|cn on|off|ads on|off] # 出站屏蔽回国 IP / 广告域名（默认关闭）
xh timediff [show|on [毫秒]|off] # Reality maxTimeDiff 时间差校验（默认关闭）
xh brutal              # TCP Brutal 极速拥塞控制状态、开启/关闭与速率调节
xh tuning [win|mac|sb] # 查看对应系统的客户端千兆调优代码
xh conflict            # sysctl 内核参数冲突检测与一键自愈
xh log [xray|nginx]    # 实时查看服务运行与连接日志
xh update [--auto]     # 一键升级 Xray-core（失败自动回滚）
xh start | stop | restart # 启停与重启服务
```

---

## 四、节点拓扑与双轨架构

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

| # | 节点名称（v4.9.64） | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | 直连 UDP 8446 | 直连 QUIC，`mode=stream-up` |
| **2** | `Hysteria2-H3-Direct` | Hysteria 2 | 直连 UDP 443 | 标准 HTTP/3 形态，实测下行最快（v4.9.26） |
| **3** | `Hysteria2-Obfs-Direct` | Hysteria 2 + salamander | 直连 UDP 8443 | 混淆版，QUIC 被深度识别时使用 |
| **4** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **5** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |
| **6** | `VLESS-Reality-Up-CDN-Down` | XHTTP 上下行分离 | 上行 Reality 直连 / 下行经 CDN | 纯客户端链接，不动服务端 |

> 默认关闭、按需用 `xh` 开启：`VLESS-XHTTP-CDN-H3`（`xh cdnh3 on`）、`VLESS-XHTTP-CDN-H2`（`xh cdnh2 on`，TCP 兜底）、`VLESS-CDN-Up-Reality-Down`（`xh split cdn-up on`）、`VLESS-XHTTP-Direct-H2`（`xh h2direct on`）。

---

## 五、常见问题与排错

| 故障现象 | 核心排查原因 | 快速解决指引 |
| :--- | :--- | :--- |
| **Reality 节点连接失败** | 客户端与网络时间偏差 > 30 秒 | 开启客户端系统「自动从网络同步时间」（防重放） |
| **Mihomo 上下行分离报错** | Mihomo 浅拷贝继承父级 Reality 配置 | 在 `download-settings` 声明 `reality-opts: { public-key: "" }` |
| **直连 UDP / Hysteria 2 超时** | 云服务商外部安全组拦截 | 云控制台安全组放行 UDP 443 / 8443 / 8446 与 TCP 443 / 8445 |
| **内核参数冲突 / 被篡改** | `/etc/sysctl.d/` 存在外部冲突脚本 | 运行 `xh conflict` 自动检测并一键自愈修复 |

---

## 六、版本迭代与核心调优演进记录 (v4.8 - v4.9.51)

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
| **精简下线 CDN-H3** | v4.9.39 | 默认精简剔除 `VLESS-XHTTP-CDN-H3` 节点（收敛为 6 大核心主力节点），避免 Cloudflare CDN 边缘 UDP 443 在部分运营商网络下的 QoS 丢包与高延迟抖动；保留 `FEATURE_CDN_H3` 与 `xh cdnh3` 支持按需开启 |
| **全面剔除低效 HTTP/1.1** | v4.9.40 | 服务端入站、客户端 URI、Mihomo 配置全面剔除 `http/1.1`，仅保留现代多路复用 ALPN（`h2` / `h3`），杜绝协议降级与队头阻塞风险，提升连接复用效率与传输稳健性；同机 sbbox 在 v2.7.24 同步加入 |
| **Nginx 回落回环加固与分流优化** | v4.9.41 | 将 Nginx 伪装站 8003 端口严格绑定至 `127.0.0.1:8003` 本地回环，杜绝向公网暴露回落伪装端口，防止网络空间测绘引擎主动探测；优化 Mihomo 客户端分流规则，修复 iCloud 错分至微软服务的规则集误配，新增独立的 `iCloud服务` 策略组与专用 Microsoft 规则集 |
| **ALPN 彻底纯化与残留清理** | v4.9.42 | 彻底清除管理命令行（`xh cdnh2`/`cdnh3`）、客户端示例模板与压测工具中遗留的 `http/1.1`，确保全协议链路纯化锁定现代多路复用 `h2`（HTTP/2 为协议下限）与 `h3`（HTTP/3），消除任何动态切组或重载时的协议回退隐患 |
| **精简下线分离节点** | v4.9.43 | 默认精简剔除上下行分离节点 `VLESS-Reality-Up-CDN-Down`，收敛为 5 大核心主力节点，大幅降低多链路维护复杂度与连接建立开销；保留 `FEATURE_REALITY_UP_CDN_DOWN` 开关支持按需开启 |
| **网卡 fq 队列开机持久化** | v4.9.44 | 修复重启后 fq 失效：`net.core.default_qdisc=fq` 只对此后新建的 qdisc 生效，网卡在 sysctl 加载前就已建好，实测重启后出口网卡是 `mq` + `pfifo_fast`，此前的 fq、`initcwnd 32`、`txqueuelen`、RPS/RFS 都只在 `xh tuning on` 时执行一次。现写成 `/usr/local/sbin/xray-xhttp-nic-tune` + `xray-xhttp-nic.service`（OpenRC 用 `/etc/local.d`）开机重设，`xh tuning off` 与卸载时移除；单核机器也会设置 fq（RPS 仍只在多核时开启）。核对：`tc qdisc show dev <网卡>` 应为 `mq` 下挂 `fq`，不能只看 sysctl。同机 sbbox 在 v2.7.32 同步加入，两边统一为 mq + 每队列 fq，谁后执行结果都相同。另修 `xh version` 因 node.env 值带引号而误报「xh 被更新过」。**不采纳**：把 443 Reality 入站 Brutal 换回 BBR——加测重传率（netns 160ms，N=3）：1% 丢包 300↓/50↑ 下行 121 vs 108 Mbps、重传 1.33% vs 0.71%；0% 丢包 300↓/50↑ 143 vs 130、0.86% vs 0.06%；100↓/20↑ 71 vs 69、0.06% vs 0.01%，Brutal 吞吐不输且不会定速超发灌爆线路，维持 |
| **证书续期改走 DNS-01** | v4.9.45 | 修复 CDN 走 Cloudflare 代理后证书**自动续期必败**：安装器只用 standalone（HTTP-01），首次签发时若 CDN 还是灰云能成功，之后 HTTP-01 验证会被 CF「Always Use HTTPS」301 到 https、回源 443（Reality / 伪装站），续期前钩子还会停掉 nginx——续期日失败、证书到期当天 CDN 526、h3-direct / hy2 握手失败，平时一切正常、日志无异常。现安装时传 `CF_Token` 即用 `dns_cf` 签发（acme.sh 保存 Token 供续期）；新增 `xh cert [show\|dnscf]` 查看 / 切换续期方式（切换前先用 CF API 验证 Token 能访问该 Zone，Token 经 stdin 传给 curl、不进进程参数）；`xh diag` 新增「standalone + CDN 已走代理」检查。本机用 LE staging 对真实配置副本完整跑通 `--renew`（TXT 写入、双域验证、TXT 清理）。同机 sbbox 在 v2.7.33 同步加入 DNS-01 签发与续期钩子自动挂载 |
| **tcp-brutal 2.0.1 适配** | v4.9.46 | 上游 tcp-brutal 2.0.1 已自带新内核 `tso_segs` 钩子适配（`BRUTAL_HAVE_TSO_SEGS`，按目标内核头文件判别），`patch_tcp_brutal_tso_segs` 遇到上游已适配的源码一律跳过。该补丁把新钩子接到恒返回 2 的 `min_tso_segs` 上，而 `tso_segs` 的返回值是「一次发送的段数」，在 7.1+ 内核会把 TSO 限成每次 2 段；上游实现返回按速率估算的段数。原厂 7.0 内核走 `min_tso_segs` 路径，2.0.0 → 2.0.1 运行时行为不变（本机实测 Reality-Vision 160ms/1%、300↓/50↑ 下行 121 → 129 Mbps，范围重叠）。同机 sbbox 在 v2.7.34 同步加入 |
| **nginx / tcp-brutal 新版本提醒与校验更新** | v4.9.47 | 每周 `xh update --auto` 顺带**只检查** nginx mainline 与 tcp-brutal 新版本：写入 `/etc/xhttp-cdn/updates-available`，root 登录时与 `xh status` 显示，**不自动安装**；日志 `journalctl -t xh-autoupdate`，已有 cron 行无需改动。手动更新：`xh nginx update`——下载源码与 `.asc`，从 nginx.org 导入发布密钥后校验签名，且签名者主指纹必须在代码内固定的 4 个 nginx 开发者指纹中（防下载源或密钥文件被替换），再按本机 `nginx -V` 的原编译参数编译、用新二进制 `-t` 测试现有配置、替换并复核 8003 端口，失败回滚；`xh brutal update [--now]`——源码包 sha256 必须同时等于发布者 `hashes.txt` 与 GitHub 独立计算的资产 digest，只编译进 DKMS（下次开机生效），`--now` / `xh brutal reload` 立即重载（Xray 停止数秒）。实测：篡改下载、缺校验数据、签名者不在固定列表均被拒绝；完整走一遍 nginx 更新（沙箱路径）28 秒，新旧编译参数一致。同机 sbbox 在 v2.7.35 同步加入外置 Hysteria2 与 tcp-brutal 的提醒与校验更新 |
| **服务端 DNS 按 CDN 边缘远近重排 · 吸收第三方调优中的有效项** | v4.9.48 | **DNS**：Xray 内置 DNS 首选改为 `9.9.9.10`（Quad9 不拦截版），`1.1.1.1` 次之。解析耗时只在每个域名首次查询时付一次，返回的 CDN 边缘远近却决定之后每条连接的延迟。本机 32 个常用域名 × 各 3 次，比最优边缘慢 3ms 以上的：8.8.8.8 有 10 个、1.1.1.1 有 5 个、9.9.9.10 只有 1 个（Apple / iCloud / Microsoft 等 Akamai 系差 10~50ms；8.8.8.8 带 ECS 反而选得远）；未缓存解析 9.9.9.10 与 1.1.1.1 相当（2~9ms）。**系统调优**：`net.core.rmem_max / wmem_max` 由 128MB 收敛为 64MB（与 `tcp_rmem / wmem` 上限一致）；新增 `vm.min_free_kbytes`（large 档 64MB / medium 档 32MB，给高速收包时软中断里的原子分配留余量）与 `kernel.sched_autogroup_enabled = 0`；`nf_conntrack` 登记进 `/etc/modules-load.d/xray-xhttp-conntrack.conf`——开机时 systemd-sysctl 早于 iptables / Docker 加载该模块，`nf_conntrack_max` 会被静默跳过（`tuning off` 一并删除）；`kernel.core_pattern = core` 改由调优代码写入（此前只在注释里提到、靠手工补写，重跑 `tuning on` 就会丢）。这几项吸收自第三方一键脚本（vps-tcp-tune）里与本项目不冲突的部分；其余不采纳：`udp_rmem_min 8192`、`somaxconn 4096`、`notsent_lowat 16384` 与已有取值冲突，开机单根 `fq` 会覆盖 `mq` + 每队列 fq，系统 DNS 走 DoT 实测未缓存解析无差异（9~25ms），THP never / `overcommit_memory=1` / dirty 比例对转发机无收益。**握手测量**：新增 `tools/xray_handshake_bench.py`（netns 纯 RTT，逐节点测冷启动 / 热连接 / 闲置后首包并折成 RTT 个数，支持 Xray / sing-box / mihomo 客户端）。160ms 实测：Hy2 / XHTTP / AnyTLS / TUIC / naive 热连接均为 1.0R，已是下限；Vision 每条连接 3R（不能多路复用；客户端 TFO 实测已协商但端到端无收益）；XHTTP 系冷启动多 1R，是 VLESS Encryption 首次没有票据、只能走 1-RTT，属协议固有。**客户端提示**：Xray-core 作为 Hysteria2 客户端时默认不发 QUIC 保活，闲置 65s 后隧道即断，下一次请求多 2R（约 330ms）；sing-box / mihomo 客户端不受影响。服务端 `finalmask.quicParams.keepAlivePeriod` 实测无效，未采纳；v2rayN 请让 Hysteria2 保持默认的 sing-box 内核。复测：`python3 tools/xray_handshake_bench.py 160 3 65,200,700`。同机 sbbox 在 v2.7.37 同步加入 64MB 与三项系统调优，并把 sing-box 与外置 Hysteria2 的出站 DNS 同样改为 9.9.9.10 |
| **Xray-core 客户端 Hysteria2 闲置断线修复** | v4.9.49 | `Hysteria2-H3-Direct` 链接新增 `fm` 参数（v2rayN / v2rayNG 的 finalmask JSON），为 Xray-core 客户端打开 QUIC 保活 `keepAlivePeriod: 10`。**根因**（v26.3.27 源码）：客户端 `transport/internet/hysteria/dialer.go` 里 10s 的默认保活被注释掉，`KeepAlivePeriod` 为 0；服务端 `hub.go` 的 QUIC 配置根本不传 `KeepAlivePeriod`（v4.9.48 试过在入站加保活，无效即因于此）；空闲超时按两端较小值取 30s。结果是 v2rayN 选 Xray 内核跑 Hy2 时闲置 30s 隧道即断，下一次请求重做 QUIC 握手 + 认证，多 2 个 RTT。**实测**（`tools/xray_handshake_bench.py`，160ms RTT）：闲置 65s 后首包 3.1R → 1.0R，闲置 200s 3.2R → 1.0R，与 sing-box 客户端一致；限速吞吐（160ms / 1% 丢包、300↓/50↑，两个变体分进程交替各 2 次 × 3 样本，v4.9.50 重测）下行中位 127 / 132 对 127 / 130、上行均为 41，无影响。**兼容**：v2rayN（7.24.9 源码）与 v2rayNG（2.2.6）见到 `fm` 会用它**整体替换**自己按 `upmbps` / `downmbps` 生成的 finalmask，所以 `fm` 原样复刻了那部分（`congestion: brutal` + 声明带宽，未声明时为 `bbr`）；JSON 无效时二者保留原配置、不会断。v2rayN 的 sing-box 内核、mihomo、Hysteria 官方客户端不读该参数；小火箭订阅在生成时剔除 `fm`（`shadowrocket.txt` 与改动前逐字节相同），Mihomo 订阅不变。只加在无混淆、无端口跳跃的 H3 节点上：带 salamander 的 `Hysteria2-Obfs-Direct`（默认关闭）若也整体替换会丢掉混淆掩码。`tools/xlinks.py` 同步按 v2rayN 的方式解析 `fm`。已部署节点执行 `xh resub` 前需先把 `fm` 加进 `client-config.txt` 的 Hy2-H3 行（或重跑安装脚本），客户端更新订阅后生效 |
| **混淆节点同样打开保活 · 测速工具修正 Xray Hy2 连接共享** | v4.9.50 | **混淆节点**：`Hysteria2-Obfs-Direct`（默认关闭）的链接也附带 `fm`。v2rayN / v2rayNG 见到 `fm` 会整体替换自己生成的 finalmask，所以 `fm` 里除 `quicParams`（brutal + 声明带宽 + `keepAlivePeriod: 10`）外还复刻 `udp: [{type: salamander, settings: {password}}]`，开端口跳跃时再加 `udpHop: {ports: mport, interval: "30"}`（二者未设置时的默认间隔，两客户端源码一致）。生成逻辑抽成 `hy2_client_fm_param`，H3 节点输出与 v4.9.49 逐字节相同；密码含 `"` 或 `\` 时不带 `fm`（退回旧行为）。实测（临时混淆服务端，160ms RTT）：闲置 65s / 200s 后首包 3.1R → 1.0R；负对照「`fm` 漏掉混淆掩码」、「混淆密码错误」、「完全不混淆」全部连不上。**测速工具**：Xray 的 hysteria 客户端按「目标 IP:端口」全局缓存连接（v26.3.27 `dialer.go` 的 `manger.m[addr]`），同一进程里指向同一服务端的多个 Hy2 出站共用第一个出站的连接与配置——v4.9.49 发版前那组同进程吞吐 A/B 因此无效（本版已按分进程重测并订正上一行），同进程的「错误示范」也会被测成能连通。`tools/xray_handshake_bench.py` 改为每个 Xray 变体单独一个进程，并新增 `uri` 变体键（直接给一条链接）；`tools/xray_rtt_bench.py` 遇到同地址的多个 Hy2 变体直接拒绝运行；握手工具的清理由宽泛的 `pkill -f` 改为只匹配本次临时目录（旧写法会误杀命令行里含同名字样的调用方 shell）；`tools/xlinks.py` 新增单条解析 `parse_link` |
| **网卡 MTU 高于 1500 时自动降到 1500（PMTU 黑洞兜底）** | v4.9.51 | 部分云厂商网卡默认 MTU 9000（巨帧），公网路径却只有 1500：服务端发出超过 1500 字节的 TCP 段（如 3.7KB 的 TLS 证书链）在公网出口被静默丢弃，表现为 TCP 握手成功、TLS 阶段超时或 RST，Reality / CDN 回源等 TCP 节点全断，而 QUIC 节点（单包 <1280）完全正常。开机网卡调优脚本 `xray-xhttp-nic-tune` 现在会在 MTU 大于 1500 时降到 1500，并补一条 `TCPMSS --clamp-mss-to-pmtu`（mangle POSTROUTING，v4/v6，已存在则不重复，落盘 `netfilter-persistent save`）；只在真的降过 MTU 时才动防火墙。本机 `enp0s6` 为 1480，不触发，行为不变。验证：netns 内 veth MTU 9000 → 1500，规则一条，二次执行不重复；MTU 1400 不被改动。同机 sbbox 在 v2.7.38 同步加入。 |
| **默认 CDN 节点改为 CDN-H3** | v4.9.52 | 默认安装的第一个节点由 `VLESS-XHTTP-CDN-H2` 改为 `VLESS-XHTTP-CDN-H3`（经 CDN 走 UDP 443 / QUIC）：`FEATURE_CDN_H3` 默认 `true`、`FEATURE_CDN_H2` 默认 `false`，安装脚本、客户端配置、节点环境文件与 `xh cdnh3` 的兜底默认值同步；README 节点表与命令列表随之更新。UDP 443 被限速或封锁时，可用 `xh cdnh2 on` 或 `FEATURE_CDN_H2=true` 开启 TCP(h2) 兜底节点 |
| **出站分流开关（`xh block`）** | v4.9.53 | 参考 zxcvos/Xray-script 的可选规则，新增默认**关闭**的 `xh block cn on\|off`（出站屏蔽回国 IP：freedom 出站 `finalRules` 在域名解析成 IP 之后再判 `geoip:cn`）与 `xh block ads on\|off`（路由规则屏蔽 `geosite:category-ads-all`）；规则各占一行并带 `xh-block-*` 标记，开关只增删该行，先 `xray -test` 校验、失败或重启失败自动回滚；状态写入 `node.env`（`FEATURE_BLOCK_CN` / `FEATURE_BLOCK_ADS`），重装时保持；管理菜单新增第 18 项（卸载顺延为 19），`xh tuning` 提示补充 win / mac / linux / sb。回国 IP 屏蔽会让依赖本代理访问国内站点的客户端断流，仅在落地机不需要回国流量时开启 |
| **Reality 时间差校验与 spiderX（`xh timediff`）** | v4.9.54 | 参照 XTLS/REALITY README：新增默认**关闭**的 `xh timediff on [毫秒]\|off`（Reality `maxTimeDiff`，默认 60000，防重放；客户端系统时间偏差超过该值会连不上，需开启自动校时），先 `xray -test` 校验、失败回滚，`REALITY_MAX_TIME_DIFF` 写入 `node.env` 重装保持；客户端 Reality 链接默认附带 `spx`（由 UUID 派生，各部署不同，`FEATURE_REALITY_SPX=false` 可关闭）；管理菜单新增第 19 项（卸载顺延为 20） |
| **Xray 入站与出站去掉 tcpMptcp（只留 TFO）** | v4.9.55 | 对 Xray Reality 入站做了与 sbbox 相同的对比测速（服务端 4 种 tfo / mptcp 组合 × 客户端 3 种，延迟 2ms 与 160ms、每向 0.5% 丢包，经代理请求 `http://www.apple.com`）：Xray 上各组合都**没有出现超时**，TFO 也没有可测的延迟收益；吞吐在噪声范围内，近距离下客户端开 MPTCP 偏慢（上行约 1.5 vs 1.9–2.0 Gbps）。Go 1.24+ 监听默认就启用 MPTCP，显式开启没有意义。因此 Reality / XHTTP / XHTTP+TLS 入站与 freedom 出站去掉 `tcpMptcp`，mihomo 的 Reality 节点去掉 `mptcp: true`，与 sbbox 的「只开 TFO」保持一致（freedom 出站的改动未单独测速）。已安装机器需重新生成配置后生效 |
| **按平台自动选默认（ARM / AMD）并撤回 tcpMptcp 改动** | v4.9.56 | 安装时识别并打印平台：架构（aarch64 / x86_64）、CPU、核数、内存、内核、虚拟化、云厂商（读 DMI，Oracle / AWS / GCP / Azure / 阿里云）。内存 < 1.5GB（如 Oracle 免费 AMD 1GB）默认不安装 TCP Brutal（现场编译内核模块，占内存且拖慢安装；显式 `FEATURE_BRUTAL=true` 仍尊重），无 swap 时给出提示，并给 xray 设 `GOMEMLIMIT`（物理内存 60%）；补装 `python3` 并自检必需命令（缺少会让 `xh minversion` / `ech` / `block` / `timediff` 等管理命令静默失效）。**撤回 v4.9.55**：那次对比测速只覆盖 Reality 入站，Xray 上各组合无超时、也无可测收益，其余入站、freedom 出站与 mihomo 的改动是推广、没有单独测过，因此全部恢复为原来的 `tcpMptcp`，不再改动 |
| **Mihomo TUN 按客户端平台自适应** | v4.9.57 | 订阅目录新增 `mihomo-full-windows.yaml` / `-linux.yaml` / `-macos.yaml` / `-android.yaml`，只改各平台确有区别的 TUN 字段：Windows 开 `strict-route`；Linux 开 `strict-route` + `auto-redirect`；macOS / Android 保持基础值（macOS 不支持 strict-route，Android 由系统 VPN 接管路由）。原 `mihomo-full.yaml` 不变；`xh resub` 与安装均会生成 |
| **全部 XHTTP 节点 mode 统一为 stream-up** | v4.9.58 | 按用户要求，CDN-H2 / CDN-H3 及其余原为 `auto` 的节点（Reality-XHTTP、CDN/Reality 分离节点）的客户端链接与 Mihomo 订阅统一写 `mode=stream-up`（直连节点原本就是）。Cloudflare 开启 gRPC / WebSockets 后实测（单次 20MB 上传，样本很小）：stream-up 可用，下载不受影响，但 6 次上传中 2 次未完整传完（auto 为 0/6），H3 上传偏低且波动大。若某网络上传卡住，把该节点的 `mode=stream-up` 改回 `auto` 即可，服务端无需改动。已安装机器执行 `xh resub` 前需先更新 `client-config.txt` 与 Mihomo 文件 |
| **默认关闭 nginx 访问日志与 Xray 访问日志** | v4.9.59 | 此前 nginx 的 `access_log` 在 http 层默认开启，会把访客 IP、订阅 token 路径与 UA 写进 `access.log`（仅个别 location 单独 `off`）。现 http 层全局 `access_log off`，nginx `error_log` 由 `notice` 改为 `error`，Xray 写 `"access": "none"` 与 `loglevel: error`。**仅新装生效**；已安装机器需手改 `/etc/nginx/nginx.conf` 与 `/usr/local/etc/xray/config.json`（`nginx -t` / `xray -test` 通过后再重载），且旧的 `access.log` 不会被清理。不涉及任何传输参数。 |
| **下行腿与服务端 mode 统一为 stream-up** | v4.9.60 | 按用户要求，Reality/CDN 分离节点的 `downloadSettings` 下行腿（含 dual-cdn / dual-ip / quic-h3 扩展）与服务端 xhttpSettings 的 `mode` 由 `auto` 改为 `stream-up`，与上行腿一致，消除两腿混用。**未实测**（沿用 v4.9.58 的取舍，若上传/下载卡住，把对应 `mode` 改回 `auto` 即可）。已安装机器需把 `/usr/local/etc/xray/config.json` 中的 `"mode": "auto"` 手改后 `xray -test` 再重启；扩展脚本里节点链接本身的上行 `mode=auto` 未改。 （v4.9.66 起 CDN 腿回到 auto） |
| **所有节点上行 / 下行 mode 统一为 stream-up** | v4.9.61 | 把 `src/11-client-config.sh` 中 CDN 分离节点下行的 `xhttpSettings`，以及 dual-cdn / dual-ip / quic-h3 / common-nodes 扩展里节点链接和 Mihomo 片段残留的 `mode=auto` 全部改为 `stream-up`；至此脚本中不再有 `auto`。**未实测**，卡住时把对应节点的 `mode` 改回 `auto` 即可（服务端无需改动）。 （v4.9.66 起 CDN 腿回到 auto） |
| **nginx 放宽 TLS 并关闭 session tickets，回源不再显式关缓冲** | v4.9.62 | 按用户要求：`ssl_protocols` 由仅 TLS1.3 改为 `TLSv1.3 TLSv1.2`（附 TLS1.2 `ssl_ciphers`），`ssl_session_tickets` 由 `on` 改为 `off`；XHTTP 回源 location 去掉 `proxy_buffering off` / `proxy_request_buffering off` / `X-Accel-Buffering`（`grpc_pass` 本就不吃 `proxy_*` 缓冲指令，实际行为基本不变）。副作用：关 tickets 后 `ssl_early_data`（0-RTT）无会话可恢复，不再生效；开 TLS1.2 会放宽原先的降级防护。已安装机器需手改 `/etc/nginx/nginx.conf`，`nginx -t` 后重载。**未实测**。 （v4.9.65 再放开 TLS1.1） （tickets 已在 v4.9.69 重新打开） |
| **默认 5 节点 + 备用节点用 xh 菜单开关** | v4.9.63 | 安装命令默认的 5 条节点（Reality-Vision、Reality-XHTTP、XHTTP-Direct-H3、CDN-H3、Hysteria2-H3）本来就是源码默认值，未改。其余备用节点新增 xh 开关：`xh h2direct`（TCP 8445，加服务端入站并放行端口）、`xh hy2obfs`（UDP 8443 salamander，同上）、`xh split reality-up|cdn-up`（纯客户端链接）；菜单 20–23，卸载顺延为 24。实现：安装时用「全部备用节点开启」的参数再渲染一遍存进 `/etc/xhttp-cdn/all/`（节点行、Mihomo、两条服务端入站文本），开关只从库里取，与全新安装逐字一致；服务端入站用成对 `// >>xh:` 标记写入，关闭时整块删除，配置字节级还原。**旧版安装的机器没有该库**，需重新部署才有这些开关。云安全组 / 安全列表仍需自行放行端口。修正 cdnh2 / cdnh3 说明里「6 大核心节点」「备用」的过时措辞。 （默认节点集已在 v4.9.64 调整） |
| **默认节点集改为当前使用的 6 条** | v4.9.64 | 按用户实际使用的节点调整安装命令默认值：`FEATURE_HY2_OBFS` 默认 `true`（Hysteria2-Obfs-Direct，UDP 8443）、`FEATURE_REALITY_UP_CDN_DOWN` 默认 `true`（Reality-Up-CDN-Down）、`FEATURE_CDN_H3` 默认 `false`（CDN-H3 改为备用，`xh cdnh3 on` 开启）。默认节点为 Direct-H3、Hysteria2-H3、Hysteria2-Obfs、Reality-Vision、Reality-XHTTP、Reality-Up-CDN-Down；其余备用节点用 xh 开关。同步修正 xh 菜单 / 帮助里「默认开启 / 备用」的措辞，README 节点表更新。**只影响新装机器**；已安装机器的节点集不变。 |
| **nginx 再放开 TLS1.1** | v4.9.65 | 按用户要求 `ssl_protocols` 为 `TLSv1.3 TLSv1.2 TLSv1.1`。OpenSSL 3 默认安全级别会拒绝 1.1，所以 `ssl_ciphers` 追加了 `ECDHE-*-AES*-SHA` 四个 CBC 套件与 `@SECLEVEL=0`，否则服务端对 1.1 客户端回 protocol version 告警。副作用：`@SECLEVEL=0` 对整个 nginx TLS 生效，会放宽 1.2 的最低密钥 / 签名强度检查；1.1 的 CBC-SHA1 套件弱于 AEAD。只影响经 nginx 8003 的 CDN / 回落流量；Xray 的直连入站仍写死 TLS1.3。本机已验证 1.1 / 1.2 / 1.3 都能握手。已安装机器需手改 `/etc/nginx/nginx.conf`，`nginx -t` 后重载。 |
| **速度不稳修复：Hy2 不再声明 Brutal 带宽，CDN 腿改回 auto** | v4.9.66 | 用户反馈节点速度慢且不稳，服务端自查（CPU / 内存 / 网卡正常，全部连接 BBR，TCP 重传约 0.9%，UDP 无丢包）无瓶颈，问题在客户端链路与节点参数：1. `HY2_UP_MBPS` / `HY2_DOWN_MBPS` 默认值由 100 / 1000 改为**空**：链接不再带 `upmbps` / `downmbps`，`fm` 的拥塞为 BBR，Mihomo 条目不再写 `up` / `down`——原先 sing-box / Mihomo 客户端会按声明速率 Brutal 硬发，线路达不到时超发丢包、速度忽快忽慢；确实知道自己的线路带宽时用 `HY2_UP_MBPS=… HY2_DOWN_MBPS=…` 再开；2. 经过 CDN 的腿（CDN-H2 / CDN-H3、CDN-Up-Reality-Down 的上行腿、Reality-Up-CDN-Down 的下行腿、dual-cdn / quic-h3 扩展）的 `mode` 由 `stream-up` 改回 `auto`，直连与 Reality 腿保持 `stream-up`（依据 v4.9.58 实测：stream-up 经 Cloudflare 上传 6 次有 2 次没传完，auto 为 0 次）。Mihomo 的分离节点下行腿没有独立 `mode` 字段，仍随父级。**未测速**：以上依据是服务端自查与既有实测，不是对你线路的实测；仍慢请告诉我是哪条节点、哪个客户端和运营商。 |
| **审查修复：服务端 8001 回到 auto，开关改为原子、可回滚** | v4.9.67 | 代码审查后的修复。1. **服务端 8001 入站 `mode` 由 `stream-up` 改回 `auto`**：v4.9.66 把 CDN 腿改成 `auto`，但 8001 写着 `stream-up` 会拒绝 packet-up 上传，本机用真实 Xray 客户端实测 `stream-up` 通、`auto` / `packet-up` 不通，改后三种全通；直连入站仍只收 `stream-up`；2. 安装时写入的 `h2direct` / `hy2obfs` 入站现在带 `// >>xh:` 标记，`xh … off` 能整块删除；无标记但端口已在配置里时明确报错，不再静默放过；3. 开关顺序改为「先改客户端文件（原子写盘）→ 再改服务端 → 最后写标志位」，任一步失败撤销前面的步骤，并打印原因；xray 校验报错、回滚后重启结果、防火墙写入失败都不再被吞；4. `xh cdnh2` / `cdnh3` 从备用节点库取节点（旧安装才用克隆兜底），修复 CDN-H3 默认关闭后克隆到错误节点的问题；5. 备用节点库先渲染到临时目录并校验 6 条节点，再整体替换，错误写入 `/etc/xhttp-cdn/all-render.log`；6. 菜单 20–23 放进子 shell，一次失败不再关掉整个菜单；7. 更正过时注释与文案。限制：备用节点库是安装时快照，装好后 `xh ech` 的改动不会同步进库；节点被 `NODE_NAME_MAP` 改名后开关会明确报错。 |
| **安装健壮性：可选入站不再拖垮 Reality** | v4.9.68 | 用户反馈新装 Ubuntu / Debian 服务器上 Reality 不通，**根因尚未确认**（没拿到失败机器的日志）。按其中一个假设做防御性修复：Xray 是一个进程，任何入站绑定失败都会让整个 Xray 起不来。1. 安装时先检查可选入站的端口：UDP `HY2_PORT`（Hysteria2-Obfs，v4.9.64 起默认开）或 TCP `H2_PORT`（h2-direct）被别的进程占用时，直接关掉该节点并提示占用者；2. `xray -test` 失败且开着这两个可选入站时，自动关掉它们、用同一份模板重新生成配置再试，核心节点（Reality 等）不受影响；核心配置本身有错仍然报错退出；3. 启动后新增监听自检：TCP 443（Reality）以及已开启的 UDP / TCP 节点端口逐个检查，缺哪个就明确告警，方便区分「服务端没监听」和「云安全组没放行」。若仍不通，请在失败机器上运行 `systemctl status xray`、`journalctl -u xray -n 40`、`xray -test -config /usr/local/etc/xray/config.json`、`ss -ltnup \| grep -E ':443 \|xray'`、`xh diag` 并反馈。 |
| **nginx 重新打开 session tickets（重连更快）** | v4.9.69 | 按用户选择，`ssl_session_tickets` 由 `off` 改回 `on`。客户端重连时可以恢复会话，少传证书，少一次完整握手；同时它是 `ssl_early_data`（0-RTT）与 `Early-Data` 头生效的前提，v4.9.62 起这两项一直是空转。本机验证：TLS1.3 与 TLS1.2 的第二次连接都显示 `Reused`。代价：ticket 密钥只在 nginx 进程内，重启后旧 ticket 失效；前向保密弱于完整握手。**未测速**：nginx 只承载 CDN 回源、订阅和伪装站，约占总流量两成，CPU 占用很低，这一项只缩短重连，不提高稳态吞吐。已安装机器需手改 `/etc/nginx/nginx.conf` 后 `nginx -t` 再重载。 |

---

## 七、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
