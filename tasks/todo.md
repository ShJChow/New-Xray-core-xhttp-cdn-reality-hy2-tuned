# 任务：按上游 Yulinanami/my-xhttp-cdn-config 补齐 Reality 节点集

## Goal
把默认节点集里的 Reality 部分对齐上游 `my-xhttp-cdn-config`（master）的三条：

1. `reality+vision 直连`（TCP + Reality + Vision）——本仓已有（`Vless-reality-vision-*`）
2. `xhttp+Reality 上下行不分离`——本仓已有（`Vless-xhttp-reality-*`）
3. `上行 xhttp+Reality | 下行 xhttp+TLS+CDN`——**本仓 v4.0.0 时被删除，本次补回**

即净变更 = 新增第 3 条上下行分离节点（URI 版 + mihomo 版），前两条保持不动。
上游的另一条镜像节点（上行 CDN / 下行 Reality）用户未要求，不加。

## Current State
- `templates/client-config.txt.tmpl`：5 行节点，第 4、5 行为两条 Reality。
- `templates/mihomo-proxies.yaml.tmpl`：5 个 proxy，末两个为两条 Reality。
- `src/11-client-config.sh` 已定义但当前**无人消费**的变量（v4.0.0 删节点时的遗留）：
  `XHTTP_PATH_ENC`、`MIHOMO_XPADDING_DOWNLOAD_BLOCK`、`MIHOMO_ECH_DOWNLOAD_BLOCK`、
  `MIHOMO_REUSE_KEEPALIVE_DOWNLOAD` —— 本次正好复用，无需新增变量。
- 服务端：两条腿落在**不同** inbound（上行 → 443 Reality → nginx → 8001；
  下行 → CDN 域名 443 → CF Origin Rule → `CDN_DIRECT_PORT` 独立 inbound）。

## Assumptions
- A1：XHTTP 上下行分离的会话相关性由 `path` + 会话 ID 在代理层完成，与落在哪个
  inbound 无关，只要 UUID2 / `XHTTP_PATH` / `decryption` 一致即可。
  → **这是一个假设，本仓没有已验证的先例支撑它。**
  上游原版、本仓 dual-ip / dual-cdn 的分离节点，两条腿都落在**同一个** inbound。
  唯一形状相同的 `extensions/quic-h3/03-client-config.sh:44` 自身依赖
  XHTTP-over-h3（上游 #4391 / #5849 均 closed as not planned，01-env.sh 已注明
  「最坏情况是 h3 退回 TCP 后它自己不通」），它是否过流量同样未测——
  拿它当「已发布功能」是我最初高估了证据强度。
  → 本次唯一的**运行时风险点**，必须实机验证（见 Verification 第 5 项）。
- A2：下行走 CDN 用 `alpn=h2`，与 `09-server-config.sh:142` CDN 独立 inbound 的
  `["h2","http/1.1"]` 匹配；不复制节点 1 的 `h3`。
- A3：新节点名不得落进 `NODE_RE_XHTTP_REALITY='#(Vless-xhttp-reality-|…)'`
  等前缀，否则 `find_node_line` 的 `head -n1` 会让 dual-ip / common-nodes 扩展
  读到错误的行。选名 `Vless-xhttp-split-realityup-cdndown-${HOSTNAME_TAG}`。
- A4：外层 `extra=` 需要**未加花括号**的 `XPAD_FIELDS_ENC` + `XMUX_ENC`
  （上游自建 `%7B…%7D`）；嵌套 `xhttpSettings.extra` 才用 `XPAD_EXTRA_ENC`。
- A5：`xray-config.json.tmpl` 无需改动——两条腿命中的 inbound 都已存在。

## Change Scope
| 文件 | 改动 |
|---|---|
| `templates/client-config.txt.tmpl` | 末尾追加 1 行分离节点 URI |
| `templates/mihomo-proxies.yaml.tmpl` | 末尾追加 1 个 proxy（含 `download-settings`），并更新顶部顺序注释 |
| `src/01-env.sh` | 节点集注释 5 条 → 6 条，补第 6 条说明 |
| `src/11-client-config.sh` | 节点集注释与 `info` 行描述 |
| `README.md` / `README.en.md` / `README.fa.md` | 节点列表补一条 |
| `src/01-env.sh` | `PROJECT_VERSION` 4.3.2 → **4.4.0**（本仓惯例：节点集变更必升版本） |
| `客户端模板.txt` / `客户端模板-mihomo.yaml` | 同步补一条（若其为节点样例） |
| `docs/5.流程图.md` | 若枚举节点则补一条 |

不改：`templates/xray-config.json.tmpl`、`src/09-server-config.sh`、
`extensions/**`（新节点名已避开全部 `NODE_RE_*`）。

