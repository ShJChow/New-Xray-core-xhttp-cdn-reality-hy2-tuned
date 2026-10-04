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
---

## 三、常驻管理命令 `xh`

终端直接输入 `xh` 即可进入交互式管理菜单：

```text
=== xray-xhttp 管理菜单 ===
  1) 查看服务与流控状态          16) CDN TCP(h2) 节点开关
  2) 查看节点参数与客户端配置      17) CDN QUIC(h3) 节点开关
  3) 查看订阅链接与二维码        18) 出站分流 (屏蔽回国 IP / 广告域名)
  4) 重启服务                  19) Reality 时间差校验 (maxTimeDiff)
  5) 查看日志 (xray)            20) 备用节点 XHTTP-Direct-H2 (TCP 直连)
  6) 更新 Xray-core            21) Hysteria2 节点与混淆管理 (hy2)
  7) 系统层调优 (show/on/off)   22) MASQUE 标准 L3 隧道 (masque)
  8) TCP Brutal 极速加速        23) XDRIVE 网盘穿透代理 (xdrive)
  9) 保活开关                  24) Finalmask Noise exp 动态混淆 (noise)
 10) 内核自动更新开关           25) 上行 Reality / 下行 CDN 分离节点
 11) UDP 节点自检 (diag)        26) 备用节点 上行 CDN / 下行 Reality
 12) sysctl 冲突检测 (conflict)  27) 重新生成全量订阅 (resub)
 13) Reality 兼容模式 (1.8.0)    28) 证书续期方式 / DNS-01 (cert)
 14) CDN ECH 加密 SNI 开关       29) Nginx 版本检查与升级 (nginx)
 15) TCP ECN 拥塞通知开关       30) 卸载
                                0) 退出
```

#### 全量 CLI 快捷指令速查表（免进菜单）

| 类别 | 快捷指令 | 对应菜单 | 功能说明 |
| :--- | :--- | :---: | :--- |
| **状态与订阅** | `xh status` | 1 | 查看服务运行状态、监听端口、TCP/BBR 流控参数与版本 |
| | `xh info` | 2 | 查看节点连接参数与客户端节点链接 |
| | `xh sub` | 3 | 查看订阅链接与终端二维码 |
| | `xh resub` | 27 | 按当前配置重新生成全量订阅文件并重启分发服务 |
| | `xh diag` | 11 | UDP / HTTP3 连通性自检与证书检测 |
| | `xh conflict` | 12 | sysctl 冲突与覆盖项排查 |
| | `xh version` | — | 查看 Xray 内核与 xh 管理脚本版本 |
| **服务运维** | `xh start` \| `stop` \| `restart` | 4 | 启动 / 停止 / 重启全部核心服务 |
| | `xh log [xray\|nginx] [行数]` | 5 | 查看实时运行与连接日志 |
| | `xh update [<ver>] [--auto]` | 6 | 升级或指定 Xray-core 版本（自检失败自动回滚） |
| | `xh keepalive [on\|off\|show]` | 9 | 服务守护进程保活与异常自动拉起开关 |
| | `xh autoupdate [on\|off\|show]` | 10 | 每周自动升级 Xray-core 开关（带版本检查提醒） |
| | `xh cert [show\|dnscf]` | 28 | 证书续期方式查看 / 切换 Cloudflare DNS-01（走 CDN 代理防失效） |
| | `xh nginx [show\|check\|update]` | 29 | Nginx mainline 检查与平滑升级（官方 PGP 验签） |
| | `xh guard` | — | 健康检查与故障自愈拉起（cron 定时任务调用） |
| | `xh uninstall` | 30 | 彻底卸载全部组件并清理配置 |
| **网络与流控** | `xh tuning [show\|on\|off\|win\|mac\|linux\|sb]` | 7 | 系统级 BBR+fq 流控调优 / 输出多平台客户端调优指令 |
| | `xh brutal [show\|on\|off\|speed]` | 8 | TCP Brutal 极速拥塞控制 / 调节速率 |
| | `xh minversion [show\|on\|off\|<ver>]` | 13 | Reality 客户端最低版本限制（默认 1.8.0 兼容 Clash/sing-box） |
| | `xh ech [show\|on\|off]` | 14 | Cloudflare CDN ECH (加密 SNI) 开关与订阅同步 |
| | `xh ecn [show\|on\|off]` | 15 | TCP ECN (显式拥塞通知) 开关与状态查看 |
| | `xh block [show\|cn on\|off\|ads on\|off]` | 18 | 出站屏蔽回国 IP / 广告域名 |
| | `xh timediff [show\|on [ms]\|off]` | 19 | Reality 客户端与服务端最大时间差校验 (maxTimeDiff) |
| | `xh noise [show\|on\|off\|set <exp>]` | 24 | Finalmask Noise exp 动态混淆（AWG 模板标签，抗 DPI 审查） |
| **节点开关** | `xh cdnh2 [show\|on\|off]` | 16 | 开启 / 关闭 CDN TCP(h2) 节点 |
| | `xh cdnh3 [show\|on\|off]` | 17 | 开启 / 关闭 CDN QUIC(h3) 节点 |
| | `xh h2direct [show\|on\|off]` | 20 | 开启 / 关闭备用直连 TCP 节点 (XHTTP-Direct-H2) |
| | `xh hy2 [show\|on\|off]` | 21 | Hysteria2 直连节点总开关（随机高 UDP 端口，默认不装） |
| | `xh hy2 obfs [show\|on\|off]` | 21 | 开启 / 关闭 Hysteria2-Obfs 混淆节点（别名 `xh hy2obfs`） |
| | `xh masque [show\|on\|off]` | 22 | 开启 / 关闭 MASQUE 标准 L3 隧道 (RFC 9484 CONNECT-IP, UDP 随机高端口) |
| | `xh xdrive [show\|setup\|on\|off]` | 23 | 开启 / 关闭 / 配置 XDRIVE 网盘穿透代理 (Google Drive 中继，零公网 IP) |
| | `xh split [show\|reality-up\|cdn-up]` | 25, 26 | 上下行分离节点开关（上行 Reality 默认开，上行 CDN 备用） |

