# 项目运作与排障记忆 (Memory)

## 1. Shadowrocket CDN 节点连通性规范与修复记录 (2026-10-07)
- **故障背景**：新版 Shadowrocket 客户端拉取订阅后 CDN 节点不通（或订阅中缺失 CDN 节点）。
- **根因分析**：
  1. `12-subscription.sh` 与 `13-manage-cli.sh` 此前存在强限制：`FEATURE_XHTTP_VLESSENC=true` 时会主动在小火箭专属订阅（`shadowrocket.txt`）中剥离 CDN 节点。
  2. Xray 8001 入站启用了后量子加密（`mlkem768x25519plus`），新版 Shadowrocket 的 VLESS 握手不支持该嵌套解密层，直连报错 `error 5`。
  3. 小火箭对复杂 JSON 参数（如 `extra`、`fm`）解析存在兼容性问题。
- **架构解法（双入站与专属独立路由）**：
  1. **Xray 双回环入站**：
     - `127.0.0.1:8001`：保留给 V2RayN / Mihomo 等，支持 `mlkem768x25519plus`。
     - `127.0.0.1:8002`：专门给 Shadowrocket 等原生客户端，`decryption: none`。
  2. **Nginx 路由分流**：
     - 原始 `/xhttp-path` 路由转到 `8001`。
     - 独立 `/sr-xhttp-path`（即 `/sr${XHTTP_PATH#/}`）路由通过 `upstream xray_xhttp_sr` 转发到 `8002`。
  3. **订阅生成逻辑**：
     - 小火箭专属订阅自动注入标准格式的 `VLESS-XHTTP-CDN-H2` 节点（连接 `bestcf-domain:443`，SNI `cdn-domain`，path `/sr-xhttp-path`，`encryption=none`）。
  4. **Reality 握手兼容**：
     - 配置 `minClientVer: 1.8.0`（通过 `xh minversion on`），避免非官方 Xray 客户端在 Reality 阶段被握手校验拒绝。

## 2. Xray 内核更新通道规范 (2026-10-07)
- **更新策略**：默认通道改为 `stable`（官方正式版）。
  - 自动更新任务（每周日 04:00）默认仅拉取 GitHub Releases 中的正式版本（`/releases/latest`），遇到 Pre-release 自动跳过，保障生产环境稳定。
  - 用户若需体验 Pre-release 版本（如 26.9.30+ 的后量子加密新特性），可通过 `xh autoupdate pre` 或在菜单选择 `6` 手动输入 `pre` 切换。

## 3. Reality 节点连通性与 Xray 26.9+ 后量子强卡控排障 (2026-10-07)
- **故障背景**：Shadowrocket / sing-box / Clash Meta 连接 Reality 节点报错 `reality verification failed`。
- **根因分析**：
  - Xray v26.9.8+ (如 26.9.30) 在 REALITY 握手层对客户端强制要求后量子混合密钥 `X25519MLKEM768`。即便配置了 `minClientVer: 1.8.0`，底层密码学握手仍被内核硬阻断，第三方客户端无法连通。
- **解决对策**：
  - 生产环境将 Xray 内核回退并锁定为官方稳定正式版 **v26.3.27**，并开启 `minClientVer: 1.8.0`。
  - 实测 sing-box / Shadowrocket 与原生 Xray 客户端均秒级握手成功，连通性完全恢复。

## 4. 全节点连接与下载稳定性、持续性调优 (2026-10-07)
- **故障背景**：CDN 节点及部分直连节点在大文件下载、持续测速或长连接时出现断断续续、周期性卡顿或中途断流。
- **根因分析**：
  1. **Nginx 反代超时过紧**：全局 `client_body_timeout 10s` 和 `send_timeout 10s`。在 CDN 大文件传输或网络轻微抖动时，Nginx 在 10 秒无突发吞吐时会主动断开客户端连接。
  2. **XHTTP 上行重连周期过短**：Xray 默认 `scStreamUpServerSecs` 配置为 `"20-50"` 秒，导致服务端每 20~50 秒强制重置上行流，客户端频繁重连切片引发周期性停顿。
  3. **TCP 套接字关闭截断**：Xray policy 的 `uplinkOnly: 5s` 与 `downlinkOnly: 10s` 在单向关闭（FIN）时过快杀死连接，残余下行数据包未接收完毕即被掐断。
