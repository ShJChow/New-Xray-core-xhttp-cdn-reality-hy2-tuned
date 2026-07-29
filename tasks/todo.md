# v2.0.1 · 外部优化建议的分类落实

## Goal

把一份外部审查提出的 7 条优化建议，按 L25 的判据（**不做会坏** vs **不做只是慢一点**）
逐条裁决，只落实经得起核对的部分，并在提交说明里写清每条的取舍理由。

## Current State

v2.0.0（03a26b7 + 5dfc54a）刚确立了两条基线，本次不得无声推翻：

1. **安装期不做任何参数优化**——`src/06-tuning-lib.sh` 已不是安装模块，
   内联进 `xh`，只在用户显式 `xh tuning on` 时执行。
2. `templates/nginx.conf.tmpl` 已按作用机制回退过一次：
   `worker_connections 65535` / `use epoll` / `multi_accept` / `worker_rlimit_nofile`
   正是 03a26b7 明确回退掉的那批。

于是建议 #1–#3 落在 **opt-in 的调优模块内**（不触碰基线 1，改的只是用户显式开启后的取值），
而 #4/#5/#7 落在**安装期无条件渲染**的 nginx 模板里（与基线 2 正面冲突，需单独判定）。

## Assumptions

- A1 `dist/` 未被 git 追踪（`.gitignore` 含 `dist/`），产物由 CI 的
  `.github/scripts/build-install.sh` 构建；本地重建仅用于验证，不入库。
- A2 `xh tuning off` 是整文件 `rm -f "$SYSCTL_CONF"`（13-manage-cli.sh:422），
  新增 sysctl key 无需另行登记回滚项。
- A3 `LimitNOFILE=1048576` 只在 `xh tuning on` 时写入 systemd drop-in
  （06-tuning-lib.sh:159）；**默认安装的 nginx 走 unit 默认句柄上限**。
- A4 nginx `gzip` 是 HTTP 输出过滤器，默认 `gzip_types` 仅 `text/html`；
  XHTTP 走 `grpc_pass`，响应 `content-type: application/grpc`，不进压缩路径。
- A5 `user root` 与 `STATIC_SITE_DIR=${USER_HOME}/dist` 是成对选择（见 v2.0.0 的 A4），
  上游 `user nobody` 读不了 `/root/dist`。

## 逐条裁决

| # | 建议 | 裁决 | 理由 |
|---|------|------|------|
| 1 | `tcp_notsent_lowat` 131072 → 16384 | **采纳，改写理由** | 取值可取（16KB 是通行值），但原文机制说反了：调小是**减少**本地套接字排队、降低 HoL 延迟，而非"吞吐 +20~40%"。按能证实的写（L23）。 |
| 2 | `tcp_rmem/wmem` 中间值 → 262144 | **采纳，两项都改** | 原文只点了 rmem 的 87380；`tcp_wmem` 中间值 65536 同样偏小。措辞限定为"**初始**默认值，autotuning 会向 max 增长"，收益在连接启动与短流。 |
| 3 | 新增 `tcp_adv_win_scale = -2` | **采纳但降级表述** | `try_sysctl` 天然 best-effort；新内核语义已重排且 `tcp_moderate_rcvbuf` 覆盖多数场景，注释不断言收益。 |
| 4 | `worker_connections` 1024 → 65535 | **采纳（推翻 v2.0.0 该项）** | 能指名故障现象——并发 XHTTP 长连接触顶 → 502，按 L25 属正确性而非提速。**但"一行改动"是错的**：须同时加 `worker_rlimit_nofile`，否则 nginx 报 `worker_connections exceed open file resource limit`。 |
| 5 | 限制 `gzip_types` / `gzip_proxied off` | **驳回** | 前提不成立，见 A4：代理密文根本没进压缩路径。 |
| 6 | 回落站 `proxy_pass` 缺超时 | **采纳** | 慢响应伪装源会按默认 60s 占住 worker，是可指名的故障现象。 |
| 7 | nginx 降权非 root | **驳回（非本次推迟）** | 见 A5，与静态站目录成对；改动须连带 `/etc/ssl/private/*`、日志、pid 权限，本机无法验证，且 L14 已记录 `nginx -t` 抓不到启动期失败。 |

## Change Scope

