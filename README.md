# xray-xhttp

**语言：** **简体中文** · [English](./README.en.md) · [فارسی](./README.fa.md)

 **测试在Oracle 4ocpu+24 ubuntu 26.04/Debian 13(建议) 运行)**
 
基于 Xray-core 的 **XHTTP + CDN **一键部署方案，默认开启 **xpadding / Hysteria2 混淆 / 全部 7 条节点**（ECH 默认关闭，需 `CDN_ECH=y`），并在安装时自动应用**内核层流控调优**（BBR + fq、缓冲、句柄），附带常驻管理命令 `xh`。

支持 V2rayN / Shadowrocket / Mihomo / onexray 客户端，支持 IPv4 与 IPv6。

> ⚠️ **部署前请先阅读 [免责声明](#免责声明)**

> **原理阅读**：新版内核，同比传统内核具有运行AI agent的优势。
>
> **注意**：本方案使用 VLESS Encryption，客户端（V2rayN、Mihomo）需更新到支持 `vlessenc` / `xhttp` 的版本。
>
> **注意**：V2rayN v7.19.5+ 在 TUN 模式下链路可能不稳定，需启用旧版 TUN 保护选项（[PR #9005](https://github.com/2dust/v2rayN/pull/9005)）。
安装完成时**自动执行 `xh tuning on`**（内核层调优，best-effort；`FEATURE_AUTO_TUNING=false` 可跳过，`xh tuning off` 可回滚）
---

## 特性

| 能力 | 说明 |
|---|---|
| 节点集 | 默认 8 条，全部由 Xray 单核心提供：4 条 QUIC/h3（含 Hysteria2 obfs 与新增的 h3-cdn）+ 3 条 TCP 兜底。不再需要独立 hysteria 二进制 |
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
| 3 | `Vless-xhttp-h3-direct-<host>` | 直连 VPS，**UDP 8444** | XHTTP + TLS，alpn h3，`mode=stream-up`（v4.7.13，比 auto 快约 50ms） |
| 4 | `Vless-xhttp-h2-tcp-direct-<host>` | 直连 VPS，**TCP 8445** | XHTTP + TLS，alpn h2 + http/1.1，`mode=stream-up`（v4.7.13，比 auto 快约 50ms）（v4.7.0 新增，节点 3 的 TCP 孪生体），推荐手机使用 |
| 5 | `Hysteria2-obfs-<host>` | 直连 VPS，**UDP 8443** | Hysteria2 + Salamander 混淆 |
| 6 | `Vless-reality-vision-<host>` | 直连 VPS TCP 443 | Reality + Vision，UDP 被封时的兜底 |
| 7 | `Vless-xhttp-reality-<host>` | 直连 VPS TCP 443 | XHTTP + Reality，上下行不分离 |
| 8 | `Vless-xhttp-reality-up-cdn-down-<host>` | 上行 Reality 直连 443，下行 TLS CDN 443 | XHTTP 上下行分离（上行 Reality 直连极速响应，下行 CDN 大带宽拉取） |

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

## 握手延迟实测（v4.7.13）

**测量条件**：在 VPS 本机（Oracle 4 OCPU ARM / San Jose）发起，目标
`https://www.cloudflare.com/cdn-cgi/trace`，每条节点 10 次全新连接取中位数，
不复用连接。直连基线（完全不经节点）= **20 ms**。

| 节点 | 首字节 | 说明 |
|---|---|---|
| Vless-reality-vision | 18 ms | 与直连基线持平 |
| Vless-xhttp-reality | 19 ms | `auto` 本来就选 stream-up |
| Hysteria2-obfs | 18 ms | |
| Vless-xhttp-h3-direct | **18 ms** | v4.7.13 由 69 ms 改善（改用 `stream-up`） |
| Vless-xhttp-h2-tcp-direct | **18 ms** | v4.7.13 由 68 ms 改善（改用 `stream-up`） |
| Vless-xhttp-tls-UDP-cdn | 73 ms | packet-up 固有开销，见下 |
| Vless-xhttp-h3-cdn | 73 ms | 同上 |

### 两条 CDN 节点的 ~50 ms 是结构性的，无法优化

把 CDN 节点的 73 ms 逐层拆开，每层单独测量：

| 组成 | 耗时 | 能否优化 |
|---|---|---|
| 目标站本身（直连基线） | 20 ms | — |
| **packet-up 模式开销** | **~48 ms** | ❌ 结构性 |
| Cloudflare 边缘处理 | 5 ms | ❌ 已很小 |
| Reality 回落那一跳 | 0.1–0.8 ms | ❌ 可忽略 |

两个关键对照：**同一套 XHTTP 配置绕开 CF 直打本机 nginx 是 68 ms、经 CF 是 73 ms**
——Cloudflare 只占 5 ms，不是它慢；而本机到自己的 CF 边缘同机房（`colo=SJC`，
ping 0.86 ms），也不是地理问题。

剩下的 ~48 ms 与直连节点上 packet-up 的惩罚是同一个东西，但 CDN 节点**不能**
像直连节点那样换 `stream-up`：实测经 Cloudflare 用 stream-up，
CDN-TLS 吞吐直接掉到 0、CDN-H3 连接超时。Cloudflare 不支持流式请求体，
packet-up 正是为此存在。

以下调整均实测无效（交替采样、每组 15–20 次，全部落在 73–75 ms 误差内）：

- `scMinPostsIntervalMs` 0 / 5 / 30
- `scMaxEachPostBytes` 加大（反而 75 ms）
- `xmux maxConcurrency` 16-32 → 64-128
- 完全不用 xmux（只是 p90 变差）
- 改 Cloudflare 回源端口以绕开 Reality 回落（那一跳只有 0.1–0.8 ms）
- 缓存规则（XHTTP 路径本来就是 `cf-cache-status: DYNAMIC`，不在缓存路径上）

**结论**：不要试图优化 CDN 节点的这 50 ms，用调度解决。Mihomo 订阅的
`自动选择`（url-test）组会按实测延迟自动选路，18 ms 的直连节点天然排在前面；
CDN 节点的定位本就是「直连被封时的备胎」，50 ms 是它换取「走 Cloudflare IP、
不暴露 VPS」的代价。

> **这些数字不能直接套用到你的客户端。** 上表是在 VPS 本机测的，测的是
> 服务端侧还剩多少可优化空间。真实客户端的账完全不同：CF 边缘会在**你附近**，
> 而 CF→源站那段长途走 Cloudflare 骨干网，可能比公网直连更快——跨国链路差的
> 时候，CDN 节点的总延迟甚至可能低于直连节点。要判断你那边的实际情况，
> 只能在你自己的客户端上测。

---

## 版本更新

v4.7.4 之后的九个修复，均已包含在当前 **v4.7.13**。这些改动**不影响节点列表与订阅格式**
（仍是上表 7 条），重跑安装脚本即可获得。

| 版本 | 修复 |
|---|---|
| v4.7.5 | **CDN 回源吞吐 +25%**。nginx 的 `grpc_buffer_size` 沿用默认 4k，Xray 的下行数据被切成 4k 一片经 HTTP/2 转发，系统调用数与帧头开销成倍放大；改为 512k 后，同链路回环实测 100MB 下载由 131–162 MB/s 升至 177–193 MB/s。同时新增 `upstream xray_xhttp` + keepalive，避免每条 POST/GET 流都新建一条到 8001 的连接（packet-up 上行是大量小 POST，这笔握手开销原本落在每个包上）。 |
| v4.7.6 | **修经 CDN 的连接丢失真实客户端 IP**。`sockopt.trustedXForwardedFor` 的语义是「可信**头名**列表」而非可信对端 IP，原先填 `["127.0.0.1"]` 永远匹配不到任何头名，`X-Forwarded-For` 一律被判为伪造（线上 90 分钟内产生 8290 条 `ignored potentially forged` 错误，占日志绝大多数），所有经 CDN 的连接在日志与路由里都退回记成 127.0.0.1。改填 `["X-Real-IP"]`——该头由 nginx 无条件覆盖，客户端伪造不进来。 |
| v4.7.7 | **修重装会静默关掉 h2-direct 节点**。端口占用探测用的 `ss -lnt` 少了 `-p`，不输出 `users:(("proc",pid=…))` 那一列，持有者恒为空串，于是「8445 上有监听」即被判为被外部进程占用——而重跑安装脚本时占着 8445 的恰恰是上一版自己的 xray。后果是每次重装都把 `FEATURE_H2_DIRECT` 落成 false，订阅从 7 条节点掉到 6 条。 |
| v4.7.8 | **mihomo 订阅不再下发死节点**。mihomo 模板此前无条件渲染 h3-direct / h2-direct / Hysteria2 三条节点，不受 `FEATURE_*` 开关约束（URI 侧有对应机制，mihomo 侧一直没有）。任一节点被关闭时（证书缺失、端口被占、或显式设 `FEATURE_*=false`），v2rayN 订阅正确地少一条，mihomo 订阅却仍列着它，客户端拿到指向不存在入站的死节点，「直连择优」url-test 组还会每 60s 去测一遍。改为按 `FEATURE_*` 裁剪。 |
| v4.7.9 | ⚠️ **本条的修法是错的，已被 v4.7.12 取代——若停留在 v4.7.9~v4.7.11，Hysteria2 在 v2rayN/sing-box 下不可用，请升级。** **修 Hysteria2 节点从来没通过流量**。hysteria 入站的用户写成 `settings.clients[].auth`，而 Xray 26.x 认的是 `clients[].password`——多余的键被静默忽略，配置照样通过 `xray run -test`，但解析后没有任何有效用户，每个客户端都在认证阶段拿到 `auth failed code 404`。难发现是因为 QUIC/TLS 握手是成功的、obfs 正常、端口也在听，`xh diag` 服务端自检全绿，表现是「节点像是通的、就是过不了流量」。同时新增节点自定义命名：`NODE_TAG` 换后缀（hostname 为 `localhost` 时不再直接拿来当后缀，回退到 `vps`），`NODE_NAME_MAP` 按 `旧名=新名` 整条改名，用于机场式命名。 |
| v4.7.10 | **拼错的环境变量不再被静默忽略**。本脚本全靠环境变量做非交互配置，而 bash 对不存在的变量没有任何反馈——写了 `CDN_DIRECT_PORT=2053`、`FEATURE_XRAY_AUTO_UPGRADE=true` 这种看着很合理但脚本里根本不存在的名字，安装照常成功、日志一切正常，用户以为配置生效了，排查时几乎不可能想到这一层。现在安装开始时会列出所有「长得像本项目参数但脚本没引用过」的变量并告警（不中断安装）。已知变量表不写死，直接在脚本自身里搜该名字有没有被引用，因此永远不会和实现漂移。 |
| v4.7.11 | **ECH 改为默认关闭；`FEATURE_*` 环境变量终于真的能覆盖**。ECH 要求先在 Cloudflare 的 Edge Certificates 里开启，未满足这个前置条件就启用它会让 CDN 节点直接握手失败——对没读到「前置条件」第 6 条的人是个陷阱，因此默认改为不启用，需要的人显式设 `CDN_ECH=y`。xpadding 保持默认开启（它挡的是流量指纹识别，关掉不影响机密性，但节点更容易被识别）。同时修掉一个一直存在的问题：构建脚本注入的是无条件赋值 `FEATURE_XPADDING=true`，会**覆盖掉**用户传进来的环境变量，README 里写的 `FEATURE_XPADDING=false bash install.sh` 这个关闭方法其实从来没生效过；改成 `${VAR:-默认}` 后才真正可覆盖。 |
| v4.7.12 | **修 v4.7.9 引入的回归：Hysteria2 在 v2rayN / sing-box 下不通**。v4.7.9 把入站用户从 `clients[].auth` 改成了 `clients[].password`，依据是「用 Xray 自己的 hysteria 出站实测只有这个写法能认证」——但那次实测的客户端把 auth 放在 `settings.auth`，而[官方文档](https://xtls.github.io/config/transports/hysteria.html)规定出站的 auth 在 `streamSettings.hysteriaSettings.auth`。两处都不标准的配置凑巧互相匹配，于是得出了错误结论，反而把标准客户端弄不通了：sing-box（v2rayN 的 Hysteria2 内核）从此一直报 `authentication failed, status code: 404`。正确写法是官方文档的 `settings.users[].auth`。已用三种内核逐一验证（均带阴性对照，确认错误密码时确实失败）：sing-box 236 Mbps、Xray 253 Mbps、mihomo 通。 |
| v4.7.13 | **握手延迟按节点类型分别配置；修 Reality 节点在 mihomo 下全部不可用**。① 两条直连 XHTTP 节点（h3-direct / h2-direct）改用 `mode=stream-up`：`auto` 在 `security=tls` 下保守地选 packet-up，把上行切成一串带最小间隔的 POST，首字节要多等约 50ms。实测首字节 68/69ms → **18ms**（等于不经节点的直连基线），吞吐不变。**CDN 节点必须保持 packet-up**——packet-up 存在的理由就是 CDN 不支持流式请求体，实测经 Cloudflare 改 stream-up 后 CDN-TLS 吞吐掉到 0、CDN-H3 直接超时。Reality 节点不用改，它的 `auto` 本来就选 stream-up。② Reality 加 `minClientVer: "1.8.0"`：Xray 26.x 的 Reality 默认最低客户端版本是 Xray-core v26.3.27（启动日志里那句 `other clients may be refused to connect`），mihomo 握手时直接报 `REALITY authentication failed`，两条 Reality 节点在 mihomo / Clash 系客户端下**全部不可用**。放宽后七条节点在 mihomo 下全通。 |

## 前置条件

运行脚本前需在 Cloudflare 完成（申请一个能托管到cloudflare 的[免费]域名：https://my.dnshe.com/index.php?m=domain_hub 或https://dash.domain.digitalplat.org/dashboard）：

1. Reality 域名 DNS → **仅 DNS**（灰色云朵）指向你的vps ip,用来申请证书。
2. CDN 域名 DNS → **代理开启**（橙色云朵）,指向你的vps ip
3. SSL/TLS 加密 → **完全（严格）**
4. 网络 → **gRPC 已开启**
5. 缓存规则（建议）→ 将 XHTTP 路径设为绕过缓存，表达式在部署完成后由脚本给出
6. 如需 ECH → Edge Certificates 中先开启 ECH,默认不开启。

或者，每个入口域名使用独立的 `dist/<域名>/index.html` 作为回落页；可用 [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) 抓取网页后上传。


acme.sh 证书申请：若证书申请失败，可Reality 域名 DNS使用acme：
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
NODE_NAME_MAP='Vless-xhttp-tls-UDP-cdn-vps=🇺🇸 VLESS-XHTTP-TLS-CF-h2
Vless-xhttp-h3-cdn-vps=🇺🇸 VLESS-XHTTP-TLS-CF-h3
Vless-xhttp-h3-direct-vps=🇺🇸 VLESS-XHTTP-TLS-QUIC
Vless-xhttp-h2-tcp-direct-vps=🇺🇸 VLESS-XHTTP-TLS-TCP
Hysteria2-obfs-vps=🇺🇸 Hysteria2-QUIC-TLS
Vless-reality-vision-vps=🇺🇸 VLESS-TCP-REALITY-Vision
Vless-xhttp-reality-vps=🇺🇸 VLESS-XHTTP-REALITY' \
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

## 免责声明

**请在部署前完整阅读本节。**

### 法律与合规

本项目是一套**开源的网络传输部署脚本**，仅提供自动化配置能力，不提供任何代理
服务、不运营任何节点、不接触任何用户流量。是否部署、如何使用，以及由此产生的
全部后果，由使用者自行承担。

**面向中国大陆用户的特别提示**：在中国大陆境内，未经电信主管部门批准，
自行建立或使用非法定信道进行国际联网，涉嫌违反《计算机信息网络国际联网管理
暂行规定》第六条及其实施办法、《计算机信息网络国际联网安全保护管理办法》等
规定，可能面临责令停止联网、警告、罚款、没收违法所得等行政处罚；用于经营性
活动（如向他人售卖、分享牟利）的，性质与后果更为严重，实践中已有以
「非法经营罪」「提供侵入、非法控制计算机信息系统程序、工具罪」定罪的案例。

作者不鼓励、不建议任何人在其所在司法辖区从事违法活动。**如果你身处相关法律
适用范围内，请自行评估风险并为自己的选择负责。**本项目及其作者不对使用者的
任何行为承担法律责任。

**严禁**将本项目用于：向不特定对象售卖或分享代理服务、电信网络诈骗、跨境赌博、
洗钱、传播违法信息，或任何其它违法犯罪活动。

### 技术上的诚实说明

- **不保证不被识别，也不保证长期可用。** 本项目使用的 Reality、xpadding、
  Salamander 混淆等手段，目的是提高流量分析的成本，**不是**让流量不可识别。
  审查技术在持续演进，今天有效的配置明天可能失效。任何声称「永不被封」的
  说法都不可信。
- **IP 被封是常态。** 直连节点暴露 VPS 的裸 IP，一旦被封锁，该 IP 上的全部
  直连节点同时失效。这是这类方案的固有属性，不是配置错误。
- **UDP / QUIC 在中国大陆经常被限速或阻断。** 本项目 7 条节点中有 4 条依赖
  UDP（h3-cdn、h3-direct、Hysteria2，以及 CDN 的 UDP 443）。部分运营商在
  高峰时段对 UDP 做 QoS，表现是这些节点先能用、后变慢甚至不通，而 TCP 节点
  正常。这**不是服务端故障**——`Vless-reality-vision` 与
  `Vless-xhttp-h2-tcp-direct` 就是为此保留的 TCP 兜底。
- **Cloudflare 的实际速度因地区而异。** 从中国大陆访问 Cloudflare 的
  Anycast IP，落地节点与线路质量波动很大，可能远逊于上面的实测数字。
  建议部署后在自己的客户端上实测，再决定用哪条节点。
- **本仓库所有性能数字均为特定机器、特定时间、特定链路上的单点实测**，
  不构成对任何其它环境的性能承诺。

### 无担保

本项目按 MIT 许可「按原样」提供，不附带任何明示或默示的担保，包括但不限于
适销性、特定用途适用性与非侵权性的担保。因使用或无法使用本项目而造成的任何
直接或间接损失（含但不限于服务器被封停、数据丢失、账号损失、法律责任），
作者概不负责。

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