---

## 四、节点拓扑与双轨架构

安装完成后将提供 **6 条核心全协议节点**，客户端通过 `urltest` 自动分流调度：

| # | 节点名称（v4.9.78） | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H3` | XHTTP (h3/QUIC) + vlessenc | 经 CDN UDP 443 | QUIC 经 Cloudflare 回源 |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | 直连 UDP 8446 | 直连 QUIC，`mode=stream-up` |
| **3** | `Hysteria2-H3-Direct` | Hysteria 2 | 直连 随机高 UDP 端口 | 标准 HTTP/3 形态，实测下行最快（v4.9.26） |
| **4** | `Hysteria2-Obfs-Direct` | Hysteria 2 + salamander | 直连 随机高 UDP 端口 | 混淆版，QUIC 被深度识别时使用 |
| **5** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | 直连 TCP 443 | **xtls-rprx-vision 零拷贝**，单流极速 |
| **6** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |

> 默认不装、按需用 `xh` 开启的备用与新特性节点（xh 菜单里都有对应项）：
> - `VLESS-XHTTP-CDN-H2`（`xh cdnh2 on`，经 CDN 的 TCP 兜底，UDP 被限速 / 封锁时用）
> - `VLESS-Reality-Up-CDN-Down`（`xh split reality-up on`，上行 Reality、下行经 CDN，纯客户端链接）
> - `VLESS-CDN-Up-Reality-Down`（`xh split cdn-up on`，上行经 CDN、下行 Reality）
> - `VLESS-XHTTP-Direct-H2`（`xh h2direct on`，Direct-H3 的 TCP 孪生体）
> - `MASQUE-CONNECT-IP`（`xh masque on`，IETF RFC 9484 标准 L3 隧道）
> - `XDRIVE-Google-Drive`（`xh xdrive setup` / `xh xdrive on`，利用 Google Drive 网盘穿透无公网 IP / 白名单封锁）
> - `Finalmask Noise exp`（`xh noise on`，基于 `<b hex><r N><t><c><rd N>` 动态表达式混淆）
> - Hysteria2 默认已装；不需要时 `xh hy2 off`（连同混淆节点一起移除），只关混淆用 `xh hy2 obfs off`。