- **解决对策与优化项**：
  1. **Nginx 长连接保护**：在 `/xhttp-path` 与 `/sr-xhttp-path` 位置块显式配置 `client_body_timeout 300s` 与 `send_timeout 300s`，配合已有的 `grpc_read_timeout 1h` 与 `grpc_send_timeout 1h`，彻底消除 Nginx 提前切断长连接。
  2. **XHTTP 流保活周期扩容**：将 `scStreamUpServerSecs` 调整放宽至 `"300-600"` 秒（5~10分钟），避免 20 秒短周期频繁握手重连。
  3. **Xray Policy 优雅关闭放宽**：调整 `uplinkOnly: 15s` 与 `downlinkOnly: 30s`，保证大文件下载与尾部数据完整平滑传输。
  4. **系统级持续性参数**：保持内核 `tcpUserTimeout: 300000ms` (5分钟) 与 `tcpKeepAliveIdle: 30s`，抗击跨境链路短暂丢包与抖动。

## 5. 网卡 MTU 1500 调优与系统持久化规范 (2026-10-07)
- **背景与原因**：
  - Oracle Cloud 等云厂商默认网卡 MTU 为 9000（巨型帧），而公网标准物理以太网 MTU 为 1500。
  - 超过 1500 的巨帧在出公网边界时会遭遇 PMTU 黑洞（因中间节点丢弃 ICMP Fragmentation Needed 导致大包被静默丢弃，表现为握手成功但传输大文件/TLS 证书时断流）。
  - 因此将物理网卡 MTU 严格锁定为标准以太网上限 **1500**，并配合 `TCPMSS --clamp-mss-to-pmtu` 确保端到端通信无分片丢包。
- **持久化方案**：
  1. 系统配置 `/etc/netplan/99-mtu.yaml` 覆盖 cloud-init 默认值（锁定 `mtu: 1500`），经 `netplan generate` 注入底层 `systemd-networkd`（`MTUBytes=1500`）。
  2. 开机调优脚本（`xray-xhttp-nic-tune` / `sbbox-nic-tune`）将 MTU 校验上下限均对齐至 **1500**，杜绝开机回退为 1480 或 9000。
## 6. 全链路网络与节点性能排障与“罪证”清理规范 (2026-10-08)
- **故障背景**：节点网络吞吐受限、出现周期性微抖动，以及 TCP 握手重传率高（SNMP 显示重传数达 33 万+）。
- **根因分析**：
  1. **Xray Freedom 直连出站拥塞控制与 MPTCP 误配**：
     - `xray-config.json.tmpl` 中 freedom 出站误继承了 `${XRAY_TCP_CC:-brutal}` 以及 `tcpMptcp: true`。
     - TCP Brutal 属于单向固定速率算法，强行作用于 VPS 访问公网目标（Google、YouTube、Cloudflare）的自由出站连接时，导致拥塞窗口畸形膨胀（高达 14855 报文）并引发中间路由器缓冲区溢出与丢包。
     - 公网绝大多数目标服务器和防火墙不识别 TCP SYN 中的 `MP_CAPABLE` 选项，易引发 1~3 秒 RTO 超时重传。
  2. **DNS 本地解析死地址**：
     - Xray 配置 fallback 的 DNS 服务器填写了 `localhost`（即 127.0.0.1:53），而 systemd-resolved 仅监听在 127.0.0.53，导致本地回退查询被拒绝连接。
  3. **Cloudflare 优选 IP 测速逻辑颠倒**：
     - 在美西 VPS 上执行 `cfst` 测速只会选出美西本地（SJC 0.8ms）节点并同步至 DNS，给国内客户端造成跨洋劣质路由。
- **解决对策与优化规范**：
  1. **锁定 Freedom 出站协议栈**：
     - 显式将 freedom 出站中的 `tcpcongestion` 锁定为标准的 `"bbr"`，同时关闭 `"tcpMptcp": false`，严禁在直连出站上使用 Brutal。
     - `06-tuning-lib.sh` 中的 `set_tcp_brutal_xray` 在开启 Brutal 时通过正则守卫，确保 freedom 出站始终维持 BBR。
  2. **修复 DNS 本地解析**：
     - `xray-config.json.tmpl` 中的 fallback DNS 统一修正为 `127.0.0.53`。
  3. **停用境外服务端优选定时器**：
     - 明确优选 IP 测速必须在客户端或本地网关执行，停用服务端的 `cf-bestip.timer` 与 `cf-healthcheck.timer`。

