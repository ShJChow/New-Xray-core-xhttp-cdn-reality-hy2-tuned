# xray-xhttp 项目生成任务

## Goal

以 `Yulinanami/my-xhttp-cdn-config`（MIT）为基座，融合 `ShJChow26/argosbx` 的产品形态，生成可上传到 `github.com/ShJChow26/xhttp-cdn-tuned` 的项目：主路径为带 xpadding 的 XHTTP（ECH 可选），流控参数全部打开。

## Current State

已完成（2026-07-26）。

## Assumptions

- 构建产物头部为 `#!/bin/bash` + `set -e`，任何调优写操作必须 best-effort。
- 模板由**未加引号的 heredoc** 展开，nginx 变量必须写 `\$`。
- Xray sockopt 字段为 `tcpcongestion`（小写 c）；`tcpNoDelay` 已废弃移除。
- `xmux` 为客户端侧字段；服务端 `scMaxEachPostBytes` 是上限语义，不调大。
- 扩展脚本只改 nginx server 块、复用已有 Xray 入站，不会抹掉本次调优。

## Change Scope

- [x] 落盘基座并重编号 `src/`（01–14，步骤标签 `[n/8]`）
- [x] `src/01-env.sh`：项目常量 + `FEATURE_TUNING/KEEPALIVE/AUTOUPDATE/AUTO` 开关
- [x] `src/04-input.sh`：`ask()` + `AUTO=1` 非交互一键
- [x] `src/06-net-tuning.sh`：内核 / 句柄调优 + BBR 探测 + sockopt 片段生成
- [x] `src/09-server-config.sh`：写 `/etc/xhttp-cdn/node.env`
- [x] `src/13-manage-cli.sh`：管理命令 `xh` + 保活 / 自动更新 cron
- [x] `src/14-final-output.sh`：输出 `xh` 用法与 BBR 降级提示
- [x] `templates/xray-config.json.tmpl`：两入站 + freedom 出站注入 sockopt
- [x] `templates/nginx.conf.tmpl`：句柄 / 连接数 / gRPC 长连接超时
- [x] `.github/scripts/build-install.sh`：MODULES 数组同步
- [x] `README.md` / `NOTICE.md` / `LICENSE` / `docs/10` / `docs/11` / `docs/9` 补充

## Verification

- [x] 4 个 build 脚本产出 dist/ 5 个安装脚本
- [x] `bash -n` 全部通过
- [x] 8 组占位变量组合渲染 `xray-config.json.tmpl`，`python -m json.tool` 全部合法
- [x] nginx 模板新增行无未转义 `$`
- [x] MODULES 数组与 `src/` 文件一一对应，步骤标签 `[1/8]`–`[8/8]` 连续
- [x] 抽取生成的 `xh` 脚本（455 行）单独 `bash -n` 通过
- [x] 用桩 `crontab` 验证 `keepalive on/off`、`autoupdate on` 的幂等性：重复执行不产生重复行，
      acme.sh 续签行与用户无关 cron 行全程保留（这是唯一具有"延迟且无声"失败模式的路径）

**未验证**：无 VPS，证书签发、BBR 实际生效、Nginx 编译、Xray 启动、客户端连通性与 CDN 链路均未做运行时验证。

---

# v1.1.0（2026-07-26）

## Goal

客户端 flow 改 `xtls-rprx-vision-udp443`；按 Oracle Ampere A1（4 OCPU / 24 GB / ARM64）整体调优；节点名重写为 ASCII + 主机名后缀；新增两条 XHTTP over HTTP/3（UDP 443）节点。

## Change Scope

- [x] flow：客户端链接与手动模板改 `-udp443`；**服务端 inbound 保持 `xtls-rprx-vision`**（Xray 源码中 `XRV` 是唯一常量，客户端 `-udp443` 只是本地开关，上线仍发 `xtls-rprx-vision`）；mihomo 保持原值（其 flow 被截断到 16 字符，写了无效）
- [x] `src/06-net-tuning.sh`：探测内存/核数/架构，按内存分 large/medium/small 三档；`tcp_mem` 用 `getconf PAGESIZE` 换算，不再假定 4K 页
- [x] `templates/xray-config.json.tmpl`：新增 `policy` 段，`bufferSize` 按档位 512/256/64 KB（ARM64 默认仅 4 KB）
- [x] 节点名重写为 `Vless-*-<hostname>`（`src/05-base-env.sh` 生成 `HOSTNAME_TAG`）
- [x] 新增节点 6（经 CDN 的 h3，服务端零改动）与节点 7（直连 VPS 的 h3，Nginx 加 `listen 443 quic reuseport`，标记 `# BEGIN main-h3`）
- [x] `extensions/common-nodes/02-server-config.sh`：删除 `main-h3` 标记段，避免 `add-quic.sh` 与主脚本 `reuseport` 重复
- [x] 新增 `docs/12.机型调优-OracleARM.md`；更新 `docs/10`、`docs/2`、README

