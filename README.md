# xray-xhttp

**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

 **测试在Oracle 4ocpu+24 ubuntu 26.04 运行)**
 
基于 Xray-core 的 **XHTTP + CDN **一键部署方案，默认开启 **xpadding / Hysteria2 混淆 / 全部 7 条节点**（ECH 默认关闭，需 `CDN_ECH=y`），并在安装时自动应用**内核层流控调优**（BBR + fq、缓冲、句柄），附带常驻管理命令 `xh`。

支持 V2rayN / Shadowrocket / Mihomo / onexray 客户端，支持 IPv4 与 IPv6。

> **原理阅读**：XHTTP、上下行分离及其抗审查优势 — <https://habr.com/en/articles/990208/>
>
> **注意**：本方案使用 VLESS Encryption，客户端（V2rayN、Mihomo）需更新到支持 `vlessenc` / `xhttp` 的版本。
>
> **注意**：V2rayN v7.19.5+ 在 TUN 模式下链路可能不稳定，需启用旧版 TUN 保护选项（[PR #9005](https://github.com/2dust/v2rayN/pull/9005)）。
安装完成时**自动执行 `xh tuning on`**（内核层调优，best-effort；`FEATURE_AUTO_TUNING=false` 可跳过，`xh tuning off` 可回滚）
---

## 特性

| 能力 | 说明 |
|---|---|
| 节点集（v4.7.4） | 默认 7 条，全部由 Xray 单核心提供：4 条 QUIC/h3（含 Hysteria2 obfs 与新增的 h3-cdn）+ 3 条 TCP 兜底。不再需要独立 hysteria 二进制 |
| xpadding | 默认开启，`xPaddingObfsMode` + 自定义 Header 与参数名，绕过 CDN 侧的 XHTTP 特征检测 |
| ECH | **默认关闭**，加密 TLS 握手中的 SNI；需先在 Cloudflare Edge Certificates 开启，再设 `CDN_ECH=y` |
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

v4.7.4 起默认输出**下表 7 条**，全部由 Xray 单核心提供——Hysteria2 改用 Xray 原生
inbound（v26.3.27+），不再需要独立的 hysteria 二进制。

**节点顺序**：第 1、2 条经 CDN（分别走 TCP/h2 与 UDP/h3），第 3、4 条直连 XHTTP
（QUIC 与 TCP 孪生体），第 5 条 Hysteria2，后 2 条 TCP 直连兜底。
Mihomo 的策略组用 `include-all: true`，排序直接由此决定。

v4.6.0 起 Mihomo 订阅带 **`自动选择`（url-test）**策略组，并作为 `节点选择` 的默认项：
按延迟自动选路，节点变慢或失效时自动切走，不必人工排查。仍可在 `节点选择` 里手动
指定具体节点。详见 [docs/10 §9](docs/10.流控调优.md)。

v4.7.0 新增 **`直连择优`**策略组（v4.7.3 前叫 `直连回落`，类型是 fallback）：
只含 4 条直连节点，按实测延迟自动选。节点 `h2-tcp-direct` 正是为此引入：
它是 `h3-direct` 的 TCP 孪生体（同 UUID、同 path、同 decryption，仅传输层不同），
此前直连侧的 TCP 兜底只有 Reality。

改用 url-test 的原因：fallback 只判断通不通、不判断快不快。晚高峰 h3-direct
卡到 200ms 且丢包严重时它依然「健康」，于是一直被占用，后面的节点永远轮不到——
而这恰恰是最该切走的时刻。url-test 在这种劣化下会自动切，且 UDP 被完全封锁时
同样会切（那时 h3 直接测速失败），是 fallback 的超集。

与 `自动选择` 的分工：那个组 `include-all`（含 CDN 节点），这个组只含直连节点，
用于「我明确要走直连」的场景。**注意** url-test 测的是握手延迟，不是吞吐也不是
丢包率——Hysteria2 在高丢包下的吞吐优势测不出来，重丢包时段仍需手动切过去。

节点 1 经 CDN、server 是域名，在 v2rayN TUN 模式下需要把 CDN 域名加入直连列表，
否则会自环。节点 2–5 直连裸 IP，只需为 VPS IP 加直连路由。
安装时生成的 `~/client-config-v2rayn-tun.txt` 已按本机实际值给出该清单。

名称为纯 ASCII + 主机名后缀（`<host>` = `NODE_TAG`，未设时取 `hostname -s`；
为 `localhost` 或为空时用 `vps`）。想换成机场式的完整名字见
[自定义节点名](#自定义节点名)：

| # | 节点名 | 链路 | 传输 |
|---|---|---|---|
| 1 | `Vless-xhttp-tls-UDP-cdn-<host>` | 经 CDN，**TCP 443** | XHTTP + TLS，alpn h2 + http/1.1（v4.6.0 由 h3 改回 TCP，见 docs/10 §8；名字里的 UDP 是那次改动前的遗留，为不打断既有客户端的节点选择而保留） |
| 2 | `Vless-xhttp-h3-cdn-<host>` | 经 CDN，**UDP 443** | XHTTP + TLS，alpn 仅 h3（v4.7.4 新增，节点 1 的 QUIC 孪生体，服务端零改动） |
| 3 | `Vless-xhttp-h3-direct-<host>` | 直连 VPS，**UDP 8444** | XHTTP + TLS，alpn h3 |
| 4 | `Vless-xhttp-h2-tcp-direct-<host>` | 直连 VPS，**TCP 8445** | XHTTP + TLS，alpn h2 + http/1.1（v4.7.0 新增，节点 3 的 TCP 孪生体），推荐手机使用 |
| 5 | `Hysteria2-obfs-<host>` | 直连 VPS，**UDP 8443** | Hysteria2 + Salamander 混淆 |
| 6 | `Vless-reality-vision-<host>` | 直连 VPS TCP 443 | Reality + Vision，UDP 被封时的兜底 |
| 7 | `Vless-xhttp-reality-<host>` | 直连 VPS TCP 443 | XHTTP + Reality，上下行不分离 |

节点 3/5 走裸 UDP 直连、节点 4 走 TCP 8445，都需要在**云厂商安全组**放行
（UDP 8444、UDP 8443、TCP 8445）。节点 2 经 CDN，走的是 Cloudflare 的 UDP 443，
**不需要**在安全组开任何端口——这一层在机器外面，脚本查不到也改不了。
Xray 版本低于 26.6.1 时节点 2/4 会被自动禁用。节点 3 的端口可用 `H2_PORT=<port>`
指定，不需要时设 `FEATURE_H2_DIRECT=false` 关闭。

> **节点 2 的已知局限**（v4.0.3 曾降为 opt-in，v4.2.0 恢复默认开启）：XHTTP over h3
> 在上游有两个未修复且已 closed as not planned 的问题——[#4391](https://github.com/XTLS/Xray-core/issues/4391)
> `alpn=h3` 被静默忽略而退回 TCP、[#5849](https://github.com/XTLS/Xray-core/issues/5849)
> h3 长期不工作。端口已独立为 **8444**，退回 TCP 也不会与 Reality 抢 443；
> 最坏情况是它自己连不通。不需要时可设 `FEATURE_H3_DIRECT=false` 关闭。

### 从旧版升级

装过 `add-quic.sh`（独立 hysteria 二进制）或 `add-quic-h3.sh` 的机器，重跑安装脚本时
会**自动迁移**：停用旧组件、备份配置到 `/var/backups/xray-xhttp-migrate/`、
从 nginx 移除 quic 监听段，把 UDP 端口让给 Xray 原生实现。

旧的独立 hysteria **没有 Salamander 混淆**，迁移后才会有。若想保留旧组件，
设 `KEEP_LEGACY_UDP=true`——此时新的两条 UDP 节点会被自动关闭以避免端口冲突。

Xray 内核低于 26.6.1 时，安装脚本会**自动升级内核**（Alpine 除外），
而不是跳过后静默关闭这两条节点。

> **TUIC v5 未提供**：Xray-core 的 inbound 协议列表中没有 TUIC，在「仅用 Xray」的
> 前提下无法实现。节点 2（XHTTP over h3 直连）传输层同为 QUIC，是最接近的替代。

## 版本更新

v4.7.4 之后的七个修复，均已包含在当前 **v4.7.11**。这些改动**不影响节点列表与订阅格式**
（仍是上表 7 条），重跑安装脚本即可获得。

| 版本 | 修复 |
|---|---|
| v4.7.5 | **CDN 回源吞吐 +25%**。nginx 的 `grpc_buffer_size` 沿用默认 4k，Xray 的下行数据被切成 4k 一片经 HTTP/2 转发，系统调用数与帧头开销成倍放大；改为 512k 后，同链路回环实测 100MB 下载由 131–162 MB/s 升至 177–193 MB/s。同时新增 `upstream xray_xhttp` + keepalive，避免每条 POST/GET 流都新建一条到 8001 的连接（packet-up 上行是大量小 POST，这笔握手开销原本落在每个包上）。 |
| v4.7.6 | **修经 CDN 的连接丢失真实客户端 IP**。`sockopt.trustedXForwardedFor` 的语义是「可信**头名**列表」而非可信对端 IP，原先填 `["127.0.0.1"]` 永远匹配不到任何头名，`X-Forwarded-For` 一律被判为伪造（线上 90 分钟内产生 8290 条 `ignored potentially forged` 错误，占日志绝大多数），所有经 CDN 的连接在日志与路由里都退回记成 127.0.0.1。改填 `["X-Real-IP"]`——该头由 nginx 无条件覆盖，客户端伪造不进来。 |
| v4.7.7 | **修重装会静默关掉 h2-direct 节点**。端口占用探测用的 `ss -lnt` 少了 `-p`，不输出 `users:(("proc",pid=…))` 那一列，持有者恒为空串，于是「8445 上有监听」即被判为被外部进程占用——而重跑安装脚本时占着 8445 的恰恰是上一版自己的 xray。后果是每次重装都把 `FEATURE_H2_DIRECT` 落成 false，订阅从 7 条节点掉到 6 条。 |
| v4.7.8 | **mihomo 订阅不再下发死节点**。mihomo 模板此前无条件渲染 h3-direct / h2-direct / Hysteria2 三条节点，不受 `FEATURE_*` 开关约束（URI 侧有对应机制，mihomo 侧一直没有）。任一节点被关闭时（证书缺失、端口被占、或显式设 `FEATURE_*=false`），v2rayN 订阅正确地少一条，mihomo 订阅却仍列着它，客户端拿到指向不存在入站的死节点，「直连择优」url-test 组还会每 60s 去测一遍。改为按 `FEATURE_*` 裁剪。 |
| v4.7.9 | **修 Hysteria2 节点从来没通过流量**。hysteria 入站的用户写成 `settings.clients[].auth`，而 Xray 26.x 认的是 `clients[].password`——多余的键被静默忽略，配置照样通过 `xray run -test`，但解析后没有任何有效用户，每个客户端都在认证阶段拿到 `auth failed code 404`。难发现是因为 QUIC/TLS 握手是成功的、obfs 正常、端口也在听，`xh diag` 服务端自检全绿，表现是「节点像是通的、就是过不了流量」。同时新增节点自定义命名：`NODE_TAG` 换后缀（hostname 为 `localhost` 时不再直接拿来当后缀，回退到 `vps`），`NODE_NAME_MAP` 按 `旧名=新名` 整条改名，用于机场式命名。 |
| v4.7.10 | **拼错的环境变量不再被静默忽略**。本脚本全靠环境变量做非交互配置，而 bash 对不存在的变量没有任何反馈——写了 `CDN_DIRECT_PORT=2053`、`FEATURE_XRAY_AUTO_UPGRADE=true` 这种看着很合理但脚本里根本不存在的名字，安装照常成功、日志一切正常，用户以为配置生效了，排查时几乎不可能想到这一层。现在安装开始时会列出所有「长得像本项目参数但脚本没引用过」的变量并告警（不中断安装）。已知变量表不写死，直接在脚本自身里搜该名字有没有被引用，因此永远不会和实现漂移。 |
| v4.7.11 | **ECH 改为默认关闭；`FEATURE_*` 环境变量终于真的能覆盖**。ECH 要求先在 Cloudflare 的 Edge Certificates 里开启，未满足这个前置条件就启用它会让 CDN 节点直接握手失败——对没读到「前置条件」第 6 条的人是个陷阱，因此默认改为不启用，需要的人显式设 `CDN_ECH=y`。xpadding 保持默认开启（它挡的是流量指纹识别，关掉不影响机密性，但节点更容易被识别）。同时修掉一个一直存在的问题：构建脚本注入的是无条件赋值 `FEATURE_XPADDING=true`，会**覆盖掉**用户传进来的环境变量，README 里写的 `FEATURE_XPADDING=false bash install.sh` 这个关闭方法其实从来没生效过；改成 `${VAR:-默认}` 后才真正可覆盖。 |

## 前置条件

运行脚本前需在 Cloudflare 完成（申请一个能托管到cloudflare 的[免费]域名：https://my.dnshe.com/index.php?m=domain_hub 或https://dash.domain.digitalplat.org/dashboard）：

1. Reality 域名 DNS → **仅 DNS**（灰色云朵）
2. CDN 域名 DNS → **代理开启**（橙色云朵）
3. SSL/TLS 加密 → **完全（严格）**
4. 网络 → **gRPC 已开启**
5. 缓存规则（建议）→ 将 XHTTP 路径设为绕过缓存，表达式在部署完成后由脚本给出
6. 如需 ECH → Edge Certificates 中先开启 ECH

每个入口域名使用独立的 `dist/<域名>/index.html` 作为回落页；可用 [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) 抓取网页后上传。


acme.sh 证书申请：若证书申请失败，可使用acme：
bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
---

## 一键部署

> **版本要求**：Xray 内核 ≥ `26.6.1`，Mihomo 内核 ≥ `1.19.24`。
> Xray 的下限由两条直连 UDP 节点决定：Hysteria2 inbound 需 26.3.27+，finalmask 的 UDP listener 崩溃 bug（issue #6184）需 26.6.1+ 才修复。低于该版本时安装脚本会自动禁用这两条节点。
>
> v4.7.4 起**全部 7 条节点 + 全部功能默认开启**：xpadding（XHTTP 填充混淆）、
> ECH（默认关闭，需 `CDN_ECH=y` 显式开启）、Hysteria2 finalmask + Salamander 混淆、VLESS Encryption（ML-KEM-768）、
> h3-direct 直连节点，并在安装时自动应用内核层调优（`xh tuning on`，best-effort）。
> 需要最小化配置时用
> `FEATURE_H3_DIRECT=false FEATURE_XPADDING=false FEATURE_CDN_ECH=false FEATURE_AUTO_TUNING=false bash install.sh`。

Debian / Ubuntu：

```bash
sudo -i
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
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu \
CDN_FALLBACK_ORIGIN=https://www.harvard.edu \
CDN_ECH=n \
bash ~/install.sh
```

可用环境变量：

| 变量 | 说明 | 默认 |
|---|---|---|
| `AUTO` | `1` 表示零交互 | `0` |
| `REALITY_DOMAIN` / `CDN_DOMAIN` | 两个域名，**必填** | — |
| `IP_CHOICE` | `1`=IPv4，`2`=IPv6 | `1` |
| `FALLBACK_MODE` | `static`（本地页面）/ `proxy`（反代） | `proxy` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | `proxy` 模式下的回落站 | sjsu / harvard |
| `FEATURE_XPADDING` | `false` 关闭 XHTTP 填充混淆（xpadding） | `true` |
| `FEATURE_CDN_ECH` | `false` 关闭 ECH 询问（ECH 本身仍需 `CDN_ECH=y`） | `true` |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | xpadding 字段 | `Referer` / `x_padding` |
| `CDN_ECH` | `y` 启用 ECH（需先在 Cloudflare Edge Certificates 开启，否则 CDN 节点握手失败） | `n` |
| `VISION_UDP443` | `1` 时节点 1 的 flow 用 `xtls-rprx-vision-udp443`（需客户端支持） | `0` |
| `FEATURE_H3_DIRECT` | `false` 关闭直连 h3 节点（UDP 8444，上游有已知问题，默认开） | `true` |
| `FEATURE_HY2` | `false` 关闭 Hysteria2-obfs 节点（UDP 8443） | `true` |
| `FEATURE_AUTO_TUNING` | `false` 跳过安装时的自动内核调优（`xh tuning off` 可随时回滚） | `true` |
| `H3_PORT` / `HY2_PORT` | 两条直连 UDP 节点的端口（`H3_PORT` 禁止设 443，会被强制改回 8444） | `8444` / `8443` |
| `KEEP_LEGACY_UDP` | `true` 保留旧的独立 hysteria / quic-h3 扩展（此时新的两条 UDP 节点会被关闭） | `false` |
| `FEATURE_XHTTP_H3_NODE` | Hysteria2 扩展的开关：`true` 恢复 `Vless-xhttp-tls-h3-direct` 节点与配套 nginx quic 监听 | `false` |
| `FEATURE_KEEPALIVE` | `false` 不装保活 cron | `true` |
| `FEATURE_AUTOUPDATE` | `false` 不装自动更新 cron | `true` |
| `NODE_TAG` | 节点名后缀，替代主机名 | 主机名（为空或 `localhost` 时用 `vps`） |
| `NODE_NAME_MAP` / `NODE_NAME_FILE` | 自定义节点名，每行 `旧名=新名`；`NODE_NAME_FILE` 指向同格式的文件 | — |

`AUTO=1` 且 `FALLBACK_MODE=static` 时会自动生成占位 `index.html` 并跳过人工确认，事后可自行替换。

#### 自定义节点名

默认节点名是 `Vless-xhttp-h3-cdn-${主机名}`。多数 VPS 镜像的主机名就是 `localhost`，
这种后缀在多机订阅里无法区分，所以 `localhost` 会被当成没设置、回退到 `vps`；
想要有意义的后缀就设 `NODE_TAG=hk-oracle`。

要换成机场式的完整名字（emoji + 地区），用 `NODE_NAME_MAP`，左边写默认生成的
完整节点名（含后缀），右边写想要的显示名：

```bash
NODE_TAG=vps \
NODE_NAME_MAP='Vless-xhttp-tls-UDP-cdn-vps=🇺🇸 US-CDN-TLS
Vless-xhttp-h3-cdn-vps=🇺🇸 US-CDN-H3
Vless-xhttp-h3-direct-vps=🇺🇸 US-H3-Direct
Vless-xhttp-h2-tcp-direct-vps=🇺🇸 US-H2-Direct
Hysteria2-obfs-vps=🇺🇸 US-Hysteria2
Vless-reality-vision-vps=🇺🇸 US-Reality-Vision
Vless-xhttp-reality-vps=🇺🇸 US-Reality-XHTTP' \
AUTO=1 ... bash install.sh
```

改名同时作用于 `client-config.txt`、两份 mihomo yaml（含 proxy-groups 里的引用）
和据此生成的订阅。URI 的 fragment 会自动百分号编码——带空格的节点名不编码会被
Shadowrocket 一类客户端在空格处截断。

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
`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat`、`somaxconn=65535`、UDP 缓冲与 `udp_mem`（QUIC/H3）、
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
