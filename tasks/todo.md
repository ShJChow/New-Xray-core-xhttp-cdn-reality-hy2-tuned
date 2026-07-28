# v2.0.0 · 回归上游基线，只保留 UDP+XHTTP+CDN 节点

## Goal

1. 节点集 = 上游 `Yulinanami/my-xhttp-cdn-config` 的 5 条，唯一保留的本项目改动是
   把上游那条「纯 CDN，alpn=h2」换成 **UDP + XHTTP + CDN（alpn=h3）**。
2. 删除直连 h3 节点（`Vless-xhttp-tls-UDP-direct`）及其全部支撑代码。
3. 安装期**不做任何参数优化**：渲染出的 `xray-config.json` 与上游逐字节一致；
   `nginx.conf` 只保留「正确性」改动，吞吐旋钮全部回退。
4. 全部系统层优化收进 `xh tuning on/off`，安装流程不再触碰宿主机全局状态。
5. 节点名保持英文。
6. 简化安装步骤：8 步 → 7 步（移除「网络与流控调优」）。

## Current State

- `src/06-net-tuning.sh` 在安装期写 sysctl / limits / systemd drop-in，并向
  `xray-config.json` 注入 `policy.bufferSize` 与 `sockopt`。
- `FEATURE_TUNING`（默认 true）、`FEATURE_SYSCTL`（默认 false）、
  `FEATURE_H3_DIRECT`（默认 false）三个开关交织。
- `templates/mihomo-proxies.yaml.tmpl` 与 `src/11-client-config.sh` 里的 xmux
  被硬编码为 `32-64` / `3600-6000`，h3 节点 `64-128`——**不受任何开关控制**。
- `templates/nginx.conf.tmpl` 混合了吞吐旋钮与正确性修复。

## Assumptions

- A1「只保留 udp+xhttp+cdn 那个节点」= 只保留**这一条本项目特有的节点**，
  其余回归上游；不是「整个订阅只有一条节点」（否则「其它的节点」无所指）。
- A2「参数优化都不要做」指安装期默认不做；`xh tuning` 手动开启仍保留。
- A3 nginx 的 `grpc_read_timeout/send_timeout/socket_keepalive` 与
  `resolver ipv6=off/ipv4=off` 属于**正确性**而非调优（前者对应 L11 记录的
  60 秒断流，后者对应纯 v4 机器 `Network is unreachable`），不回退。
- A4 `user root` + `STATIC_SITE_DIR=${USER_HOME}/dist` 是成对的选择，一起保留
  （上游 `user nobody` 读不了 `/root/dist`）。

## Change Scope

| 文件 | 改动 |
|---|---|
| `src/01-env.sh` | 删 `FEATURE_TUNING` / `FEATURE_SYSCTL` / `FEATURE_H3_DIRECT` |
| `src/04-input.sh` | 删调优摘要行 |
| `src/05,07,08,09,10,11,13-*.sh` | 步骤号 `[n/8]` → `[n/7]` |
| `src/06-net-tuning.sh` | 重写为**纯函数库**，不再在安装期执行，由 `xh` 内联 |
| `src/09-server-config.sh` | 删 `NGINX_H3_DIRECT_BLOCK`；`node.env` 删调优字段 |
| `src/10-service-check.sh` | 删 h3 自动降级分支 |
| `src/11-client-config.sh` | 删直连 h3 节点；xmux 回退 `16-32`/`1800-3000`；删 `XMUX_H3_ENC` |
| `src/13-manage-cli.sh` | `xh tuning on` 真正执行调优；删 h3 相关诊断 |
| `templates/xray-config.json.tmpl` | 回退到与上游逐字节一致 |
| `templates/nginx.conf.tmpl` | 回退吞吐旋钮，保留 A3 两项 |
| `templates/mihomo-proxies.yaml.tmpl` | xmux 回退；删 `MIHOMO_UDP_DIRECT_BLOCK` |
| `.github/scripts/build-install.sh` | `MODULES` 移除 `06-net-tuning.sh` |
| `README.md` / `docs/` | 同步 |

## Verification

- V1 `bash -n` 全部 `dist/*.sh` 与 `src/*.sh`。
- V2 离线渲染 `xray-config.json`：与上游同 env 渲染结果 **`diff` 为空**。
- V3 离线渲染 `client-config.txt`：5 行；第 1/2/4/5 行与上游对应行仅节点名不同；
  第 3 行与上游「纯 CDN」行仅 `alpn=h2`→`h3` 与节点名不同。
- V4 xmux 交叉断言（L19）：URI 与 mihomo YAML 中所有 `max-concurrency` 均为
  `16-32`、`h-max-reusable-secs` 均为 `1800-3000`，`64-128` / `32-64` / `3600-6000`
  出现次数为 0。
- V5 两个 profile（normal / xpadding）各跑一遍 V2–V4（L18）。
- V6 `grep -c 'UDP-direct' dist/` == 0；`NODE_RE_*` 引用的节点名全部仍存在（L10）。
- V7 未验证项（L8）：证书签发、`xray -test`、nginx 实际启动、链路连通性——本机无法验证。

---

## Review

全部 Change Scope 项已完成。验证结果：

| 项 | 结果 |
|---|---|
| V1 `bash -n` dist/ + src/ + extensions/ | ✅ 全部通过 |
| V2 `xray-config.json` 与上游逐字节对比 | ✅ normal / xpadding **均 IDENTICAL** |
| V3 `client-config.txt` 5 条节点 | ✅ 节点 1/2/3/5 正文与上游**完全一致**，仅节点名不同；节点 4 唯一差异是 `alpn=h2→h3` |
| V4 xmux 交叉断言（URI + mihomo YAML） | ✅ `64-128` / `32-64` / `3600-6000` 出现 0 次；6 处 `16-32`、6 处 `1800-3000` |
| V5 两个 profile 各跑一遍 | ✅ 均通过 |
| V6 `UDP-direct` / `FEATURE_*` 残留 | ✅ dist 中均为 0；5 个 `NODE_RE_*` 目标节点名全部仍存在 |
| nginx.conf 与上游差异 | ✅ 仅 3 处：`user root`（配 `$USER_HOME/dist` 静态目录）、`resolver` 协议族、`grpc_*` 超时 |
| xh 内联调优 | ✅ `bash -n` 通过，`apply_system_tuning` 已内联进 heredoc（引号 heredoc，`$` 不被展开） |

### V7 未验证项（本机无法验证，L8）

- 证书签发（acme.sh）、`xray -test`、nginx 实际启动、服务保活
- `xh tuning on` 在真实 Linux 上的逐项 sysctl 写入结果
- 「所有版本都很卡」是否因本次回退而缓解——**这是一个假设，不是结论**。
  本项目安装完即退出，链路上跑的是 Xray-core / nginx / 内核，本次改动的作用路径
  是「安装期写进去的那些数值」。若回退后仍卡，说明根因在链路侧（晚高峰拥塞、
  CDN 线路），与本仓库无关，可用同机同时刻的 CDN vs 直连节点对比来定位。