## Verification

- [x] 4 个 build 脚本 + `bash -n dist/*.sh` 全绿；抽取的 `xh` 单独 `bash -n` 通过
- [x] 渲染矩阵 13 组（3 档 bufferSize × BBR 有无 × xpadding 有无 + 关闭调优），`python -m json.tool` + 断言：`bufferSize` 正确、服务端 flow 必须是 `xtls-rprx-vision`、`tcpcongestion` 只在 BBR 可用时出现。**渲染函数直接从 `dist/install-xpadding.sh` 抽取执行**，不再手抄副本，源码漂移会被测出
- [x] 分档回归覆盖 4K/16K/64K 页大小，断言 `tcp_mem` 上限恒低于物理内存
- [x] 节点断言：7 条链接、7 个唯一 ASCII 名、`main-h3` 段落存在

**未验证**：无 VPS —— `bufferSize` 的实际吞吐收益、BBR 生效、Nginx `listen 443 quic` 能否通过 `nginx -t`、两条 h3 节点的连通性均未做运行时验证。

---

# v1.1.4（2026-07-26）

## Goal

用户要求"回滚到 1.2 版本的节点"（即 v1.1.2 的 7 节点，含两条 `alpn=h3` 的 UDP 节点），同时保留 v1.1.3 修的两个问题（flow 默认值、acme reloadcmd 报错吞没）。已知这会重新引入曾导致 nginx 启动失败的 `listen 443 quic` 监听，用户在 AskUserQuestion 中明确知情后选择该项。

## Change Scope

- [x] 新增 `FEATURE_H3_DIRECT`（默认 `true`）开关，作为逃生舱：`false` 时不生成 nginx 的 `443 quic` 监听，也不生成对应的死链接节点
- [x] `templates/nginx.conf.tmpl`：CDN server 块改为 `${NGINX_H3_DIRECT_BLOCK}` 占位符
- [x] `src/09-server-config.sh`：渲染 nginx.conf 前按开关生成该占位符内容；`node.env` 记录 `FEATURE_H3_DIRECT`
- [x] `templates/client-config.txt.tmpl`：恢复节点 7（经 CDN 的 h3，服务端零改动，不受开关影响）；节点 8（直连 h3）改为 `${NODE_UDP_DIRECT_LINE}` 占位符
- [x] `src/11-client-config.sh`：按开关生成节点 8 的链接或空串
- [x] `src/13-manage-cli.sh`：`xh info` 显示该开关状态
- [x] README / docs/10 / docs/12 / 客户端模板.txt 同步：8 节点表、开关用法、Oracle 防火墙提醒改回需要放行 UDP 443（除非关闭该开关）

## Verification

- [x] 4 个 build 脚本 + `bash -n dist/*.sh` 全绿
- [x] nginx 模板未转义 `$` 检查（两处例外是既有的 `$(nginx_fallback_config ...)` 函数调用，非本次引入）
- [x] 13 组 xray-config 渲染矩阵（复用既有测试，未受本次改动影响）
- [x] 新增 h3 开关回归：`FEATURE_H3_DIRECT` true/false 两种取值下，分别断言 nginx.conf 是否含 `main-h3` 段、`client-config.txt` 是否为 8/7 条节点、是否含/不含 UDP-direct 节点
- [x] 复用既有的扩展节点定位回归，确认恢复的 UDP 节点不会被 `NODE_RE_CDN_BOTH` 等正则误匹配

**未验证**：无 VPS —— 节点 8 的 nginx `443 quic` 监听能否通过 `nginx -t` 与实际连通性仍未做运行时验证，这正是 `FEATURE_H3_DIRECT` 开关存在的原因。

---

# v1.2.0（2026-07-27）

## Goal

按用户要求收敛节点：只保留 `xhttp+reality` 直连与 UDP（h3）节点，CDN 侧只留 UDP 版；并处理"两条 UDP 节点都不通"。

## Current State

v1.1.4 有 8 条节点。用户反馈两条 UDP 节点**都**连不上。