| 文件 | 改动 |
|---|---|
| `src/06-tuning-lib.sh` | L83/84 rmem/wmem 中间值；L109 notsent_lowat；新增 adv_win_scale |
| `templates/nginx.conf.tmpl` | 新增 `worker_rlimit_nofile`；events 块 `worker_connections`（不加 `use epoll` / `multi_accept`，理由见 Review） |
| `src/09-server-config.sh` | `nginx_fallback_config()` 补 proxy 超时三项 |
| `tasks/lessons.md` | 新增 L27 / L28 |

## Verification

- V1 `grep '\$' templates/nginx.conf.tmpl | grep -v '\\\$'` —— L2 未转义变量复查
- V2 本地跑 `.github/scripts/build-install.sh`，`bash -n` 覆盖 `dist/ + src/ + extensions/`
- V3 渲染 `nginx.conf` 改动前后 diff，断言变更集恰好等于声明范围
- V4 断言 `xray-config.json` 渲染结果本次**未被触碰**
- V5 未验证项（L8）：真实内核上的 sysctl 逐项写入结果、nginx 实际启动、链路吞吐

---

## Review

全部 Change Scope 项已完成。7 条建议中采纳 4 条（#1/#2/#3/#6）、
部分采纳 1 条（#4，去掉其中的 epoll/multi_accept）、驳回 2 条（#5/#7）。

| 项 | 结果 |
|---|---|
| V1 L2 未转义变量复查 | ✅ 剩余 `$` 全是有意的 `${VAR}` shell 插值；新增行不含任何 `$` |
| V2 build + `bash -n`（dist/ + src/ + extensions/） | ✅ 全部通过 |
| V3 渲染 nginx.conf 前后 diff | ✅ 变更集**恰好等于**声明范围：worker_rlimit_nofile / worker_connections / 两处 proxy 超时；`$host` 等 nginx 变量渲染正常 |
| V4 xray-config.json 与客户端节点 | ✅ 零改动，与上游仍逐字节一致 |
| 调优值内联进 `xh` | ✅ dist/install.sh:2580/2581/2585/2613 |
| 旧值残留（131072 / 87380 / worker_connections 1024） | ✅ 0 |

### #4 的取舍

采纳 `worker_connections 65535`（能指名 502，L25 判为正确性），
**同时**新增 `worker_rlimit_nofile 65535`——原建议称一行改动是错的，见 L28。
不采纳 `use epoll`（Linux 上 nginx 本就自动选择该事件模型，写出来是冗余）与
`multi_accept on`（纯吞吐旋钮，指不出故障现象，按 L25 应留在回退侧）。

### 复审后的三处修正（同一批工作，878f033 之后补提交）

1. `worker_rlimit_nofile` 65535 → **131072**。本项目所有连接都是代理
   （`grpc_pass` / `proxy_pass`），每条同时占「客户端 + 上游」两个描述符，
   1:1 会在半数连接处触顶——即原先的注释断言的配对关系其实并不成立。
2. 回落站超时 5s/10s/10s → **10s/30s/30s**。回落站的用途就是让主动探测看到
   真实站点内容，超时提前返 504 而真站返正文，本身是指纹差异；而拖满连接池
   需要有人刻意冲刷。收得过紧是拿更重要的一侧去换更轻的一侧。
3. 文档同步（L10：有东西在按字符串找这些值）。`docs/10.流控调优.md` 表格里
   `87380` / `65536` / `131072` 三处硬编码旧值已更新并补 `tcp_adv_win_scale` 行；
   `docs/2.文件配置.md` 的 nginx 示例同步。
   `tools/perf-audit.sh` 经查只列 key 名、不硬编码期望值（L123/L330），不受影响。

另在模板里写明 `worker_connections 65535` 的内存代价（连接槽预分配，
约 15~20 MB/worker × worker_processes），上游的 1024 不只是偷懒。

### V5 未验证项（本机无法执行，L8）

- `xh tuning on` 在真实内核上的逐项 sysctl 写入结果（`tcp_adv_win_scale -2` 在
  新内核上可能被 SKIPPED，这是预期行为）
- nginx 实际启动（L14：`nginx -t` 抓不到启动期失败）
- 上述参数对实际吞吐/延迟的影响——**未测量**。#1/#2/#3 属于 opt-in 路径下的
  取值调整，收益是推断而非实测。
