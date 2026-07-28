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

---

# v1.2.1（2026-07-27）

## Goal

修复 `Vless-xhttp-tls-UDP-direct`（主脚本）与 `Vless-xhttp-tls-h3-direct`（add-quic 扩展）
两条直连节点不通。按用户指示：直连节点不使用 CDN 域名，改用 **Reality 域名（Cloudflare
灰云、DNS 直指 VPS）**；xpadding 的 `extra=` 保持不变。

## Current State（根因，已核对源码/配置，非猜测）

**h3-direct（扩展）—— 结构性错配，确定性 bug：**
`extensions/common-nodes/02-server-config.sh` 把 QUIC 监听与 `location ${XHTTP_PATH}`
插进 **Reality 域名**的 server 块，而 `03-client-config.sh` 生成的节点却发
`sni=${CDN_DOMAIN}`。客户端 SNI 与服务端 `server_name` 分处两块 → TLS 握手命中的是
另一个 server 块（回落网站）→ 必然不通。

**UDP-direct（主脚本）—— 同一族问题：**
`templates/nginx.conf.tmpl` 把 `${NGINX_H3_DIRECT_BLOCK}` 放在 CDN 域名块（与上游
`Yulinanami/my-xhttp-cdn-config` 一致），配置本身自洽；但用户要求直连侧改用灰云的
Reality 域名，而 Reality 块**原本没有 XHTTP 的 `location`**，只改 sni 会失败得更彻底。
因此监听与 location 必须一起搬进 Reality 块。

## Assumptions（已核对）

- 证书为 `REALITY_DOMAIN + CDN_DOMAIN` 双 SAN（`src/07-acme-cert.sh`），换 SNI 不影响校验。
- Xray 8001 入站 `xhttpSettings.host = ""`（不校验 Host），换 Host 无需改服务端 Xray。
- `nginx.conf.tmpl` 由**未加引号**的 heredoc 展开 → 新增 nginx 变量必须写 `\$`（L2）。
- `extensions/common-nodes/02` 会整段删除 `# BEGIN main-h3 … # END main-h3` 后自行插入
  location → 新增 location **必须留在标记内**，否则同块两个同名 location，`nginx -t` 失败。

## 借鉴上游

- `Yulinanami/my-xhttp-cdn-config`（master 分支，2026-07-26 最新）：确认其 `extensions/quic/02`
  把监听插进 **CDN** 块并复用该块已有 location —— 反证我们扩展插进 Reality 块是错配。
- 从上游借入 `add_header Alt-Svc 'h3=":443"; ma=86400' always;`（本项目此前缺失）。
- 未移植上游的上下行分离（H2↑/H3↓）节点，超出本次范围。

## Change Scope

- [x] `templates/nginx.conf.tmpl`：`${NGINX_H3_DIRECT_BLOCK}` 从 CDN 块**移到** Reality 块
- [x] `src/09-server-config.sh`：该段内补 `location ${XHTTP_PATH}` + `Alt-Svc`；heredoc 由
      `<<'EOF'` 改为 `<<EOF`（需展开 `${XHTTP_PATH}`），5 个 nginx 变量转义为 `\$`
- [x] `src/11-client-config.sh`：UDP-direct 的 `sni`/`host`/`servername` → `REALITY_DOMAIN`
- [x] `extensions/common-nodes/03-client-config.sh`：h3-direct 同改；去掉直连节点的 ECH
      （ECH 是 Cloudflare 侧机制，直连不适用）
- [x] `extensions/common-nodes/01-read-existing.sh`：CDN 节点缺失不再 `error` 中断（L10：
      该变量原本只为直连节点服务）；移除 ECH 复用询问
- [x] `extensions/common-nodes/02-server-config.sh`：其 sed 插入的 `location` 补上
      `grpc_socket_keepalive` / `grpc_read_timeout 1h` / `grpc_send_timeout 1h` /
      `grpc_connect_timeout 15s`。该 location 此前**从未被命中**（客户端 SNI 走的是
      CDN 域名），本次修复让它首次生效，不补就会继承 nginx 默认 60s 超时，
      表现为"能连上但每 60 秒断一次"