## Assumptions（已核对，非记忆）

- Xray `transport/internet/splithttp/dialer.go:84-101` `decideHTTPVersion`：**`alpn` 必须恰好为 `["h3"]`** 才走 HTTP/3；`len != 1` 一律降级为 h2。链接写 `alpn=h3` 满足。
- Xray 同文件 `:363-371`：`mode=auto` + TLS（无 reality）→ `packet-up`；我们的 CDN 节点即此模式。
- **Mihomo `transport/xhttp/client.go:159` 同样支持 h3**（`len(alpn)==1 && alpn[0]=="h3"`）。此前 docs 里"未核实 mihomo 对 XHTTP-over-H3 的支持"是错的，本次一并纠正，Mihomo 配置也纳入 UDP 节点。
- 两条 UDP 节点走**完全不同**的路径（CDN 节点根本不碰本项目服务端，与已能用的 h2 CDN 节点只差 client↔CF 这一段）。两条同时失败 ⇒ 共同因子在客户端侧网络或客户端内核，**服务端改不了**。

## Change Scope

节点收敛为 4 条（用户选择保留 Vision 作兜底）：

| # | 节点 | 说明 |
|---|---|---|
| 1 | `Vless-reality-vision-<host>` | TCP 直连，唯一走 Splice，UDP 全挂时的兜底 |
| 2 | `Vless-xhttp-reality-<host>` | TCP 直连，XHTTP + Reality |
| 3 | `Vless-xhttp-tls-UDP-cdn-<host>` | UDP 443 经 CDN，`alpn=h3` |
| 4 | `Vless-xhttp-tls-UDP-direct-<host>` | UDP 443 直连，受 `FEATURE_H3_DIRECT` 控制 |

- `templates/client-config.txt.tmpl`：删除节点 3/4/5/6（h2 的 CDN 与直连 TLS）
- `templates/mihomo-proxies.yaml.tmpl`：同步为 4 条，UDP 节点用 `alpn: [h3]`
- `src/11-client-config.sh`：删除随之失效的 `EXTRA_3` / `EXTRA_5` 及其专用编码变量；新增 `${MIHOMO_UDP_DIRECT_BLOCK}`
- **`extensions/*/00-env-utils.sh`**：`NODE_RE_CDN_BOTH` 增加 `Vless-xhttp-tls-UDP-cdn-` 分支。h2 的 CDN 节点已删除，不加这条会让三个扩展全部报"未找到节点"（v1.1.1 同款回归）。旧装机仍存在 h2 节点时，因 `head -n1` 取文件首个匹配，仍优先命中 h2 节点。
- **`src/13-manage-cli.sh` 新增 `xh diag`**：把"UDP 不通"从猜测变成可判定——检查 nginx 是否在监听 UDP 443、防火墙是否放行、`FEATURE_H3_DIRECT` 状态，并给出客户端侧自测步骤。

## Verification

1. 4 个 build 脚本 + `bash -n dist/*.sh`
2. nginx 模板未转义 `$` 复查
3. 既有 13 组 xray-config 渲染矩阵
4. `FEATURE_H3_DIRECT` 开关回归（节点数 4/3、nginx 含/不含 main-h3）
5. 扩展节点定位回归：**新 4 节点文件**、v1.1.4 的 8 节点文件、v1.0.0 中文名文件三种输入下均能定位到 CDN 参数
6. Mihomo YAML 用 Python `yaml.safe_load` 解析验证结构合法

**未验证**：无 VPS —— UDP 连通性、nginx `443 quic` 能否起来均未做运行时验证。

## Review

- 两条 UDP 节点同时失败，服务端侧无法解释：CDN 那条不经过本项目任何新增配置。`xh diag` 的价值在于**排除**服务端，把结论收敛到客户端网络（UDP 443 被封是常见情况）或客户端内核版本。
- 纠正了一处此前写进公开文档的错误结论（mihomo 不支持 XHTTP-h3）——源码显示支持。

## Review（v1.0.0）

- 最实质的性能修复是 Nginx 的 `grpc_read_timeout` / `grpc_send_timeout`（默认 60s 会周期性切断 XHTTP 长连接），而非内核参数本身。
- "流控最佳全开" 的正确含义不是把每个旋钮拉满：`tcpMptcp`、`scMaxEachPostBytes`、内核替换都被明确排除。
- 全部调优可用 `xh tuning off` 单命令回滚，符合"最易回滚"的选型标准。