## 顺带发现（本次不修）
`extensions/dual-ip/03-client-config.sh:65,81,99,118` 用 awk 锚定
`^  - name: xhttp\+Reality 上下行不分离`，但本仓 mihomo 模板发出的名字是
`Vless-xhttp-reality-${HOSTNAME_TAG}`，该锚点在本仓从不命中 —— 疑似 v4.0.0
改名时的遗漏，属既有缺陷，与本次变更无因果关系，单独立项处理。

## Verification
1. 静态渲染：喂一组假变量展开 `@@include`，`client-config.txt` 应为 6 行、
   每行以 `vless://` 或 `hysteria2://` 开头。
2. `extra=` URL-decode 后必须是合法 JSON，且 `downloadSettings.address == CDN_DOMAIN`、
   `security == "tls"`、`alpn == ["h2"]`。
3. mihomo YAML 解析通过，新 proxy 的
   `download-settings.reality-opts.public-key == ""`（防父级 reality 泄漏）。
4. 扩展兼容：对渲染出的 `client-config.txt` 跑
   `grep -E '#(Vless-xhttp-reality-|xhttp%2BReality%20)' | head -n1`，
   结果必须仍是不分离节点那一行，不是新节点。
5. 实机（A1 风险点）：装机后单独测该节点是否真能过流量。
   若不通，**修法在服务端侧**：CF Origin Rule 掌握 cdn 域名 → `CDN_DIRECT_PORT`
   的映射，客户端 URI 改不动下行落点，无法自行绕回 443 回落链。

## Review

Change Scope 全部完成。净变更 = 新增 1 条节点（URI 版 + mihomo 版）+ 文档同步。

| 验证项 | 结果 |
|---|---|
| V1 渲染行数 | ✅ `client-config.txt` 6 行，尾行为新节点 |
| V2 `extra=` JSON | ✅ xpadding 开/关两个 profile 均解析通过；`address=CDN_DOMAIN`、`security=tls`、`alpn=["h2"]`、`path` 用 `XHTTP_PATH_ENC` |
| V2b ECH profile | ✅ `CDN_ECH_QUERY_ENC` 非空时 `downloadSettings.tlsSettings.echConfigList` 正确出现 |
| V3 mihomo YAML | ✅ 6 个 proxy 解析通过，`download-settings.reality-opts == {'public-key': ''}`，父级 reality-opts 未泄漏 |
| V4 扩展兼容 | ✅ `grep -E '#(Vless-xhttp-reality-\|xhttp%2BReality%20)' \| head -n1` 仍命中不分离节点 |
| 构建 + 语法 | ✅ `build-install.sh` 通过；`dist/*.sh` + `src/*.sh` + `extensions/*/*.sh` 全部 `bash -n` 通过 |
| V5 实机过流量 | ⚠️ **未验证**，本机无 VPS，见 A1（无已验证先例可依） |

### 过程中发现并修掉的一个真实缺陷

首版注释里写了 `` `reality-opts: { public-key: "" }` ``（带反引号）。
`mihomo-proxies.yaml.tmpl` 是被 **unquoted heredoc** 展开的，反引号 = 命令替换，
安装时会执行 `reality-opts: ...` 并报 `command not found`，同时把该段注释吞成空串。
已改为不含反引号的写法，并在注释里就地记下这条约束。

→ 通用规则：`templates/*.tmpl` 里禁止出现反引号和未转义的 `$(`，因为全部模板
都走 unquoted heredoc 渲染。

### 未验证 / 已知遗留

1. **A1 跨 inbound 分离会话**（本次唯一运行时风险）。上行腿落 8001 inbound，
   下行腿落 `CDN_DIRECT_PORT` 独立 inbound。本仓**没有**已验证的跨 inbound 先例
   （详见修订后的 A1）。修法在服务端侧，客户端 URI 改不动。
   → 交付时必须向使用者明说：这条节点未经实机验证。
2. `docs/5.流程图.md` 的「模式 5」子图**本次未改**。它画的下行路径是
   CDN → 443 → nginx 8003 → 8001，属 v4.3.0 引入 CDN 独立 inbound 之前的旧路径；
   同样的过时也存在于模式 1/4。这是既有文档漂移，与本次变更无因果关系，
   要修就该连 CDN 全路径一起修，另立一项。
3. `docs/2.文件配置.md`「模式五」与 `docs/3.xpadding配置.md` 的第二个
   `downloadSettings` 示例，经逐字段核对与本次生成结果**一致**
   （address=CDN_DOMAIN / security=tls / alpn=["h2"] / xpadding 内外层都写），
   无需改动——它们本就是这条节点被删前留下的文档，现在重新生效。
   两文件里的「模式三」示例（上行 CDN / 下行 Reality）对应上游的镜像节点，
   本仓不生成，仍为孤儿文档，本次不动。