## 7. 全局单流缓冲区保护上限 64MB 规格调整与 Brutal 卸载 (2026-10-08)
- **背景与原因**：
  - 此前 medium/large 档位将单流缓冲区保护上限与 TCP 读写缓冲直接开至 128MB (`134217728` 字节)。
  - 在高突发多并发连接场景下，单流无节制增长至 128MB 会导致内存池被局部大流侵占，增加系统 OOM 风险。
  - 彻底停用并卸载内核 `brutal` 模块，使全协议回归标准 BBRv3 控制环路。
- **调整规范**：
  1. **缓冲区保护上限降至 64MB**：
     - `net.core.rmem_max` 与 `net.core.wmem_max` 调整为 `67108864` (64MB)。
     - `net.ipv4.tcp_rmem` 与 `net.ipv4.tcp_wmem` 的最大值从 128MB 收敛为 `67108864` (64MB)。
     - `06-tuning-lib.sh`、`13-manage-cli.sh`、`ubuntu_vps_optimize.sh`、`vps-tune.sh` 中的 large/medium 档位计算及 `show` 摘要展示统一对齐 64MB 规格。
  2. **Brutal 彻底退役**：
     - 内核中通过 `rmmod brutal` 卸载模块，禁用 `tcp-brutal-rules.service`，清理开机加载项。

## 8. CDN 节点连通性排障与多客户端兼容性规范 (2026-10-08)
- **故障背景**：客户端拉取订阅后测试 CDN 节点显示延迟为 `-1`（连接超时/不可达）。
- **根因分析**：
  1. **Cloudflare 默认 Anycast IP 遭遇 GFW 阻断**：
     - 服务端自动同步将优选域名绑定到了美西本地 SJC 的 `104.21.x.x` IP，而 CDN 域名默认解析也是 Cloudflare 易被墙的 `172.67 / 104.21` 段。大陆网络环境下该 IP 段的 443 端口被运营商与 GFW 大面积阻断丢包，TCP 握手无法完成，直接超时报 `-1`。
  2. **Shadowrocket 专属订阅回退 Bug**：
     - `node.env` 缺少 `BESTCF_DOMAIN` 时，小火箭订阅中的 CDN 节点连接地址回退成了被墙的默认 CDN 域名，而非优选 IP。
  3. **客户端对后量子加密（ML-KEM-768）不兼容**：
     - Mihomo (Clash Meta) 与旧版 V2RayN (Xray < 26.9) 不支持 VLESS 嵌套后量子加密（`mlkem768x25519plus`），带该加密的节点在上述客户端测速必然报错 `-1`。
  4. **Sing-box 客户端 TUN MTU 9000 巨帧黑洞**：
     - `sbox_client.json` 中 TUN 入站硬编码 `"mtu": 9000`，客户端发出巨型帧在公网触发 PMTU 黑洞丢包。
- **解决对策与多端兼容规范**：
  1. **优选 IP 绑定纯净 Anycast 段**：
     - 优选域名必须绑定国内运营商访问优良的官方纯净 Anycast IP 段（如 `104.16.x.x`、`162.159.x.x` 优质节点）。
  2. **小火箭专属 CDN 节点规范**：
     - 补齐 `BESTCF_DOMAIN`，小火箭订阅中的 CDN 节点连接地址锁定为优选域名端口 443，SNI/Host 保持 CDN 域名，路由走免加密的 8002 入站（`/sr-path`，`encryption=none`）。
  3. **客户端协议差异化下发**：
     - Mihomo/Clash 与普通客户端使用免后量子加密的标准节点。
     - Shadowrocket TUIC 链接显式补齐 `version=5`，Naive 转换为 `http3://` / `http2://`，过滤不支持的 `anytls`。
     - Sing-box 客户端 TUN 入站 MTU 严格锁定为标准物理以太网 `1500`。


