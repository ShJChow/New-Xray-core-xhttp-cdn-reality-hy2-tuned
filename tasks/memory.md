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