4. TUN 绕行经核查**无需改动**：`templates/mihomo-full.yaml.tmpl:467` 的
   `DOMAIN-SUFFIX,${CDN_DOMAIN},全局直连` 与 `v2rayn-tun.txt.tmpl` 的 CDN 域名
   条目已覆盖节点 6 的下行腿（与节点 1 同一域名）。
5. `extensions/dual-ip/03-client-config.sh:65,81,99,118` 的 awk 锚点
   `^  - name: xhttp\+Reality 上下行不分离` 在本仓从不命中（本仓发出的名字是
   `Vless-xhttp-reality-*`），疑似 v4.0.0 改名遗漏，既有缺陷，本次不修。

---

# 事故记录：quic-h3 扩展打死主链路（2026-08-06）

## 现象
用户跑 `add-quic-h3.sh` 后，**三条新节点全不通，且默认的
`Vless-xhttp-tls-UDP-cdn` 节点也一起不通**。

nginx error.log 持续报：
```
upstream rejected request with error 5 while reading response header from upstream,
client: 127.0.0.1, server: cdn.xxx, request: "POST /<path>/<sessionid>/0 HTTP/2.0",
upstream: "grpc://127.0.0.1:8001"
```
gRPC error 5 = NOT_FOUND，是 Xray 8001 在拒绝上行 POST。

## 排查过程与两次判断失误
1. 先按「三条节点的公因子是 h3 腿」推断根因在 UDP 不通（云安全组）。
   诊断输出否定了它：nginx 确实在监听 UDP 443（4 socket = 4 worker × reuseport）、
   quic 段插入位置正确、本机 nft 全 accept、nginx 无启动错误。
2. 改推「h3 腿死 → 会话建不起来 → 上行 POST 404」。用户一句
   「默认 CDN 节点也不通」直接推翻——error 5 是主症状不是连带症状。
3. 单变量二分（删掉 BEGIN/END quic-h3 段 + 重启 nginx）→ **主链路立刻恢复**。
   根因确定落在插入的那两行内。

## 根因：定位到 2 行，机制未查清
插入内容：
```nginx
listen ${PORT} quic reuseport;
add_header Alt-Svc 'h3=":${PORT}"; ma=86400' always;
```
- **可排除 `add_header`**：它只作用于响应，而故障发生在「读上游响应头」
  之前的请求阶段，响应头改不出 NOT_FOUND。
- **嫌疑在 `listen ... quic reuseport`**，但「一个 UDP 监听为何会打死同一个
  server 块里 TCP 8003 的请求路径」这条因果链**没有推出来**。
- 用户要求立即修复，未做「只加 listen / 只加 add_header」的二次二分。

## 修法：绕开而非修补
既然机制未明，就不去修那一行，改成**生产路径一个字符都不动**：
`extensions/quic-h3/02-server-config.sh` 由「往 CDN 块插 2 行」改为
「往 http{} 末尾追加一个独立 server 块」（自带 server_name / 证书 /
location ${XHTTP_PATH} / location / → 404）。故障就无从发生，与机制无关。

配套：
- 默认端口 UDP 443 → **8445**（远离 Reality 的 TCP 443；8443=Hy2、8444=h3-direct）。
- 新增通用端口占用检查（`ss -uln`）——原检查只认独立 hysteria 二进制的
  配置文件，而 v4.0.0 起 Hy2/h3-direct 都由 Xray 监听，查不到。
- `PROJECT_VERSION` 4.4.0 → 4.4.1。
- `docs/8.拓展-QUIC添加.md` 加勘误 + 替换手工配置片段。

## 最重要的一条：自检失效
这次故障里 `nginx -t` **通过**、`systemctl is-active` **通过**，扩展照常报成功，
主链路却已经死了。「配置能解析」「进程活着」都不等于「业务还通」。

已在 02-server-config.sh 新增第 ③ 道验证：改动**前**用 curl 对主链路取一次
指纹（带 CDN 域名 SNI 打 8003 上的 XHTTP path，记 HTTP 状态码），改动**后**
再取一次，不一致就自动回滚并重启 nginx。只断言「与改动前一致」、不断言具体值
——写死期望值会在某次 Xray 上游变更后变成假警报。

→ 通用规则：**任何往 nginx.conf 注入配置的扩展，都必须有一条「主链路是否还活着」
的事后校验**。`nginx -t` + `is-active` 是必要不充分条件。

## 仍未做的事
- 「只加 listen / 只加 add_header」的二次二分（能把机制说死）。
- Xray 侧 `journalctl -u xray` 在故障窗口的日志（会直接说明 8001 为何 NOT_FOUND）。
- 新扩展在实机上是否真的能让三条 h3 节点通——**未验证**。修的是「不再打死主链路」，
  不是「h3 节点从此可用」。XHTTP-over-h3 的上游问题（#4391 / #5849）依然在。