## 9. sbbox 多端客户端全兼容规范与发布落地 (v2.7.65, 2026-10-08)
- **多端适配矩阵**：
  1. **Sing-box 原生客户端**：
     - TUN 入站 MTU 全面修正为 `1500`（物理以太网标准），消灭 PMTU 巨帧丢包黑洞。
  2. **Shadowrocket (小火箭)**：
     - TUIC 链接显式补齐 `version=5`，防止小火箭误判为 v4 导致握手失败。
     - Naive 链接在识别小火箭 UA 时自动由 `naive+quic://` / `naive+https://` 转换为 `http3://` / `http2://`。
     - 自动过滤剔除小火箭不支持的 `anytls://` 协议，确保导入节点 100% 可用。
  3. **Clash / Mihomo**：
     - `clmi.yaml` 默认隔离 `type: anytls`，并在 `sub_server.py` 下发时执行 `sanitize_clash_yaml` 清洗，防止内核因未知代理类型报错崩溃。
     - 保持 TUIC (`congestion-controller: cubic`) 与 Hysteria2 (`obfs: salamander`) 规范完全兼容。
  4. **v2rayN**：
     - `anytls://` 与 `tuic://` 强校验携带 `security=tls`，满足 core 解析要求，防止无 TLS 配置闪退。
- **发布记录**：
  - 仓库：`ShJChow/New-sing-box-naiveproxy-tuic-hy2-tuning`
  - 版本：`v2.7.65`，Commit: `fc14735`


## 10. CDN 节点自适应 ALPN (h2, h3) 规范与落地 (2026-10-09)
- **背景与需求**：
  - 此前 CDN 节点在客户端 URI 和配置中写死为单一协议（如仅 `alpn=h2` 或仅 `alpn=h3`）。
  - 当客户端网络环境或代理工具对 HTTP/2 与 HTTP/3 (QUIC) 具备不同支持度时，单一协议锁定会导致无法动态协商最优传输层。
  - 调整 CDN 节点为自适应协商 ALPN (`h2, h3`)。
- **调整规范与多端落地**：
  1. **VLESS URI 链接规范**：
     - CDN 节点链接中的 `alpn` 参数调整为 `alpn=h2,h3`（小火箭/v2rayN/Xray 原生均支持逗号分隔解析为 `["h2", "h3"]` 列表）。
  2. **Mihomo (Clash Meta) 代理条目**：
     - `VLESS-XHTTP-CDN-H2` 的 `alpn` 配置更新为 `[h2, h3]` 列表。
     - 同时保留纯 QUIC 的 `VLESS-XHTTP-CDN-H3` (`alpn: [h3]`)，使 Mihomo 的「自动选择」测速组能在 TCP 与 QUIC 间智能择优。
  3. **小火箭 (Shadowrocket) 专属订阅**：
     - 免加密 8002 入站通道下发的 CDN 节点同步下发 `alpn=h2,h3` 与 `alpn=h3,h2`，由客户端自主发起握手协商。
  4. **管理脚本与安装包对齐**：
     - `11-client-config.sh`、`12-subscription.sh`、`13-manage-cli.sh`、`/usr/local/bin/xh` 以及 `dist/` 安装包全量更新。

## 11. 借鉴 Yulinanami 项目：静态回落规范化、Nginx Alt-Svc 广播与参考资料体系演进 (2026-10-09)
- **背景与借鉴来源**：
  - 对标并吸收开源项目 [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config) 的工程实践规范。