- [x] `src/13-manage-cli.sh`：`xh diag` 新增"quic 监听与 location 是否同在 Reality 块"的
      判定；客户端自测新增一条 `curl --http3-only --resolve` 直打本机 UDP 443
- [x] `README.md` / `docs/8` / `客户端模板.txt` / `客户端模板-mihomo.yaml` 同步
- [x] 重建 `dist/` 5 个产物

## Verification

- [x] 4 个 build 脚本 + `bash -n dist/*.sh` 全绿；抽取的 `cmd_diag` 单独 `bash -n` 通过
- [x] **从 `dist/install-xpadding.sh` 抽取真实模板与真实 `FEATURE_H3_DIRECT` 分支**执行渲染
      （L5：不手抄副本），断言：
      - `true`：Reality 块同时含 quic 监听 + `location`（恰好 1 次）+ `Alt-Svc`；
        CDN 块仍有自己的 `location` 且**不含** quic；`$host` 已正确解转义（无残留 `\$`）
      - `false`：全文无 `main-h3`，Reality 块既无 quic 也无 location
- [x] 模拟 add-quic 流程（删 `main-h3` 段 → 插入扩展自己的 location）后，Reality 块中
      `location` 恰好 1 次（防重复定义导致 `nginx -t` 失败）
- [x] 两条直连节点链接断言：`sni`/`host` 均为 Reality 域名，`extra=`（xpadding）仍在；
      `Vless-xhttp-tls-UDP-cdn` 未被波及，仍用 CDN 域名
- [x] `客户端模板-mihomo.yaml` 经 `yaml.safe_load` 解析通过
- [x] **从 `dist/add-quic.sh` 抽取真实 `build_common_nodes_block` 执行**（该函数本次由
      三段 heredoc 合并为一段、删掉了中间的 `ech-opts` 分支，是 YAML 缩进最易出错处），
      `XHTTP_EXTRA` 有/无两种取值下 `yaml.safe_load` 均通过，断言 `servername`/`host`
      为 Reality 域名、无 `ech-opts`、xpadding 随 `XHTTP_EXTRA` 正确开合
- [x] `grep -rn 'sni=|host=|servername' extensions/dual-cdn extensions/dual-ip`：两个扩展
      分别读 CDN 节点与 Reality 节点，均不读直连节点，未受本次改动影响（L10）

## Review

- h3-direct 的失败是**可判定的配置错配**（服务端与客户端分处两个 `server_name`），
  与 v1.2.0 结论中"两条 UDP 节点同时失败 ⇒ 共同因子在客户端"不同——那条结论针对的是
  UDP-cdn + UDP-direct 的组合，对 add-quic 的 h3-direct 并不成立。
- 修复后 `xh diag` 能直接判定这一类错配，不再依赖人工比对两个 server 块。

### 附带的行为变化（非 bug，记录以免意外）

`location ${XHTTP_PATH}` 进入 Reality 块后，也会经 Xray REALITY 的 `dest 8003` 回落
暴露在 **TCP 443** 上。这是搬移 location 的副作用，等于多了一条直连 TCP 路径，
不影响既有节点。

**未验证（L8）**：无 VPS —— nginx 能否加载 `443 quic`、证书链、以及两条直连节点的实际
连通性均未做运行时验证。若云厂商安全组未放行 UDP 443，本次改动**不解决**问题，
`xh diag` 会明确提示这一层查不到。

---

# v1.2.7 · 节点方案回归上游拓扑 + 停用直连 H3 + xmux 分层调优（2026-07-28）

## Goal

1. 停用两条在 Shadowrocket 下实测不通的直连 h3 节点；
2. 节点集回归上游 `Yulinanami/my-xhttp-cdn-config` 拓扑（恢复 v1.2.0 删掉的两条上下行分离节点），
   同时保留本项目自有的 `Vless-xhttp-tls-UDP-cdn`；节点名统一为英文且不沿用上游命名；
3. xmux 参数调优。

## Current State

已完成（2026-07-28）。节点数 4 → 5。

## Assumptions