---

## 五、常见问题与排错

| 故障现象 | 核心排查原因 | 快速解决指引 |
| :--- | :--- | :--- |
| **Reality 节点连接失败** | 客户端与网络时间偏差 > 30 秒 | 开启客户端系统「自动从网络同步时间」（防重放） |
| **Mihomo 上下行分离报错** | Mihomo 浅拷贝继承父级 Reality 配置 | 在 `download-settings` 声明 `reality-opts: { public-key: "" }` |
| **直连 UDP / Hysteria 2 超时** | 云服务商外部安全组拦截 | 云控制台安全组放行对应 UDP 端口与 TCP 端口 |
| **内核参数冲突 / 被篡改** | `/etc/sysctl.d/` 存在外部冲突脚本 | 运行 `xh conflict` 自动检测并一键自愈修复 |

---

## 六、版本迭代与核心调优演进记录 (v4.8 - v4.9.79)

本项目经跨洋高延迟弱网环境（160ms+ / 1% 丢包）实测迭代，核心演进总结如下：

| 演进领域 | 涉及版本 | 核心技术方案与调优结论 |
| :--- | :--- | :--- |
| **ALPN 全面审计：Hy2-Obfs 链接显式 alpn=h3，nginx 可只接受 HTTP/2** | v4.9.79 | 按用户「ALPN 全部设置为 h2 和 h3 以上」的要求审计了线上与源码：Xray 入站 h3 / h3 / h3 / h2，sing-box 入站 h2 / h3 / h3 / h3+h2，节点和入站里**没有 http/1.1**。做了两处：1. Hysteria2-Obfs 链接此前没写 alpn，现在显式 `alpn=h3`；2. **新增 `xh nginx h2only [show\|on\|off]`，安装时默认写入**：nginx 无法在 ALPN 握手层去掉 http/1.1，只能在请求层拒绝，所以对 HTTP/1.x 请求直接 `return 444`，`/sub/` 订阅页与 `/.well-known/` 例外（部分订阅客户端只会 HTTP/1.1）。本机已开启（只重载 nginx，Xray 没重启）：HTTP/1.1 访问首页被断开、HTTP/2 返回 200，订阅页两种协议都是 200，CDN-H3、Direct-H3、Direct-H2、Reality-Vision、Reality-XHTTP 五条节点用真实链接复测都通。**风险：** 经 Cloudflare 回源时 CF 对普通页面可能用 HTTP/1.1，开启后用浏览器打开 CDN 域名首页会看到 CF 的 52x 错误页；主动探测用 HTTP/1.1 访问伪装站会得到空响应，和真实网站不同，隐蔽性略降；xhttp / gRPC 本来就是 HTTP/2，不受影响。不需要时 `xh nginx h2only off`。**没有做「每条 TLS 节点都同时写 h3,h2」**：Xray 的 XHTTP 客户端在 alpn 不止一项时一律走 HTTP/2（源码 `decideHTTPVersion`），会把 Direct-H3 与 CDN-H3 静默降级成 TCP；这两类节点各有对应的 h2 孪生节点（Direct-H2、CDN-H2），本来就能兜底。 |
| **默认节点集对齐本机当前设置，其余节点作为备用集成到 xh 菜单** | v4.9.78 | 按用户要求，安装命令默认的节点集改为本机当前在用的 6 条：CDN-H3、Direct-H3、Hysteria2-H3、Hysteria2-Obfs、Reality-Vision、Reality-XHTTP。变化：`FEATURE_HY2` 与 `FEATURE_HY2_OBFS` 重新默认 `true`（Hysteria2 端口仍是随机高端口）；`FEATURE_CDN_H2` 与 `FEATURE_REALITY_UP_CDN_DOWN` 改为默认 `false`，与 `CDN-Up-Reality-Down`、`Direct-H2`、`MASQUE`、`XDRIVE`、`Noise exp` 一起作为备用，xh 菜单里都有对应项（16 CDN-H2、20 Direct-H2、21 Hysteria2、22 MASQUE、23 XDRIVE、24 Noise、25 / 26 上下行分离）。同步修正安装器 profile、node.env 兜底值、xh 菜单 / 帮助里「默认开启 / 备用」的措辞与 README 节点表。**只影响新装机器**；已安装机器的节点集不变。本机 `node.env` 本来就是这个状态，无需改动。**未纳入默认的非节点设置**：本机当前还开着 Finalmask Noise exp（`FEATURE_NOISE_EXP`）与屏蔽回国 IP / 广告域名（`FEATURE_BLOCK_CN` / `FEATURE_BLOCK_ADS`），它们是链路 / 出站策略而不是节点，新装仍默认关闭，需要时用 `xh noise on`、`xh block`。 |
| **小火箭订阅：Reality 节点 type=raw 改成 type=tcp** | v4.9.77 | 用户反馈 Reality 节点在最新版 v2rayN 能通、在小火箭不通。Reality-Vision 链接里写的是 `type=raw`（Xray 对 TCP 的新叫法，v2rayN 认），小火箭的链接解析只认 `type=tcp`，不认识 `raw` 时节点连不上；对 Xray 内核两者等价。现在 `shadowrocket.txt` 专属订阅（`xh resub` 与安装时生成）里把 `type=raw` 改成 `type=tcp`，并去掉纯客户端参数 `spx`（连同原有的 `fm`）。**v2rayN / Mihomo 订阅不变。** **这是对根因的推断，没有在小火箭上实测**（本机没有 iOS 环境）：如果仍不通，请反馈小火箭的版本、连接日志里的报错文字，以及在服务器上执行 `journalctl -u xray -n 40` 的结果（IP、域名、密钥换成占位符）。已知无关项：服务端 `minClientVer` 本机显式为 1.8.0，不会拒绝小火箭。 |
| **按 Xray 26.9.30 微调：H3 接收窗口、CDN 腿 maxConnections、Xray 原生 TUN 配置、TUN 订阅含 CDN 节点** | v4.9.76 | 读了 26.3.27→26.9.30 的 277 条提交，只改有实测依据的项。1. **XHTTP/3 链接加 `fm` 放大 QUIC 接收窗口**（Direct-H3、CDN-H3）：流 4MB/32MB、连接 8MB/64MB。netns + netem（RTT 160ms、下行 1% 丢包、限速 300Mbit）下载 40MB，每组 3 轮：默认窗口 109–119 Mbps（5 次），8MB/16MB 127，16MB/32MB 168，**32MB/64MB 196–215**；RTT 60ms / 0.5% 丢包时各档都是 264–270 Mbps，没有差别。只放大客户端（接收方），服务端不放大；Direct-H3 实测，CDN-H3 的 QUIC 是客户端到 Cloudflare 边缘，无法用 netem 复现，未单独测。2. **`quicParams.bbrProfile`（conservative / standard / aggressive）对 XHTTP/3 没有可测差别**（同条件 109–119 Mbps，无丢包时三档都是 223 Mbps），所以不设。3. **CDN 腿的 xmux 改用 `maxConnections: 3`**（26.9.x 客户端的默认值，不能与 `maxConcurrency` 同时出现）：本机经 Cloudflare 回连，8 路并行下载每组 2 轮，h2 下 413 / 426 Mbps（3 / 6）对 344 / 359 Mbps（`maxConcurrency` 16-32），h3 下 391 / 394 对 358 / 373 Mbps；上传方向波动太大，没有结论。只用于 CDN 腿，直连与 Reality 腿不变。4. **新增 Xray 原生 TUN 配置** `xray-tun-{windows,linux,macos}.json`（订阅目录，`xh resub` 与安装时生成）：`autoSystemRoutingTable` + `autoOutboundsInterface: auto`（Xray 自己的出站绑物理网卡，不再回环，不必手工给服务器地址加直连）、Windows 加 `autoSystemWfpBlockLeak`、observatory + leastPing 自动择优、CN 与内网直连。Linux 版在 netns 里实测：TUN 与路由自动建好，6 个 vless 节点都存活，非 CN 目标经代理、CN 目标直连，DNS 正常；**Windows / macOS 只做了 `xray run -test` 配置校验，没有真机运行。** 5. **v2rayN TUN 订阅（`v2rayn-tun.txt`）不再排除 CDN 节点**（旧规则是为旧版 TUN 的 DNS 丢包写的），**没有在 v2rayN 上实测**；若 TUN 下 CDN 节点 DNS 超时，把 CDN 域名加进 v2rayN 直连规则。6. `xh tuning` 优先读 `/sys/module/tcp_bbr/version` 识别 BBR 版本（本机 BBRv3 内核显示 `v3`）。**注意 Xray 26.9.30 的变化**：freedom 出站默认拒绝私网 / 回环目标，需要在 `finalRules` 里写 `allow` 才能放行（本项目线上配置已有显式 `finalRules`）。 |
| **全面升级对齐 Xray-core v26.9.30：引入 XDRIVE 云盘代理、MASQUE 标准化隧道、Noise 动态表达式混淆与 30 项对称管理菜单** | v4.9.75 | 1. **内核与协议升级**：锁定 Xray-core 最新正式/预发版 v26.9.30；2. **MASQUE 标准 L3 隧道**：引入标准 IETF RFC 9484 (CONNECT-IP) / RFC 8441 Extended CONNECT，支持 FullCone UDP 与内部虚拟网卡池（`10.13.0.1/24`、`fd13::1/64`），提供 `xh masque [show\|on\|off]` 管理与自检；3. **XDRIVE 网盘穿透代理**：原生集成 Google Drive 云存储中转传输层，无需公网 IP 即可突破极端 IP 白名单封锁，提供 `xh xdrive [show\|setup\|on\|off]` 交互式配置与客户端 outbound 导出；4. **Finalmask Noise 动态模板混淆**：支持 `type: "exp"` 动态表达式混淆（`<b hex>`、`<r N>`、`<t>`、`<c>`、`<rd N>` 等），提供 `xh noise [show\|on\|off\|set]` 动态注入与热重载；5. **xh 交互菜单重构**：扩展并严格对齐为 30 项完美对称布局（左 1-15、右 16-30，退出 0），全量 CLI 矩阵同步更新；6. **防泄漏与兼容性**：客户端模板全面对齐 Windows WFP 级防泄漏 (`autoSystemWfpBlockLeak`) 与 Linux `autoSystemDnsToGateway`，FakeDNS IPv6 网段更新为 RFC 5180 `2001:2::/48` 避开 Chrome 141+ PNA 弹窗。 |
| **速度不稳修复：Hy2 不再声明 Brutal 带宽，CDN 腿改回 auto** | v4.9.66 | 用户反馈节点速度慢且不稳，服务端自查（CPU / 内存 / 网卡正常，全部连接 BBR，TCP 重传约 0.9%，UDP 无丢包）无瓶颈，问题在客户端链路与节点参数：1. `HY2_UP_MBPS` / `HY2_DOWN_MBPS` 默认值由 100 / 1000 改为**空**：链接不再带 `upmbps` / `downmbps`，`fm` 的拥塞为 BBR，Mihomo 条目不再写 `up` / `down`——原先 sing-box / Mihomo 客户端会按声明速率 Brutal 硬发，线路达不到时超发丢包、速度忽快忽慢；确实知道自己的线路带宽时用 `HY2_UP_MBPS=… HY2_DOWN_MBPS=…` 再开；2. 经过 CDN 的腿（CDN-H2 / CDN-H3、CDN-Up-Reality-Down 的上行腿、Reality-Up-CDN-Down 的下行腿、dual-cdn / quic-h3 扩展）的 `mode` 由 `stream-up` 改回 `auto`，直连与 Reality 腿保持 `stream-up`（依据 v4.9.58 实测：stream-up 经 Cloudflare 上传 6 次有 2 次没传完，auto 为 0 次）。Mihomo 的分离节点下行腿没有独立 `mode` 字段，仍随父级。**未测速**：以上依据是服务端自查与既有实测，不是对你线路的实测；仍慢请告诉我是哪条节点、哪个客户端和运营商。 （CDN 上传腿已在 v4.9.70 改回 stream-up） |
| **审查修复：服务端 8001 回到 auto，开关改为原子、可回滚** | v4.9.67 | 代码审查后的修复。1. **服务端 8001 入站 `mode` 由 `stream-up` 改回 `auto`**：v4.9.66 把 CDN 腿改成 `auto`，但 8001 写着 `stream-up` 会拒绝 packet-up 上传，本机用真实 Xray 客户端实测 `stream-up` 通、`auto` / `packet-up` 不通，改后三种全通；直连入站仍只收 `stream-up`；2. 安装时写入的 `h2direct` / `hy2obfs` 入站现在带 `// >>xh:` 标记，`xh … off` 能整块删除；无标记但端口已在配置里时明确报错，不再静默放过；3. 开关顺序改为「先改客户端文件（原子写盘）→ 再改服务端 → 最后写标志位」，任一步失败撤销前面的步骤，并打印原因；xray 校验报错、回滚后重启结果、防火墙写入失败都不再被吞；4. `xh cdnh2` / `cdnh3` 从备用节点库取节点（旧安装才用克隆兜底），修复 CDN-H3 默认关闭后克隆到错误节点的问题；5. 备用节点库先渲染到临时目录并校验 6 条节点，再整体替换，错误写入 `/etc/xhttp-cdn/all-render.log`；6. 菜单 20–23 放进子 shell，一次失败不再关掉整个菜单；7. 更正过时注释与文案。限制：备用节点库是安装时快照，装好后 `xh ech` 的改动不会同步进库；节点被 `NODE_NAME_MAP` 改名后开关会明确报错。 |
| **安装健壮性：可选入站不再拖垮 Reality** | v4.9.68 | 用户反馈新装 Ubuntu / Debian 服务器上 Reality 不通，**根因尚未确认**（没拿到失败机器的日志）。按其中一个假设做防御性修复：Xray 是一个进程，任何入站绑定失败都会让整个 Xray 起不来。1. 安装时先检查可选入站的端口：UDP `HY2_PORT`（Hysteria2-Obfs，v4.9.64 起默认开）或 TCP `H2_PORT`（h2-direct）被别的进程占用时，直接关掉该节点并提示占用者；2. `xray -test` 失败且开着这两个可选入站时，自动关掉它们、用同一份模板重新生成配置再试，核心节点（Reality 等）不受影响；核心配置本身有错仍然报错退出；3. 启动后新增监听自检：TCP 443（Reality）以及已开启的 UDP / TCP 节点端口逐个检查，缺哪个就明确告警，方便区分「服务端没监听」和「云安全组没放行」。若仍不通，请在失败机器上运行 `systemctl status xray`、`journalctl -u xray -n 40`、`xray -test -config /usr/local/etc/xray/config.json`、`ss -ltnup \| grep -E ':443 \|xray'`、`xh diag` 并反馈。 |
| **nginx 重新打开 session tickets（重连更快）** | v4.9.69 | 按用户选择，`ssl_session_tickets` 由 `off` 改回 `on`。客户端重连时可以恢复会话，少传证书，少一次完整握手；同时它是 `ssl_early_data`（0-RTT）与 `Early-Data` 头生效的前提，v4.9.62 起这两项一直是空转。本机验证：TLS1.3 与 TLS1.2 的第二次连接都显示 `Reused`。代价：ticket 密钥只在 nginx 进程内，重启后旧 ticket 失效；前向保密弱于完整握手。**未测速**：nginx 只承载 CDN 回源、订阅和伪装站，约占总流量两成，CPU 占用很低，这一项只缩短重连，不提高稳态吞吐。已安装机器需手改 `/etc/nginx/nginx.conf` 后 `nginx -t` 再重载。 |
| **CDN 上传腿改回 stream-up** | v4.9.70 | 按用户「提高 CDN 吞吐」的要求做了小规模对比：本机用 Xray 客户端经 Cloudflare 回连自己，各 40 次传输（20MB 下载 / 10MB 上传）没有卡住，上传 **stream-up 约 365–441 Mbps，auto 约 163–261 Mbps（快 1.7–2.7 倍）**，下载两者接近（约 490–640 Mbps）。因此 CDN-H2 / CDN-H3、CDN-Up-Reality-Down 的上传腿，以及 dual-cdn / quic-h3 扩展里的上传腿改回 `stream-up`；经 CDN 的**下载腿**（Reality-Up-CDN-Down 的 downloadSettings）保持 `auto`。服务端 8001 继续是 `auto`（什么模式都收）。这个结果取代 v4.9.66 里「CDN 腿全部 auto」，当时的依据是更早一次 stream-up 经 CF 上传 2/6 没传完，在 Cloudflare 开启 gRPC / WebSockets 后的这次测试里没有复现。**限制：只代表本机到 Cloudflare 这一段，不代表用户客户端的线路；样本小、波动大（单次 60–720 Mbps）。** 当前在用的 Reality-Up-CDN-Down 上行走 Reality、下行走 CDN，不受这项影响。 |
| **默认节点集：去掉 Hysteria2，默认装两条 CDN 节点；Hysteria2 做进 xh 菜单** | v4.9.71 | 按用户要求：1. 安装命令默认**不再装 Hysteria2**：`FEATURE_HY2` 默认 `false`（Hysteria2-H3 随它关闭），`FEATURE_HY2_OBFS` 默认 `false`；2. **默认安装两条 CDN 节点**：`FEATURE_CDN_H2` 与 `FEATURE_CDN_H3` 默认 `true`；3. 默认节点集变为 CDN-H2、CDN-H3、Direct-H3、Reality-Vision、Reality-XHTTP、Reality-Up-CDN-Down（6 条）；4. 新增 `xh hy2 [show\|on\|off]` 与菜单第 24 项（卸载顺延为 25）：开启 = 加服务端入站 + 放行 UDP 443 + 加客户端节点 + 写标志位，失败即撤销；关闭会连同混淆节点一起移除；`xh hy2obfs on` 现在要求先开 Hysteria2；5. Hysteria2-H3 入站也带 `// >>xh:` 标记，备用节点库新增 `inbound-hy2h3.json`；6. 入站标记的「已存在」检查改按 tag 判断（Hysteria2 的 UDP 443 与 Reality 的 TCP 443 同号）。本机往返验证：`xh hy2 off`（连同混淆）→ `xh hy2 on` → `xh hy2obfs on`，客户端文件与订阅逐字节一致，`xh diag` 显示 TCP 443、UDP 443、UDP 8443 都在监听。**只影响新装机器**；已安装机器的节点集不变。本机 Hysteria2 入站原先没有标记，已用同样的标记包起来，之后即可用 `xh hy2` 开关。 |
| **Hysteria2 端口改为默认随机分配，与混淆管理合并至 xh 菜单** | v4.9.73 | 1. **Hysteria2 端口随机化**：`HY2_H3_PORT` 与 `HY2_PORT` 默认改为 10000-65000 动态随机分配高端口（避免固定 443 / 8443 被运营商针对性 QoS 限速或阻断，仍支持环境变量显式自定义）；2. **xh 菜单精简合并**：原分散的「Hysteria2 总开关」与「Hysteria2-Obfs 混淆节点」合并为菜单第 21 项（支持子交互与 `xh hy2 on\|off`、`xh hy2 obfs on\|off`），全量菜单收敛为 27 项；3. 同步优化服务端入站 tag 识别并完全向下兼容既有配置与旧命令 `xh hy2obfs`。 |
| **默认安装对齐本机：锁定 Xray 官方正式稳定内核 v26.3.27 并固化 6 核心节点集** | v4.9.72 | 1. 默认安装 Xray 内核版本锁定为官方稳定正式版 v26.3.27（与本机运行环境一致），规避上游预发布版对第三方客户端的兼容性断层；2. 默认安装节点与本机完全对齐为 6 条主力节点（CDN-H2、CDN-H3、Direct-H3、Reality-Vision、Reality-XHTTP、Reality-Up-CDN-Down，Hysteria2 默认不装并收录于 xh 菜单备用）；3. 同步环境变量矩阵、安装器 profile 与构建发布脚本。 |

---

## 七、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