- **优化与改进明细**：
  1. **静态站回落目录规范化 (`/var/www/dist`)**：
     - 将静态回落根目录由 `${USER_HOME}/dist` 规范迁移至符合 Linux FHS 标准的 `/var/www/dist`，彻底杜绝 Ubuntu/Debian 普通用户 home 目录权限（700）下 Nginx 运行身份（nobody/www-data）因权限不足导致的 403 报错；
     - 保持向后兼容：当 `${USER_HOME}/dist` 存在时自动平滑识别，目录与文件统一赋予 755/644 安全访问权限；
     - 同步更新 `src/04-input.sh`、`extensions/dual-cdn/01-read-existing.sh`、`extensions/dual-ip/01-read-existing.sh`。
  2. **Nginx HTTP/3 广播声明 (`Alt-Svc`)**：
     - 在 `templates/nginx.conf.tmpl` 与本机运行的 Nginx 对应 server 块中，加入标准 HTTP/3 响应头声明：`add_header Alt-Svc 'h3=":443"; ma=86400' always;`；
     - 使得伪装站点和直接请求对现代浏览器和客户端通告 443 端口支持 HTTP/3，对齐主流互联网大厂（Cloudflare/Google）真实站点行为特征。
  3. **Mihomo TUN DNS 劫持防护强化**：
     - 在 `templates/mihomo-full.yaml.tmpl` 的 `tun.dns-hijack` 中补充 `- tcp://any:53`，MTU 锁定标准 `1500`，杜绝 TCP DNS 查询绕过劫持导致的泄露。
  4. **全套权威参考资料与协议规范体系 (`docs/参考资料.md`)**：
     - 补充 `docs/参考资料.md`，完整收录 Xray-core XHTTP 官方讨论（#4113, #4118）、xpadding 长度混淆泄露分析与 BBS 讨论、Cloudflare ECH 边缘规范与 Xray-core v26.3.27 演进、Mihomo 传输标准、以及 BBRv3 / 64MB 单流保护模型。
  5. **客户端直连与 CDN 灵活路由切换指引**：
     - 在 `README.md` 中补充技术解析：阐明 SNI 锁定 CDN 域名时，客户端 Server 地址在「CDN 优选 IP」与「真实 VPS IP」之间切换的原理，方便用户按需一键切换低延迟直连或抗封锁 CDN。

## 12. 基于 REA-Agents 二进制逆向洞察的 Xray 运行时与硬件级调优 (2026-10-09)
- **背景与逆向发现**：
  - 通过 `rea-agents` 对 `/usr/local/bin/xray` (Xray 26.3.27 ARM64 静态 ELF) 进行结构与 Go buildinfo 深度逆向分析：
    1. **硬件特性匹配**：宿主机为 ARM Neoverse-N1 (ARMv8.2-A)，具备硬件 `atomics` (LSE)、`aes`、`pmull`、`sha1`、`sha2` 与点积指令加速，而预编译版仅锁定 `GOARM64=v8.0`；
    2. **Go 运行时 GC 与调度瓶颈**：当前 VPS 拥有 24GB 物理内存，而默认 Go 运行时无软内存限制（GOMEMLIMIT 未设定），高吞吐并发下容易因默认 GOGC 行为发生不必要的 GC 停顿或抖动。
- **优化与工程落地**：
  1. **自适应 Go 运行时软上限 (`GOMEMLIMIT`)**：
     - 在 `06-tuning-lib.sh` 与系统 drop-in (`10-xray-xhttp.conf`) 中加入动态自适应逻辑：大内存机（>=2GB）将 `GOMEMLIMIT` 设定为物理内存的 75%（24GB 机器设为 `18GiB`），允许 Go 运行时充分享受大物理内存对象池，彻底消除并发激增时的 GC 停顿；小内存机保持 60% 防止 OOM。
  2. **锁定内存与进程调度加固 (`LimitMEMLOCK` / `Nice`)**：
     - drop-in 中追加 `LimitMEMLOCK=infinity`，提升 UDP/QUIC 缓冲区锁定能力；
     - 追加 `Nice=-10`，赋予 Xray 核心更高的系统级 CPU 调度优先级，消除网络包处理的排队调度抖动。
  3. **实时生效与验证**：
     - 本机 `/etc/systemd/system/xray.service.d/10-xray-xhttp.conf` 已更新并重载生效，Xray 进程成功加载 `GOMEMLIMIT=18GiB`、`LimitMEMLOCK=infinity` 并在 7 个核心端口稳定监听。
  4. **彻底修复 systemd-resolved 回退 DNS 异常**：
     - 将 fallback DNS 统一修正为全球权威 Anycast DNS `8.8.8.8`（与 `9.9.9.9`、`1.1.1.1` 组成三核 Anycast 冗余），彻底根除 `127.0.0.53` 在处理特定压缩标签时触发的 `segment prefix is reserved` 异常；
     - 本机 `/usr/local/etc/xray/config.json` 与 `templates/xray-config.json.tmpl` 均已同步修正，Xray 进程零报错稳定运行。
