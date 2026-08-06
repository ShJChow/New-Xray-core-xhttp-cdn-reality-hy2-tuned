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