- **「回退到 1.2.5」不做 git revert**：`git diff v1.2.5 v1.2.6` 只动了 nginx resolver 协议族、
  `access_log off`、`listen backlog=65535`，**全部不在 H3/QUIC 路径上**——直连 h3 的问题从
  v1.2.0/v1.2.1 时代就存在，literal revert 修不好它。v1.2.6 的 `tools/perf-audit.sh`、
  `xh conflict`、nginx 三项调优全部保留。
- **Shadowrocket 对 `downloadSettings` 的支持本机无法验证**（用户确认照常生成），已在
  README / 客户端模板显式标注「SR 支持待验证，推荐 mihomo / onexray」。
- `add-quic.sh` 扩展**整体保留不动**：它同时产出 `Hysteria2-direct`（独立协议，与 h3 无关），
  整体废弃会误伤。仅在 docs/8 加勘误。
- 服务端零改动即可承载恢复的两条节点：两条腿走的都是已验证通路（Reality 腿直落 Xray TCP 443；
  CDN 腿落 nginx `${CDN_DOMAIN}` server 块，该块已有 `location` 且带 `grpc_read_timeout 1h`）。
- 已核实无需改动：`src/12-subscription.sh`（只 cp/base64）；`mihomo-full.yaml.tmpl` 的
  proxy-groups 用 `include-all: true`；`extensions/dual-cdn|dual-ip/03-client-config.sh`
  均为「`sed -i` 删自己那条 + `>>` 追加」的增量写法。

## Change Scope

- [x] `src/01-env.sh`：`FEATURE_H3_DIRECT` 默认 `true` → `false`（一行同时关掉节点链接、
      mihomo 块、nginx `443 quic` 监听；代码路径完整保留可回滚）
- [x] `src/11-client-config.sh`：`NODE_UDP_DIRECT_LINE` 自带 `$'\n'` 前缀，关闭时不留空行
- [x] `src/11-client-config.sh`：新增 `XMUX_H3_ENC`（64-128，h3 专用）；新增下行渲染变量
      `MIHOMO_XPADDING_DOWNLOAD_BLOCK` / `MIHOMO_ECH_DOWNLOAD_BLOCK` / `MIHOMO_REUSE_KEEPALIVE_DOWNLOAD`
- [x] `templates/client-config.txt.tmpl`：追加两条上下行分离节点 URI，**逐字保留上游的
      `${VAR:+…}` guard 写法**——若换成本项目的 `${EXTRA_N_PARAM}` 风格，normal 版
      （`FEATURE_XPADDING=false`）会整体丢掉 `downloadSettings`，节点退化成普通 CDN/Reality
      节点且**能连通、看着正常**
- [x] `templates/mihomo-proxies.yaml.tmpl`：追加两个 proxy 块（含 `download-settings`）
- [x] `extensions/common-nodes/00-env-utils.sh`：新增 `NODE_RE_SPLIT_*`；**保留全部历史正则**
- [x] `src/13-manage-cli.sh`：`xh diag` 的跳过文案改为「v1.2.7 起默认停用」，默认值同步 false
- [x] README / docs/8 勘误 / `客户端模板.txt` / `客户端模板-mihomo.yaml`
- [x] 重建 `dist/` 全部 5 个产物

### 节点命名

| # | 节点名 | 上行 | 下行 |
|---|---|---|---|
| 1 | `Vless-reality-vision-<tag>` | 直连 TCP 443 Reality+Vision | 同左 |
| 2 | `Vless-xhttp-reality-<tag>` | 直连 TCP 443 XHTTP+Reality | 同左 |
| 3 | `Vless-xhttp-tls-UDP-cdn-<tag>` | CDN h3 | 同左 |
| 4 | `Vless-xhttp-split-cdnup-realitydown-<tag>` | CDN+TLS (h2) | 直连+Reality |
| 5 | `Vless-xhttp-split-realityup-cdndown-<tag>` | 直连+Reality | CDN+TLS (h2) |

`Vless-xhttp-split-` 前缀刻意与 `NODE_RE_XHTTP_REALITY` / `NODE_RE_CDN_BOTH` 都不重叠。

### xmux（依据 `Xray-core transport/internet/splithttp/mux.go` 逐字核对）

