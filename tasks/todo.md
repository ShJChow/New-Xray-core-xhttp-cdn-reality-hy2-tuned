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

## Review

- 最实质的性能修复是 Nginx 的 `grpc_read_timeout` / `grpc_send_timeout`（默认 60s 会周期性切断 XHTTP 长连接），而非内核参数本身。
- "流控最佳全开" 的正确含义不是把每个旋钮拉满：`tcpMptcp`、`scMaxEachPostBytes`、内核替换都被明确排除。
- 全部调优可用 `xh tuning off` 单命令回滚，符合"最易回滚"的选型标准。
