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
  5) 查看日志 (xray)            20) XHTTP-Direct-H2 (TCP 直连)
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
| | `xh minversion [show\|on\|off\|<ver>]` | 13 | Reality 客户端最低版本限制（默认关闭，用最新 Xray 默认值；`on` = 1.8.0 兼容 Clash/sing-box） |
| | `xh ech [show\|on\|off]` | 14 | Cloudflare CDN ECH (加密 SNI) 开关与订阅同步 |
| | `xh ecn [show\|on\|off]` | 15 | TCP ECN (显式拥塞通知) 开关与状态查看 |
| | `xh block [show\|cn on\|off\|ads on\|off]` | 18 | 出站屏蔽回国 IP / 广告域名 |
| | `xh timediff [show\|on [ms]\|off]` | 19 | Reality 客户端与服务端最大时间差校验 (maxTimeDiff) |
| | `xh noise [show\|on\|off\|set <exp>]` | 24 | Finalmask Noise exp 动态混淆（AWG 模板标签，抗 DPI 审查） |
| **节点开关** | `xh cdnh2 [show\|on\|off]` | 16 | 开启 / 关闭 CDN TCP(h2) 节点 |
| | `xh cdnh3 [show\|on\|off]` | 17 | 开启 / 关闭 CDN QUIC(h3) 节点 |
| | `xh h2direct [show\|on\|off]` | 20 | 开启 / 关闭直连 TCP 节点 (XHTTP-Direct-H2，默认开启) |
| | `xh hy2 [show\|on\|off]` | 21 | Hysteria2 直连节点总开关（随机高 UDP 端口，默认不装） |
| | `xh hy2 obfs [show\|on\|off]` | 21 | 开启 / 关闭 Hysteria2-Obfs 混淆节点（别名 `xh hy2obfs`） |
| | `xh masque [show\|on\|off]` | 22 | 开启 / 关闭 MASQUE 标准 L3 隧道 (RFC 9484 CONNECT-IP, UDP 随机高端口) |
| | `xh xdrive [show\|setup\|on\|off]` | 23 | 开启 / 关闭 / 配置 XDRIVE 网盘穿透代理 (Google Drive 中继，零公网 IP) |
| | `xh split [show\|reality-up\|cdn-up]` | 25, 26 | 上下行分离节点开关（上行 Reality 默认开，上行 CDN 备用） |

---

## 四、节点拓扑与双轨架构

安装完成后将提供 **6 条核心全协议节点**，客户端通过 `urltest` 自动分流调度：

| # | 节点名称（v4.9.83） | 传输协议 | 路由链路 | 核心特性 |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H2` | XHTTP (h2) + vlessenc | 经 CDN TCP 443 | TCP 经 Cloudflare 回源 |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | 直连 UDP 8446 | 直连 QUIC，`mode=stream-up` |
| **3** | `VLESS-XHTTP-Direct-H2` | XHTTP (h2) + vlessenc | 直连 TCP 8445 | Direct-H3 的 TCP 孪生体 |
| **4** | `Hysteria2-H3-Direct` | Hysteria 2 | 直连 随机高 UDP 端口 | 标准 HTTP/3 形态，实测下行最快（v4.9.26） |
| **5** | `Hysteria2-Obfs-Direct` | Hysteria 2 + salamander | 直连 随机高 UDP 端口 | 混淆版，QUIC 被深度识别时使用 |
| **6** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | 直连 TCP 443 | Reality 伪装 + XHTTP 填充混淆 |

> 默认不装、按需用 `xh` 开启的备用与新特性节点（xh 菜单里都有对应项）：
> - `VLESS-XHTTP-CDN-H3`（`xh cdnh3 on`，经 CDN 的 UDP 443 / QUIC）
> - `VLESS-Reality-Vision-Direct`（`xh reality vision on`，xtls-rprx-vision 零拷贝，直连 TCP 443）
> - `VLESS-Reality-Up-CDN-Down`（`xh split reality-up on`，上行 Reality、下行经 CDN，纯客户端链接）
> - `VLESS-CDN-Up-Reality-Down`（`xh split cdn-up on`，上行经 CDN、下行 Reality）
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

## 六、版本迭代与核心调优演进记录 (v4.8 - v5.0.0)

本项目经跨洋高延迟弱网环境（160ms+ / 1% 丢包）实测迭代，核心演进总结如下：

| 演进领域 | 涉及版本 | 核心技术方案与调优结论 |
| :--- | :--- | :--- |
| **v5.0.0 正式版：默认节点集对齐本机、Reality 兼容模式默认关闭** | v5.0.0 | 本版把 v4.9.83 与 v4.9.84 的变化定为 5.0 基线，除版本号外没有新的功能改动。**默认节点（6 条）**：CDN-H2、Direct-H3、Direct-H2、Hysteria2-H3、Hysteria2-Obfs、Reality-XHTTP；备用节点（CDN-H3、Reality-Vision、Up-CDN-Down、CDN-Up-Reality-Down、MASQUE、XDRIVE、Noise）在 xh 菜单里开关。**Reality**：默认不写 `minClientVer`，使用 Xray 26.9.x 内核默认值（26.3.27），低于它的客户端内核需要升级；要兼容老客户端用 `xh minversion 1.8.0`。默认 Xray 内核 26.9.30。 |

---

## 七、免责声明

1. 本项目为开源的网络传输技术研究与自动化部署工具，不提供任何公共代理服务，不接触任何用户数据。
2. 使用者请严格遵守当地法律法规。严禁将本项目用于任何违法犯罪活动。
3. 技术具有时效性，不保证在任何网络环境下永久可用。因使用本项目产生的任何后果由使用者自行承担。

---

## 致谢与开源许可

- 基于 [Xray-core](https://github.com/XTLS/Xray-core) 与 [sing-box](https://github.com/SagerNet/sing-box) 构建。
- 本项目遵循 [MIT 许可证](./LICENSE)。欢迎提交 Issue 与 Pull Request！