| 字段 | 值 | 源码语义 | 动作 |
|---|---|---|---|
| `cMaxReuseTimes` | 0 | `leftUsage = -1` = **无限复用** | 不动（L16） |
| `hKeepAlivePeriod` | 0 | h3 取 quic-go 默认、h2 取 Chrome 默认 | 不动（L16） |
| `hMaxRequestTimes` | 未设 | `LeftRequests = MaxInt32` | 不设 |
| `hMaxReusableSecs` | 3600-6000 | 连接存活上限 | 不动 |
| `maxConcurrency` | 见下 | 每连接并发请求上限 | 唯一旋钮 |

- 节点 3（h3）：32-64 → **64-128**
- 节点 1/2/4/5（h2 或 Reality 腿）：保持 **32-64**（单条 TCP，拉高会放大队头阻塞）

## Verification

- [x] **V1** `bash -n` 跑遍 `dist/*.sh` —— 5/5 通过
- [x] **V2** 从 `dist/install.sh` **与** `dist/install-xpadding.sh` 用 awk 抽取真实代码执行渲染
      （L5：不手抄副本），三种组合 `normal` / `xpadding` / `xpadding+h3`：
      每条 URI 的 `extra=` URL-decode 后过 `json.tool` 合法；mihomo YAML 过 `yaml.safe_load` 合法；
      proxies 名单逐字相等；**`downloadSettings` 在两个 profile 下都出现在节点 4/5**
- [x] **V3** L11 SNI ↔ server_name：节点 4 上行 `sni=CDN` / 下行 `serverName=Reality`，
      节点 5 反向，四项全部断言通过
- [x] **V4** 扩展定位回归（L10）：v1.0.0 中文名 / v1.2.4 四节点 / v1.2.7 五节点三种历史格式下，
      5 条 `NODE_RE_*` 命中的**都是应该命中的那一条**；`Vless-xhttp-split-*` 未被误命中
- [x] **V5** 5 条基础节点在全部扩展（dual-cdn / dual-ip / common-nodes）的 `sed` 删除模式下均存活
- [x] **V6** `FEATURE_H3_DIRECT=false` 渲染洁净：无空行、无 `UDP-direct`、nginx 无 `listen 443 quic`
- [x] **V7** heredoc 转义复查（L2）：`nginx.conf.tmpl` 无未转义 `$`
- [x] **V8** profile 维度全覆盖：`normal` / `xpadding` / `xpadding+h3` / **`xpadding+ECH`** /
      **`xpadding+IPv6`** 共 5 种组合，合计 **155 条断言全绿**。
      - ECH 是新代码最集中的地方：`MIHOMO_ECH_DOWNLOAD_BLOCK` 与 `MIHOMO_XPADDING_DOWNLOAD_BLOCK`
        在节点 5 的 `client-fingerprint: chrome${...}${...}` 处背靠背拼接（YAML 缩进最易出错处），
        且节点 5 的 `${CDN_ECH_QUERY_ENC:+%2C%22echConfigList%22…}` 注入 `downloadSettings` JSON。
        两处经 `yaml.safe_load` / `json.loads` 验证通过。
      - IPv6 覆盖节点 4 的 `${VPS_IP//:/%3A}`：断言 `downloadSettings.address == "2001:db8::1"`
        （未被 `%3A` 污染）。

### 验证中发现并修复的真实问题

1. `Vless-xhttp-tls-UDP-direct` 的 **mihomo 块**仍是 `max-concurrency: "32-64"`，而其 URI 版
   已改为 64-128（同为 h3）——V2 断言抓到，已同步。
2. `客户端模板-mihomo.yaml` 里 `Vless-xhttp-tls-UDP-cdn` 的 `servername`/`host` 误写为
   `YOUR_REALITY_DOMAIN`（应为 CDN 域名）——同 L11 类错配，顺手修正。

## 未验证项（L8，需 VPS / 客户端实测）

- 节点 4/5 在 **Shadowrocket** 中能否连通（`downloadSettings` 支持性）；
- 节点 3 把 `maxConcurrency` 提到 64-128 后的**实际吞吐方向**——CF 边缘的 HTTP/3
  `MAX_STREAMS` 若低于 128，quic-go 会阻塞在建流上而非另开连接，并行度可能反降。回滚值 32-64；
- nginx 去掉 `443 quic` 监听后能否正常启动（预期只会更稳）。
